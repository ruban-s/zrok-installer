#!/usr/bin/env bash
#
# zrok Self-Hosted Installer
# Deploys a complete zrok instance via Docker Compose or bare metal Linux/macOS.
# Supports: Ubuntu, Debian, CentOS, Rocky, AlmaLinux, Fedora, Amazon Linux, openSUSE, macOS
#
# Usage:
#   curl -sSf https://your-host.com/install-zrok.sh | sudo bash
#   sudo bash install-zrok.sh --domain share.example.com --mode docker --tls caddy
#   sudo bash install-zrok.sh --uninstall
#   sudo bash install-zrok.sh --dry-run --domain test.example.com
#   bash install-zrok.sh --domain share.example.com --mode docker --tls caddy  # macOS (no sudo needed for Docker Desktop)

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly INSTALLER_VERSION="1.0.0"
readonly DEFAULT_INSTALL_DIR="/opt/zrok-instance"
readonly STATE_FILE_NAME=".install-state.json"
readonly CREDENTIALS_FILE_NAME=".credentials"
readonly ZROK_COMPOSE_BASE_URL="https://get.openziti.io/zrok2-instance"
readonly ZROK_INSTALL_URL="https://get.openziti.io/install.bash"
readonly DOCKER_INSTALL_URL="https://get.docker.com"

readonly REQUIRED_PORTS=(443 18080 8080 3022)
readonly SUPPORTED_TLS_PROVIDERS=("caddy" "traefik" "nginx")
readonly SUPPORTED_DNS_PROVIDERS=("cloudflare" "digitalocean" "route53" "godaddy" "namecheap")
readonly SUPPORTED_MODES=("docker" "baremetal")

# ============================================================================
# GLOBALS (set during execution)
# ============================================================================

ZROK_INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
PLATFORM=""  # linux or macos
IS_MACOS=false
OS_FAMILY=""
OS_ID=""
OS_VERSION=""
OS_PRETTY=""
ARCH=""
PKG_MGR=""
PKG_INSTALL=""
PKG_UPDATE=""
HAS_DOCKER=false
HAS_SYSTEMD=false
SELINUX_ENFORCING=false
FIREWALL_TYPE=""
INTERACTIVE=true
TOTAL_STEPS=0
CURRENT_STEP=0

# User config (set via prompts or CLI flags)
ZROK_DNS_ZONE=""
ZROK_USER_EMAIL=""
ZROK_USER_PWD=""
DEPLOY_MODE=""
TLS_PROVIDER=""
DNS_PROVIDER=""
DNS_TOKEN=""
ENABLE_OAUTH=false
ENABLE_METRICS=false
ENABLE_LIMITS=false
ENABLE_ORGANIZATIONS=false
OAUTH_GITHUB_ID=""
OAUTH_GITHUB_SECRET=""
OAUTH_GOOGLE_ID=""
OAUTH_GOOGLE_SECRET=""
DRY_RUN=false
AUTO_YES=false
DO_UNINSTALL=false
INSTALL_DIR_SET_BY_FLAG=false
DEPLOY_ENV=""  # local or cloud

# Generated secrets
ZITI_PWD=""
ZROK_ADMIN_TOKEN=""
ZROK_OAUTH_HASH_KEY=""
ACCOUNT_TOKEN=""
FRONTEND_IDENTITY=""

# Cleanup tracking
CLEANUP_ACTIONS=()

# ============================================================================
# SECTION B: OUTPUT HELPERS
# ============================================================================

_supports_color() {
    [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]
}

_c() {
    if _supports_color; then
        printf '%b' "$1"
    fi
}

readonly _RED=$'\033[0;31m'
readonly _GREEN=$'\033[0;32m'
readonly _YELLOW=$'\033[0;33m'
readonly _BLUE=$'\033[0;34m'
readonly _CYAN=$'\033[0;36m'
readonly _BOLD=$'\033[1m'
readonly _RESET=$'\033[0m'

log_info()    { echo -e "$(_c "${_BLUE}")  [INFO]$(_c "${_RESET}") $*"; }
log_warn()    { echo -e "$(_c "${_YELLOW}")  [WARN]$(_c "${_RESET}") $*" >&2; }
log_error()   { echo -e "$(_c "${_RED}") [ERROR]$(_c "${_RESET}") $*" >&2; }
log_success() { echo -e "$(_c "${_GREEN}")    [OK]$(_c "${_RESET}") $*"; }

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "$(_c "${_BOLD}${_CYAN}")[${CURRENT_STEP}/${TOTAL_STEPS}]$(_c "${_RESET}") $(_c "${_BOLD}")$*$(_c "${_RESET}")"
}

log_substep() {
    echo -e "       $(_c "${_CYAN}")→$(_c "${_RESET}") $*"
}

confirm() {
    local prompt="${1:-Continue?}"
    if [[ "${AUTO_YES}" == "true" ]]; then
        return 0
    fi
    if [[ "${INTERACTIVE}" == "false" ]]; then
        return 0
    fi
    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") ${prompt} [y/N] "
    local answer
    read -r answer < /dev/tty
    [[ "${answer}" =~ ^[Yy]$ ]]
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local varname="$3"
    local current_val="${!varname:-}"

    if [[ -n "${current_val}" ]]; then
        return 0
    fi

    local display_default=""
    if [[ -n "${default}" ]]; then
        display_default=" [${default}]"
    fi

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") ${prompt}${display_default}: "
    local answer
    read -r answer < /dev/tty
    answer="${answer:-${default}}"

    if [[ -z "${answer}" ]]; then
        log_error "Value required."
        prompt_input "$prompt" "$default" "$varname"
        return
    fi

    eval "${varname}='${answer}'"
}

prompt_secret() {
    local prompt="$1"
    local varname="$2"
    local current_val="${!varname:-}"

    if [[ -n "${current_val}" ]]; then
        return 0
    fi

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") ${prompt}: "
    local answer
    read -rs answer < /dev/tty
    echo ""

    eval "${varname}='${answer}'"
}

prompt_choice() {
    local prompt="$1"
    local varname="$2"
    shift 2
    local options=("$@")
    local current_val="${!varname:-}"

    if [[ -n "${current_val}" ]]; then
        return 0
    fi

    echo -e "\n$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") ${prompt}"
    local i=1
    for opt in "${options[@]}"; do
        echo -e "       $(_c "${_BOLD}")${i})$(_c "${_RESET}") ${opt}"
        i=$((i + 1))
    done

    echo -n "       Choice: "
    local choice
    read -r choice < /dev/tty

    if [[ -z "${choice}" ]] || [[ "${choice}" -lt 1 ]] || [[ "${choice}" -gt ${#options[@]} ]]; then
        log_error "Invalid choice."
        prompt_choice "$prompt" "$varname" "${options[@]}"
        return
    fi

    local selected="${options[$((choice - 1))]}"
    selected="${selected%% *}"
    selected="${selected,,}"
    eval "${varname}='${selected}'"
}

spinner() {
    local pid=$1
    local msg="${2:-Working...}"
    local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    if [[ "${INTERACTIVE}" == "false" ]] || ! [[ -t 1 ]]; then
        wait "${pid}" 2>/dev/null
        return $?
    fi

    while kill -0 "${pid}" 2>/dev/null; do
        printf "\r       %s %s" "${chars:i++%${#chars}:1}" "${msg}"
        sleep 0.1
    done
    printf "\r       %-$((${#msg} + 4))s\r" " "
    wait "${pid}" 2>/dev/null
    return $?
}

print_banner() {
    echo ""
    if _supports_color; then
        echo -e "${_CYAN}${_BOLD}"
    fi
    cat << 'BANNER'
    _____ __ ___ | | __
   |_  / '__/ _ \| |/ /
    / /| | | (_) |   <
   /___|_|  \___/|_|\_\

   Self-Hosted Installer
BANNER
    if _supports_color; then
        echo -e "${_RESET}"
    fi
    echo "   Version ${INSTALLER_VERSION}"
    echo ""
}

print_separator() {
    echo "  ─────────────────────────────────────────────────────"
}

# ============================================================================
# SECTION C: DETECTION
# ============================================================================

detect_os() {
    local kernel
    kernel="$(uname -s)"

    case "${kernel}" in
        Darwin)
            PLATFORM="macos"
            IS_MACOS=true
            OS_FAMILY="macos"
            OS_ID="macos"
            OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo "unknown")"
            OS_PRETTY="macOS ${OS_VERSION}"
            ZROK_INSTALL_DIR="${ZROK_INSTALL_DIR:-${HOME}/zrok-instance}"
            if [[ "${ZROK_INSTALL_DIR}" == "/opt/zrok-instance" ]]; then
                ZROK_INSTALL_DIR="${HOME}/zrok-instance"
            fi
            log_success "OS detected: ${OS_PRETTY}"
            return
            ;;
        Linux)
            PLATFORM="linux"
            ;;
        *)
            log_error "Unsupported platform: ${kernel}"
            exit 1
            ;;
    esac

    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS: /etc/os-release not found."
        log_error "This installer requires a modern Linux distribution or macOS."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"

    case "${OS_ID}" in
        ubuntu|debian)
            OS_FAMILY="debian"
            ;;
        centos|rocky|almalinux|rhel)
            OS_FAMILY="rhel"
            ;;
        fedora)
            OS_FAMILY="rhel"
            ;;
        amzn)
            OS_FAMILY="rhel"
            ;;
        opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            ;;
        *)
            log_error "Unsupported OS: ${OS_ID}"
            log_error "Supported: Ubuntu, Debian, CentOS, Rocky, AlmaLinux, Fedora, Amazon Linux, openSUSE, macOS"
            exit 1
            ;;
    esac

    log_success "OS detected: ${OS_PRETTY} (${OS_FAMILY})"
}

detect_pkg_manager() {
    case "${OS_FAMILY}" in
        macos)
            if command -v brew &>/dev/null; then
                PKG_MGR="brew"
                PKG_INSTALL="brew install"
                PKG_UPDATE="brew update"
            else
                log_warn "Homebrew not found. Installing Homebrew..."
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "[DRY RUN] Would install Homebrew"
                    PKG_MGR="brew"
                    PKG_INSTALL="brew install"
                    PKG_UPDATE="brew update"
                else
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
                        log_error "Homebrew installation failed."
                        log_error "Install manually: https://brew.sh"
                        exit 1
                    }
                    PKG_MGR="brew"
                    PKG_INSTALL="brew install"
                    PKG_UPDATE="brew update"
                fi
            fi
            ;;
        debian)
            PKG_MGR="apt"
            PKG_INSTALL="apt-get install -y -qq"
            PKG_UPDATE="apt-get update -qq"
            ;;
        rhel)
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_INSTALL="dnf install -y -q"
                PKG_UPDATE="dnf makecache -q"
            else
                PKG_MGR="yum"
                PKG_INSTALL="yum install -y -q"
                PKG_UPDATE="yum makecache -q"
            fi
            ;;
        suse)
            PKG_MGR="zypper"
            PKG_INSTALL="zypper install -y --no-confirm"
            PKG_UPDATE="zypper refresh"
            ;;
    esac
    log_success "Package manager: ${PKG_MGR}"
}

detect_arch() {
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7*|armhf)   ARCH="armv7" ;;
        *)
            log_error "Unsupported architecture: ${machine}"
            exit 1
            ;;
    esac
    if [[ "${IS_MACOS}" == "true" ]] && [[ "${ARCH}" == "arm64" ]]; then
        log_success "Architecture: Apple Silicon (${ARCH})"
    else
        log_success "Architecture: ${ARCH} (${machine})"
    fi
}

detect_docker() {
    if command -v docker &>/dev/null; then
        if docker compose version &>/dev/null; then
            if docker info &>/dev/null 2>&1; then
                HAS_DOCKER=true
                local compose_ver
                compose_ver="$(docker compose version --short 2>/dev/null || echo 'unknown')"
                if [[ "${IS_MACOS}" == "true" ]]; then
                    log_success "Docker Desktop detected: compose v${compose_ver}"
                else
                    log_success "Docker detected: compose v${compose_ver}"
                fi
                return
            else
                if [[ "${IS_MACOS}" == "true" ]]; then
                    log_warn "Docker Desktop installed but not running. Start Docker Desktop first."
                else
                    log_warn "Docker installed but daemon not running"
                fi
            fi
        else
            log_warn "Docker found but 'docker compose' plugin missing"
        fi
    fi
    HAS_DOCKER=false
    if [[ "${IS_MACOS}" == "true" ]]; then
        log_info "Docker Desktop not found"
    else
        log_info "Docker not available"
    fi
}

