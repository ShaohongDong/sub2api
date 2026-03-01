#!/usr/bin/env bash
# =============================================================================
# Sub2API One-Click Binary Deployment Script (Ubuntu/Debian)
# =============================================================================
# This script performs end-to-end deployment with systemd:
#   - Installs required dependencies via apt
#   - Installs and configures PostgreSQL + Redis locally
#   - Installs/updates Sub2API binary via deploy/install.sh
#   - Enables AUTO_SETUP and writes service drop-in env vars
#   - Restarts service and verifies /health
#
# Usage examples:
#   curl -sSL https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/one-click-deploy.sh | bash
#   ./one-click-deploy.sh --server-port 8080 --admin-email admin@example.com --admin-password 'StrongPassword'
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

GITHUB_REPO="Wei-Shaw/sub2api"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_REPO}/main/deploy"

STATE_FILE="/etc/sub2api/.one-click-deploy.env"
CREDENTIALS_FILE="/etc/sub2api/.install-credentials"
DROPIN_DIR="/etc/systemd/system/sub2api.service.d"
DROPIN_FILE="${DROPIN_DIR}/10-autosetup.conf"

INSTALL_DIR="/opt/sub2api"
SERVICE_FILE="/etc/systemd/system/sub2api.service"
SERVICE_NAME="sub2api"

declare -a SUDO_CMD

set_defaults() {
    SERVER_HOST="0.0.0.0"
    SERVER_PORT="8080"
    ADMIN_EMAIL="admin@sub2api.local"
    ADMIN_PASSWORD=""
    FORCE="false"
    SKIP_UPGRADE_SYSTEM="false"
    DRY_RUN="false"

    CLI_SERVER_HOST=""
    CLI_SERVER_PORT=""
    CLI_ADMIN_EMAIL=""
    CLI_ADMIN_PASSWORD=""

    POSTGRES_APP_USER="sub2api"
    POSTGRES_APP_DB="sub2api"
    POSTGRES_APP_PASSWORD=""
    REDIS_APP_PASSWORD=""
    JWT_SECRET=""

    ADMIN_PASSWORD_SOURCE="unset"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

format_cmd() {
    local out=""
    local arg=""
    for arg in "$@"; do
        out+="$(printf '%q' "$arg") "
    done
    printf '%s' "${out% }"
}

run_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} [dry-run] $(format_cmd "$@")" >&2
        return 0
    fi
    "$@"
}

run_root() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} [dry-run][root] $(format_cmd "$@")" >&2
        return 0
    fi

    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then
        "${SUDO_CMD[@]}" "$@"
    else
        "$@"
    fi
}

run_as_postgres() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[INFO]${NC} [dry-run][postgres] $(format_cmd "$@")" >&2
        return 0
    fi

    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then
        "${SUDO_CMD[@]}" -u postgres "$@"
        return
    fi

    if command_exists runuser; then
        runuser -u postgres -- "$@"
        return
    fi

    print_error "runuser is required when running as root without sudo."
    exit 1
}

usage() {
    cat <<'EOF'
Sub2API One-Click Binary Deployment (Ubuntu/Debian)

Usage:
  one-click-deploy.sh [options]

Options:
  --server-host <host>         Sub2API listen address (default: 0.0.0.0)
  --server-port <port>         Sub2API listen port (default: 8080)
  --admin-email <email>        Initial admin email (default: admin@sub2api.local)
  --admin-password <password>  Initial admin password (default: auto-generate)
  --force                      Regenerate managed credentials and overwrite drop-in
  --skip-upgrade-system        Skip apt-get update step
  --dry-run                    Print planned actions only
  -h, --help                   Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --server-host)
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
                    CLI_SERVER_HOST="$2"
                    shift 2
                else
                    print_error "--server-host requires a value."
                    exit 1
                fi
                ;;
            --server-port)
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
                    if ! validate_port "$2"; then
                        print_error "--server-port must be between 1 and 65535."
                        exit 1
                    fi
                    CLI_SERVER_PORT="$2"
                    shift 2
                else
                    print_error "--server-port requires a value."
                    exit 1
                fi
                ;;
            --admin-email)
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
                    CLI_ADMIN_EMAIL="$2"
                    shift 2
                else
                    print_error "--admin-email requires a value."
                    exit 1
                fi
                ;;
            --admin-password)
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
                    CLI_ADMIN_PASSWORD="$2"
                    shift 2
                else
                    print_error "--admin-password requires a value."
                    exit 1
                fi
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --skip-upgrade-system)
                SKIP_UPGRADE_SYSTEM="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

