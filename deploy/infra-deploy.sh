#!/bin/bash
# =============================================================================
# Sub2API Infrastructure Deployment Script
# =============================================================================
# This script prepares and optionally starts a PostgreSQL + Redis 7+ stack,
# and can also start Sub2API for end-to-end validation.
#
# Usage examples:
#   curl -sSL https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy/infra-deploy.sh | bash
#   ./infra-deploy.sh --mode infra --redis-major 8
#   ./infra-deploy.sh --mode full --redis-major 8 --server-port 8081
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

GITHUB_RAW_URL="https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/deploy"

COMPOSE_TEMPLATE="docker-compose.infra.local.yml"
ENV_TEMPLATE=".env.infra.example"
ENV_FILE=".env.infra"

MODE="full"
REDIS_MAJOR="8"
NO_START="false"
FORCE="false"
BIND_HOST_OVERRIDE=""
SERVER_PORT_OVERRIDE=""
TZ_OVERRIDE=""

POSTGRES_PASSWORD=""
REDIS_PASSWORD=""
JWT_SECRET=""
TOTP_ENCRYPTION_KEY=""

declare -a COMPOSE_CMD
COMPOSE_CMD_STR=""

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

usage() {
    cat <<'EOF'
Sub2API Infrastructure Deployment Script

Usage:
  infra-deploy.sh [options]

Options:
  --mode <infra|full>       Deployment mode (default: full)
  --redis-major <7|8>       Redis major version (default: 8)
  --no-start                Only generate files, do not start containers
  --force                   Overwrite existing files without prompt
  --bind-host <host>        Override BIND_HOST in generated env file
  --server-port <port>      Override SERVER_PORT in generated env file
  --tz <timezone>           Override TZ in generated env file
  -h, --help                Show this help
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

generate_secret() {
    openssl rand -hex 32
}

detect_compose_command() {
    if command_exists docker && docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD=(docker compose)
    elif command_exists docker-compose; then
        COMPOSE_CMD=(docker-compose)
    else
        print_error "Neither 'docker compose' nor 'docker-compose' is available."
        print_error "Please install Docker Compose first."
        exit 1
    fi
    COMPOSE_CMD_STR="${COMPOSE_CMD[*]}"
}

download_file() {
    local url="$1"
    local output_file="$2"

    if command_exists curl; then
        curl -fsSL "$url" -o "$output_file"
    elif command_exists wget; then
        wget -q "$url" -O "$output_file"
    else
        print_error "Neither curl nor wget is installed."
        exit 1
    fi
}

resolve_script_dir() {
    local script_source="${BASH_SOURCE[0]:-}"
    if [ -n "$script_source" ] && [ -f "$script_source" ]; then
        (cd "$(dirname "$script_source")" && pwd)
    else
        pwd
    fi
}

confirm_overwrite() {
    local target="$1"
    if [ ! -f "$target" ]; then
        return 0
    fi

    if [ "$FORCE" = "true" ]; then
        return 0
    fi

    if [ ! -t 0 ]; then
        print_error "$target already exists. Re-run with --force to overwrite in non-interactive mode."
        exit 1
    fi

    print_warning "$target already exists."
    read -r -p "Overwrite $target? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi
}

fetch_template() {
    local template_name="$1"
    local script_dir="$2"
    local local_source="${script_dir}/${template_name}"
    local remote_source="${GITHUB_RAW_URL}/${template_name}"

    if [ -f "$local_source" ] && [ "$local_source" = "$(pwd)/${template_name}" ]; then
        # Running from repo/deploy; keep tracked template file as-is.
        print_info "Using existing local ${template_name}."
        return 0
    fi

    confirm_overwrite "$template_name"

    if [ -f "$local_source" ] && [ "$local_source" != "$(pwd)/${template_name}" ]; then
        cp "$local_source" "$template_name"
        print_success "Copied ${template_name} from local template."
    else
        print_info "Downloading ${template_name}..."
        download_file "$remote_source" "$template_name"
        print_success "Downloaded ${template_name}."
    fi
}

sed_in_place() {
    local expr="$1"
    local target="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i "$expr" "$target"
    else
        sed -i '' "$expr" "$target"
    fi
}

escape_sed_replacement() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//\//\\/}"
    printf '%s' "$value"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local escaped_value
    escaped_value="$(escape_sed_replacement "$value")"
    sed_in_place "s/^${key}=.*/${key}=${escaped_value}/" "$ENV_FILE"
}

run_compose() {
    (
        set -a
        # shellcheck disable=SC1090
        . "./${ENV_FILE}"
        set +a
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_TEMPLATE}" "$@"
    )
}

get_env_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE"
}