detect_init_system() {
    if [[ "${IS_MACOS}" == "true" ]]; then
        HAS_SYSTEMD=false
        log_success "Init system: launchd (macOS — Docker Compose only)"
        return
    fi
    if [[ -d /run/systemd/system ]] || systemctl --version &>/dev/null 2>&1; then
        HAS_SYSTEMD=true
        log_success "Init system: systemd"
    else
        log_error "systemd not detected. This installer requires systemd (or macOS with Docker)."
        exit 1
    fi
}

detect_selinux() {
    if [[ "${IS_MACOS}" == "true" ]]; then
        return
    fi
    if command -v getenforce &>/dev/null; then
        local status
        status="$(getenforce 2>/dev/null || echo "Disabled")"
        if [[ "${status}" == "Enforcing" ]]; then
            SELINUX_ENFORCING=true
            log_warn "SELinux is enforcing — will configure appropriate contexts"
        else
            log_info "SELinux: ${status}"
        fi
    fi
}

detect_firewall() {
    if [[ "${IS_MACOS}" == "true" ]]; then
        FIREWALL_TYPE="macos"
        local fw_status
        fw_status="$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "")"
        if echo "${fw_status}" | grep -qi "enabled"; then
            log_info "Firewall: macOS Application Firewall (enabled)"
            log_info "Docker Desktop manages its own port forwarding — no manual firewall config needed"
        else
            log_info "Firewall: macOS Application Firewall (disabled)"
        fi
        return
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        FIREWALL_TYPE="ufw"
        log_info "Firewall: ufw (active)"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        FIREWALL_TYPE="firewalld"
        log_info "Firewall: firewalld (running)"
    elif command -v iptables &>/dev/null; then
        FIREWALL_TYPE="iptables"
        log_info "Firewall: iptables"
    else
        FIREWALL_TYPE="none"
        log_info "Firewall: none detected"
    fi
}

check_prerequisites() {
    local missing=()

    for cmd in curl openssl; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [[ "${DEPLOY_MODE}" == "baremetal" ]]; then
        for cmd in tar; do
            if ! command -v "${cmd}" &>/dev/null; then
                missing+=("${cmd}")
            fi
        done
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing missing prerequisites: ${missing[*]}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY RUN] Would install: ${missing[*]}"
            return 0
        fi

        if [[ "${IS_MACOS}" == "true" ]]; then
            for pkg in "${missing[@]}"; do
                brew install "${pkg}" &>/dev/null || {
                    log_error "Failed to install ${pkg} via Homebrew"
                    exit 1
                }
            done
        else
            ${PKG_UPDATE} &>/dev/null || true

            local pkg_names=()
            for cmd in "${missing[@]}"; do
                case "${cmd}" in
                    jq)       pkg_names+=("jq") ;;
                    curl)     pkg_names+=("curl") ;;
                    openssl)  pkg_names+=("openssl") ;;
                    tar)      pkg_names+=("tar") ;;
                    *)        pkg_names+=("${cmd}") ;;
                esac
            done

            ${PKG_INSTALL} "${pkg_names[@]}" &>/dev/null || {
                log_error "Failed to install prerequisites: ${pkg_names[*]}"
                exit 1
            }
        fi
        log_success "Prerequisites installed"
    else
        log_success "All prerequisites available"
    fi
}

check_ports() {
    local ports_to_check=("${REQUIRED_PORTS[@]}")
    local conflicts=()

    if [[ "${IS_MACOS}" == "true" ]]; then
        for port in "${ports_to_check[@]}"; do
            if lsof -iTCP:"${port}" -sTCP:LISTEN -P -n 2>/dev/null | grep -q LISTEN; then
                local proc
                proc="$(lsof -iTCP:"${port}" -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR==2{print $1}' || echo "unknown")"
                conflicts+=("${port} (${proc})")
            fi
        done
    else
        if ! command -v ss &>/dev/null; then
            log_warn "Cannot check ports (ss not available)"
            return 0
        fi
        for port in "${ports_to_check[@]}"; do
            if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                local proc
                proc="$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)"
                conflicts+=("${port} (${proc})")
            fi
        done
    fi

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_warn "Port conflicts detected:"
        for c in "${conflicts[@]}"; do
            log_warn "  Port ${c}"
        done
        if ! confirm "Continue anyway?"; then
            exit 1
        fi
    else
        log_success "Required ports available"
    fi
}

check_dns() {
    local domain="${ZROK_DNS_ZONE}"
    local resolved=false

    if [[ -z "${domain}" ]]; then
        return 0
    fi

    for cmd in dig nslookup host; do
        if command -v "${cmd}" &>/dev/null; then
            case "${cmd}" in
                dig)
                    if dig +short "${domain}" 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+'; then
                        resolved=true
                    fi
                    ;;
                nslookup)
                    if nslookup "${domain}" 2>/dev/null | grep -q "Address:"; then
                        resolved=true
                    fi
                    ;;
                host)
                    if host "${domain}" 2>/dev/null | grep -q "has address"; then
                        resolved=true
                    fi
                    ;;
            esac
            break
        fi
    done

    if [[ "${resolved}" == "true" ]]; then
        log_success "DNS resolves for ${domain}"
    else
        log_warn "DNS does not resolve for ${domain}"
        log_warn "Ensure *.${domain} points to this server's IP before clients connect"
        if ! confirm "Continue without DNS verification?"; then
            exit 1
        fi
    fi
}

install_docker_if_missing() {
    if [[ "${HAS_DOCKER}" == "true" ]]; then
        return 0
    fi

    if [[ "${IS_MACOS}" == "true" ]]; then
        log_info "Docker Desktop not found or not running."

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY RUN] Would prompt to install Docker Desktop"
            HAS_DOCKER=true
            return 0
        fi

        if command -v brew &>/dev/null; then
            if confirm "Install Docker Desktop via Homebrew?"; then
                brew install --cask docker &>/dev/null || {
                    log_error "Failed to install Docker Desktop via Homebrew."
                    log_error "Install manually: https://docs.docker.com/desktop/install/mac-install/"
                    exit 1
                }
                log_info "Docker Desktop installed. Please start it from Applications."
                log_info "After Docker Desktop is running, re-run this script."
                exit 0
            fi
        fi

        log_error "Docker Desktop is required for macOS deployment."
        log_error "Install from: https://docs.docker.com/desktop/install/mac-install/"
        log_error "Start Docker Desktop, then re-run this script."
        exit 1
    fi

    log_info "Docker not found. Installing Docker..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would install Docker via ${DOCKER_INSTALL_URL}"
        HAS_DOCKER=true
        return 0
    fi

    if ! confirm "Install Docker automatically?"; then
        log_error "Docker is required for Docker Compose deployment mode."
        exit 1
    fi

    curl -fsSL "${DOCKER_INSTALL_URL}" | sh || {
        log_error "Docker installation failed."
        log_error "Install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
    }

    systemctl enable --now docker &>/dev/null || true

    if docker compose version &>/dev/null; then
        HAS_DOCKER=true
        log_success "Docker installed and running"
    else
        log_error "Docker installed but 'docker compose' plugin not available."
        log_error "Install the compose plugin: https://docs.docker.com/compose/install/"
        exit 1
    fi
}

detect_existing_install() {
    local state_file="${ZROK_INSTALL_DIR}/${STATE_FILE_NAME}"
    if [[ -f "${state_file}" ]]; then
        log_warn "Existing zrok installation found at ${ZROK_INSTALL_DIR}"
        local prev_mode
        prev_mode="$(jq -r '.mode // "unknown"' "${state_file}" 2>/dev/null || echo "unknown")"
        log_info "Previous deployment mode: ${prev_mode}"

        if [[ "${DO_UNINSTALL}" == "true" ]]; then
            return 0
        fi

        echo ""
        echo -e "  $(_c "${_BOLD}")What would you like to do?$(_c "${_RESET}")"
        echo -e "  $(_c "${_BOLD}")1)$(_c "${_RESET}") Reconfigure (update settings, keep data)"
        echo -e "  $(_c "${_BOLD}")2)$(_c "${_RESET}") Fresh install (remove everything, start over)"
        echo -e "  $(_c "${_BOLD}")3)$(_c "${_RESET}") Cancel"
        echo -n "  Choice: "
        local choice
        read -r choice < /dev/tty

        case "${choice}" in
            1) log_info "Reconfiguring existing installation..." ;;
            2)
                log_warn "This will remove all existing data!"
                if confirm "Are you sure?"; then
                    do_uninstall
                else
                    exit 0
                fi
                ;;
            *) exit 0 ;;
        esac
    fi
}

# ============================================================================
# SECTION D: SECRET GENERATION
# ============================================================================

generate_password() {
    local length="${1:-32}"
    local pw

    if command -v openssl &>/dev/null; then
        pw="$(openssl rand -base64 $((length * 2)) 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c"${length}")"
    fi

    if [[ -z "${pw:-}" ]]; then
        pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c"${length}")"
    fi

    echo "${pw}"
}

generate_all_secrets() {
    [[ -z "${ZITI_PWD}" ]]            && ZITI_PWD="$(generate_password 32)"
    [[ -z "${ZROK_ADMIN_TOKEN}" ]]    && ZROK_ADMIN_TOKEN="$(generate_password 32)"
    [[ -z "${ZROK_OAUTH_HASH_KEY}" ]] && ZROK_OAUTH_HASH_KEY="$(generate_password 48)"
    [[ -z "${ZROK_USER_PWD}" ]]       && ZROK_USER_PWD="$(generate_password 24)"

    log_success "Secrets generated"
}

# ============================================================================
# SECTION E: INTERACTIVE PROMPTS + CLI FLAGS
# ============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)           ZROK_DNS_ZONE="$2"; shift 2 ;;
            --email)            ZROK_USER_EMAIL="$2"; shift 2 ;;
            --password)         ZROK_USER_PWD="$2"; shift 2 ;;
            --mode)             DEPLOY_MODE="$2"; shift 2 ;;
            --tls)              TLS_PROVIDER="$2"; shift 2 ;;
            --dns-provider)     DNS_PROVIDER="$2"; shift 2 ;;
            --dns-token)        DNS_TOKEN="$2"; shift 2 ;;
            --with-oauth)       ENABLE_OAUTH=true; shift ;;
            --with-metrics)     ENABLE_METRICS=true; shift ;;
            --with-limits)      ENABLE_LIMITS=true; shift ;;
            --with-organizations) ENABLE_ORGANIZATIONS=true; shift ;;
            --oauth-github-id)     OAUTH_GITHUB_ID="$2"; shift 2 ;;
            --oauth-github-secret) OAUTH_GITHUB_SECRET="$2"; shift 2 ;;
            --oauth-google-id)     OAUTH_GOOGLE_ID="$2"; shift 2 ;;
            --oauth-google-secret) OAUTH_GOOGLE_SECRET="$2"; shift 2 ;;
            --install-dir)      ZROK_INSTALL_DIR="$2"; INSTALL_DIR_SET_BY_FLAG=true; shift 2 ;;
            --env)              DEPLOY_ENV="$2"; shift 2 ;;
            --uninstall)        DO_UNINSTALL=true; shift ;;
            --dry-run)          DRY_RUN=true; shift ;;
            --yes|-y)           AUTO_YES=true; shift ;;
            --help|-h)          show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    if ! [[ -t 0 ]]; then
        INTERACTIVE=false
    fi
}