init_privileges() {
    if [ "$DRY_RUN" = "true" ]; then
        SUDO_CMD=()
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        SUDO_CMD=()
        return
    fi

    if ! command_exists sudo; then
        print_error "This script needs root privileges. Install sudo or run as root."
        exit 1
    fi

    SUDO_CMD=(sudo)
}

check_supported_os() {
    if [ ! -f /etc/os-release ]; then
        print_error "Unable to detect OS (/etc/os-release missing)."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    local id_lower="${ID,,}"
    local id_like_lower="${ID_LIKE,,}"
    if [ "$id_lower" != "ubuntu" ] && [ "$id_lower" != "debian" ] && [[ "$id_like_lower" != *debian* ]]; then
        print_error "Unsupported OS: ${ID}. This script currently supports Ubuntu/Debian."
        exit 1
    fi

    print_info "Detected OS: ${PRETTY_NAME}"
}

install_dependencies() {
    local packages=(
        curl
        tar
        openssl
        ca-certificates
        postgresql
        redis-server
        redis-tools
    )

    if ! command_exists systemctl; then
        print_error "systemctl not found. A systemd-based host is required."
        exit 1
    fi

    if [ "$SKIP_UPGRADE_SYSTEM" != "true" ]; then
        print_info "Running apt-get update..."
        run_root apt-get update
    else
        print_warning "Skipping apt-get update (--skip-upgrade-system enabled)."
    fi

    print_info "Installing dependencies: ${packages[*]}"
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

check_release_endpoint() {
    if [ "$DRY_RUN" = "true" ]; then
        print_info "[dry-run] Skipping release endpoint check."
        return
    fi

    print_info "Checking GitHub release endpoint..."
    if ! curl -fsS --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" >/dev/null; then
        print_error "Failed to reach GitHub release API."
        print_error "Please verify network access and retry."
        exit 1
    fi
}

generate_secret() {
    if [ "$DRY_RUN" = "true" ]; then
        printf 'dryrun-%s-%s' "$(date +%s)" "$RANDOM"
        return
    fi
    openssl rand -hex 32
}

load_state_file() {
    if [ "$DRY_RUN" = "true" ]; then
        return 1
    fi

    if ! run_root test -f "$STATE_FILE"; then
        return 1
    fi

    print_info "Loading existing deployment state from ${STATE_FILE}."
    local reader="cat"
    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then
        reader="${SUDO_CMD[*]} cat"
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            POSTGRES_APP_USER|POSTGRES_APP_DB|POSTGRES_APP_PASSWORD|REDIS_APP_PASSWORD|JWT_SECRET|ADMIN_EMAIL|ADMIN_PASSWORD|SERVER_HOST|SERVER_PORT)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < <(bash -lc "${reader} '$STATE_FILE'")

    if [ -n "${ADMIN_PASSWORD:-}" ]; then
        ADMIN_PASSWORD_SOURCE="state"
    fi

    return 0
}

save_state_file() {
    local tmp_file=""
    tmp_file="$(mktemp)"

    cat >"$tmp_file" <<EOF
POSTGRES_APP_USER=${POSTGRES_APP_USER}
POSTGRES_APP_DB=${POSTGRES_APP_DB}
POSTGRES_APP_PASSWORD=${POSTGRES_APP_PASSWORD}
REDIS_APP_PASSWORD=${REDIS_APP_PASSWORD}
JWT_SECRET=${JWT_SECRET}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}
EOF

    run_root mkdir -p /etc/sub2api
    run_root install -m 600 "$tmp_file" "$STATE_FILE"
    rm -f "$tmp_file"
}

