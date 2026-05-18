#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../install-zrok.sh" --source-only
}

@test "generate_password produces requested length" {
    pw="$(generate_password 16)"
    [ "${#pw}" -ge 16 ]
}

@test "generate_password default length is 24" {
    pw="$(generate_password)"
    [ "${#pw}" -ge 20 ]
}

@test "get_dns_plugin_name returns provider name" {
    DNS_PROVIDER="cloudflare"
    result="$(get_dns_plugin_name)"
    [ "$result" = "cloudflare" ]
}

@test "get_dns_plugin_name with prefix returns prefixed name" {
    DNS_PROVIDER="cloudflare"
    result="$(get_dns_plugin_name "certbot-dns-")"
    [ "$result" = "certbot-dns-cloudflare" ]
}

@test "get_caddy_plugin_name delegates to get_dns_plugin_name" {
    DNS_PROVIDER="digitalocean"
    result="$(get_caddy_plugin_name)"
    [ "$result" = "digitalocean" ]
}

@test "get_certbot_plugin_name adds certbot-dns- prefix" {
    DNS_PROVIDER="route53"
    result="$(get_certbot_plugin_name)"
    [ "$result" = "certbot-dns-route53" ]
}

@test "printf -v does not execute shell metacharacters" {
    local test_var=""
    local varname="test_var"
    local malicious_input="\$(echo PWNED)"
    printf -v "${varname}" '%s' "${malicious_input}"
    [ "$test_var" = "\$(echo PWNED)" ]
}

@test "retry_curl function exists" {
    run type retry_curl
    [ "$status" -eq 0 ]
}
