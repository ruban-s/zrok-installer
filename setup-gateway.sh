#!/usr/bin/env bash
#
# zrok Gateway Proxy
# Routes multiple domains to different zrok instances on your local network.
# Run on ONE machine that receives all port-forwarded traffic from your router.
#
# Usage:
#   bash setup-gateway.sh --setup          # interactive setup
#   bash setup-gateway.sh --add            # add a new domain→backend mapping
#   bash setup-gateway.sh --list           # list current routes
#   bash setup-gateway.sh --remove-route   # remove a domain route
#   bash setup-gateway.sh --uninstall      # remove gateway entirely

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_DIR="/etc/zrok-gateway"
readonly ROUTES_FILE="${CONFIG_DIR}/routes.json"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly NGINX_CONFIG_DIR="/etc/nginx/conf.d"

# ============================================================================
# COLORS
# ============================================================================

readonly _RED=$'\033[0;31m'
readonly _GREEN=$'\033[0;32m'
readonly _YELLOW=$'\033[0;33m'
readonly _CYAN=$'\033[0;36m'
readonly _BOLD=$'\033[1m'
readonly _RESET=$'\033[0m'

_c() { if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then printf '%b' "$1"; fi; }

log_info()    { echo -e "$(_c "${_CYAN}")  [INFO]$(_c "${_RESET}") $*"; }
log_warn()    { echo -e "$(_c "${_YELLOW}")  [WARN]$(_c "${_RESET}") $*" >&2; }
log_error()   { echo -e "$(_c "${_RED}") [ERROR]$(_c "${_RESET}") $*" >&2; }
log_success() { echo -e "$(_c "${_GREEN}")    [OK]$(_c "${_RESET}") $*"; }

# ============================================================================
# DETECTION
# ============================================================================

PROXY_ENGINE=""
OS_FAMILY=""
PKG_INSTALL=""

detect_os() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        OS_FAMILY="macos"
        PKG_INSTALL="brew install"
    elif [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "${ID}" in
            ubuntu|debian) OS_FAMILY="debian"; PKG_INSTALL="apt-get install -y -qq" ;;
            centos|rocky|almalinux|fedora|rhel|amzn)
                OS_FAMILY="rhel"
                if command -v dnf &>/dev/null; then
                    PKG_INSTALL="dnf install -y -q"
                else
                    PKG_INSTALL="yum install -y -q"
                fi
                ;;
            opensuse*|sles) OS_FAMILY="suse"; PKG_INSTALL="zypper install -y" ;;
        esac
    fi
}

detect_proxy_engine() {
    if command -v caddy &>/dev/null; then
        PROXY_ENGINE="caddy"
    elif command -v nginx &>/dev/null; then
        PROXY_ENGINE="nginx"
    fi
}

# ============================================================================
# INSTALL PROXY
# ============================================================================

install_proxy() {
    local engine="$1"

    case "${engine}" in
        caddy)
            if command -v caddy &>/dev/null; then
                log_success "Caddy already installed"
                return 0
            fi
            log_info "Installing Caddy..."
            case "${OS_FAMILY}" in
                debian)
                    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https &>/dev/null || true
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                        > /etc/apt/sources.list.d/caddy-stable.list
                    apt-get update -qq &>/dev/null
                    apt-get install -y -qq caddy &>/dev/null
                    ;;
                rhel)
                    ${PKG_INSTALL} 'dnf-command(copr)' &>/dev/null || true
                    dnf copr enable -y @caddy/caddy &>/dev/null || true
                    ${PKG_INSTALL} caddy &>/dev/null
                    ;;
                macos)
                    brew install caddy &>/dev/null
                    ;;
                *)
                    ${PKG_INSTALL} caddy &>/dev/null || {
                        log_error "Could not install Caddy. Install manually: https://caddyserver.com/docs/install"
                        exit 1
                    }
                    ;;
            esac
            log_success "Caddy installed"
            ;;
        nginx)
            if command -v nginx &>/dev/null; then
                log_success "Nginx already installed"
                return 0
            fi
            log_info "Installing Nginx..."
            ${PKG_INSTALL} nginx &>/dev/null || {
                log_error "Could not install Nginx."
                exit 1
            }
            log_success "Nginx installed"
            ;;
    esac
}