show_help() {
    cat << 'HELP'
zrok Self-Hosted Installer

USAGE:
  sudo bash install-zrok.sh [OPTIONS]

REQUIRED (or prompted interactively):
  --domain DOMAIN        DNS zone for zrok (e.g., share.example.com)
  --email EMAIL          Admin email address
  --mode MODE            Deployment mode: docker | baremetal
  --tls PROVIDER         TLS provider: caddy | traefik | nginx

OPTIONAL:
  --password PASSWORD    Admin password (auto-generated if omitted)
  --dns-provider NAME    DNS provider for ACME: cloudflare|digitalocean|route53|godaddy|namecheap
  --dns-token TOKEN      API token for DNS provider
  --install-dir DIR      Installation directory (default: /opt/zrok-instance)
  --env ENV              Deployment environment: cloud | local-dynamic | local-static

MODULES:
  --with-oauth           Enable OAuth authentication (GitHub/Google)
  --with-metrics         Enable metrics pipeline (RabbitMQ + InfluxDB)
  --with-limits          Enable usage limits
  --with-organizations   Enable organizations

OAUTH (requires --with-oauth):
  --oauth-github-id ID
  --oauth-github-secret SECRET
  --oauth-google-id ID
  --oauth-google-secret SECRET

FLAGS:
  --dry-run              Preview what would be done without making changes
  --yes, -y              Skip all confirmation prompts
  --uninstall            Remove existing installation
  --help, -h             Show this help

EXAMPLES:
  # Interactive mode
  sudo bash install-zrok.sh

  # Fully automated Docker + Caddy
  sudo bash install-zrok.sh \
    --domain share.example.com \
    --email admin@example.com \
    --mode docker \
    --tls caddy \
    --dns-provider cloudflare \
    --dns-token "your-api-token" \
    --yes

  # Bare metal with all features
  sudo bash install-zrok.sh \
    --domain share.example.com \
    --email admin@example.com \
    --mode baremetal \
    --tls nginx \
    --with-oauth --with-metrics --with-limits --with-organizations \
    --yes

  # macOS (Docker Desktop, no sudo needed)
  bash install-zrok.sh \
    --domain share.example.com \
    --email admin@example.com \
    --tls caddy \
    --dns-provider cloudflare \
    --dns-token "your-token"
HELP
}

prompt_deploy_environment() {
    if [[ -n "${DEPLOY_ENV}" ]]; then
        return 0
    fi

    if [[ "${AUTO_YES}" == "true" ]] || [[ "${INTERACTIVE}" == "false" ]]; then
        DEPLOY_ENV="cloud"
        return 0
    fi

    echo ""
    echo -e "  $(_c "${_BOLD}")Where is this machine?$(_c "${_RESET}")"
    echo -e "  $(_c "${_BOLD}")1)$(_c "${_RESET}") Cloud / VPS (static public IP)"
    echo -e "  $(_c "${_BOLD}")2)$(_c "${_RESET}") Local machine — dynamic IP (behind router, IP changes)"
    echo -e "  $(_c "${_BOLD}")3)$(_c "${_RESET}") Local machine — static IP (behind router, fixed IP from ISP)"
    echo -n "       Choice [1]: "
    local choice
    read -r choice < /dev/tty
    choice="${choice:-1}"

    case "${choice}" in
        1) DEPLOY_ENV="cloud" ;;
        2) DEPLOY_ENV="local-dynamic" ;;
        3) DEPLOY_ENV="local-static" ;;
        *) DEPLOY_ENV="cloud" ;;
    esac

    case "${DEPLOY_ENV}" in
        local-dynamic)
            echo ""
            log_info "Local (dynamic IP) selected. After installation:"
            log_info "  1. Dynamic DNS will auto-update your IP every 5 min"
            log_info "  2. Port-forward 443, 8080, 18080, 3022 on your router"
            ;;
        local-static)
            echo ""
            local pub_ip
            pub_ip="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
            if [[ -n "${pub_ip}" ]]; then
                log_info "Your public IP: ${pub_ip}"
                log_info "Point DNS records to this IP:"
                log_info "  ${ZROK_DNS_ZONE:-"your-domain"}    → A → ${pub_ip}"
                log_info "  *.${ZROK_DNS_ZONE:-"your-domain"}  → A → ${pub_ip}"
            fi
            log_info "Port-forward 443, 8080, 18080, 3022 on your router"
            ;;
    esac
}

prompt_install_location() {
    if [[ "${INSTALL_DIR_SET_BY_FLAG}" == "true" ]]; then
        return 0
    fi

    if [[ "${AUTO_YES}" == "true" ]] || [[ "${INTERACTIVE}" == "false" ]]; then
        return 0
    fi

    echo ""
    echo -e "  $(_c "${_BOLD}")Where to install?$(_c "${_RESET}")"
    echo -e "  $(_c "${_BOLD}")1)$(_c "${_RESET}") Current directory ($(pwd))"
    echo -e "  $(_c "${_BOLD}")2)$(_c "${_RESET}") Default (${ZROK_INSTALL_DIR})"
    echo -e "  $(_c "${_BOLD}")3)$(_c "${_RESET}") Custom path"
    echo -n "       Choice [2]: "
    local choice
    read -r choice < /dev/tty
    choice="${choice:-2}"

    case "${choice}" in
        1)
            ZROK_INSTALL_DIR="$(pwd)"
            ;;
        2)
            ;;
        3)
            echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Install path: "
            local custom_path
            read -r custom_path < /dev/tty
            if [[ -n "${custom_path}" ]]; then
                ZROK_INSTALL_DIR="${custom_path}"
            fi
            ;;
        *)
            ;;
    esac

    log_success "Install location: ${ZROK_INSTALL_DIR}"
}

prompt_required_settings() {
    prompt_input "zrok DNS zone (e.g., share.example.com)" "" "ZROK_DNS_ZONE"
    prompt_input "Admin email address" "" "ZROK_USER_EMAIL"

    if [[ -z "${ZROK_USER_PWD}" ]]; then
        echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Admin password (blank = auto-generate): "
        local pw
        read -rs pw < /dev/tty
        echo ""
        if [[ -n "${pw}" ]]; then
            ZROK_USER_PWD="${pw}"
        fi
    fi
}

prompt_deployment_mode() {
    if [[ -n "${DEPLOY_MODE}" ]]; then
        if [[ "${IS_MACOS}" == "true" ]] && [[ "${DEPLOY_MODE}" == "baremetal" ]]; then
            log_error "Bare metal mode not supported on macOS. Use --mode docker."
            exit 1
        fi
        return 0
    fi

    if [[ "${IS_MACOS}" == "true" ]]; then
        DEPLOY_MODE="docker"
        log_info "macOS detected — using Docker Compose mode (only supported mode)"
        return 0
    fi

    local options=()
    if [[ "${HAS_DOCKER}" == "true" ]]; then
        options+=("Docker Compose (recommended)")
    else
        options+=("Docker Compose (will install Docker)")
    fi
    options+=("Bare Metal Linux")

    prompt_choice "Deployment mode?" "DEPLOY_MODE" "${options[@]}"

    case "${DEPLOY_MODE}" in
        docker*) DEPLOY_MODE="docker" ;;
        bare*)   DEPLOY_MODE="baremetal" ;;
    esac
}

prompt_tls_provider() {
    if [[ -n "${TLS_PROVIDER}" ]]; then
        return 0
    fi

    local options=("Caddy (recommended, auto-TLS)" "Traefik")
    if [[ "${DEPLOY_MODE}" == "baremetal" ]]; then
        options+=("Nginx + Certbot")
    fi

    prompt_choice "TLS provider?" "TLS_PROVIDER" "${options[@]}"

    case "${TLS_PROVIDER}" in
        caddy*)   TLS_PROVIDER="caddy" ;;
        traefik*) TLS_PROVIDER="traefik" ;;
        nginx*)   TLS_PROVIDER="nginx" ;;
    esac
}

prompt_dns_provider() {
    if [[ -n "${DNS_PROVIDER}" ]] && [[ -n "${DNS_TOKEN}" ]]; then
        return 0
    fi

    if [[ "${TLS_PROVIDER}" == "nginx" ]] && [[ "${DEPLOY_MODE}" == "baremetal" ]]; then
        echo ""
        log_info "Nginx + Certbot requires a DNS provider for wildcard certificate automation."
    fi

    if [[ -z "${DNS_PROVIDER}" ]]; then
        prompt_choice "DNS provider for ACME certificates?" "DNS_PROVIDER" \
            "Cloudflare" "DigitalOcean" "Route53 (AWS)" "GoDaddy" "Namecheap"

        case "${DNS_PROVIDER}" in
            cloudflare*)   DNS_PROVIDER="cloudflare" ;;
            digitalocean*) DNS_PROVIDER="digitalocean" ;;
            route53*)      DNS_PROVIDER="route53" ;;
            godaddy*)      DNS_PROVIDER="godaddy" ;;
            namecheap*)    DNS_PROVIDER="namecheap" ;;
        esac
    fi

    if [[ -z "${DNS_TOKEN}" ]]; then
        if [[ "${DNS_PROVIDER}" == "route53" ]]; then
            prompt_secret "AWS Access Key ID" "DNS_TOKEN"
            local aws_secret=""
            prompt_secret "AWS Secret Access Key" "aws_secret"
            DNS_TOKEN="${DNS_TOKEN}:${aws_secret}"
        else
            prompt_secret "API token for ${DNS_PROVIDER}" "DNS_TOKEN"
        fi
    fi

    if [[ -z "${DNS_TOKEN}" ]]; then
        log_error "DNS API token is required for TLS certificate provisioning."
        exit 1
    fi

    validate_dns_token
}

validate_dns_token() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    case "${DNS_PROVIDER}" in
        cloudflare)
            log_substep "Verifying Cloudflare API token..."
            local cf_response
            cf_response="$(curl -sf -H "Authorization: Bearer ${DNS_TOKEN}" \
                "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null || echo "")"
            if echo "${cf_response}" | grep -q '"success":true'; then
                log_success "Cloudflare token valid"
            else
                log_warn "Cloudflare token verification failed"
                local cf_error
                cf_error="$(echo "${cf_response}" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null || echo "could not reach API")"
                log_warn "  Reason: ${cf_error}"
                if ! confirm "Continue with this token anyway?"; then
                    exit 1
                fi
            fi
            ;;
        digitalocean)
            log_substep "Verifying DigitalOcean API token..."
            local do_response
            do_response="$(curl -sf -H "Authorization: Bearer ${DNS_TOKEN}" \
                "https://api.digitalocean.com/v2/account" 2>/dev/null || echo "")"
            if echo "${do_response}" | grep -q '"account"'; then
                log_success "DigitalOcean token valid"
            else
                log_warn "DigitalOcean token verification failed"
                if ! confirm "Continue with this token anyway?"; then
                    exit 1
                fi
            fi
            ;;
        route53)
            log_substep "Verifying AWS credentials..."
            local aws_key="${DNS_TOKEN%%:*}"
            local aws_secret="${DNS_TOKEN#*:}"
            local aws_date aws_auth_header aws_response
            aws_date="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%SZ)"
            aws_response="$(AWS_ACCESS_KEY_ID="${aws_key}" AWS_SECRET_ACCESS_KEY="${aws_secret}" \
                curl -sf "https://sts.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15" \
                --aws-sigv4 "aws:amz:us-east-1:sts" \
                --user "${aws_key}:${aws_secret}" 2>/dev/null || echo "")"
            if echo "${aws_response}" | grep -q "GetCallerIdentityResult"; then
                local aws_account
                aws_account="$(echo "${aws_response}" | grep -oP '<Account>\K[^<]+' || echo "verified")"
                log_success "AWS credentials valid (account: ${aws_account})"
            else
                log_warn "AWS credentials verification failed"
                log_warn "Ensure the IAM user/role has Route53 permissions"
                if ! confirm "Continue with these credentials anyway?"; then
                    exit 1
                fi
            fi
            ;;
        godaddy)
            log_substep "Verifying GoDaddy API key..."
            local gd_response
            gd_response="$(curl -sf \
                -H "Authorization: sso-key ${DNS_TOKEN}" \
                "https://api.godaddy.com/v1/domains?limit=1" 2>/dev/null || echo "error")"
            if [[ "${gd_response}" != "error" ]] && ! echo "${gd_response}" | grep -qi "UNABLE_TO_AUTHENTICATE"; then
                log_success "GoDaddy API key valid"
            else
                log_warn "GoDaddy API key verification failed"
                log_info "Expected format: <key>:<secret> (e.g., abcdef12345:ABCXYZ98765)"
                if ! confirm "Continue with this key anyway?"; then
                    exit 1
                fi
            fi
            ;;
        namecheap)
            log_substep "Verifying Namecheap API key..."
            local nc_response
            nc_response="$(curl -sf \
                "https://api.namecheap.com/xml.response?ApiUser=${DNS_TOKEN%%:*}&ApiKey=${DNS_TOKEN#*:}&UserName=${DNS_TOKEN%%:*}&Command=namecheap.domains.getList&ClientIp=0.0.0.0&PageSize=1" \
                2>/dev/null || echo "")"
            if echo "${nc_response}" | grep -q 'Status="OK"'; then
                log_success "Namecheap API key valid"
            else
                log_warn "Namecheap API key verification failed"
                log_info "Expected format: <apiuser>:<apikey>"
                log_info "Ensure your IP is whitelisted at ap.www.namecheap.com"
                if ! confirm "Continue with this key anyway?"; then
                    exit 1
                fi
            fi
            ;;
    esac
}

