#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${SCRIPT_DIR}"

PASS=0
FAIL=0

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_TEST}"' EXIT

run_test() {
    local name="$1"
    shift
    if bash install-zrok.sh --install-dir "${TMPDIR_TEST}/zrok-$$" "$@" >/dev/null 2>&1; then
        echo "PASS: ${name}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${name}"
        FAIL=$((FAIL + 1))
    fi
}

run_test "docker+caddy+cloudflare" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls caddy --dns-provider cloudflare --dns-token tk --yes

run_test "docker+traefik+digitalocean" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls traefik --dns-provider digitalocean --dns-token tk --yes

run_test "docker+caddy+route53" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls caddy --dns-provider route53 --dns-token key:secret --yes

run_test "docker+caddy+godaddy" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls caddy --dns-provider godaddy --dns-token tk --yes

run_test "docker+caddy+namecheap" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls caddy --dns-provider namecheap --dns-token tk --yes

run_test "docker+caddy+all-modules" \
    --dry-run --domain test.example.com --email t@t.com --password p \
    --mode docker --tls caddy --dns-provider cloudflare --dns-token tk \
    --with-oauth --with-metrics --with-limits --with-organizations --yes

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