# ============================================================================
# ROUTE MANAGEMENT
# ============================================================================

init_routes() {
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${ROUTES_FILE}" ]]; then
        echo '{"routes":[]}' > "${ROUTES_FILE}"
    fi
}

add_route() {
    local domain=""
    local backend_ip=""
    local backend_ports=""

    echo ""
    echo -e "$(_c "${_BOLD}")  Add Domain Route$(_c "${_RESET}")"
    echo ""

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Domain (e.g., share.example.com): "
    read -r domain < /dev/tty

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Backend machine IP (e.g., 192.168.1.20): "
    read -r backend_ip < /dev/tty

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") zrok HTTPS port on backend [443]: "
    read -r backend_ports < /dev/tty
    backend_ports="${backend_ports:-443}"

    if [[ -z "${domain}" ]] || [[ -z "${backend_ip}" ]]; then
        log_error "Domain and backend IP are required."
        return 1
    fi

    # Validate backend is reachable
    if ping -c 1 -W 2 "${backend_ip}" &>/dev/null; then
        log_success "Backend ${backend_ip} is reachable"
    else
        log_warn "Backend ${backend_ip} is not responding to ping"
        echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Continue anyway? [y/N] "
        local answer
        read -r answer < /dev/tty
        if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi

    # Add to routes file
    local tmp
    tmp="$(mktemp)"
    jq --arg d "${domain}" --arg ip "${backend_ip}" --arg p "${backend_ports}" \
        '.routes += [{"domain": $d, "backend_ip": $ip, "backend_port": $p}]' \
        "${ROUTES_FILE}" > "${tmp}" && mv "${tmp}" "${ROUTES_FILE}"

    log_success "Route added: ${domain} → ${backend_ip}:${backend_ports}"
    log_info "Wildcard *.${domain} also routed to same backend"

    regenerate_proxy_config
}

remove_route() {
    list_routes

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Domain to remove: "
    local domain
    read -r domain < /dev/tty

    if [[ -z "${domain}" ]]; then
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    jq --arg d "${domain}" '.routes = [.routes[] | select(.domain != $d)]' \
        "${ROUTES_FILE}" > "${tmp}" && mv "${tmp}" "${ROUTES_FILE}"

    log_success "Route removed: ${domain}"
    regenerate_proxy_config
}

list_routes() {
    if [[ ! -f "${ROUTES_FILE}" ]]; then
        log_info "No routes configured."
        return
    fi

    local count
    count="$(jq '.routes | length' "${ROUTES_FILE}" 2>/dev/null || echo 0)"

    if [[ "${count}" -eq 0 ]]; then
        log_info "No routes configured."
        return
    fi

    echo ""
    echo -e "$(_c "${_BOLD}")  Current Routes$(_c "${_RESET}")"
    echo ""
    printf "  %-35s %-20s %s\n" "DOMAIN" "BACKEND IP" "PORT"
    printf "  %-35s %-20s %s\n" "$(printf '%0.s─' {1..35})" "$(printf '%0.s─' {1..20})" "$(printf '%0.s─' {1..6})"

    jq -r '.routes[] | "  \(.domain)\t\(.backend_ip)\t\(.backend_port)"' "${ROUTES_FILE}" 2>/dev/null | \
        while IFS=$'\t' read -r domain ip port; do
            printf "  %-35s %-20s %s\n" "${domain}" "${ip}" "${port}"
            printf "  %-35s %-20s %s\n" "*.${domain}" "${ip}" "8080"
        done
    echo ""
}

# ============================================================================
# PROXY CONFIG GENERATION
# ============================================================================

regenerate_proxy_config() {
    case "${PROXY_ENGINE}" in
        caddy) generate_caddy_config ;;
        nginx) generate_nginx_config ;;
    esac
}

