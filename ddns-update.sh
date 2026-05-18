#!/usr/bin/env bash
#
# zrok Dynamic DNS Updater
# Automatically updates Cloudflare DNS when your public IP changes.
# Pair with install-zrok.sh for local/home server deployments.
#
# Usage:
#   bash ddns-update.sh --setup     # interactive setup + install cron/launchd
#   bash ddns-update.sh --run       # single update check (used by cron)
#   bash ddns-update.sh --status    # show current config and IP
#   bash ddns-update.sh --remove    # remove cron/launchd job

set -euo pipefail

# ============================================================================
# CONSTANTS
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/${SCRIPT_NAME}"

CONFIG_DIR="${HOME}/.zrok-ddns"
CONFIG_FILE="${CONFIG_DIR}/config"
IP_CACHE_FILE="${CONFIG_DIR}/last-ip"
LOG_FILE="${CONFIG_DIR}/ddns.log"

# ============================================================================
# COLORS
# ============================================================================

_supports_color() { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }

readonly _RED=$'\033[0;31m'
readonly _GREEN=$'\033[0;32m'
readonly _YELLOW=$'\033[0;33m'
readonly _CYAN=$'\033[0;36m'
readonly _BOLD=$'\033[1m'
readonly _RESET=$'\033[0m'

_c() { if _supports_color; then printf '%b' "$1"; fi; }

log_info()    { echo -e "$(_c "${_CYAN}")  [INFO]$(_c "${_RESET}") $*"; }
log_warn()    { echo -e "$(_c "${_YELLOW}")  [WARN]$(_c "${_RESET}") $*" >&2; }
log_error()   { echo -e "$(_c "${_RED}") [ERROR]$(_c "${_RESET}") $*" >&2; }
log_success() { echo -e "$(_c "${_GREEN}")    [OK]$(_c "${_RESET}") $*"; }

log_to_file() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "${LOG_FILE}" 2>/dev/null || true
}

# ============================================================================
# PUBLIC IP DETECTION
# ============================================================================

get_public_ip() {
    local ip=""
    local services=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ipecho.net/plain"
    )

    for svc in "${services[@]}"; do
        ip="$(curl -sf --max-time 5 "${svc}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done

    log_error "Could not detect public IP from any service"
    return 1
}

get_cached_ip() {
    if [[ -f "${IP_CACHE_FILE}" ]]; then
        cat "${IP_CACHE_FILE}" 2>/dev/null
    fi
}

save_cached_ip() {
    echo "$1" > "${IP_CACHE_FILE}"
}

# ============================================================================
# CLOUDFLARE API
# ============================================================================

cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local args=(-sf -X "${method}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    if [[ -n "${data}" ]]; then
        args+=(-d "${data}")
    fi

    curl "${args[@]}" "https://api.cloudflare.com/client/v4${endpoint}" 2>/dev/null
}

cf_get_zone_id() {
    local zone_name="$1"
    local response
    response="$(cf_api GET "/zones?name=${zone_name}&status=active")"

    echo "${response}" | jq -r '.result[0].id // empty' 2>/dev/null
}

cf_get_record() {
    local zone_id="$1"
    local record_name="$2"
    local record_type="${3:-A}"

    local response
    response="$(cf_api GET "/zones/${zone_id}/dns_records?type=${record_type}&name=${record_name}")"

    echo "${response}" | jq -r '.result[0] // empty' 2>/dev/null
}

cf_create_record() {
    local zone_id="$1"
    local record_name="$2"
    local ip="$3"
    local proxied="${4:-false}"

    local data
    data=$(jq -n \
        --arg type "A" \
        --arg name "${record_name}" \
        --arg content "${ip}" \
        --argjson proxied "${proxied}" \
        --argjson ttl 60 \
        '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')

    cf_api POST "/zones/${zone_id}/dns_records" "${data}"
}

