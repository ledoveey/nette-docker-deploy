#!/bin/bash

# Exit immediately if a command exits with a non-zero status, catch unbound vars, track pipe errors
set -euo pipefail

echo "=== Automated Nette Web Deployment ==="

# === DEPENDENCY CHECK & AUTO-INSTALL ===
REQUIRED_DEPS=("curl" "jq" "openssl" "git" "docker")
MISSING_DEPS=()

for dep in "${REQUIRED_DEPS[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "Missing dependencies: ${MISSING_DEPS[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        echo "Attempting automatic installation via apt-get..."
        if [ "$EUID" -ne 0 ]; then
            sudo apt-get update && sudo apt-get install -y "${MISSING_DEPS[@]}"
        else
            apt-get update && apt-get install -y "${MISSING_DEPS[@]}"
        fi
    else
        echo "Error: Automated installation is only supported on Debian/Ubuntu (apt-get)."
        echo "Please install missing packages manually: ${MISSING_DEPS[*]}"
        exit 1
    fi
fi

# === CONFIGURATION MANAGEMENT (NPM + CLOUDFLARE) ===
CONFIG_FILE="$HOME/.npm_config"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

if [ -z "${NPM_URL:-}" ] || [ -z "${NPM_EMAIL:-}" ] || [ -z "${NPM_PASSWORD:-}" ] || [ -z "${NPM_SERVICE_TARGET:-}" ] || [ -z "${DOCKER_NETWORK:-}" ] || [ -z "${CF_ACCOUNT_ID:-}" ] || [ -z "${CF_TUNNEL_ID:-}" ] || [ -z "${CF_TOKEN:-}" ]; then
    echo "Configuration incomplete. Enter required credentials (will be saved to $CONFIG_FILE):"

    if [ -z "${NPM_URL:-}" ]; then
        read -p "Nginx Proxy Manager Admin URL [http://localhost:81]: " NEW_NPM_URL
        NPM_URL="${NEW_NPM_URL:-http://localhost:81}"
    fi
    if [ -z "${NPM_EMAIL:-}" ]; then
        read -p "NPM login email: " NPM_EMAIL
    fi
    if [ -z "${NPM_PASSWORD:-}" ]; then
        read -sp "NPM password: " NPM_PASSWORD
        echo ""
    fi
    if [ -z "${NPM_SERVICE_TARGET:-}" ]; then
        read -p "NPM container service target for CF Tunnel [http://nginx-proxy-manager:80]: " NEW_NPM_SERVICE
        NPM_SERVICE_TARGET="${NEW_NPM_SERVICE:-http://nginx-proxy-manager:80}"
    fi
    if [ -z "${DOCKER_NETWORK:-}" ]; then
        read -p "Shared Docker network name [web_network]: " NEW_DOCKER_NETWORK
        DOCKER_NETWORK="${NEW_DOCKER_NETWORK:-web_network}"
    fi

    echo "--- Cloudflare Zero Trust Configuration ---"
    if [ -z "${CF_ACCOUNT_ID:-}" ]; then
        read -p "Cloudflare Account ID: " CF_ACCOUNT_ID
    fi
    if [ -z "${CF_TUNNEL_ID:-}" ]; then
        read -p "Cloudflare Tunnel ID: " CF_TUNNEL_ID
    fi
    if [ -z "${CF_TOKEN:-}" ]; then
        read -sp "Cloudflare API Token: " CF_TOKEN
        echo ""
    fi

    cat << EOF > "$CONFIG_FILE"
NPM_URL="$NPM_URL"
NPM_EMAIL="$NPM_EMAIL"
NPM_PASSWORD="$NPM_PASSWORD"
NPM_SERVICE_TARGET="$NPM_SERVICE_TARGET"
DOCKER_NETWORK="$DOCKER_NETWORK"
CF_ACCOUNT_ID="$CF_ACCOUNT_ID"
CF_TUNNEL_ID="$CF_TUNNEL_ID"
CF_TOKEN="$CF_TOKEN"
EOF
    chmod 600 "$CONFIG_FILE"
    echo "Configuration saved."
fi

# === ARGUMENT PARSING / INTERACTIVE PROMPTS ===
PROJECT_NAME="${1:-}"
DOMAIN="${2:-}"
GIT_URL="${3:-}"

if [ -z "$PROJECT_NAME" ]; then read -p "Project name (e.g. sample_app): " PROJECT_NAME; fi
if [ -z "$DOMAIN" ]; then read -p "Domain (e.g. app.example.com): " DOMAIN; fi
if [ -z "$GIT_URL" ]; then read -p "Git repository URL: " GIT_URL; fi

# === CLOUDFLARE ZONE RESOLUTION (API-MATCHED) ===
echo "--> Resolving Cloudflare Zone for $DOMAIN via Cloudflare API..."

CF_ZONES_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50&status=active" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

if [ "$(echo "$CF_ZONES_RESPONSE" | jq -r '.success // false')" != "true" ]; then
    echo "Error: Failed to fetch zones from Cloudflare API."
    echo "Response: $CF_ZONES_RESPONSE"
    exit 1
fi

mapfile -t CF_ZONES < <(echo "$CF_ZONES_RESPONSE" | jq -r '.result[] | "\(.id)|\(.name)"')

CF_ZONE_ID=""
APEX_DOMAIN=""
LONGEST_MATCH=0

for entry in "${CF_ZONES[@]}"; do
    ZONE_ID="${entry%%|*}"
    ZONE_NAME="${entry##*|}"

    if [[ "$DOMAIN" == "$ZONE_NAME" || "$DOMAIN" == *."$ZONE_NAME" ]]; then
        if [ ${#ZONE_NAME} -gt $LONGEST_MATCH ]; then
            LONGEST_MATCH=${#ZONE_NAME}
            CF_ZONE_ID="$ZONE_ID"
            APEX_DOMAIN="$ZONE_NAME"
        fi
    fi
done

if [ -z "$CF_ZONE_ID" ]; then
    echo "Error: No matching Cloudflare zone found for domain '$DOMAIN' in this account."
    exit 1
fi

echo "Zone resolved: $APEX_DOMAIN (Zone ID: $CF_ZONE_ID)"

# === ENVIRONMENT & DOCKER SETUP ===
DB_PASSWORD=$(openssl rand -hex 12)
DB_NAME="${PROJECT_NAME}_db"
DB_USER="${PROJECT_NAME}_user"
WEB_CONTAINER="${PROJECT_NAME}_web"
DB_CONTAINER="${PROJECT_NAME}_db"

BASE_DIR="$HOME/docker/sites/$PROJECT_NAME"

echo "--> Initializing project directory at $BASE_DIR"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# Ensure common external bridge network exists
if ! docker network ls --format '{{.Name}}' | grep -wq "$DOCKER_NETWORK"; then
    echo "--> Creating missing external network: $DOCKER_NETWORK"
    docker network create "$DOCKER_NETWORK"
fi

# 1. Repository Clone
if [ -d "src" ]; then
    echo "--> Directory 'src' already exists, skipping clone."
else
    echo "--> Cloning repository..."
    git clone "$GIT_URL" src
fi

# 2. Dockerfile Generation
echo "--> Generating Dockerfile..."
cat << 'EOF' > Dockerfile
FROM php:8.2-apache

# Use official extension installer for pre-built binaries (supports ARM architectures)
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

RUN install-php-extensions gd pdo_mysql intl zip opcache

RUN a2enmod rewrite

ENV APACHE_DOCUMENT_ROOT /var/www/html/www
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf

COPY php.ini /usr/local/etc/php/conf.d/custom.ini
EOF

# 3. PHP Configuration
echo "--> Generating custom php.ini..."
cat << 'EOF' > php.ini
upload_max_filesize = 100M
post_max_size = 100M
memory_limit = 256M
EOF

# 4. Compose File Generation
echo "--> Generating docker-compose.yml..."
cat << EOF > docker-compose.yml
services:
  web:
    build: .
    container_name: $WEB_CONTAINER
    restart: unless-stopped
    volumes:
      - ./src:/var/www/html
    networks:
      - $DOCKER_NETWORK
    depends_on:
      - db

  db:
    image: mariadb:10.11
    container_name: $DB_CONTAINER
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: $DB_PASSWORD
      MYSQL_DATABASE: $DB_NAME
      MYSQL_USER: $DB_USER
      MYSQL_PASSWORD: $DB_PASSWORD
    volumes:
      - ./db_data:/var/lib/mysql
    networks:
      - $DOCKER_NETWORK

networks:
  $DOCKER_NETWORK:
    external: true
EOF

# 5. Directory Pre-creation & Upload Detection
mkdir -p src/temp src/log

# Detekce složky pro nahrávání souborů podle standardních názvů
UPLOADS_DIR=$(find src/ -type d \( -name "uploads" -o -name "upload" -o -name "storage" -o -name "files" \) 2>/dev/null | head -n 1)
if [ -z "$UPLOADS_DIR" ]; then
    if [ -d "src/www" ]; then
        UPLOADS_DIR="src/www/uploads"
    else
        UPLOADS_DIR="src/uploads"
    fi
    mkdir -p "$UPLOADS_DIR"
fi

# Pokud existuje nebo má vzniknout složka pro miniatury v Nette
if [ -d "src/www" ] && [ ! -d "src/www/webtemp" ]; then
    mkdir -p "src/www/webtemp"
fi

# 6. Nette Configuration & Local.neon Injection
echo "--> Configuring Nette database connection..."

MAIN_NEON_PATH=$(find src/ -type f \( -name "common.neon" -o -name "config.neon" -o -name "services.neon" \) 2>/dev/null | head -n 1)

if [ -n "$MAIN_NEON_PATH" ]; then
    CONFIG_DIR=$(dirname "$MAIN_NEON_PATH")
    LOCAL_NEON_PATH="$CONFIG_DIR/local.neon"

    echo "--> Writing database settings to $LOCAL_NEON_PATH..."
    cat << EOF > "$LOCAL_NEON_PATH"
# Generated automatically by deployment script
database:
    dsn: 'mysql:host=$DB_CONTAINER;dbname=$DB_NAME'
    user: $DB_USER
    password: '$DB_PASSWORD'
EOF

    # Zkontrolujeme, zda NEON už local.neon načítá
    if grep -q "local\.neon" "$MAIN_NEON_PATH"; then
        echo "--> $(basename "$MAIN_NEON_PATH") already includes local.neon."
    else
        echo "--> Inlining includes into $(basename "$MAIN_NEON_PATH")..."
        sed -i '1i includes:\n    - local.neon\n' "$MAIN_NEON_PATH"
    fi
else
    echo "Warning: No standard NEON configuration found (.neon). Creating fallback local.neon in src/config..."
    mkdir -p src/config
    cat << EOF > src/config/local.neon
database:
    dsn: 'mysql:host=$DB_CONTAINER;dbname=$DB_NAME'
    user: $DB_USER
    password: '$DB_PASSWORD'
EOF
fi

# Dodatečná pojistka: Kontrola Bootstrap.php
BOOTSTRAP_PATH=$(find src/ -type f -iname "Bootstrap.php" 2>/dev/null | head -n 1)
if [ -n "$BOOTSTRAP_PATH" ]; then
    if ! grep -q "local\.neon" "$BOOTSTRAP_PATH"; then
        if grep -q "\->addConfig(" "$BOOTSTRAP_PATH"; then
            echo "--> Ensuring local.neon registration in Bootstrap.php..."
            sed -i '/->addConfig(/ { p; s/->addConfig(.*)/->addConfig(__DIR__ . '\''\/..\/config\/local.neon'\'');/; :a; n; ba }' "$BOOTSTRAP_PATH" 2>/dev/null || true
        fi
    fi
fi

# 7. Start Containers
echo "--> Building and starting containers..."
docker compose up -d --build

# 8. Permissions Setup (Inside Container - Clean & Safe: 775 directories, 664 files)
echo "--> Setting permissions for www-data inside container..."
INTERNAL_UPLOADS_PATH="${UPLOADS_DIR#src/}"

TARGET_DIRS=(
    "/var/www/html/temp"
    "/var/www/html/log"
    "/var/www/html/$INTERNAL_UPLOADS_PATH"
    "/var/www/html/www/webtemp"
)

for TARGET in "${TARGET_DIRS[@]}"; do
    if docker compose exec -u 0:0 web test -e "$TARGET" 2>/dev/null; then
        docker compose exec -u 0:0 web chown -R www-data:www-data "$TARGET"
        docker compose exec -u 0:0 web chmod -R u=rwX,g=rwX,o=rX "$TARGET"
    fi
done

# 9. Dependency Resolution
echo "--> Running composer install..."
docker run --rm -v "$(pwd)/src:/app" --entrypoint git composer config --global --add safe.directory /app 2>/dev/null || true
docker run --rm -v "$(pwd)/src:/app" -u "$(id -u):$(id -g)" composer install

# 10. MariaDB Readiness Check
echo "--> Waiting for MariaDB service readiness..."
MAX_TRIES=30
COUNT=0
until docker exec "$DB_CONTAINER" mariadb-admin ping -u "$DB_USER" -p"$DB_PASSWORD" --silent &>/dev/null && \
      docker exec "$DB_CONTAINER" mariadb -u "$DB_USER" -p"$DB_PASSWORD" -e "SELECT 1;" "$DB_NAME" &>/dev/null; do
    sleep 2
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge $MAX_TRIES ]; then
        echo "Error: MariaDB timed out after 60 seconds."
        exit 1
    fi
done
echo "MariaDB is ready."

# 11. Interactive SQL Selection & Import
echo "--> Scanning for SQL files in repository..."
mapfile -t FOUND_SQL_FILES < <(find src/ -type f -name "*.sql" 2>/dev/null)

TARGET_SQL=""
if [ ${#FOUND_SQL_FILES[@]} -gt 0 ]; then
    echo "Found the following SQL files:"
    for i in "${!FOUND_SQL_FILES[@]}"; do
        echo "  [$((i+1))] ${FOUND_SQL_FILES[$i]}"
    done
    echo "  [m] Enter custom path manually"
    echo "  [s] Skip database import"

    read -p "Select an option [1-${#FOUND_SQL_FILES[@]}/m/s]: " SQL_CHOICE

    if [[ "$SQL_CHOICE" =~ ^[0-9]+$ ]] && [ "$SQL_CHOICE" -ge 1 ] && [ "$SQL_CHOICE" -le "${#FOUND_SQL_FILES[@]}" ]; then
        TARGET_SQL="${FOUND_SQL_FILES[$((SQL_CHOICE-1))]}"
    elif [ "$SQL_CHOICE" = "m" ] || [ "$SQL_CHOICE" = "M" ]; then
        read -p "Enter path to SQL file (relative to project root, e.g. src/db/dump.sql): " MANUAL_PATH
        if [ -f "$MANUAL_PATH" ]; then
            TARGET_SQL="$MANUAL_PATH"
        else
            echo "Warning: File '$MANUAL_PATH' not found. Skipping import."
        fi
    else
        echo "Skipping SQL import."
    fi
else
    echo "No .sql files discovered in repository."
    read -p "Would you like to specify a path manually? [y/N]: " MANUAL_CHOICE
    if [ "$MANUAL_CHOICE" = "y" ] || [ "$MANUAL_CHOICE" = "Y" ]; then
        read -p "Enter path to SQL file: " MANUAL_PATH
        if [ -f "$MANUAL_PATH" ]; then
            TARGET_SQL="$MANUAL_PATH"
        else
            echo "Warning: File '$MANUAL_PATH' not found. Skipping import."
        fi
    fi
fi

if [ -n "$TARGET_SQL" ] && [ -f "$TARGET_SQL" ]; then
    echo "--> Preparing and importing $TARGET_SQL..."
    sed -i 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g' "$TARGET_SQL"
    sed -i 's/CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci/CHARSET=utf8mb4/g' "$TARGET_SQL" || true
    sed -i '/DROP DATABASE/d' "$TARGET_SQL"
    sed -i '/CREATE DATABASE/d' "$TARGET_SQL"
    sed -i '/USE `/d' "$TARGET_SQL"

    docker exec -i "$DB_CONTAINER" mariadb -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" < "$TARGET_SQL"
    echo "Database import complete."

    read -p "Delete the imported file ($TARGET_SQL) for security reasons? [y/N]: " DELETE_CHOICE
    if [ "$DELETE_CHOICE" = "y" ] || [ "$DELETE_CHOICE" = "Y" ]; then
        rm -f "$TARGET_SQL"
        echo "File deleted."
    fi
fi

# Clear Nette Cache
rm -rf src/temp/cache

# 12. Nginx Proxy Manager Provisioning
echo "--> Requesting NPM authorization token..."
TOKEN=$(curl -s -X POST "$NPM_URL/api/tokens" \
    -H "Content-Type: application/json" \
    -d "{\"identity\": \"$NPM_EMAIL\", \"secret\": \"$NPM_PASSWORD\"}" | jq -r '.token // empty')

if [ -z "$TOKEN" ]; then
    echo "Error: NPM authentication failed."
    exit 1
fi

echo "--> Registering proxy host in NPM..."
NPM_RESPONSE=$(curl -s -X POST "$NPM_URL/api/nginx/proxy-hosts" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
        \"domain_names\": [\"$DOMAIN\"],
        \"forward_scheme\": \"http\",
        \"forward_host\": \"$WEB_CONTAINER\",
        \"forward_port\": 80,
        \"access_list_id\": 0,
        \"certificate_id\": 0,
        \"ssl_forced\": 0,
        \"caching_enabled\": 0,
        \"block_exploits\": 1,
        \"advanced_config\": \"\",
        \"meta\": {\"letsencrypt_agree\": false},
        \"http2_support\": 1,
        \"hsts_enabled\": 0,
        \"hsts_subdomains\": 0
    }")

PROXY_ID=$(echo "$NPM_RESPONSE" | jq -r '.id // empty')
if [ -n "$PROXY_ID" ]; then
    echo "NPM proxy host created (ID: $PROXY_ID)."
else
    echo "Warning: Proxy host may already exist. NPM response: $NPM_RESPONSE"
fi

# 13. Cloudflare Zero Trust Tunnel Route Update
echo "--> Updating Cloudflare tunnel ingress rules..."
CURRENT_TUNNEL_CONFIG=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json")

INGRESS_RULES=$(echo "$CURRENT_TUNNEL_CONFIG" | jq '.result.config.ingress')

UPDATED_INGRESS=$(echo "$INGRESS_RULES" | jq \
    --arg domain "$DOMAIN" \
    --arg service "$NPM_SERVICE_TARGET" \
    '[ {hostname: $domain, service: $service} ] + [ .[] | select(.hostname != $domain and .service != "http_status:404") ] + [ {"service": "http_status:404"} ]')

CF_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${CF_TUNNEL_ID}/configurations" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"config\": {\"ingress\": $UPDATED_INGRESS}}")

if [ "$(echo "$CF_RESPONSE" | jq -r '.success // false')" = "true" ]; then
    echo "Cloudflare tunnel ingress updated successfully."
else
    echo "Error updating Cloudflare tunnel: $CF_RESPONSE"
    exit 1
fi

# 14. Cloudflare DNS CNAME Record Provisioning
echo "--> Provisioning Cloudflare CNAME record..."
EXISTING_DNS_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${DOMAIN}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty')

DNS_PAYLOAD="{
    \"type\": \"CNAME\",
    \"name\": \"$DOMAIN\",
    \"content\": \"${CF_TUNNEL_ID}.cfargotunnel.com\",
    \"ttl\": 1,
    \"proxied\": true
}"

if [ -n "$EXISTING_DNS_ID" ]; then
    echo "CNAME record exists, updating (ID: $EXISTING_DNS_ID)..."
    CF_DNS_RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${EXISTING_DNS_ID}" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$DNS_PAYLOAD")
else
    echo "Creating new CNAME record..."
    CF_DNS_RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$DNS_PAYLOAD")
fi

if [ "$(echo "$CF_DNS_RESPONSE" | jq -r '.success')" == "true" ]; then
    echo "Cloudflare DNS record configured."
else
    echo "Error updating DNS record: $CF_DNS_RESPONSE"
    exit 1
fi

echo "=========================================="
echo "Deployment successful: $PROJECT_NAME"
echo "Endpoint: https://$DOMAIN"
echo "=========================================="