generate_caddy_config() {
    local config=""

    config+="# zrok Gateway Proxy — auto-generated\n"
    config+="# Do not edit manually. Use: setup-gateway.sh --add / --remove-route\n\n"

    local routes
    routes="$(jq -c '.routes[]' "${ROUTES_FILE}" 2>/dev/null)"

    while IFS= read -r route; do
        [[ -z "${route}" ]] && continue
        local domain backend_ip backend_port
        domain="$(echo "${route}" | jq -r '.domain')"
        backend_ip="$(echo "${route}" | jq -r '.backend_ip')"
        backend_port="$(echo "${route}" | jq -r '.backend_port')"

        config+="${domain} {\n"
        config+="    reverse_proxy ${backend_ip}:${backend_port} {\n"
        config+="        transport http {\n"
        config+="            tls_insecure_skip_verify\n"
        config+="        }\n"
        config+="    }\n"
        config+="}\n\n"

        config+="*.${domain} {\n"
        config+="    reverse_proxy ${backend_ip}:8080\n"
        config+="}\n\n"
    done <<< "${routes}"

    mkdir -p "$(dirname "${CADDY_CONFIG}")"
    echo -e "${config}" > "${CADDY_CONFIG}"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        brew services restart caddy &>/dev/null || caddy reload --config "${CADDY_CONFIG}" &>/dev/null || true
    else
        systemctl reload caddy &>/dev/null || systemctl restart caddy &>/dev/null || true
    fi

    log_success "Caddy config regenerated and reloaded"
}

generate_nginx_config() {
    local routes
    routes="$(jq -c '.routes[]' "${ROUTES_FILE}" 2>/dev/null)"

    # Clear old zrok gateway configs
    rm -f "${NGINX_CONFIG_DIR}"/zrok-gw-*.conf 2>/dev/null

    while IFS= read -r route; do
        [[ -z "${route}" ]] && continue
        local domain backend_ip backend_port
        domain="$(echo "${route}" | jq -r '.domain')"
        backend_ip="$(echo "${route}" | jq -r '.backend_ip')"
        backend_port="$(echo "${route}" | jq -r '.backend_port')"

        local safe_domain="${domain//\./-}"

        cat > "${NGINX_CONFIG_DIR}/zrok-gw-${safe_domain}.conf" << NGXEOF
# zrok Gateway — ${domain}
server {
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    location / {
        proxy_pass https://${backend_ip}:${backend_port};
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    server_name *.${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

    location / {
        proxy_pass http://${backend_ip}:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGXEOF
    done <<< "${routes}"

    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null || {
        log_warn "Nginx config test failed. Check: nginx -t"
    }

    log_success "Nginx configs regenerated and reloaded"
}

# ============================================================================
# SETUP
# ============================================================================

do_setup() {
    echo ""
    echo -e "$(_c "${_BOLD}${_CYAN}")  zrok Gateway Proxy — Setup$(_c "${_RESET}")"
    echo ""
    echo -e "  Routes multiple domains to different zrok instances"
    echo -e "  on your local network through a single public IP."
    echo ""
    echo -e "  $(_c "${_BOLD}")Network Layout:$(_c "${_RESET}")"
    echo ""
    echo "    Internet"
    echo "       ↓"
    echo "    Router (:443, :8080, :18080, :3022)"
    echo "       ↓  port forward all to this machine"
    echo "    Gateway (this machine)"
    echo "       ├── share.example.com   → 192.168.1.20"
    echo "       ├── share.company.com   → 192.168.1.30"
    echo "       └── share.other.com     → 192.168.1.40"
    echo ""

    detect_os

    if [[ "$(id -u)" -ne 0 ]] && [[ "${OS_FAMILY}" != "macos" ]]; then
        log_error "Run as root: sudo bash setup-gateway.sh --setup"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_info "Installing jq..."
        ${PKG_INSTALL} jq &>/dev/null || {
            log_error "Failed to install jq"
            exit 1
        }
    fi

    detect_proxy_engine

    if [[ -z "${PROXY_ENGINE}" ]]; then
        echo -e "  $(_c "${_BOLD}")Select reverse proxy:$(_c "${_RESET}")"
        echo -e "  $(_c "${_BOLD}")1)$(_c "${_RESET}") Caddy (recommended — auto TLS)"
        echo -e "  $(_c "${_BOLD}")2)$(_c "${_RESET}") Nginx (requires manual TLS certs)"
        echo -n "       Choice [1]: "
        local choice
        read -r choice < /dev/tty
        choice="${choice:-1}"

        case "${choice}" in
            1) PROXY_ENGINE="caddy" ;;
            2) PROXY_ENGINE="nginx" ;;
            *) PROXY_ENGINE="caddy" ;;
        esac

        install_proxy "${PROXY_ENGINE}"
    else
        log_success "Using existing ${PROXY_ENGINE}"
    fi

    init_routes

    echo ""
    log_info "Add your first domain route:"
    add_route

    echo ""
    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Add another route? [y/N] "
    local more
    read -r more < /dev/tty
    while [[ "${more}" =~ ^[Yy]$ ]]; do
        add_route
        echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Add another route? [y/N] "
        read -r more < /dev/tty
    done

    echo ""
    log_success "Gateway configured!"
    echo ""
    echo -e "  $(_c "${_BOLD}")Router port forwarding:$(_c "${_RESET}")"
    local gw_ip
    gw_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || ifconfig 2>/dev/null | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}' | head -1 || echo "this-machine")"
    echo -e "    443   → ${gw_ip}  (HTTPS)"
    echo -e "    8080  → ${gw_ip}  (zrok frontends)"
    echo -e "    18080 → ${gw_ip}  (zrok APIs — route per backend if needed)"
    echo -e "    3022  → ${gw_ip}  (OpenZiti — route per backend if needed)"
    echo ""
    echo -e "  $(_c "${_BOLD}")On each backend machine:$(_c "${_RESET}")"
    echo "    Run install-zrok.sh normally (bare metal or Docker)"
    echo "    TLS is handled by this gateway — backends can use HTTP internally"
    echo ""
    echo -e "  $(_c "${_BOLD}")Manage routes:$(_c "${_RESET}")"
    echo "    bash setup-gateway.sh --add           # add domain"
    echo "    bash setup-gateway.sh --list          # list routes"
    echo "    bash setup-gateway.sh --remove-route  # remove domain"
    echo ""
}