apply_cli_overrides() {
    if [ -n "$CLI_SERVER_HOST" ]; then
        SERVER_HOST="$CLI_SERVER_HOST"
    fi
    if [ -n "$CLI_SERVER_PORT" ]; then
        SERVER_PORT="$CLI_SERVER_PORT"
    fi
    if [ -n "$CLI_ADMIN_EMAIL" ]; then
        ADMIN_EMAIL="$CLI_ADMIN_EMAIL"
    fi
    if [ -n "$CLI_ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD="$CLI_ADMIN_PASSWORD"
        ADMIN_PASSWORD_SOURCE="cli"
    fi
}

initialize_state() {
    if [ "$FORCE" != "true" ]; then
        load_state_file || true
    fi

    apply_cli_overrides

    if [ -z "$POSTGRES_APP_PASSWORD" ] || [ "$FORCE" = "true" ]; then
        POSTGRES_APP_PASSWORD="$(generate_secret)"
    fi
    if [ -z "$REDIS_APP_PASSWORD" ] || [ "$FORCE" = "true" ]; then
        REDIS_APP_PASSWORD="$(generate_secret)"
    fi
    if [ -z "$JWT_SECRET" ] || [ "$FORCE" = "true" ]; then
        JWT_SECRET="$(generate_secret)"
    fi

    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD="$(generate_secret)"
        ADMIN_PASSWORD_SOURCE="auto"
    elif [ "$ADMIN_PASSWORD_SOURCE" = "unset" ]; then
        ADMIN_PASSWORD_SOURCE="state"
    fi

    save_state_file
}

configure_postgresql() {
    print_info "Ensuring PostgreSQL is enabled and running..."
    run_root systemctl enable --now postgresql

    if [ "$DRY_RUN" = "true" ]; then
        return
    fi

    print_info "Configuring PostgreSQL role/database for Sub2API..."
    run_as_postgres psql -v ON_ERROR_STOP=1 --dbname postgres <<EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_APP_USER}') THEN
        CREATE ROLE ${POSTGRES_APP_USER} LOGIN PASSWORD '${POSTGRES_APP_PASSWORD}';
    ELSE
        ALTER ROLE ${POSTGRES_APP_USER} WITH LOGIN PASSWORD '${POSTGRES_APP_PASSWORD}';
    END IF;
END
\$\$;
EOF

    local db_exists=""
    db_exists="$(run_as_postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${POSTGRES_APP_DB}'" | tr -d '[:space:]' || true)"
    if [ "$db_exists" != "1" ]; then
        run_as_postgres createdb --owner="${POSTGRES_APP_USER}" "${POSTGRES_APP_DB}"
    fi

    print_success "PostgreSQL is ready."
}

detect_redis_conf() {
    local candidates=(
        "/etc/redis/redis.conf"
        "/etc/redis/redis-server.conf"
    )

    local item=""
    for item in "${candidates[@]}"; do
        if run_root test -f "$item"; then
            printf '%s' "$item"
            return 0
        fi
    done

    return 1
}

configure_redis() {
    print_info "Ensuring Redis is enabled and running..."
    run_root systemctl enable --now redis-server

    local redis_conf=""
    redis_conf="$(detect_redis_conf || true)"
    if [ -z "$redis_conf" ]; then
        print_error "Unable to locate Redis config file."
        exit 1
    fi

    print_info "Configuring Redis password in ${redis_conf}..."
    local backup_file="${redis_conf}.bak.one-click.$(date +%Y%m%d%H%M%S)"
    run_root cp "$redis_conf" "$backup_file"

    if ! run_root sed -i -E "s|^[#[:space:]]*requirepass[[:space:]].*|requirepass ${REDIS_APP_PASSWORD}|g" "$redis_conf"; then
        print_error "Failed to update Redis config."
        print_warning "Restoring backup: ${backup_file}"
        run_root cp "$backup_file" "$redis_conf"
        exit 1
    fi

    if ! run_root grep -Eq '^[[:space:]]*requirepass[[:space:]]+' "$redis_conf"; then
        run_root bash -lc "printf '\nrequirepass %s\n' '${REDIS_APP_PASSWORD}' >> '${redis_conf}'"
    fi

    if ! run_root systemctl restart redis-server; then
        print_error "Failed to restart Redis after password update."
        print_warning "Restoring backup and retrying..."
        run_root cp "$backup_file" "$redis_conf"
        run_root systemctl restart redis-server || true
        exit 1
    fi

    if [ "$DRY_RUN" != "true" ]; then
        local pong=""
        pong="$(redis-cli -a "$REDIS_APP_PASSWORD" ping 2>/dev/null || true)"
        if [ "$pong" != "PONG" ]; then
            print_error "Redis password verification failed."
            exit 1
        fi
    fi

    print_success "Redis is ready."
}

