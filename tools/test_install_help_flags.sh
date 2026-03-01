#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

output="$(bash "${ROOT_DIR}/deploy/install.sh" --help 2>&1 || true)"

echo "$output" | grep -q -- "--non-interactive" || {
    echo "FAIL: --non-interactive flag missing from install.sh help" >&2
    exit 1
}

echo "$output" | grep -q -- "--server-host <host>" || {
    echo "FAIL: --server-host flag missing from install.sh help" >&2
    exit 1
}

echo "$output" | grep -q -- "--server-port <port>" || {
    echo "FAIL: --server-port flag missing from install.sh help" >&2
    exit 1
}

echo "PASS: test_install_help_flags.sh"
