# zrok-installer

One-command installer for self-hosted [zrok](https://zrok.io) instances. Deploys a complete zero-trust sharing platform via Docker Compose or bare metal.

## Quick Start

```bash
# Interactive
curl -sSf https://raw.githubusercontent.com/ruban-s/zrok-installer/main/install-zrok.sh | sudo bash

# Or download and run
curl -O https://raw.githubusercontent.com/ruban-s/zrok-installer/main/install-zrok.sh
chmod +x install-zrok.sh
sudo bash install-zrok.sh
```

## Automated Install

```bash
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker \
  --tls caddy \
  --dns-provider cloudflare \
  --dns-token "your-api-token" \
  --yes
```

## Supported Platforms

| Platform | Mode |
|----------|------|
| Ubuntu 20.04 / 22.04 / 24.04 | Docker Compose, Bare Metal |
| Debian 11 / 12 | Docker Compose, Bare Metal |
| CentOS Stream 8 / 9 | Docker Compose, Bare Metal |
| Rocky Linux 8 / 9 | Docker Compose, Bare Metal |
| AlmaLinux 8 / 9 | Docker Compose, Bare Metal |
| Fedora 38–41 | Docker Compose, Bare Metal |
| Amazon Linux 2 / 2023 | Docker Compose, Bare Metal |
| openSUSE Leap 15.x | Docker Compose, Bare Metal |
| macOS (Apple Silicon / Intel) | Docker Compose (via Docker Desktop) |

## TLS Providers

| Provider | Docker | Bare Metal |
|----------|--------|------------|
| Caddy (auto-TLS) | ✓ | ✓ |
| Traefik | ✓ | ✓ |
| Nginx + Certbot | — | ✓ |

## DNS Providers

Cloudflare · DigitalOcean · Route53 (AWS) · GoDaddy · Namecheap

## Optional Modules

Enable with flags:

| Module | Flag | What it adds |
|--------|------|-------------|
| OAuth | `--with-oauth` | GitHub/Google authentication for shares |
| Metrics | `--with-metrics` | RabbitMQ + InfluxDB usage tracking |
| Limits | `--with-limits` | Bandwidth and resource limits |
| Organizations | `--with-organizations` | Multi-tenant organization support |

## All Options

```
REQUIRED (or prompted interactively):
  --domain DOMAIN        DNS zone (e.g., share.example.com)
  --email EMAIL          Admin email address
  --mode MODE            docker | baremetal
  --tls PROVIDER         caddy | traefik | nginx

OPTIONAL:
  --password PASSWORD    Admin password (auto-generated if omitted)
  --dns-provider NAME    cloudflare | digitalocean | route53 | godaddy | namecheap
  --dns-token TOKEN      API token for DNS provider
  --install-dir DIR      Installation directory (default: /opt/zrok-instance)

MODULES:
  --with-oauth           --oauth-github-id ID    --oauth-github-secret SECRET
  --with-metrics         --oauth-google-id ID    --oauth-google-secret SECRET
  --with-limits
  --with-organizations

FLAGS:
  --dry-run              Preview without making changes
  --yes, -y              Skip confirmation prompts
  --uninstall            Remove existing installation
```

## Examples

```bash
# Dry run (preview only)
sudo bash install-zrok.sh --dry-run --domain test.example.com --mode docker --tls caddy

# Docker + Caddy + OAuth
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "cf-token" \
  --with-oauth \
  --oauth-github-id "gh-id" --oauth-github-secret "gh-secret" \
  --yes

# Bare metal + Nginx + all modules
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode baremetal --tls nginx \
  --dns-provider route53 --dns-token "aws-key:aws-secret" \
  --with-oauth --with-metrics --with-limits --with-organizations \
  --yes

# macOS (no sudo needed)
bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --tls caddy \
  --dns-provider cloudflare --dns-token "cf-token"

# Uninstall
sudo bash install-zrok.sh --uninstall
```

## DNS Setup

Before running the installer, create these DNS records pointing to your server:

```
*.share.example.com  →  A  →  <server-ip>
  share.example.com  →  A  →  <server-ip>
```

## After Installation

The installer prints connection details. Customers connect with:

```bash
zrok config set apiEndpoint https://share.example.com
zrok enable <account_token>
zrok share public localhost:8080
```

## Management

**Docker Compose:**
```bash
cd /opt/zrok-instance
docker compose logs -f
docker compose restart
docker compose down
```

**Bare Metal:**
```bash
systemctl status zrok-controller
systemctl status zrok-frontend
journalctl -u zrok-controller -f
```

## License

MIT