download_install_script() {
    local target_file="$1"
    if command_exists curl; then
        run_cmd curl -fsSL "${GITHUB_RAW_BASE}/install.sh" -o "$target_file"
        return
    fi
    if command_exists wget; then
        run_cmd wget -q "${GITHUB_RAW_BASE}/install.sh" -O "$target_file"
        return
    fi

    print_error "Neither curl nor wget is available."
    exit 1
}

install_sub2api_binary() {
    local install_script=""
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "${script_dir}/install.sh" ]; then
        install_script="${script_dir}/install.sh"
    else
        install_script="$(mktemp)"
        print_info "Local install.sh not found, downloading from GitHub..."
        download_install_script "$install_script"
    fi

    local already_installed="false"
    if run_root test -x "${INSTALL_DIR}/sub2api" && run_root test -f "${SERVICE_FILE}" && [ "$FORCE" != "true" ]; then
        already_installed="true"
    fi

    if [ "$already_installed" = "true" ]; then
        print_info "Sub2API binary already installed. Skipping reinstall (use --force to reinstall)."
    else
        print_info "Installing Sub2API binary via install.sh..."
        run_root bash "$install_script" install --non-interactive --server-host "$SERVER_HOST" --server-port "$SERVER_PORT"
    fi

    if [ "$install_script" != "${script_dir}/install.sh" ]; then
        run_cmd rm -f "$install_script"
    fi
}

escape_systemd_value() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_autosetup_dropin() {
    print_info "Writing systemd drop-in for AUTO_SETUP..."

    local tmp_file=""
    tmp_file="$(mktemp)"

    local e_server_host e_server_port e_db_user e_db_name e_db_pass
    local e_redis_pass e_admin_email e_admin_pass e_jwt
    e_server_host="$(escape_systemd_value "$SERVER_HOST")"
    e_server_port="$(escape_systemd_value "$SERVER_PORT")"
    e_db_user="$(escape_systemd_value "$POSTGRES_APP_USER")"
    e_db_name="$(escape_systemd_value "$POSTGRES_APP_DB")"
    e_db_pass="$(escape_systemd_value "$POSTGRES_APP_PASSWORD")"
    e_redis_pass="$(escape_systemd_value "$REDIS_APP_PASSWORD")"
    e_admin_email="$(escape_systemd_value "$ADMIN_EMAIL")"
    e_admin_pass="$(escape_systemd_value "$ADMIN_PASSWORD")"
    e_jwt="$(escape_systemd_value "$JWT_SECRET")"

    cat >"$tmp_file" <<EOF
[Service]
Environment="AUTO_SETUP=true"
Environment="GIN_MODE=release"
Environment="SERVER_HOST=${e_server_host}"
Environment="SERVER_PORT=${e_server_port}"
Environment="DATABASE_HOST=127.0.0.1"
Environment="DATABASE_PORT=5432"
Environment="DATABASE_USER=${e_db_user}"
Environment="DATABASE_PASSWORD=${e_db_pass}"
Environment="DATABASE_DBNAME=${e_db_name}"
Environment="DATABASE_SSLMODE=disable"
Environment="REDIS_HOST=127.0.0.1"
Environment="REDIS_PORT=6379"
Environment="REDIS_PASSWORD=${e_redis_pass}"
Environment="REDIS_DB=0"
Environment="ADMIN_EMAIL=${e_admin_email}"
Environment="ADMIN_PASSWORD=${e_admin_pass}"
Environment="JWT_SECRET=${e_jwt}"
EOF

    run_root mkdir -p "$DROPIN_DIR"
    run_root install -m 600 "$tmp_file" "$DROPIN_FILE"
    run_cmd rm -f "$tmp_file"
}

