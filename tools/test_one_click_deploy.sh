#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ONE_CLICK_DEPLOY_TEST_MODE=1
# shellcheck disable=SC1091
source "${ROOT_DIR}/deploy/one-click-deploy.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "${msg}: expected '${expected}', got '${actual}'"
    fi
}

test_defaults() {
    set_defaults
    assert_eq "$SERVER_HOST" "0.0.0.0" "default server host"
    assert_eq "$SERVER_PORT" "8080" "default server port"
    assert_eq "$FORCE" "false" "default force"
    assert_eq "$DRY_RUN" "false" "default dry-run"
}

test_parse_args_custom_values() {
    set_defaults
    parse_args \
        --server-host 127.0.0.1 \
        --server-port 18080 \
        --admin-email root@example.com \
        --admin-password secret123 \
        --force \
        --skip-upgrade-system \
        --dry-run

    assert_eq "$CLI_SERVER_HOST" "127.0.0.1" "custom server host"
    assert_eq "$CLI_SERVER_PORT" "18080" "custom server port"
    assert_eq "$CLI_ADMIN_EMAIL" "root@example.com" "custom admin email"
    assert_eq "$CLI_ADMIN_PASSWORD" "secret123" "custom admin password"
    assert_eq "$FORCE" "true" "force flag"
    assert_eq "$SKIP_UPGRADE_SYSTEM" "true" "skip upgrade flag"
    assert_eq "$DRY_RUN" "true" "dry-run flag"
}

test_admin_password_source_cli() {
    set_defaults
    parse_args --admin-password secret123
    apply_cli_overrides
    assert_eq "$ADMIN_PASSWORD" "secret123" "admin password override"
    assert_eq "$ADMIN_PASSWORD_SOURCE" "cli" "admin password source"
}

test_parse_args_invalid_port() {
    if ( set_defaults; parse_args --server-port 70000 >/dev/null 2>&1 ); then
        fail "invalid port should fail"
    fi
}

test_escape_systemd_value() {
    local input='abc"def\ghi'
    local escaped=""
    escaped="$(escape_systemd_value "$input")"
    assert_eq "$escaped" 'abc\"def\\ghi' "systemd escape"
}

main() {
    test_defaults
    test_parse_args_custom_values
    test_admin_password_source_cli
    test_parse_args_invalid_port
    test_escape_systemd_value
    echo "PASS: test_one_click_deploy.sh"
}

main "$@"