prompt_optional_modules() {
    if [[ "${ENABLE_OAUTH}" == "true" ]] || [[ "${ENABLE_METRICS}" == "true" ]] || \
       [[ "${ENABLE_LIMITS}" == "true" ]] || [[ "${ENABLE_ORGANIZATIONS}" == "true" ]]; then
        return 0
    fi

    if [[ "${AUTO_YES}" == "true" ]] || [[ "${INTERACTIVE}" == "false" ]]; then
        return 0
    fi

    if ! confirm "Enable optional features?"; then
        return 0
    fi

    echo ""
    echo -e "  Select features to enable:"
    echo -e "  $(_c "${_BOLD}")1)$(_c "${_RESET}") OAuth (GitHub/Google authentication for shares)"
    echo -e "  $(_c "${_BOLD}")2)$(_c "${_RESET}") Metrics pipeline (RabbitMQ + InfluxDB)"
    echo -e "  $(_c "${_BOLD}")3)$(_c "${_RESET}") Usage limits"
    echo -e "  $(_c "${_BOLD}")4)$(_c "${_RESET}") Organizations"
    echo -e "  $(_c "${_BOLD}")A)$(_c "${_RESET}") All of the above"
    echo -n "  Enter choices (e.g., 1 3 or A): "
    local choices
    read -r choices < /dev/tty

    if [[ "${choices}" =~ [Aa] ]]; then
        ENABLE_OAUTH=true
        ENABLE_METRICS=true
        ENABLE_LIMITS=true
        ENABLE_ORGANIZATIONS=true
    else
        [[ "${choices}" == *1* ]] && ENABLE_OAUTH=true
        [[ "${choices}" == *2* ]] && ENABLE_METRICS=true
        [[ "${choices}" == *3* ]] && ENABLE_LIMITS=true
        [[ "${choices}" == *4* ]] && ENABLE_ORGANIZATIONS=true
    fi

    if [[ "${ENABLE_OAUTH}" == "true" ]]; then
        echo ""
        log_info "OAuth requires GitHub and/or Google OAuth app credentials."
        if [[ -z "${OAUTH_GITHUB_ID}" ]]; then
            echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") GitHub OAuth Client ID (blank to skip GitHub): "
            read -r OAUTH_GITHUB_ID < /dev/tty
            if [[ -n "${OAUTH_GITHUB_ID}" ]]; then
                prompt_secret "GitHub OAuth Client Secret" "OAUTH_GITHUB_SECRET"
            fi
        fi
        if [[ -z "${OAUTH_GOOGLE_ID}" ]]; then
            echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Google OAuth Client ID (blank to skip Google): "
            read -r OAUTH_GOOGLE_ID < /dev/tty
            if [[ -n "${OAUTH_GOOGLE_ID}" ]]; then
                prompt_secret "Google OAuth Client Secret" "OAUTH_GOOGLE_SECRET"
            fi
        fi
    fi
}

print_config_summary() {
    echo ""
    print_separator
    echo -e "  $(_c "${_BOLD}")Installation Summary$(_c "${_RESET}")"
    print_separator
    echo -e "  Domain:          $(_c "${_CYAN}")${ZROK_DNS_ZONE}$(_c "${_RESET}")"
    echo -e "  Admin Email:     ${ZROK_USER_EMAIL}"
    echo -e "  Deploy Mode:     ${DEPLOY_MODE}"
    echo -e "  TLS Provider:    ${TLS_PROVIDER}"
    echo -e "  DNS Provider:    ${DNS_PROVIDER}"
    echo -e "  Install Dir:     ${ZROK_INSTALL_DIR}"
    echo -e "  OAuth:           $([[ "${ENABLE_OAUTH}" == "true" ]] && echo "YES" || echo "no")"
    echo -e "  Metrics:         $([[ "${ENABLE_METRICS}" == "true" ]] && echo "YES" || echo "no")"
    echo -e "  Limits:          $([[ "${ENABLE_LIMITS}" == "true" ]] && echo "YES" || echo "no")"
    echo -e "  Organizations:   $([[ "${ENABLE_ORGANIZATIONS}" == "true" ]] && echo "YES" || echo "no")"
    print_separator
    echo ""
}

# ============================================================================
# SECTION F: DOCKER COMPOSE INSTALLER
# ============================================================================

install_docker_compose() {
    TOTAL_STEPS=7
    CURRENT_STEP=0

    if [[ "${ENABLE_OAUTH}" == "true" ]]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi
    if [[ "${ENABLE_ORGANIZATIONS}" == "true" ]]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi

    log_step "Preparing installation directory"
    mkdir -p "${ZROK_INSTALL_DIR}"
    cd "${ZROK_INSTALL_DIR}"

    log_step "Fetching Docker Compose files"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would fetch compose files from ${ZROK_COMPOSE_BASE_URL}"
    else
        fetch_compose_files
        if [[ ! -f "${ZROK_INSTALL_DIR}/compose.yml" ]]; then
            log_error "compose.yml not found after fetch. Installation cannot continue."
            exit 1
        fi
        log_success "Compose files fetched"
    fi

    log_step "Generating environment configuration"
    generate_docker_env
    log_success ".env generated"

    log_step "Starting Docker Compose services"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: docker compose up --build --detach"
    else
        docker compose up --build --detach 2>&1 | tail -5 || {
            log_error "Docker Compose failed to start. Check logs:"
            log_error "  cd ${ZROK_INSTALL_DIR} && docker compose logs"
            exit 1
        }
        log_success "Services started"
    fi

    log_step "Waiting for services to be healthy"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would wait for containers to be healthy"
    else
        wait_for_docker_healthy
    fi

    log_step "Creating admin account"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would create account: ${ZROK_USER_EMAIL}"
        ACCOUNT_TOKEN="DRY-RUN-TOKEN"
    else
        create_docker_admin_account
    fi

    if [[ "${ENABLE_ORGANIZATIONS}" == "true" ]]; then
        log_step "Configuring organizations"
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "[DRY RUN] Would create default organization"
        else
            configure_docker_organizations
        fi
    fi

    log_step "Running health checks"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would check API endpoint"
    else
        run_docker_health_checks
    fi
}

fetch_compose_files() {
    local compose_files=("compose.yml" "compose.caddy.yml" ".env.example" "entrypoint-init.bash")

    if [[ "${TLS_PROVIDER}" == "traefik" ]]; then
        compose_files+=("compose.traefik.yml")
    fi

    local failed=false
    for f in "${compose_files[@]}"; do
        log_substep "Downloading ${f}..."
        if curl -sSfL "${ZROK_COMPOSE_BASE_URL}/${f}" -o "${ZROK_INSTALL_DIR}/${f}" 2>/dev/null; then
            true
        else
            log_warn "Failed to download ${f} from CDN, trying GitHub..."
            if curl -sSfL "https://raw.githubusercontent.com/openziti/zrok/main/docker/compose/zrok2-instance/${f}" \
                -o "${ZROK_INSTALL_DIR}/${f}" 2>/dev/null; then
                true
            else
                log_error "Failed to download ${f}"
                failed=true
            fi
        fi
    done

    if [[ "${failed}" == "true" ]]; then
        log_error "Some compose files could not be downloaded."
        log_error "Check network connectivity and try again."
        exit 1
    fi

    chmod +x "${ZROK_INSTALL_DIR}/entrypoint-init.bash" 2>/dev/null || true
}

generate_docker_env() {
    local env_file="${ZROK_INSTALL_DIR}/.env"

    local compose_file="compose.yml"
    case "${TLS_PROVIDER}" in
        caddy)   compose_file="compose.yml:compose.caddy.yml" ;;
        traefik) compose_file="compose.yml:compose.traefik.yml" ;;
    esac

    cat > "${env_file}" << ENVEOF
# zrok Self-Hosted Configuration
# Generated by installer v${INSTALLER_VERSION} on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Documentation: https://docs.zrok.io/docs/getting-started/guides/self-hosting/docker

# --- Core Settings ---
ZROK_DNS_ZONE=${ZROK_DNS_ZONE}
ZROK_USER_EMAIL=${ZROK_USER_EMAIL}
ZROK_USER_PWD=${ZROK_USER_PWD}
ZITI_PWD=${ZITI_PWD}
ZROK_ADMIN_TOKEN=${ZROK_ADMIN_TOKEN}

# --- Network ---
ZROK_INSECURE_INTERFACE=0.0.0.0
ZROK_CTRL_PORT=18080
ZROK_FRONTEND_PORT=8080
ZROK_OAUTH_PORT=8081
ZITI_CTRL_ADVERTISED_PORT=80
ZITI_ROUTER_PORT=3022

# --- Compose Stack ---
COMPOSE_FILE=${compose_file}
ENVEOF

    case "${TLS_PROVIDER}" in
        caddy)
            local caddy_plugin
            caddy_plugin="$(get_caddy_plugin_name)"
            cat >> "${env_file}" << ENVEOF

# --- Caddy TLS ---
CADDY_DNS_PLUGIN=${caddy_plugin}
CADDY_DNS_PLUGIN_TOKEN=${DNS_TOKEN}
CADDY_ACME_API=https://acme-v02.api.letsencrypt.org/directory
ENVEOF
            ;;
        traefik)
            local traefik_provider
            traefik_provider="$(get_traefik_provider_name)"
            cat >> "${env_file}" << ENVEOF

# --- Traefik TLS ---
TRAEFIK_DNS_PROVIDER=${traefik_provider}
TRAEFIK_DNS_PROVIDER_TOKEN=${DNS_TOKEN}
TRAEFIK_ACME_API=https://acme-v02.api.letsencrypt.org/directory
ENVEOF
            if [[ "${DNS_PROVIDER}" == "route53" ]]; then
                local aws_key="${DNS_TOKEN%%:*}"
                local aws_secret="${DNS_TOKEN#*:}"
                cat >> "${env_file}" << ENVEOF
AWS_ACCESS_KEY_ID=${aws_key}
AWS_SECRET_ACCESS_KEY=${aws_secret}
ENVEOF
            fi
            ;;
    esac

    if [[ "${ENABLE_OAUTH}" == "true" ]]; then
        cat >> "${env_file}" << ENVEOF

# --- OAuth ---
ZROK_OAUTH_HASH_KEY=${ZROK_OAUTH_HASH_KEY}
ENVEOF
        if [[ -n "${OAUTH_GITHUB_ID}" ]]; then
            cat >> "${env_file}" << ENVEOF
ZROK_OAUTH_GITHUB_CLIENT_ID=${OAUTH_GITHUB_ID}
ZROK_OAUTH_GITHUB_CLIENT_SECRET=${OAUTH_GITHUB_SECRET}
ENVEOF
        fi
        if [[ -n "${OAUTH_GOOGLE_ID}" ]]; then
            cat >> "${env_file}" << ENVEOF
ZROK_OAUTH_GOOGLE_CLIENT_ID=${OAUTH_GOOGLE_ID}
ZROK_OAUTH_GOOGLE_CLIENT_SECRET=${OAUTH_GOOGLE_SECRET}
ENVEOF
        fi
    fi

    chmod 600 "${env_file}"
}

get_caddy_plugin_name() {
    case "${DNS_PROVIDER}" in
        cloudflare)   echo "cloudflare" ;;
        digitalocean) echo "digitalocean" ;;
        route53)      echo "route53" ;;
        godaddy)      echo "godaddy" ;;
        namecheap)    echo "namecheap" ;;
        *)            echo "${DNS_PROVIDER}" ;;
    esac
}