ensure_postgres_password_sync() {
    local postgres_user
    local postgres_password
    local container_id
    local sql_user
    local sql_password

    postgres_user="$(get_env_value "POSTGRES_USER")"
    postgres_password="$(get_env_value "POSTGRES_PASSWORD")"

    if [ -z "$postgres_user" ]; then
        postgres_user="sub2api"
    fi
    if [ -z "$postgres_password" ]; then
        print_error "POSTGRES_PASSWORD is missing in ${ENV_FILE}."
        return 1
    fi

    container_id="$(run_compose ps -q postgres 2>/dev/null | head -n 1 || true)"
    if [ -z "$container_id" ]; then
        print_error "Unable to locate running postgres container."
        return 1
    fi

    sql_user="${postgres_user//\"/\"\"}"
    sql_password="${postgres_password//\'/\'\'}"

    print_info "Synchronizing PostgreSQL credentials for user '${postgres_user}'..."
    if docker exec -u postgres "$container_id" \
        psql -v ON_ERROR_STOP=1 -U "$postgres_user" -d postgres \
        -c "ALTER ROLE \"${sql_user}\" WITH PASSWORD '${sql_password}';" >/dev/null 2>&1; then
        print_success "PostgreSQL credentials synchronized."
        return 0
    fi

    print_error "Failed to synchronize PostgreSQL credentials for '${postgres_user}'."
    print_warning "Recent logs for postgres:"
    run_compose logs --tail=80 postgres || true
    return 1
}

wait_for_service_health() {
    local service="$1"
    local timeout_seconds="${2:-180}"
    local elapsed=0
    local container_id=""
    local status=""

    print_info "Waiting for ${service} to become healthy..."
    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        container_id="$(run_compose ps -q "$service" 2>/dev/null | head -n 1 || true)"
        if [ -n "$container_id" ]; then
            status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
            if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
                print_success "${service} is ${status}."
                return 0
            fi
            if [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
                break
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    print_error "${service} failed to become healthy within ${timeout_seconds}s."
    print_warning "Recent logs for ${service}:"
    run_compose logs --tail=100 "$service" || true
    return 1
}

http_health_check() {
    local url="$1"
    if command_exists curl; then
        curl -fsS "$url" >/dev/null 2>&1
        return $?
    fi
    if command_exists wget; then
        wget -q -O /dev/null "$url"
        return $?
    fi
    return 1
}

validate_inputs() {
    if [ "$MODE" != "infra" ] && [ "$MODE" != "full" ]; then
        print_error "Invalid mode: $MODE (expected: infra or full)"
        exit 1
    fi

    if [ "$REDIS_MAJOR" != "7" ] && [ "$REDIS_MAJOR" != "8" ]; then
        print_error "Invalid redis major version: $REDIS_MAJOR (expected: 7 or 8)"
        exit 1
    fi

    if [ -n "$SERVER_PORT_OVERRIDE" ] && ! [[ "$SERVER_PORT_OVERRIDE" =~ ^[0-9]+$ ]]; then
        print_error "Invalid --server-port value: $SERVER_PORT_OVERRIDE"
        exit 1
    fi

    if [ -n "$SERVER_PORT_OVERRIDE" ] && [ "$SERVER_PORT_OVERRIDE" -lt 1 -o "$SERVER_PORT_OVERRIDE" -gt 65535 ]; then
        print_error "--server-port must be between 1 and 65535"
        exit 1
    fi
}

check_dependencies() {
    if ! command_exists openssl; then
        print_error "openssl is not installed. Please install openssl first."
        exit 1
    fi

    if [ "$NO_START" = "true" ]; then
        if command_exists docker && docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD=(docker compose)
            COMPOSE_CMD_STR="${COMPOSE_CMD[*]}"
        elif command_exists docker-compose; then
            COMPOSE_CMD=(docker-compose)
            COMPOSE_CMD_STR="${COMPOSE_CMD[*]}"
        else
            COMPOSE_CMD_STR="docker compose"
            print_warning "Docker Compose not detected. Generated files are still usable."
        fi
        return 0
    fi

    if ! command_exists docker; then
        print_error "docker is not installed. Please install Docker first."
        exit 1
    fi

    detect_compose_command

    if ! docker info >/dev/null 2>&1; then
        print_error "Docker daemon is not reachable."
        print_error "Please start Docker and re-run this script."
        exit 1
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)
                MODE="${2:-}"
                shift 2
                ;;
            --redis-major)
                REDIS_MAJOR="${2:-}"
                shift 2
                ;;
            --no-start)
                NO_START="true"
                shift
                ;;
            --force)
                FORCE="true"
                shift
                ;;
            --bind-host)
                BIND_HOST_OVERRIDE="${2:-}"
                shift 2
                ;;
            --server-port)
                SERVER_PORT_OVERRIDE="${2:-}"
                shift 2
                ;;
            --tz)
                TZ_OVERRIDE="${2:-}"
                shift 2
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