cf_update_record() {
    local zone_id="$1"
    local record_id="$2"
    local record_name="$3"
    local ip="$4"
    local proxied="${5:-false}"

    local data
    data=$(jq -n \
        --arg type "A" \
        --arg name "${record_name}" \
        --arg content "${ip}" \
        --argjson proxied "${proxied}" \
        --argjson ttl 60 \
        '{type: $type, name: $name, content: $content, proxied: $proxied, ttl: $ttl}')

    cf_api PATCH "/zones/${zone_id}/dns_records/${record_id}" "${data}"
}

# ============================================================================
# DNS UPDATE LOGIC
# ============================================================================

update_dns_record() {
    local zone_id="$1"
    local record_name="$2"
    local ip="$3"

    local existing
    existing="$(cf_get_record "${zone_id}" "${record_name}")"

    if [[ -z "${existing}" ]] || [[ "${existing}" == "null" ]]; then
        log_info "Creating DNS record: ${record_name} → ${ip}"
        local result
        result="$(cf_create_record "${zone_id}" "${record_name}" "${ip}" false)"
        if echo "${result}" | jq -e '.success' &>/dev/null; then
            log_success "Created: ${record_name} → ${ip}"
            log_to_file "CREATED ${record_name} → ${ip}"
            return 0
        else
            local err
            err="$(echo "${result}" | jq -r '.errors[0].message // "unknown"' 2>/dev/null)"
            log_error "Failed to create ${record_name}: ${err}"
            log_to_file "FAILED create ${record_name}: ${err}"
            return 1
        fi
    fi

    local current_ip
    current_ip="$(echo "${existing}" | jq -r '.content' 2>/dev/null)"
    local record_id
    record_id="$(echo "${existing}" | jq -r '.id' 2>/dev/null)"

    if [[ "${current_ip}" == "${ip}" ]]; then
        return 0
    fi

    log_info "Updating DNS record: ${record_name} ${current_ip} → ${ip}"
    local result
    result="$(cf_update_record "${zone_id}" "${record_id}" "${record_name}" "${ip}" false)"
    if echo "${result}" | jq -e '.success' &>/dev/null; then
        log_success "Updated: ${record_name} → ${ip}"
        log_to_file "UPDATED ${record_name} ${current_ip} → ${ip}"
        return 0
    else
        local err
        err="$(echo "${result}" | jq -r '.errors[0].message // "unknown"' 2>/dev/null)"
        log_error "Failed to update ${record_name}: ${err}"
        log_to_file "FAILED update ${record_name}: ${err}"
        return 1
    fi
}

do_update() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_error "Not configured. Run: ${SCRIPT_NAME} --setup"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    local current_ip
    current_ip="$(get_public_ip)" || exit 1

    local cached_ip
    cached_ip="$(get_cached_ip)"

    if [[ "${current_ip}" == "${cached_ip}" ]]; then
        log_to_file "NO CHANGE ip=${current_ip}"
        if [[ -t 1 ]]; then
            log_info "IP unchanged: ${current_ip}"
        fi
        return 0
    fi

    log_info "IP changed: ${cached_ip:-"(none)"} → ${current_ip}"
    log_to_file "IP CHANGED ${cached_ip:-"(none)"} → ${current_ip}"

    local zone_id
    zone_id="$(cf_get_zone_id "${CF_ZONE_ROOT}")"

    if [[ -z "${zone_id}" ]]; then
        log_error "Could not find Cloudflare zone for: ${CF_ZONE_ROOT}"
        log_error "Check API token has Zone:Read permission"
        exit 1
    fi

    update_dns_record "${zone_id}" "${DDNS_DOMAIN}" "${current_ip}"

    update_dns_record "${zone_id}" "*.${DDNS_DOMAIN}" "${current_ip}"

    save_cached_ip "${current_ip}"
    log_success "DNS updated to ${current_ip}"
}

# ============================================================================
# SETUP
# ============================================================================