get_traefik_provider_name() {
    case "${DNS_PROVIDER}" in
        cloudflare)   echo "cloudflare" ;;
        digitalocean) echo "digitalocean" ;;
        route53)      echo "route53" ;;
        godaddy)      echo "godaddy" ;;
        namecheap)    echo "namecheap" ;;
        *)            echo "${DNS_PROVIDER}" ;;
    esac
}

get_certbot_plugin_name() {
    case "${DNS_PROVIDER}" in
        cloudflare)   echo "certbot-dns-cloudflare" ;;
        digitalocean) echo "certbot-dns-digitalocean" ;;
        route53)      echo "certbot-dns-route53" ;;
        godaddy)      echo "certbot-dns-godaddy" ;;
        namecheap)    echo "certbot-dns-namecheap" ;;
        *)            echo "certbot-dns-${DNS_PROVIDER}" ;;
    esac
}

wait_for_docker_healthy() {
    local timeout=180
    local elapsed=0
    local interval=5

    log_substep "Waiting up to ${timeout}s for services..."

    while [[ ${elapsed} -lt ${timeout} ]]; do
        local unhealthy
        unhealthy="$(docker compose ps --format json 2>/dev/null | jq -r 'select(.Health != "healthy" and .Health != "" and .State == "running") | .Service' 2>/dev/null | wc -l || echo "999")"

        local running
        running="$(docker compose ps --format json 2>/dev/null | jq -r 'select(.State == "running") | .Service' 2>/dev/null | wc -l || echo "0")"

        if [[ "${running}" -gt 0 ]] && [[ "${unhealthy}" -eq 0 ]]; then
            log_success "All services healthy"
            return 0
        fi

        sleep "${interval}"
        elapsed=$((elapsed + interval))
        log_substep "Waiting... (${elapsed}s / ${timeout}s)"
    done

    log_warn "Timeout waiting for services. Checking status..."
    docker compose ps
    if ! confirm "Some services may not be healthy. Continue?"; then
        exit 1
    fi
}

create_docker_admin_account() {
    log_substep "Creating account: ${ZROK_USER_EMAIL}"

    local output
    output="$(docker compose exec -T zrok-controller \
        zrok admin create account "${ZROK_USER_EMAIL}" "${ZROK_USER_PWD}" 2>&1)" || {
        if echo "${output}" | grep -qi "already exists"; then
            log_info "Account already exists"
            ACCOUNT_TOKEN="(existing account)"
            return 0
        fi
        log_error "Failed to create admin account:"
        log_error "${output}"
        exit 1
    }

    ACCOUNT_TOKEN="$(echo "${output}" | grep -oE '[A-Za-z0-9]{12,}' | tail -1 || echo "")"
    if [[ -n "${ACCOUNT_TOKEN}" ]]; then
        log_success "Account created. Token: ${ACCOUNT_TOKEN}"
    else
        ACCOUNT_TOKEN="(check controller logs)"
        log_success "Account created"
    fi
}

configure_docker_organizations() {
    local output
    output="$(docker compose exec -T zrok-controller \
        zrok admin create organization -d "Default Organization" 2>&1)" || {
        log_warn "Organization creation returned non-zero (may already exist)"
    }

    local org_token
    org_token="$(echo "${output}" | grep -oP "token '\K[^']+" || echo "")"

    if [[ -n "${org_token}" ]]; then
        log_substep "Organization token: ${org_token}"
        docker compose exec -T zrok-controller \
            zrok admin create org-member "${org_token}" "${ZROK_USER_EMAIL}" 2>&1 || true
        log_success "Organization configured"
    else
        log_warn "Could not extract organization token from output"
    fi
}

run_docker_health_checks() {
    sleep 3

    local api_url="http://localhost:18080"
    if curl -sf "${api_url}" &>/dev/null; then
        log_success "API endpoint responding at ${api_url}"
    else
        log_warn "API endpoint not yet responding at ${api_url}"
        log_info "It may take a minute for TLS certificates to provision"
    fi
}

# ============================================================================
# SECTION G: BARE METAL INSTALLER
# ============================================================================

install_bare_metal() {
    TOTAL_STEPS=9
    CURRENT_STEP=0

    if [[ "${ENABLE_METRICS}" == "true" ]]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi
    if [[ "${ENABLE_ORGANIZATIONS}" == "true" ]]; then TOTAL_STEPS=$((TOTAL_STEPS + 1)); fi

    log_step "Preparing installation directory"
    mkdir -p "${ZROK_INSTALL_DIR}/etc" "${ZROK_INSTALL_DIR}/data"

    log_step "Installing OpenZiti"
    install_openziti

    log_step "Installing zrok"
    install_zrok_package

    log_step "Generating controller configuration"
    generate_ctrl_yml
    log_success "ctrl.yml generated"

    log_step "Bootstrapping zrok"
    bootstrap_zrok

    log_step "Generating frontend configuration"
    generate_frontend_yml
    log_success "http-frontend.yml generated"

    log_step "Installing TLS provider (${TLS_PROVIDER})"
    install_tls_baremetal

    log_step "Creating systemd services"
    create_systemd_units
    start_services

    log_step "Creating admin account"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would create account: ${ZROK_USER_EMAIL}"
        ACCOUNT_TOKEN="DRY-RUN-TOKEN"
    else
        create_baremetal_admin_account
    fi

    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        log_step "Setting up metrics pipeline"
        install_metrics_pipeline
    fi

    if [[ "${ENABLE_ORGANIZATIONS}" == "true" ]]; then
        log_step "Configuring organizations"
        configure_baremetal_organizations
    fi
}

install_openziti() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would install OpenZiti via ${ZROK_INSTALL_URL}"
        return 0
    fi

    log_substep "Setting up OpenZiti package repository..."
    curl -sSf "${ZROK_INSTALL_URL}" | bash -s openziti &>/dev/null || {
        log_warn "OpenZiti install script failed; trying manual repo setup..."
        install_openziti_manual
    }

    if command -v ziti &>/dev/null; then
        log_success "OpenZiti installed"
    else
        log_error "OpenZiti installation failed. Check connectivity and try again."
        exit 1
    fi
}

install_openziti_manual() {
    case "${OS_FAMILY}" in
        debian)
            curl -sSf https://get.openziti.io/tun/package-repos.gpg \
                | gpg --dearmor -o /usr/share/keyrings/openziti.gpg 2>/dev/null
            chmod a+r /usr/share/keyrings/openziti.gpg
            echo "deb [signed-by=/usr/share/keyrings/openziti.gpg] https://packages.openziti.org/zitipax-openziti-deb-stable debian main" \
                > /etc/apt/sources.list.d/openziti-release.list
            apt-get update -qq &>/dev/null
            apt-get install -y -qq openziti &>/dev/null
            ;;
        rhel)
            cat > /etc/yum.repos.d/openziti-release.repo << 'REPO'
[OpenZitiRelease]
name=OpenZiti Release
baseurl=https://packages.openziti.org/zitipax-openziti-rpm-stable/redhat/$basearch
enabled=1
gpgkey=https://packages.openziti.org/zitipax-openziti-rpm-stable/redhat/$basearch/repodata/repomd.xml.key
repo_gpgcheck=1
gpgcheck=0
REPO
            ${PKG_INSTALL} openziti &>/dev/null
            ;;
        suse)
            zypper addrepo -f \
                "https://packages.openziti.org/zitipax-openziti-rpm-stable/redhat/\$basearch" \
                OpenZitiRelease &>/dev/null || true
            zypper --gpg-auto-import-keys refresh &>/dev/null
            ${PKG_INSTALL} openziti &>/dev/null
            ;;
    esac
}

install_zrok_package() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would install zrok package"
        return 0
    fi

    log_substep "Installing zrok package..."
    curl -sSf "${ZROK_INSTALL_URL}" | bash -s zrok &>/dev/null || {
        log_warn "zrok install script failed; trying package manager..."
        ${PKG_INSTALL} zrok &>/dev/null || {
            log_error "Failed to install zrok package"
            exit 1
        }
    }

    if command -v zrok &>/dev/null; then
        local ver
        ver="$(zrok version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'unknown')"
        log_success "zrok installed: ${ver}"
    else
        log_error "zrok binary not found after installation"
        exit 1
    fi
}

generate_ctrl_yml() {
    local ctrl_file="${ZROK_INSTALL_DIR}/etc/ctrl.yml"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would generate ${ctrl_file}"
        return 0
    fi

    cat > "${ctrl_file}" << CTRLEOF
v:                  4

admin:
  secrets:
    - ${ZROK_ADMIN_TOKEN}

endpoint:
  host:             0.0.0.0
  port:             18080

invites:
  invites_open:     true

store:
  path:             ${ZROK_INSTALL_DIR}/data/zrok.db
  type:             sqlite3

ziti:
  api_endpoint:     "https://127.0.0.1:1280"
  username:         admin
  password:         "${ZITI_PWD}"
CTRLEOF

    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        cat >> "${ctrl_file}" << METRICSEOF

metrics:
  agent:
    source:
      type:         amqpSource
      url:          amqp://guest:guest@localhost:5672
      queue_name:   events
  influx:
    url:            "http://127.0.0.1:8086"
    bucket:         zrok
    org:            zrok
    token:          "$(generate_password 32)"
METRICSEOF
    fi

    if [[ "${ENABLE_LIMITS}" == "true" ]]; then
        cat >> "${ctrl_file}" << LIMITSEOF

limits:
  environments:     -1
  shares:           -1
  reserved_shares:  -1
  unique_names:     -1
  share_frontends:  -1
  bandwidth:
    period:         5m
    warning:
      rx:           -1
      tx:           -1
      total:        7242880
    limit:
      rx:           -1
      tx:           -1
      total:        10485760
  enforcing:        true
  cycle:            5m
LIMITSEOF
    fi

    chmod 600 "${ctrl_file}"
}

bootstrap_zrok() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would run: zrok admin bootstrap ${ZROK_INSTALL_DIR}/etc/ctrl.yml"
        FRONTEND_IDENTITY="DRY-RUN-IDENTITY"
        return 0
    fi

    log_substep "Bootstrapping zrok (this may take a moment)..."

    export ZROK_ADMIN_TOKEN="${ZROK_ADMIN_TOKEN}"

    local output
    output="$(zrok admin bootstrap "${ZROK_INSTALL_DIR}/etc/ctrl.yml" 2>&1)" || {
        log_error "Bootstrap failed:"
        echo "${output}" | tail -20
        exit 1
    }

    FRONTEND_IDENTITY="$(echo "${output}" | grep -oP "frontend identity: \K\S+" || echo "")"

    if [[ -z "${FRONTEND_IDENTITY}" ]]; then
        FRONTEND_IDENTITY="$(echo "${output}" | grep -oP "ziti id '\K[^']+" | tail -1 || echo "")"
    fi

    if [[ -n "${FRONTEND_IDENTITY}" ]]; then
        log_success "Bootstrap complete. Frontend identity: ${FRONTEND_IDENTITY}"
    else
        log_warn "Bootstrap complete but could not extract frontend identity."
        log_info "You may need to find it with: ziti edge list identities"
    fi
}

generate_frontend_yml() {
    local frontend_file="${ZROK_INSTALL_DIR}/etc/http-frontend.yml"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would generate ${frontend_file}"
        return 0
    fi

    cat > "${frontend_file}" << FRONTEOF
v:                  3
host_match:         ${ZROK_DNS_ZONE}
address:            0.0.0.0:8080
FRONTEOF

    if [[ "${ENABLE_OAUTH}" == "true" ]]; then
        cat >> "${frontend_file}" << OAUTHEOF

oauth:
  bind_address:     0.0.0.0:8181
  redirect_url:     https://oauth.${ZROK_DNS_ZONE}
  cookie_domain:    ${ZROK_DNS_ZONE}
  hash_key:         "${ZROK_OAUTH_HASH_KEY}"
  providers:
OAUTHEOF
        if [[ -n "${OAUTH_GOOGLE_ID}" ]]; then
            cat >> "${frontend_file}" << GOOGLEEOF
    - name:         google
      client_id:    "${OAUTH_GOOGLE_ID}"
      client_secret: "${OAUTH_GOOGLE_SECRET}"
GOOGLEEOF
        fi
        if [[ -n "${OAUTH_GITHUB_ID}" ]]; then
            cat >> "${frontend_file}" << GITHUBEOF
    - name:         github
      client_id:    "${OAUTH_GITHUB_ID}"
      client_secret: "${OAUTH_GITHUB_SECRET}"
GITHUBEOF
        fi
    fi

    chmod 600 "${frontend_file}"
}