do_uninstall() {
    echo ""
    log_warn "This will remove the gateway proxy configuration."
    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Remove zrok gateway? [y/N] "
    local answer
    read -r answer < /dev/tty
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        exit 0
    fi

    rm -rf "${CONFIG_DIR}"
    rm -f "${NGINX_CONFIG_DIR}"/zrok-gw-*.conf 2>/dev/null
    nginx -t &>/dev/null && systemctl reload nginx &>/dev/null 2>&1 || true

    if [[ -f "${CADDY_CONFIG}" ]]; then
        echo "# Gateway removed" > "${CADDY_CONFIG}"
        systemctl reload caddy &>/dev/null 2>&1 || true
    fi

    log_success "Gateway removed"
}

# ============================================================================
# HELP
# ============================================================================

show_help() {
    cat << 'HELP'
zrok Gateway Proxy

Routes multiple zrok domains to different machines on your local network
through a single public IP and port-forwarded router.

USAGE:
  sudo bash setup-gateway.sh --setup          # interactive first-time setup
  sudo bash setup-gateway.sh --add            # add a new domain→backend route
  sudo bash setup-gateway.sh --list           # list current routes
  sudo bash setup-gateway.sh --remove-route   # remove a domain route
  sudo bash setup-gateway.sh --uninstall      # remove gateway entirely
  sudo bash setup-gateway.sh --help           # show this help

NETWORK LAYOUT:
  Internet → Router → Gateway (this machine) → Backend machines
                         ↓
              share.example.com  → 192.168.1.20 (zrok instance 1)
              share.company.com  → 192.168.1.30 (zrok instance 2)
              share.other.com    → 192.168.1.40 (zrok instance 3)

PREREQUISITES:
  - One machine dedicated as gateway (receives all router port forwards)
  - Each backend machine runs its own zrok instance via install-zrok.sh
  - curl, jq installed
  - Root access (Linux) or admin (macOS)

PROXY ENGINES:
  Caddy   — recommended, handles TLS automatically
  Nginx   — requires manual TLS certificate setup
HELP
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    case "${1:-}" in
        --setup)        do_setup ;;
        --add)
            detect_os; detect_proxy_engine; init_routes
            add_route
            ;;
        --list)
            init_routes
            list_routes
            ;;
        --remove-route)
            detect_os; detect_proxy_engine; init_routes
            remove_route
            ;;
        --uninstall)    do_uninstall ;;
        --help|-h)      show_help ;;
        *)              show_help; exit 1 ;;
    esac
}

main "$@"