main() {
    local script_dir=""
    local health_url=""
    local health_attempt=0
    local max_health_attempts=30
    local sub2api_port=""

    parse_args "$@"
    validate_inputs

    echo ""
    echo "=========================================="
    echo "  Sub2API Infrastructure Deployment"
    echo "=========================================="
    echo ""

    check_dependencies
    script_dir="$(resolve_script_dir)"

    print_info "Preparing deployment templates..."
    fetch_template "$COMPOSE_TEMPLATE" "$script_dir"
    fetch_template "$ENV_TEMPLATE" "$script_dir"

    confirm_overwrite "$ENV_FILE"
    cp "$ENV_TEMPLATE" "$ENV_FILE"

    print_info "Generating secure secrets..."
    POSTGRES_PASSWORD="$(generate_secret)"
    REDIS_PASSWORD="$(generate_secret)"
    JWT_SECRET="$(generate_secret)"
    TOTP_ENCRYPTION_KEY="$(generate_secret)"

    set_env_value "POSTGRES_PASSWORD" "$POSTGRES_PASSWORD"
    set_env_value "REDIS_PASSWORD" "$REDIS_PASSWORD"
    set_env_value "JWT_SECRET" "$JWT_SECRET"
    set_env_value "TOTP_ENCRYPTION_KEY" "$TOTP_ENCRYPTION_KEY"
    set_env_value "REDIS_IMAGE" "redis:${REDIS_MAJOR}-alpine"

    if [ -n "$BIND_HOST_OVERRIDE" ]; then
        set_env_value "BIND_HOST" "$BIND_HOST_OVERRIDE"
    fi
    if [ -n "$SERVER_PORT_OVERRIDE" ]; then
        set_env_value "SERVER_PORT" "$SERVER_PORT_OVERRIDE"
    fi
    if [ -n "$TZ_OVERRIDE" ]; then
        set_env_value "TZ" "$TZ_OVERRIDE"
    fi

    chmod 600 "$ENV_FILE"
    print_success "Generated ${ENV_FILE} with secure defaults."

    print_info "Creating data directories..."
    mkdir -p data postgres_data redis_data
    print_success "Created data/, postgres_data/, redis_data/."

    if [ "$NO_START" = "true" ]; then
        print_warning "--no-start enabled. Files generated only."
        echo ""
        echo "Generated files:"
        echo "  ${COMPOSE_TEMPLATE}"
        echo "  ${ENV_TEMPLATE}"
        echo "  ${ENV_FILE}"
        echo ""
        echo "Start later with:"
        if [ "$MODE" = "infra" ]; then
            echo "  ${COMPOSE_CMD_STR} -f ${COMPOSE_TEMPLATE} --env-file ${ENV_FILE} up -d postgres redis"
        else
            echo "  ${COMPOSE_CMD_STR} -f ${COMPOSE_TEMPLATE} --env-file ${ENV_FILE} up -d"
        fi
        exit 0
    fi

    if [ "$MODE" = "infra" ]; then
        print_info "Starting PostgreSQL + Redis only (infra mode)..."
    else
        print_info "Starting PostgreSQL + Redis (preparing full mode)..."
    fi

    run_compose up -d postgres redis

    wait_for_service_health "postgres" 180
    wait_for_service_health "redis" 180
    ensure_postgres_password_sync

    if [ "$MODE" = "full" ]; then
        print_info "Starting Sub2API..."
        run_compose up -d sub2api
        wait_for_service_health "sub2api" 240
        sub2api_port="$(awk -F= '/^SERVER_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
        health_url="http://127.0.0.1:${sub2api_port}/health"
        print_info "Checking Sub2API health endpoint: ${health_url}"
        while [ "$health_attempt" -lt "$max_health_attempts" ]; do
            if http_health_check "$health_url"; then
                print_success "Sub2API health check passed."
                break
            fi
            sleep 2
            health_attempt=$((health_attempt + 1))
        done

        if [ "$health_attempt" -ge "$max_health_attempts" ]; then
            print_error "Sub2API health endpoint did not become ready in time."
            run_compose logs --tail=100 sub2api || true
            exit 1
        fi
    fi

    echo ""
    echo "=========================================="
    echo "  Deployment Complete!"
    echo "=========================================="
    echo ""
    echo "Generated credentials (shown once):"
    echo "  POSTGRES_PASSWORD:   ${POSTGRES_PASSWORD}"
    echo "  REDIS_PASSWORD:      ${REDIS_PASSWORD}"
    echo "  JWT_SECRET:          ${JWT_SECRET}"
    echo "  TOTP_ENCRYPTION_KEY: ${TOTP_ENCRYPTION_KEY}"
    echo ""
    print_warning "Credentials are stored in ${ENV_FILE}. Keep this file secure."
    echo ""
    echo "Useful commands:"
    echo "  ${COMPOSE_CMD_STR} -f ${COMPOSE_TEMPLATE} --env-file ${ENV_FILE} ps"
    echo "  ${COMPOSE_CMD_STR} -f ${COMPOSE_TEMPLATE} --env-file ${ENV_FILE} logs -f"
    echo "  ${COMPOSE_CMD_STR} -f ${COMPOSE_TEMPLATE} --env-file ${ENV_FILE} down"
    echo ""
    if [ "$MODE" = "full" ]; then
        sub2api_port="$(awk -F= '/^SERVER_PORT=/{print $2}' "$ENV_FILE" | tail -n1)"
        echo "Web UI: http://localhost:${sub2api_port}"
        echo ""
    fi
}

main "$@"