restart_sub2api() {
    print_info "Reloading systemd and restarting ${SERVICE_NAME}..."
    run_root systemctl daemon-reload
    run_root systemctl enable --now "$SERVICE_NAME"
    run_root systemctl restart "$SERVICE_NAME"
}

health_check() {
    local check_host="$SERVER_HOST"
    if [ "$check_host" = "0.0.0.0" ] || [ "$check_host" = "::" ]; then
        check_host="127.0.0.1"
    fi
    local url="http://${check_host}:${SERVER_PORT}/health"
    local max_attempts=60
    local attempt=1

    if [ "$DRY_RUN" = "true" ]; then
        print_info "[dry-run] Skipping health check: ${url}"
        return
    fi

    print_info "Checking health endpoint: ${url}"
    while [ "$attempt" -le "$max_attempts" ]; do
        if curl -fsS "$url" >/dev/null 2>&1; then
            print_success "Health check passed."
            return
        fi
        sleep 2
        attempt=$((attempt + 1))
    done

    print_error "Health check failed after $((max_attempts * 2)) seconds."
    print_info "Try: sudo journalctl -u ${SERVICE_NAME} -n 100"
    exit 1
}

write_credentials_file() {
    local tmp_file=""
    tmp_file="$(mktemp)"

    cat >"$tmp_file" <<EOF
Sub2API one-click deployment credentials
Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

SERVER_HOST=${SERVER_HOST}
SERVER_PORT=${SERVER_PORT}

POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DB=${POSTGRES_APP_DB}
POSTGRES_USER=${POSTGRES_APP_USER}
POSTGRES_PASSWORD=${POSTGRES_APP_PASSWORD}

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_APP_PASSWORD}

ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}

JWT_SECRET=${JWT_SECRET}
STATE_FILE=${STATE_FILE}
DROPIN_FILE=${DROPIN_FILE}
EOF

    run_root mkdir -p /etc/sub2api
    run_root install -m 600 "$tmp_file" "$CREDENTIALS_FILE"
    run_cmd rm -f "$tmp_file"
}

print_summary() {
    local display_host="$SERVER_HOST"
    if [ "$display_host" = "0.0.0.0" ] || [ "$display_host" = "::" ]; then
        display_host="127.0.0.1"
    fi

    echo ""
    echo "=========================================="
    echo "  Sub2API One-Click Deployment Complete"
    echo "=========================================="
    echo ""
    echo "Service URL:"
    echo "  http://${display_host}:${SERVER_PORT}"
    echo ""
    echo "Credentials file (root-only):"
    echo "  ${CREDENTIALS_FILE}"
    echo ""
    echo "Admin account:"
    echo "  email:    ${ADMIN_EMAIL}"
    if [ "$ADMIN_PASSWORD_SOURCE" = "cli" ]; then
        echo "  password: (provided via --admin-password)"
    elif [ "$ADMIN_PASSWORD_SOURCE" = "state" ]; then
        echo "  password: (reused from previous deployment state)"
    else
        echo "  password: ${ADMIN_PASSWORD}"
    fi
    echo ""
    if [ "$ADMIN_PASSWORD_SOURCE" = "auto" ]; then
        print_warning "Admin password was auto-generated. Save it now."
    fi
    print_warning "Rotate credentials after first login if this is production."
    echo ""
    echo "Useful commands:"
    echo "  sudo systemctl status ${SERVICE_NAME}"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f"
    echo "  sudo cat ${CREDENTIALS_FILE}"
    echo ""
}

main() {
    set_defaults
    parse_args "$@"

    echo ""
    echo "=========================================="
    echo "  Sub2API One-Click Binary Deployment"
    echo "=========================================="
    echo ""

    init_privileges
    check_supported_os
    install_dependencies
    check_release_endpoint
    initialize_state
    configure_postgresql
    configure_redis
    install_sub2api_binary
    write_autosetup_dropin
    restart_sub2api
    health_check
    write_credentials_file
    print_summary
}

if [ "${ONE_CLICK_DEPLOY_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