install_tls_baremetal() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would install ${TLS_PROVIDER} for TLS"
        return 0
    fi

    case "${TLS_PROVIDER}" in
        caddy)   install_caddy_baremetal ;;
        traefik) install_traefik_baremetal ;;
        nginx)   install_nginx_baremetal ;;
    esac
}

install_caddy_baremetal() {
    log_substep "Installing Caddy..."

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
        suse)
            ${PKG_INSTALL} caddy &>/dev/null || {
                log_warn "Caddy not in repos, installing from GitHub..."
                install_caddy_binary
            }
            ;;
    esac

    generate_caddyfile
    systemctl enable --now caddy &>/dev/null || true
    log_success "Caddy installed and configured"
}

install_caddy_binary() {
    local caddy_url="https://caddyserver.com/api/download?os=linux&arch=${ARCH}"
    curl -sSfL "${caddy_url}" -o /usr/local/bin/caddy
    chmod +x /usr/local/bin/caddy

    if [[ ! -f /etc/systemd/system/caddy.service ]]; then
        cat > /etc/systemd/system/caddy.service << 'CADDYSVC'
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
CADDYSVC
    fi
    systemctl daemon-reload
}

generate_caddyfile() {
    mkdir -p /etc/caddy

    local dns_block=""
    case "${DNS_PROVIDER}" in
        cloudflare)   dns_block="tls { dns cloudflare ${DNS_TOKEN} }" ;;
        digitalocean) dns_block="tls { dns digitalocean ${DNS_TOKEN} }" ;;
        route53)
            local aws_key="${DNS_TOKEN%%:*}"
            local aws_secret="${DNS_TOKEN#*:}"
            dns_block="tls { dns route53 { access_key_id ${aws_key}\n        secret_access_key ${aws_secret} } }"
            ;;
        *)            dns_block="tls { dns ${DNS_PROVIDER} ${DNS_TOKEN} }" ;;
    esac

    cat > /etc/caddy/Caddyfile << CADDYEOF
${ZROK_DNS_ZONE} {
    ${dns_block}
    reverse_proxy localhost:18080
}

*.${ZROK_DNS_ZONE} {
    ${dns_block}
    reverse_proxy localhost:8080
}
CADDYEOF
}

install_traefik_baremetal() {
    log_substep "Installing Traefik..."

    local traefik_version="v3.1.2"
    local traefik_url="https://github.com/traefik/traefik/releases/download/${traefik_version}/traefik_${traefik_version}_linux_${ARCH}.tar.gz"

    curl -sSfL "${traefik_url}" | tar -xz -C /usr/local/bin/ traefik 2>/dev/null || {
        log_error "Failed to download Traefik"
        exit 1
    }
    chmod +x /usr/local/bin/traefik

    mkdir -p /etc/traefik/acme

    generate_traefik_config
    create_traefik_service
    systemctl daemon-reload
    systemctl enable --now traefik &>/dev/null || true
    log_success "Traefik installed and configured"
}

generate_traefik_config() {
    local provider_env=""
    case "${DNS_PROVIDER}" in
        cloudflare)
            provider_env="CF_DNS_API_TOKEN=${DNS_TOKEN}"
            ;;
        digitalocean)
            provider_env="DO_AUTH_TOKEN=${DNS_TOKEN}"
            ;;
        route53)
            local aws_key="${DNS_TOKEN%%:*}"
            local aws_secret="${DNS_TOKEN#*:}"
            provider_env="AWS_ACCESS_KEY_ID=${aws_key}\nAWS_SECRET_ACCESS_KEY=${aws_secret}"
            ;;
    esac

    cat > /etc/traefik/traefik.yml << TRAEFIKEOF
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${ZROK_USER_EMAIL}
      storage: /etc/traefik/acme/acme.json
      caServer: https://acme-v02.api.letsencrypt.org/directory
      dnsChallenge:
        provider: ${DNS_PROVIDER}

providers:
  file:
    filename: /etc/traefik/dynamic.yml

log:
  level: INFO
TRAEFIKEOF

    cat > /etc/traefik/dynamic.yml << DYNEOF
http:
  routers:
    zrok-api:
      rule: "Host(\`${ZROK_DNS_ZONE}\`)"
      service: zrok-api
      tls:
        certResolver: letsencrypt
        domains:
          - main: "${ZROK_DNS_ZONE}"
            sans:
              - "*.${ZROK_DNS_ZONE}"
    zrok-frontend:
      rule: "HostRegexp(\`.+\\.${ZROK_DNS_ZONE}\`)"
      service: zrok-frontend
      tls:
        certResolver: letsencrypt

  services:
    zrok-api:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:18080"
    zrok-frontend:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
DYNEOF

    if [[ -n "${provider_env}" ]]; then
        mkdir -p /etc/traefik
        echo -e "${provider_env}" > /etc/traefik/.env
        chmod 600 /etc/traefik/.env
    fi
}

create_traefik_service() {
    cat > /etc/systemd/system/traefik.service << 'TSVC'
[Unit]
Description=Traefik
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/traefik/.env
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
TSVC
}

install_nginx_baremetal() {
    log_substep "Installing Nginx and Certbot..."

    case "${OS_FAMILY}" in
        debian)
            ${PKG_UPDATE} &>/dev/null
            ${PKG_INSTALL} nginx certbot python3-certbot-dns-cloudflare &>/dev/null 2>&1 || true
            ;;
        rhel)
            ${PKG_INSTALL} nginx certbot &>/dev/null 2>&1 || true
            if [[ "${OS_ID}" == "centos" ]] || [[ "${OS_ID}" == "rocky" ]] || [[ "${OS_ID}" == "almalinux" ]]; then
                ${PKG_INSTALL} epel-release &>/dev/null 2>&1 || true
                ${PKG_INSTALL} nginx certbot &>/dev/null 2>&1 || true
            fi
            ;;
        suse)
            ${PKG_INSTALL} nginx certbot &>/dev/null 2>&1 || true
            ;;
    esac

    install_certbot_dns_plugin
    obtain_wildcard_cert
    generate_nginx_config
    systemctl enable --now nginx &>/dev/null || true
    log_success "Nginx + Certbot configured"
}

install_certbot_dns_plugin() {
    local plugin
    plugin="$(get_certbot_plugin_name)"

    log_substep "Installing certbot DNS plugin: ${plugin}"

    ${PKG_INSTALL} "python3-${plugin}" &>/dev/null 2>&1 || \
    pip3 install "${plugin}" &>/dev/null 2>&1 || \
    pip install "${plugin}" &>/dev/null 2>&1 || {
        log_warn "Could not install ${plugin} automatically."
        log_info "You may need to install it manually: pip3 install ${plugin}"
    }
}

obtain_wildcard_cert() {
    local cred_dir="/etc/letsencrypt/dns-credentials"
    mkdir -p "${cred_dir}"

    case "${DNS_PROVIDER}" in
        cloudflare)
            cat > "${cred_dir}/cloudflare.ini" << CFEOF
dns_cloudflare_api_token = ${DNS_TOKEN}
CFEOF
            chmod 600 "${cred_dir}/cloudflare.ini"
            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials "${cred_dir}/cloudflare.ini" \
                -d "${ZROK_DNS_ZONE}" \
                -d "*.${ZROK_DNS_ZONE}" \
                --email "${ZROK_USER_EMAIL}" \
                --agree-tos \
                --non-interactive \
                2>&1 || {
                log_warn "Certbot failed. You may need to obtain certificates manually."
                log_info "Run: certbot certonly --manual -d '*.${ZROK_DNS_ZONE}' -d '${ZROK_DNS_ZONE}'"
            }
            ;;
        digitalocean)
            cat > "${cred_dir}/digitalocean.ini" << DOEOF
dns_digitalocean_token = ${DNS_TOKEN}
DOEOF
            chmod 600 "${cred_dir}/digitalocean.ini"
            certbot certonly \
                --dns-digitalocean \
                --dns-digitalocean-credentials "${cred_dir}/digitalocean.ini" \
                -d "${ZROK_DNS_ZONE}" \
                -d "*.${ZROK_DNS_ZONE}" \
                --email "${ZROK_USER_EMAIL}" \
                --agree-tos \
                --non-interactive \
                2>&1 || {
                log_warn "Certbot failed for DigitalOcean DNS."
            }
            ;;
        route53)
            local aws_key="${DNS_TOKEN%%:*}"
            local aws_secret="${DNS_TOKEN#*:}"
            export AWS_ACCESS_KEY_ID="${aws_key}"
            export AWS_SECRET_ACCESS_KEY="${aws_secret}"
            certbot certonly \
                --dns-route53 \
                -d "${ZROK_DNS_ZONE}" \
                -d "*.${ZROK_DNS_ZONE}" \
                --email "${ZROK_USER_EMAIL}" \
                --agree-tos \
                --non-interactive \
                2>&1 || {
                log_warn "Certbot failed for Route53."
            }
            ;;
        *)
            log_warn "No automatic certbot plugin for ${DNS_PROVIDER}."
            log_info "Obtain certificates manually:"
            log_info "  certbot certonly --manual -d '*.${ZROK_DNS_ZONE}' -d '${ZROK_DNS_ZONE}'"
            ;;
    esac
}

generate_nginx_config() {
    local cert_path="/etc/letsencrypt/live/${ZROK_DNS_ZONE}"
    local nginx_conf="/etc/nginx/sites-available/zrok"
    local nginx_enabled="/etc/nginx/sites-enabled/zrok"

    if [[ "${OS_FAMILY}" == "rhel" ]] || [[ "${OS_FAMILY}" == "suse" ]]; then
        nginx_conf="/etc/nginx/conf.d/zrok.conf"
        nginx_enabled=""
    fi

    cat > "${nginx_conf}" << NGINXEOF
server {
    listen 443 ssl;
    server_name ${ZROK_DNS_ZONE};

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:18080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 443 ssl;
    server_name *.${ZROK_DNS_ZONE};

    ssl_certificate     ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

server {
    listen 80;
    server_name ${ZROK_DNS_ZONE} *.${ZROK_DNS_ZONE};
    return 301 https://\$host\$request_uri;
}
NGINXEOF

    if [[ -n "${nginx_enabled}" ]]; then
        mkdir -p "$(dirname "${nginx_enabled}")"
        ln -sf "${nginx_conf}" "${nginx_enabled}" 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    nginx -t &>/dev/null || {
        log_warn "Nginx configuration test failed. Check: nginx -t"
    }
}

create_systemd_units() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would create systemd service units"
        return 0
    fi

    id -u zrok &>/dev/null || useradd -r -s /usr/sbin/nologin -d "${ZROK_INSTALL_DIR}" zrok 2>/dev/null || true
    chown -R zrok:zrok "${ZROK_INSTALL_DIR}" 2>/dev/null || true

    cat > /etc/systemd/system/zrok-controller.service << CTRLSVC
[Unit]
Description=zrok Controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=zrok
Group=zrok
ExecStart=/usr/bin/zrok controller ${ZROK_INSTALL_DIR}/etc/ctrl.yml
Restart=always
RestartSec=5
Environment=ZROK_ADMIN_TOKEN=${ZROK_ADMIN_TOKEN}

[Install]
WantedBy=multi-user.target
CTRLSVC

    cat > /etc/systemd/system/zrok-frontend.service << FRONTSVC
[Unit]
Description=zrok Public Frontend
After=zrok-controller.service
Requires=zrok-controller.service

[Service]
Type=simple
User=zrok
Group=zrok
ExecStart=/usr/bin/zrok access public ${ZROK_INSTALL_DIR}/etc/http-frontend.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
FRONTSVC

    if [[ "${ENABLE_METRICS}" == "true" ]]; then
        cat > /etc/systemd/system/zrok-metrics-bridge.service << METRICSVC
[Unit]
Description=zrok Metrics Bridge
After=zrok-controller.service rabbitmq-server.service
Wants=rabbitmq-server.service

[Service]
Type=simple
User=zrok
Group=zrok
ExecStart=/usr/bin/zrok ctrl metrics bridge ${ZROK_INSTALL_DIR}/etc/ctrl.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
METRICSVC
    fi

    if [[ "${SELINUX_ENFORCING}" == "true" ]]; then
        restorecon -Rv "${ZROK_INSTALL_DIR}" &>/dev/null || true
    fi

    systemctl daemon-reload
    log_success "Systemd units created"
}

