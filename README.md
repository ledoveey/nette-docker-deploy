# Automated Nette Web Deployment

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20ARM-lightgrey.svg)]()
[![PHP](https://img.shields.io/badge/PHP-8.2-777bb4.svg)]()
[![Docker](https://img.shields.io/badge/Docker-Enabled-2496ed.svg)]()

A zero-touch Bash deployment script designed for provisioning and deploying [Nette Framework](https://nette.org/) (PHP 8.2) applications inside Docker containers.

It automates the entire lifecycle: repository cloning, PHP environment configuration, database containerization, Nginx Proxy Manager host provisioning, and Cloudflare Zero Trust tunnel routing with managed DNS records.

---

## Architecture Overview

```text
               Internet
                  │
                  ▼
         [Cloudflare Edge]
       (Proxied DNS + CNAME)
                  │
         (Cloudflare Tunnel)
                  │
                  ▼
       [Nginx Proxy Manager]
     (Reverse Proxy & SSL offload)
                  │
        (Docker Bridge Network)
                  │
       ┌──────────┴──────────┐
       ▼                     ▼
[Web: PHP 8.2 Apache]   [DB: MariaDB 10.11]
```

---

## Key Features

- **Dependency Auto-Resolution:** Verifies and auto-installs system prerequisites (`curl`, `jq`, `openssl`, `git`, `docker`) using `apt-get` on Debian/Ubuntu systems.
- **Dynamic Docker Generation:** Generates a lightweight, multi-arch `Dockerfile` utilizing `mlocati/docker-php-extension-installer` (`gd`, `pdo_mysql`, `intl`, `zip`, `opcache`).
- **Nette Auto-Configuration:**
  - Injects database credentials directly into `local.neon`.
  - Automatically links `local.neon` inside `common.neon`/`config.neon` or registers it inside `Bootstrap.php`.
  - Detects storage directories (`temp/`, `log/`, `uploads/`, `webtemp/`) and adjusts permissions (`775` / `664`) for `www-data`.
- **Database Provisioning:**
  - Spins up MariaDB 10.11 with randomized credentials.
  - Implements wait-loops for service readiness before applying changes.
  - Interactive SQL import scanner with automatic collation sanitization (`utf8mb4_0900_ai_ci` to `utf8mb4_unicode_ci`).
- **Nginx Proxy Manager Integration:** Automatically creates HTTP proxy hosts via NPM REST API with exploit blocking and HTTP/2 enabled.
- **Cloudflare Zero Trust & DNS Automation:**
  - Dynamically detects the correct apex zone via Cloudflare API.
  - Updates Cloudflare Tunnel ingress configurations to forward traffic to NPM.
  - Automatically provisions or updates proxied CNAME records.

---

## Prerequisites

- Linux server (Debian/Ubuntu recommended, Raspberry Pi / ARM supported).
- Docker and Docker Compose installed and running.
- A running **Nginx Proxy Manager** instance connected to a shared Docker network (default: `web_network`).
- A **Cloudflare** account with:
  - An active domain/zone added to Cloudflare DNS.
  - A pre-configured Cloudflare Zero Trust Tunnel.
  - An API Token with permissions: `Zone.DNS` (Edit), `Zone.Zone` (Read), and `Account.Cloudflare Tunnel` (Edit).

---

## Quick Start

### 1. Download the Script

You can download `deploy.sh` directly into your working environment:

```bash
curl -fsSL [https://raw.githubusercontent.com/ledoveey/nette-docker-deploy/main/deploy.sh](https://raw.githubusercontent.com/ledoveey/nette-docker-deploy/main/deploy.sh) -o deploy.sh
chmod +x deploy.sh
```

### 2. Run the Deployment

Run interactively to be guided through the deployment prompts:

```bash
./deploy.sh
```

Or provide parameters directly:

```bash
./deploy.sh <project_name> <domain> <git_repo_url>
```

#### Example:

```bash
./deploy.sh my_eshop shop.example.com [https://github.com/example/nette-eshop.git](https://github.com/example/nette-eshop.git)
```

---

## Configuration (`~/.npm_config`)

On its first execution, the script prompts for infrastructure API credentials and stores them securely at `~/.npm_config` with restrictive permissions (`chmod 600`):

```bash
NPM_URL="http://localhost:81"
NPM_EMAIL="admin@example.com"
NPM_PASSWORD="your_password"
NPM_SERVICE_TARGET="http://nginx-proxy-manager:80"
DOCKER_NETWORK="web_network"
CF_ACCOUNT_ID="your_account_id"
CF_TUNNEL_ID="your_tunnel_uuid"
CF_TOKEN="your_cloudflare_api_token"
```

To update your credentials later, edit or remove this file.

---

## Deployed Directory Structure

Projects are isolated under `$HOME/docker/sites/<project_name>`:

```text
$HOME/docker/sites/<project_name>/
├── Dockerfile              # Generated PHP 8.2 Apache image configuration
├── php.ini                 # Upload limits and memory overrides
├── docker-compose.yml      # Service composition (web + db)
├── db_data/                # Persistent MariaDB volume
└── src/                    # Application source code
    ├── app/
    ├── config/
    │   └── local.neon      # Generated database connection settings
    ├── temp/
    ├── log/
    └── www/
```

---

## License

This project is open-source and available under the [MIT License](LICENSE).