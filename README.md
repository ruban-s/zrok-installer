# zrok-installer

One-command installer for self-hosted [zrok](https://zrok.io) instances. Deploys a complete zero-trust sharing platform via Docker Compose or bare metal. Works on cloud servers, local machines, and VMs.

## Quick Start

### One-liner (interactive)

```bash
curl -sSf https://raw.githubusercontent.com/ruban-s/zrok-installer/main/install-zrok.sh | sudo bash
```

### Or download and run

**1. Download**

```bash
curl -O https://raw.githubusercontent.com/ruban-s/zrok-installer/main/install-zrok.sh
```

**2. Make executable**

```bash
chmod +x install-zrok.sh
```

**3. Run**

```bash
sudo bash install-zrok.sh
```

## Deployment Environments

The installer asks where you're running and adapts accordingly:

| Environment | IP Type | DNS Updates | Port Forwarding |
| --- | --- | --- | --- |
| Cloud / VPS | Static public IP | Manual (one-time) | Not needed |
| Local — dynamic IP | Changes (ISP assigns) | Automatic via DDNS | Required |
| Local — static IP | Fixed (from ISP) | Manual (one-time) | Required |

### Cloud / VPS

Standard deployment. Point DNS to your server's IP and run the installer.

```bash
# On your VPS
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "your-token" \
  --env cloud --yes
```

### Local Machine — Dynamic IP

For home servers or dev machines where your ISP changes your IP. The installer automatically sets up Dynamic DNS (Cloudflare) to keep your domain pointed at your current IP.

```bash
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "your-token" \
  --env local-dynamic --yes
```

What happens:

1. zrok installs normally
2. `ddns-update.sh` is downloaded and configured
3. A cron job (Linux) or launchd job (macOS) checks your IP every 5 minutes
4. If IP changes, Cloudflare DNS records update automatically
5. Port forwarding instructions are printed

### Local Machine — Static IP

For machines with a fixed public IP from your ISP. No DDNS needed, but port forwarding is still required.

```bash
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "your-token" \
  --env local-static --yes
```

The installer detects your public IP and prints the DNS records to create.

### Port Forwarding (Local Deployments)

For any local deployment, forward these ports from your router to your machine:

| Port | Service | Protocol |
| --- | --- | --- |
| 443 | HTTPS (TLS) | TCP |
| 8080 | zrok frontend | TCP |
| 18080 | zrok API | TCP |
| 3022 | OpenZiti | TCP |

## Dynamic DNS Updater

Included as a standalone script for local deployments with dynamic IPs.

### Automatic Setup

When you choose "Local — dynamic IP" during installation, DDNS is configured automatically using your Cloudflare token.

### Manual Setup

```bash
# Download
curl -O https://raw.githubusercontent.com/ruban-s/zrok-installer/main/ddns-update.sh
chmod +x ddns-update.sh

# Interactive setup (prompts for domain, token, interval)
bash ddns-update.sh --setup

# Check status
bash ddns-update.sh --status

# Force update now
bash ddns-update.sh --run

# Remove scheduled job
bash ddns-update.sh --remove
```

### How It Works

```
Your router's public IP changes (e.g., 49.207.x.x → 103.42.x.x)
         ↓
Cron/launchd runs ddns-update.sh every 5 min
         ↓
Detects new IP via ifconfig.me / api.ipify.org
         ↓
Compares with last known IP
         ↓
IP changed → Cloudflare API → updates A records:
  share.example.com    → new IP
  *.share.example.com  → new IP
```

### Requirements

- Cloudflare DNS (for automatic DDNS)
- API token with **Zone:Read** and **DNS:Edit** permissions
- `curl` and `jq` installed

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
| --- | --- |
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
| --- | --- | --- |
| Caddy (auto-TLS) | ✓ | ✓ |
| Traefik | ✓ | ✓ |
| Nginx + Certbot | — | ✓ |

## DNS Providers

Cloudflare · DigitalOcean · Route53 (AWS) · GoDaddy · Namecheap

API tokens are validated during setup before proceeding with installation.

## Optional Modules

Enable with flags:

| Module | Flag | What it adds |
| --- | --- | --- |
| OAuth | `--with-oauth` | GitHub/Google authentication for shares |
| Metrics | `--with-metrics` | RabbitMQ + InfluxDB usage tracking |
| Limits | `--with-limits` | Bandwidth and resource limits |
| Organizations | `--with-organizations` | Multi-tenant organization support |

## All Options

```text
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
  --env ENV              Deployment environment: cloud | local-dynamic | local-static

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

# Cloud VPS + Docker + Caddy
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "cf-token" \
  --env cloud --yes

# Local home server + dynamic IP + DDNS
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode docker --tls caddy \
  --dns-provider cloudflare --dns-token "cf-token" \
  --env local-dynamic --yes

# Bare metal + Nginx + all modules
sudo bash install-zrok.sh \
  --domain share.example.com \
  --email admin@example.com \
  --mode baremetal --tls nginx \
  --dns-provider route53 --dns-token "aws-key:aws-secret" \
  --with-oauth --with-metrics --with-limits --with-organizations \
  --env cloud --yes

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

### Cloud / Static IP

Create these DNS records pointing to your server (set to **DNS only**, not proxied):

```text
  share.example.com  →  A  →  <server-ip>
*.share.example.com  →  A  →  <server-ip>
```

### Local / Dynamic IP

DNS is managed automatically by the DDNS updater. No manual setup needed — the installer handles everything.

## After Installation

The installer prints connection details. Clients connect with:

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

**Dynamic DNS:**

```bash
bash ddns-update.sh --status     # check current state
bash ddns-update.sh --run        # force update now
bash ddns-update.sh --remove     # stop auto-updates
```

## Files

```text
zrok-installer/
├── install-zrok.sh    # Main installer (cloud + local, Docker + bare metal)
├── ddns-update.sh     # Dynamic DNS updater (Cloudflare, standalone)
├── README.md
└── LICENSE
```

## License

MIT