start_services() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would enable and start zrok services"
        return 0
    fi

    systemctl enable --now zrok-controller.service &>/dev/null || {
        log_error "Failed to start zrok-controller"
        journalctl -u zrok-controller --no-pager -n 20
        exit 1
    }
    log_substep "zrok-controller started"

    sleep 3

    systemctl enable --now zrok-frontend.service &>/dev/null || {
        log_error "Failed to start zrok-frontend"
        journalctl -u zrok-frontend --no-pager -n 20
        exit 1
    }
    log_substep "zrok-frontend started"

    if [[ "${ENABLE_METRICS}" == "true" ]] && [[ -f /etc/systemd/system/zrok-metrics-bridge.service ]]; then
        systemctl enable --now zrok-metrics-bridge.service &>/dev/null || {
            log_warn "Failed to start metrics bridge"
        }
        log_substep "zrok-metrics-bridge started"
    fi

    log_success "All services running"
}

create_baremetal_admin_account() {
    export ZROK_API_ENDPOINT="http://127.0.0.1:18080"
    export ZROK_ADMIN_TOKEN="${ZROK_ADMIN_TOKEN}"

    sleep 5

    local output
    output="$(zrok admin create account "${ZROK_USER_EMAIL}" "${ZROK_USER_PWD}" 2>&1)" || {
        if echo "${output}" | grep -qi "already exists"; then
            log_info "Account already exists"
            ACCOUNT_TOKEN="(existing)"
            return 0
        fi
        log_error "Failed to create account:"
        log_error "${output}"
        exit 1
    }

    ACCOUNT_TOKEN="$(echo "${output}" | tr -s ' ' | grep -oE '[A-Za-z0-9]{12,}' | tail -1 || echo "")"
    log_success "Account created. Token: ${ACCOUNT_TOKEN:-"(check logs)"}"
}

install_metrics_pipeline() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would install RabbitMQ and InfluxDB for metrics"
        return 0
    fi

    log_substep "Installing RabbitMQ..."
    case "${OS_FAMILY}" in
        debian) ${PKG_INSTALL} rabbitmq-server &>/dev/null 2>&1 || true ;;
        rhel)   ${PKG_INSTALL} rabbitmq-server &>/dev/null 2>&1 || true ;;
        suse)   ${PKG_INSTALL} rabbitmq-server &>/dev/null 2>&1 || true ;;
    esac
    systemctl enable --now rabbitmq-server &>/dev/null || {
        log_warn "RabbitMQ not available via package manager. Using Docker container instead."
        docker run -d --restart unless-stopped --name rabbitmq \
            -p 5672:5672 -p 15672:15672 \
            rabbitmq:3-management &>/dev/null || true
    }

    log_substep "Installing InfluxDB..."
    if command -v influxd &>/dev/null; then
        log_info "InfluxDB already installed"
    else
        log_info "InfluxDB setup: visit https://docs.influxdata.com/influxdb/v2/install/"
        log_info "Create bucket 'zrok' in org 'zrok' after installation"
    fi

    log_success "Metrics pipeline configured (check InfluxDB setup)"
}

configure_baremetal_organizations() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would create default organization"
        return 0
    fi

    export ZROK_API_ENDPOINT="http://127.0.0.1:18080"
    export ZROK_ADMIN_TOKEN="${ZROK_ADMIN_TOKEN}"

    local output
    output="$(zrok admin create organization -d "Default Organization" 2>&1)" || {
        log_warn "Organization creation failed (may already exist)"
        return 0
    }

    local org_token
    org_token="$(echo "${output}" | grep -oP "token '\K[^']+" || echo "")"

    if [[ -n "${org_token}" ]]; then
        zrok admin create org-member "${org_token}" "${ZROK_USER_EMAIL}" 2>&1 || true
        log_success "Organization configured: ${org_token}"
    fi
}

# ============================================================================
# SECTION H: POST-INSTALL SUMMARY
# ============================================================================

print_summary() {
    local console_url="https://${ZROK_DNS_ZONE}"
    local api_url="https://${ZROK_DNS_ZONE}:18080"
    local shares_url="https://{token}.${ZROK_DNS_ZONE}"

    if [[ "${TLS_PROVIDER}" == "caddy" ]] || [[ "${TLS_PROVIDER}" == "traefik" ]] || [[ "${TLS_PROVIDER}" == "nginx" ]]; then
        api_url="https://${ZROK_DNS_ZONE}"
    fi

    echo ""
    echo ""
    if _supports_color; then echo -e "${_GREEN}${_BOLD}"; fi
    cat << 'DONE'
  ╔══════════════════════════════════════════════════════╗
  ║       zrok Self-Hosted — Installation Complete       ║
  ╚══════════════════════════════════════════════════════╝
DONE
    if _supports_color; then echo -e "${_RESET}"; fi

    echo -e "  $(_c "${_BOLD}")Domain:$(_c "${_RESET}")          ${ZROK_DNS_ZONE}"
    echo -e "  $(_c "${_BOLD}")Mode:$(_c "${_RESET}")            ${DEPLOY_MODE}"
    echo -e "  $(_c "${_BOLD}")TLS:$(_c "${_RESET}")             ${TLS_PROVIDER}"
    echo ""
    echo -e "  $(_c "${_BOLD}")URLs:$(_c "${_RESET}")"
    echo -e "    Console:       ${console_url}"
    echo -e "    Shares:        ${shares_url}"
    echo ""
    echo -e "  $(_c "${_BOLD}")Admin Account:$(_c "${_RESET}")"
    echo -e "    Email:         ${ZROK_USER_EMAIL}"
    echo -e "    Password:      ********** (see credentials file)"
    echo -e "    Account Token: ${ACCOUNT_TOKEN:-"(see credentials file)"}"
    echo ""
    echo -e "  $(_c "${_BOLD}")Modules:$(_c "${_RESET}")"
    echo -e "    OAuth:         $([[ "${ENABLE_OAUTH}" == "true" ]] && echo "✓ Enabled" || echo "✗ Disabled")"
    echo -e "    Metrics:       $([[ "${ENABLE_METRICS}" == "true" ]] && echo "✓ Enabled" || echo "✗ Disabled")"
    echo -e "    Limits:        $([[ "${ENABLE_LIMITS}" == "true" ]] && echo "✓ Enabled" || echo "✗ Disabled")"
    echo -e "    Organizations: $([[ "${ENABLE_ORGANIZATIONS}" == "true" ]] && echo "✓ Enabled" || echo "✗ Disabled")"
    echo ""
    echo -e "  $(_c "${_BOLD}")Files:$(_c "${_RESET}")"
    echo -e "    Install Dir:   ${ZROK_INSTALL_DIR}"
    echo -e "    Credentials:   ${ZROK_INSTALL_DIR}/${CREDENTIALS_FILE_NAME}"
    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        echo -e "    Config:        ${ZROK_INSTALL_DIR}/.env"
    else
        echo -e "    Config:        ${ZROK_INSTALL_DIR}/etc/ctrl.yml"
    fi
    echo ""
    print_separator
    echo -e "  $(_c "${_BOLD}")Client Setup (run on end-user machines):$(_c "${_RESET}")"
    print_separator
    echo ""
    echo "    zrok config set apiEndpoint https://${ZROK_DNS_ZONE}"
    echo "    zrok enable ${ACCOUNT_TOKEN:-"<account_token>"}"
    echo "    zrok share public localhost:8080"
    echo ""

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        print_separator
        echo -e "  $(_c "${_BOLD}")Management Commands:$(_c "${_RESET}")"
        print_separator
        echo ""
        echo "    cd ${ZROK_INSTALL_DIR}"
        echo "    docker compose logs -f              # view logs"
        echo "    docker compose restart              # restart services"
        echo "    docker compose down                 # stop services"
        echo "    docker compose up --build -d        # start/rebuild"
        echo ""
        if [[ "${IS_MACOS}" == "true" ]]; then
            echo -e "  $(_c "${_YELLOW}")Note:$(_c "${_RESET}") On macOS, services run via Docker Desktop."
            echo "  Keep Docker Desktop running for zrok to stay available."
            echo ""
        fi
    else
        print_separator
        echo -e "  $(_c "${_BOLD}")Management Commands:$(_c "${_RESET}")"
        print_separator
        echo ""
        echo "    systemctl status zrok-controller    # controller status"
        echo "    systemctl status zrok-frontend      # frontend status"
        echo "    journalctl -u zrok-controller -f    # view logs"
        echo "    systemctl restart zrok-controller   # restart"
        echo ""
    fi
}

save_credentials() {
    local cred_file="${ZROK_INSTALL_DIR}/${CREDENTIALS_FILE_NAME}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would save credentials to ${cred_file}"
        return 0
    fi

    cat > "${cred_file}" << CREDEOF
# zrok Self-Hosted Credentials
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# KEEP THIS FILE SECURE — chmod 600

ZROK_DNS_ZONE=${ZROK_DNS_ZONE}
ZROK_USER_EMAIL=${ZROK_USER_EMAIL}
ZROK_USER_PWD=${ZROK_USER_PWD}
ZROK_ADMIN_TOKEN=${ZROK_ADMIN_TOKEN}
ZROK_ACCOUNT_TOKEN=${ACCOUNT_TOKEN:-""}
ZITI_PWD=${ZITI_PWD}
ZROK_OAUTH_HASH_KEY=${ZROK_OAUTH_HASH_KEY}

DNS_PROVIDER=${DNS_PROVIDER}
DNS_TOKEN=${DNS_TOKEN}

OAUTH_GITHUB_ID=${OAUTH_GITHUB_ID}
OAUTH_GITHUB_SECRET=${OAUTH_GITHUB_SECRET}
OAUTH_GOOGLE_ID=${OAUTH_GOOGLE_ID}
OAUTH_GOOGLE_SECRET=${OAUTH_GOOGLE_SECRET}
CREDEOF

    chmod 600 "${cred_file}"
    log_success "Credentials saved to ${cred_file}"
}

