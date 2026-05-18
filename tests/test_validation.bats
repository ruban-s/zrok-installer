#!/usr/bin/env bats

setup() {
    source "${BATS_TEST_DIRNAME}/../install-zrok.sh" --source-only
}

@test "validate_domain accepts valid domain" {
    run validate_domain "share.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain accepts subdomain" {
    run validate_domain "zrok.share.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_domain rejects bare TLD" {
    run validate_domain "localhost"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain with semicolon" {
    run validate_domain "share;evil.com"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects domain with spaces" {
    run validate_domain "share .example.com"
    [ "$status" -eq 1 ]
}

@test "validate_domain rejects empty string" {
    run validate_domain ""
    [ "$status" -eq 1 ]
}

@test "validate_email accepts valid email" {
    run validate_email "admin@example.com"
    [ "$status" -eq 0 ]
}

@test "validate_email accepts email with dots" {
    run validate_email "admin.user@sub.example.com"
    [ "$status" -eq 0 ]
}

@test "validate_email rejects missing @" {
    run validate_email "adminexample.com"
    [ "$status" -eq 1 ]
}

@test "validate_email rejects empty string" {
    run validate_email ""
    [ "$status" -eq 1 ]
}

@test "validate_ip accepts valid IP" {
    run validate_ip "192.168.1.1"
    [ "$status" -eq 0 ]
}

@test "validate_ip rejects alpha chars" {
    run validate_ip "abc.def.ghi.jkl"
    [ "$status" -eq 1 ]
}

@test "validate_ip rejects empty string" {
    run validate_ip ""
    [ "$status" -eq 1 ]
}

@test "validate_port accepts valid port" {
    run validate_port "443"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 1" {
    run validate_port "1"
    [ "$status" -eq 0 ]
}

@test "validate_port accepts port 65535" {
    run validate_port "65535"
    [ "$status" -eq 0 ]
}

@test "validate_port rejects 0" {
    run validate_port "0"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric" {
    run validate_port "abc"
    [ "$status" -eq 1 ]
}

@test "validate_port rejects 65536" {
    run validate_port "65536"
    [ "$status" -eq 1 ]
}