do_setup() {
    echo ""
    echo -e "$(_c "${_BOLD}${_CYAN}")  zrok Dynamic DNS Updater — Setup$(_c "${_RESET}")"
    echo ""

    if ! command -v jq &>/dev/null; then
        log_error "jq is required. Install: brew install jq (macOS) or apt install jq (Linux)"
        exit 1
    fi

    local domain=""
    local token=""
    local interval="5"

    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
        domain="${DDNS_DOMAIN:-}"
        token="${CF_API_TOKEN:-}"
        log_info "Existing config found. Press Enter to keep current values."
    fi

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") zrok domain (e.g., share.example.com) [${domain}]: "
    local input
    read -r input < /dev/tty
    domain="${input:-${domain}}"

    if [[ -z "${domain}" ]]; then
        log_error "Domain required."
        exit 1
    fi

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Cloudflare API token [${token:+****${token: -4}}]: "
    read -rs input < /dev/tty
    echo ""
    token="${input:-${token}}"

    if [[ -z "${token}" ]]; then
        log_error "API token required."
        exit 1
    fi

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Check interval in minutes [${interval}]: "
    read -r input < /dev/tty
    interval="${input:-${interval}}"

    # Extract root zone (last two parts of domain)
    local zone_root
    zone_root="$(echo "${domain}" | awk -F. '{print $(NF-1)"."$NF}')"

    # Verify token
    log_info "Verifying Cloudflare token..."
    CF_API_TOKEN="${token}"
    local verify
    verify="$(cf_api GET "/user/tokens/verify" 2>/dev/null || echo "")"
    if echo "${verify}" | grep -q '"success":true'; then
        log_success "Token valid"
    else
        log_error "Token verification failed"
        exit 1
    fi

    # Verify zone access
    local zone_id
    zone_id="$(cf_get_zone_id "${zone_root}")"
    if [[ -z "${zone_id}" ]]; then
        log_error "Cannot find zone '${zone_root}' with this token"
        log_error "Token needs Zone:Read and DNS:Edit permissions"
        exit 1
    fi
    log_success "Zone found: ${zone_root} (${zone_id})"

    # Save config
    mkdir -p -m 700 "${CONFIG_DIR}"
    install -m 600 /dev/null "${CONFIG_FILE}"
    cat > "${CONFIG_FILE}" << CFGEOF
# zrok DDNS config — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
DDNS_DOMAIN="${domain}"
CF_API_TOKEN="${token}"
CF_ZONE_ROOT="${zone_root}"
DDNS_INTERVAL="${interval}"
CFGEOF
    log_success "Config saved to ${CONFIG_FILE}"

    # Initial update
    log_info "Running initial DNS update..."
    do_update

    # Install scheduled job
    install_scheduled_job "${interval}"

    echo ""
    log_success "Dynamic DNS configured!"
    echo ""
    echo -e "  Domain:    ${domain}"
    echo -e "  Wildcard:  *.${domain}"
    echo -e "  Interval:  every ${interval} minutes"
    echo -e "  Log:       ${LOG_FILE}"
    echo -e "  Config:    ${CONFIG_FILE}"
    echo ""
}

# ============================================================================
# CRON / LAUNCHD
# ============================================================================

install_scheduled_job() {
    local interval="$1"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        install_launchd_job "${interval}"
    else
        install_cron_job "${interval}"
    fi
}

install_cron_job() {
    local interval="$1"
    local cron_line="*/${interval} * * * * ${SCRIPT_PATH} --run >> ${LOG_FILE} 2>&1"
    local cron_marker="# zrok-ddns"

    (crontab -l 2>/dev/null | grep -v "${cron_marker}") | {
        cat
        echo "${cron_line} ${cron_marker}"
    } | crontab -

    log_success "Cron job installed (every ${interval} min)"
}