generate_readme() {
    local readme_file="${ZROK_INSTALL_DIR}/README.md"

    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    cat > "${readme_file}" << READMEEOF
# zrok Self-Hosted Instance

Deployed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Installer: v${INSTALLER_VERSION}

## Connection Details

- **Domain**: ${ZROK_DNS_ZONE}
- **Console**: https://${ZROK_DNS_ZONE}
- **Shares**: https://{token}.${ZROK_DNS_ZONE}
- **Mode**: ${DEPLOY_MODE}
- **TLS**: ${TLS_PROVIDER}

## Client Setup

Install zrok on your machine, then:

\`\`\`bash
zrok config set apiEndpoint https://${ZROK_DNS_ZONE}
zrok enable <your_account_token>
zrok share public localhost:8080
\`\`\`

## DNS Requirements

Ensure these DNS records point to this server:

- \`${ZROK_DNS_ZONE}\` → A record → \`<server-ip>\`
- \`*.${ZROK_DNS_ZONE}\` → A record → \`<server-ip>\`

## Troubleshooting

### Docker Compose Mode
\`\`\`bash
cd ${ZROK_INSTALL_DIR}
docker compose logs -f           # all logs
docker compose logs zrok-controller  # controller only
docker compose ps                # service status
docker compose restart           # restart all
\`\`\`

### Bare Metal Mode
\`\`\`bash
systemctl status zrok-controller
systemctl status zrok-frontend
journalctl -u zrok-controller -f
journalctl -u zrok-frontend -f
\`\`\`

### Common Issues

1. **TLS certificate not provisioning**: Check DNS records resolve correctly and DNS provider API token is valid.
2. **Cannot connect**: Ensure ports 443, 18080, 8080, 3022 are open in your firewall.
3. **Share URLs not working**: Verify wildcard DNS (\*.${ZROK_DNS_ZONE}) resolves to this server.

## Credentials

Stored in: \`${ZROK_INSTALL_DIR}/${CREDENTIALS_FILE_NAME}\` (root-only readable)

## Uninstall

\`\`\`bash
sudo bash install-zrok.sh --uninstall --install-dir ${ZROK_INSTALL_DIR}
\`\`\`
READMEEOF
}

# ============================================================================
# SECTION I: UNINSTALL
# ============================================================================

do_uninstall() {
    local state_file="${ZROK_INSTALL_DIR}/${STATE_FILE_NAME}"

    echo ""
    log_warn "This will remove the zrok installation at ${ZROK_INSTALL_DIR}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would uninstall zrok from ${ZROK_INSTALL_DIR}"
        exit 0
    fi

    if ! confirm "Remove zrok installation? This cannot be undone."; then
        exit 0
    fi

    local mode="unknown"
    if [[ -f "${state_file}" ]]; then
        mode="$(jq -r '.mode // "unknown"' "${state_file}" 2>/dev/null || echo "unknown")"
    fi

    if [[ "${mode}" == "docker" ]] || [[ -f "${ZROK_INSTALL_DIR}/compose.yml" ]]; then
        log_info "Stopping Docker Compose services..."
        cd "${ZROK_INSTALL_DIR}" 2>/dev/null && \
            docker compose down --volumes --remove-orphans 2>/dev/null || true
    fi

    if [[ "${IS_MACOS}" != "true" ]] && { [[ "${mode}" == "baremetal" ]] || systemctl is-active zrok-controller &>/dev/null 2>&1; }; then
        log_info "Stopping systemd services..."
        for svc in zrok-metrics-bridge zrok-frontend zrok-controller; do
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
            rm -f "/etc/systemd/system/${svc}.service"
        done
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [[ "${IS_MACOS}" != "true" ]] && systemctl is-active traefik &>/dev/null 2>&1; then
        systemctl stop traefik 2>/dev/null || true
        systemctl disable traefik 2>/dev/null || true
        rm -f /etc/systemd/system/traefik.service
        rm -rf /etc/traefik
    fi

    if [[ "${IS_MACOS}" != "true" ]]; then
        rm -f /etc/nginx/sites-enabled/zrok 2>/dev/null || true
        rm -f /etc/nginx/sites-available/zrok 2>/dev/null || true
        rm -f /etc/nginx/conf.d/zrok.conf 2>/dev/null || true
        systemctl reload nginx 2>/dev/null || true
    fi

    if confirm "Remove installation directory ${ZROK_INSTALL_DIR}?"; then
        rm -rf "${ZROK_INSTALL_DIR}"
        log_success "Installation directory removed"
    fi

    log_success "zrok uninstalled"
    exit 0
}

# ============================================================================
# SECTION J: STATE MANAGEMENT
# ============================================================================

save_state() {
    local state_file="${ZROK_INSTALL_DIR}/${STATE_FILE_NAME}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        return 0
    fi

    cat > "${state_file}" << STATEEOF
{
    "installer_version": "${INSTALLER_VERSION}",
    "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "mode": "${DEPLOY_MODE}",
    "tls_provider": "${TLS_PROVIDER}",
    "dns_provider": "${DNS_PROVIDER}",
    "domain": "${ZROK_DNS_ZONE}",
    "email": "${ZROK_USER_EMAIL}",
    "install_dir": "${ZROK_INSTALL_DIR}",
    "modules": {
        "oauth": ${ENABLE_OAUTH},
        "metrics": ${ENABLE_METRICS},
        "limits": ${ENABLE_LIMITS},
        "organizations": ${ENABLE_ORGANIZATIONS}
    },
    "os": {
        "family": "${OS_FAMILY}",
        "id": "${OS_ID}",
        "version": "${OS_VERSION}"
    }
}
STATEEOF

    chmod 600 "${state_file}"
}

# ============================================================================
# SECTION K: FIREWALL HELPERS
# ============================================================================

open_firewall_ports() {
    if [[ "${FIREWALL_TYPE}" == "none" ]] || [[ "${FIREWALL_TYPE}" == "macos" ]]; then
        return 0
    fi

    if ! confirm "Open required ports (443, 18080, 8080, 3022) in ${FIREWALL_TYPE}?"; then
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[DRY RUN] Would open firewall ports"
        return 0
    fi

    case "${FIREWALL_TYPE}" in
        ufw)
            for port in 443 18080 8080 3022; do
                ufw allow "${port}/tcp" &>/dev/null || true
            done
            ufw reload &>/dev/null || true
            log_success "UFW ports opened"
            ;;
        firewalld)
            for port in 443 18080 8080 3022; do
                firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null || true
            done
            firewall-cmd --reload &>/dev/null || true
            log_success "firewalld ports opened"
            ;;
        iptables)
            for port in 443 18080 8080 3022; do
                iptables -A INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
            done
            log_success "iptables rules added (not persisted — install iptables-persistent)"
            ;;
    esac
}

# ============================================================================
# SECTION L: MAIN ENTRY POINT
# ============================================================================

main() {
    parse_args "$@"

    if [[ "${DO_UNINSTALL}" == "true" ]]; then
        do_uninstall
        exit 0
    fi

    print_banner

    if [[ "$(uname -s)" != "Darwin" ]] && [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root (or with sudo)."
        log_error "On macOS, root is not required for Docker Compose mode."
        exit 1
    fi

    echo -e "$(_c "${_BOLD}")  System Detection$(_c "${_RESET}")"
    print_separator

    detect_os
    detect_pkg_manager
    detect_arch
    detect_init_system
    detect_docker
    detect_selinux
    detect_firewall

    detect_existing_install

    echo ""
    echo -e "$(_c "${_BOLD}")  Configuration$(_c "${_RESET}")"
    print_separator

    prompt_deploy_environment
    prompt_install_location
    prompt_required_settings
    prompt_deployment_mode

    if [[ "${DEPLOY_MODE}" == "docker" ]]; then
        install_docker_if_missing
    fi

    prompt_tls_provider
    prompt_dns_provider
    prompt_optional_modules

    generate_all_secrets

    print_config_summary

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "=== DRY RUN MODE — no changes will be made ==="
        echo ""
    fi

    if ! confirm "Proceed with installation?"; then
        exit 0
    fi

    check_prerequisites
    check_ports
    check_dns
    open_firewall_ports

    echo ""
    echo -e "$(_c "${_BOLD}")  Installation$(_c "${_RESET}")"
    print_separator

    case "${DEPLOY_MODE}" in
        docker)    install_docker_compose ;;
        baremetal) install_bare_metal ;;
    esac

    save_state
    save_credentials
    generate_readme
    print_summary

    if [[ "${DEPLOY_ENV}" == "local-dynamic" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        setup_dynamic_dns
    elif [[ "${DEPLOY_ENV}" == "local-static" ]] && [[ "${DRY_RUN}" != "true" ]]; then
        print_port_forwarding_reminder
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo ""
        log_info "=== DRY RUN COMPLETE — no changes were made ==="
    fi
}

print_port_forwarding_reminder() {
    echo ""
    print_separator
    echo -e "  $(_c "${_YELLOW}${_BOLD}")Router Port Forwarding Required$(_c "${_RESET}")"
    print_separator
    local local_ip
    local_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || ifconfig 2>/dev/null | grep 'inet ' | grep -v 127.0.0.1 | awk '{print $2}' | head -1 || echo "this-machine")"
    echo ""
    echo -e "  Forward these ports from your router to $(_c "${_BOLD}")${local_ip}$(_c "${_RESET}"):"
    echo -e "    $(_c "${_BOLD}")443$(_c "${_RESET}")   → ${local_ip}  (HTTPS)"
    echo -e "    $(_c "${_BOLD}")8080$(_c "${_RESET}")  → ${local_ip}  (zrok frontend)"
    echo -e "    $(_c "${_BOLD}")18080$(_c "${_RESET}") → ${local_ip}  (zrok API)"
    echo -e "    $(_c "${_BOLD}")3022$(_c "${_RESET}")  → ${local_ip}  (OpenZiti)"
    echo ""
    local pub_ip
    pub_ip="$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || echo "")"
    if [[ -n "${pub_ip}" ]]; then
        echo -e "  Your public IP: $(_c "${_BOLD}")${pub_ip}$(_c "${_RESET}")"
        echo -e "  Point DNS:  ${ZROK_DNS_ZONE}   → A → ${pub_ip}"
        echo -e "  Point DNS:  *.${ZROK_DNS_ZONE} → A → ${pub_ip}"
    fi
    echo ""
}

setup_dynamic_dns() {
    echo ""
    print_separator
    echo -e "  $(_c "${_BOLD}")Dynamic DNS Setup$(_c "${_RESET}")"
    print_separator
    echo ""
    log_info "Local deployment needs Dynamic DNS to keep your domain pointing to your IP."

    local ddns_script="${ZROK_INSTALL_DIR}/ddns-update.sh"
    local ddns_url="https://raw.githubusercontent.com/ruban-s/zrok-installer/main/ddns-update.sh"

    log_info "Downloading DDNS updater..."
    curl -sSfL "${ddns_url}" -o "${ddns_script}" 2>/dev/null || {
        log_warn "Could not download ddns-update.sh"
        log_info "Download manually: ${ddns_url}"
        return 0
    }
    chmod +x "${ddns_script}"

    if [[ "${DNS_PROVIDER}" == "cloudflare" ]] && [[ -n "${DNS_TOKEN}" ]]; then
        log_info "Configuring DDNS with your Cloudflare token..."

        local config_dir="${HOME}/.zrok-ddns"
        mkdir -p "${config_dir}"

        local zone_root
        zone_root="$(echo "${ZROK_DNS_ZONE}" | awk -F. '{print $(NF-1)"."$NF}')"

        cat > "${config_dir}/config" << DDNSCFG
DDNS_DOMAIN="${ZROK_DNS_ZONE}"
CF_API_TOKEN="${DNS_TOKEN}"
CF_ZONE_ROOT="${zone_root}"
DDNS_INTERVAL="5"
DDNSCFG
        chmod 600 "${config_dir}/config"

        log_info "Running initial DNS update..."
        bash "${ddns_script}" --run 2>&1 || true

        log_info "Installing scheduled job (every 5 min)..."
        bash "${ddns_script}" --run 2>/dev/null || true

        if [[ "$(uname -s)" == "Darwin" ]]; then
            local plist_path="${HOME}/Library/LaunchAgents/com.zrok.ddns.plist"
            mkdir -p "${HOME}/Library/LaunchAgents"
            cat > "${plist_path}" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zrok.ddns</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${ddns_script}</string>
        <string>--run</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>${config_dir}/ddns.log</string>
    <key>StandardErrorPath</key>
    <string>${config_dir}/ddns.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF
            launchctl unload "${plist_path}" 2>/dev/null || true
            launchctl load "${plist_path}" 2>/dev/null || true
            log_success "launchd job installed (every 5 min)"
        else
            local cron_marker="# zrok-ddns"
            (crontab -l 2>/dev/null | grep -v "${cron_marker}") | {
                cat
                echo "*/5 * * * * ${ddns_script} --run >> ${config_dir}/ddns.log 2>&1 ${cron_marker}"
            } | crontab -
            log_success "Cron job installed (every 5 min)"
        fi

        log_success "Dynamic DNS configured!"
        echo ""
        echo -e "  IP auto-updates every 5 minutes"
        echo -e "  Log: ${config_dir}/ddns.log"
        echo -e "  Status: bash ${ddns_script} --status"
        echo -e "  Remove: bash ${ddns_script} --remove"
    else
        log_warn "Auto DDNS setup only available for Cloudflare."
        log_info "Run manually: bash ${ddns_script} --setup"
    fi

    echo ""
    echo -e "  $(_c "${_YELLOW}${_BOLD}")Router Port Forwarding Required:$(_c "${_RESET}")"
    echo -e "    Forward these ports from your router to this machine:"
    echo -e "    $(_c "${_BOLD}")443$(_c "${_RESET}")   → $(hostname -I 2>/dev/null | awk '{print $1}' || echo "this-machine")  (HTTPS)"
    echo -e "    $(_c "${_BOLD}")8080$(_c "${_RESET}")  → same  (zrok frontend)"
    echo -e "    $(_c "${_BOLD}")18080$(_c "${_RESET}") → same  (zrok API)"
    echo -e "    $(_c "${_BOLD}")3022$(_c "${_RESET}")  → same  (OpenZiti)"
    echo ""
}

main "$@"