install_launchd_job() {
    local interval="$1"
    local interval_seconds=$((interval * 60))
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
        <string>${SCRIPT_PATH}</string>
        <string>--run</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval_seconds}</integer>
    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF

    launchctl unload "${plist_path}" 2>/dev/null || true
    launchctl load "${plist_path}" 2>/dev/null || true

    log_success "launchd job installed (every ${interval} min)"
}

remove_scheduled_job() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local plist_path="${HOME}/Library/LaunchAgents/com.zrok.ddns.plist"
        launchctl unload "${plist_path}" 2>/dev/null || true
        rm -f "${plist_path}"
        log_success "launchd job removed"
    else
        local cron_marker="# zrok-ddns"
        (crontab -l 2>/dev/null | grep -v "${cron_marker}") | crontab -
        log_success "Cron job removed"
    fi
}

# ============================================================================
# STATUS / REMOVE
# ============================================================================

do_status() {
    echo ""
    echo -e "$(_c "${_BOLD}")  zrok Dynamic DNS Status$(_c "${_RESET}")"
    echo ""

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log_warn "Not configured. Run: ${SCRIPT_NAME} --setup"
        return
    fi

    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    local current_ip
    current_ip="$(get_public_ip 2>/dev/null || echo "unknown")"
    local cached_ip
    cached_ip="$(get_cached_ip)"

    echo -e "  Domain:      ${DDNS_DOMAIN}"
    echo -e "  Wildcard:    *.${DDNS_DOMAIN}"
    echo -e "  Current IP:  ${current_ip}"
    echo -e "  Last known:  ${cached_ip:-"(none)"}"
    echo -e "  Interval:    every ${DDNS_INTERVAL} min"
    echo -e "  Config:      ${CONFIG_FILE}"
    echo -e "  Log:         ${LOG_FILE}"

    if [[ "${current_ip}" != "${cached_ip}" ]] && [[ "${current_ip}" != "unknown" ]]; then
        echo ""
        log_warn "IP has changed since last update!"
        log_info "Run '${SCRIPT_NAME} --run' to update now"
    fi

    if [[ -f "${LOG_FILE}" ]]; then
        echo ""
        echo -e "  $(_c "${_BOLD}")Last 5 log entries:$(_c "${_RESET}")"
        tail -5 "${LOG_FILE}" | while read -r line; do
            echo "    ${line}"
        done
    fi
    echo ""
}

do_remove() {
    echo ""
    log_warn "This will remove the DDNS scheduled job and config."

    echo -n -e "$(_c "${_YELLOW}")  [?]$(_c "${_RESET}") Remove zrok DDNS? [y/N] "
    local answer
    read -r answer < /dev/tty
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        exit 0
    fi

    remove_scheduled_job
    rm -rf "${CONFIG_DIR}"
    log_success "zrok DDNS removed"
}

# ============================================================================
# MAIN
# ============================================================================

show_help() {
    cat << 'HELP'
zrok Dynamic DNS Updater

Automatically updates Cloudflare DNS records when your public IP changes.
Designed to pair with install-zrok.sh for local/home server deployments.

USAGE:
  bash ddns-update.sh --setup      Interactive setup + install cron/launchd
  bash ddns-update.sh --run        Single update check (used by scheduler)
  bash ddns-update.sh --status     Show current config, IP, and recent logs
  bash ddns-update.sh --remove     Remove scheduled job and config
  bash ddns-update.sh --help       Show this help

REQUIREMENTS:
  - curl, jq
  - Cloudflare API token with Zone:Read and DNS:Edit permissions

WHAT IT DOES:
  1. Detects your current public IP
  2. Compares with last known IP
  3. If changed, updates Cloudflare DNS:
     - yourdomain.com    → A → new IP
     - *.yourdomain.com  → A → new IP
  4. Runs on schedule (cron on Linux, launchd on macOS)
HELP
}

main() {
    case "${1:-}" in
        --setup)   do_setup ;;
        --run)     do_update ;;
        --status)  do_status ;;
        --remove)  do_remove ;;
        --help|-h) show_help ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

main "$@"
