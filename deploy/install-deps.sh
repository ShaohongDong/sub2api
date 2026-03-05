#!/usr/bin/env bash
#
# Sub2API dependency installer for binary deployments on Ubuntu/Debian.
# Installs and initializes:
# - PostgreSQL >= 14
# - Redis >= 6 (with requirepass enabled)
#
# Default behavior:
# - Prefer system apt repository for PostgreSQL
# - Fallback to PGDG if system repo version is lower than required
# - Create/update database user and database
# - Write connection settings to /etc/sub2api/deps.env
#

set -euo pipefail

POSTGRES_MIN_VERSION=14
REDIS_MIN_VERSION=6
DEFAULT_DB_NAME="sub2api"
DEFAULT_DB_USER="sub2api"
DEFAULT_OUTPUT_ENV_FILE="/etc/sub2api/deps.env"
PGDG_LIST_FILE="/etc/apt/sources.list.d/pgdg.list"
PGDG_KEYRING="/usr/share/keyrings/postgresql.gpg"

DB_NAME="${DEFAULT_DB_NAME}"
DB_USER="${DEFAULT_DB_USER}"
DB_PASSWORD=""
REDIS_PASSWORD=""
OUTPUT_ENV_FILE="${DEFAULT_OUTPUT_ENV_FILE}"
NON_INTERACTIVE=false
SKIP_PGDG_FALLBACK=false

DIST_ID=""
DIST_CODENAME=""
APT_UPDATED=false

log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1" >&2
}

die() {
  log_error "$1"
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
Usage: install-deps.sh [options]

Options:
  --db-name <name>               Database name (default: sub2api)
  --db-user <user>               Database user (default: sub2api)
  --db-password <password>       Database password (auto-generate if omitted)
  --redis-password <password>    Redis requirepass (auto-generate if omitted)
  --postgres-min-version <ver>   Minimum PostgreSQL major version (default: 14)
  --output-env-file <path>       Output env file path (default: /etc/sub2api/deps.env)
  --non-interactive              Non-interactive mode
  --skip-pgdg-fallback           Do not use PGDG when system repo version is insufficient
  -h, --help                     Show this help
EOF
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Please run as root (use sudo)." 1
  fi
}

confirm_execution() {
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    return
  fi
  if [[ ! -t 0 ]]; then
    return
  fi

  echo "This will install and configure PostgreSQL and Redis on this system."
  read -r -p "Continue? [y/N]: " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Aborted by user." 1
      ;;
  esac
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl not found. This script requires systemd." 2
  fi
}

validate_identifier() {
  local value="$1"
  if [[ ! "$value" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
    die "Invalid identifier '${value}'. Use [a-zA-Z][a-zA-Z0-9_]* format." 4
  fi
}

validate_positive_int() {
  local value="$1"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    die "Invalid positive integer '${value}'." 4
  fi
}

generate_password() {
  local password=""
  while [[ ${#password} -lt 24 ]]; do
    password="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)"
  done
  printf "%s" "$password"
}

escape_sql_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db-name)
        DB_NAME="${2:-}"
        shift 2
        ;;
      --db-user)
        DB_USER="${2:-}"
        shift 2
        ;;
      --db-password)
        DB_PASSWORD="${2:-}"
        shift 2
        ;;
      --redis-password)
        REDIS_PASSWORD="${2:-}"
        shift 2
        ;;
      --postgres-min-version)
        POSTGRES_MIN_VERSION="${2:-}"
        shift 2
        ;;
      --output-env-file)
        OUTPUT_ENV_FILE="${2:-}"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --skip-pgdg-fallback)
        SKIP_PGDG_FALLBACK=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1" 4
        ;;
    esac
  done
}

detect_distribution() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Unsupported system." 2
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  DIST_ID="${ID:-}"
  DIST_CODENAME="${VERSION_CODENAME:-}"

  if [[ -z "${DIST_CODENAME}" ]] && command -v lsb_release >/dev/null 2>&1; then
    DIST_CODENAME="$(lsb_release -cs || true)"
  fi

  case "${DIST_ID}" in
    ubuntu|debian)
      ;;
    *)
      die "Unsupported distribution '${DIST_ID}'. Only Ubuntu and Debian are supported." 2
      ;;
  esac

  if [[ -z "${DIST_CODENAME}" ]]; then
    die "Unable to detect distribution codename (VERSION_CODENAME)." 2
  fi

  log_info "Detected distribution: ${DIST_ID} (${DIST_CODENAME})"
}

apt_update() {
  local force="${1:-false}"
  if [[ "${APT_UPDATED}" == "true" && "${force}" != "true" ]]; then
    return
  fi
  log_info "Running apt-get update..."
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  APT_UPDATED=true
}

apt_install() {
  apt_update
  log_info "Installing packages: $*"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

postgres_client_major() {
  if ! command -v psql >/dev/null 2>&1; then
    echo "0"
    return
  fi
  local version
  version="$(psql --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)"
  if [[ -z "${version}" ]]; then
    echo "0"
    return
  fi
  echo "${version%%.*}"
}

redis_server_major() {
  if ! command -v redis-server >/dev/null 2>&1; then
    echo "0"
    return
  fi
  local version
  version="$(redis-server --version 2>/dev/null | sed -n 's/.*v=\([0-9][0-9]*\).*/\1/p' | head -1 || true)"
  if [[ -z "${version}" ]]; then
    echo "0"
    return
  fi
  echo "${version}"
}

setup_pgdg_repository() {
  log_warn "System repository PostgreSQL version is below ${POSTGRES_MIN_VERSION}. Configuring PGDG fallback."

  apt_install ca-certificates curl gnupg lsb-release

  if [[ ! -f "${PGDG_KEYRING}" ]]; then
    curl -fsSL "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
      | gpg --dearmor -o "${PGDG_KEYRING}"
    chmod 0644 "${PGDG_KEYRING}"
  fi

  echo "deb [signed-by=${PGDG_KEYRING}] http://apt.postgresql.org/pub/repos/apt ${DIST_CODENAME}-pgdg main" > "${PGDG_LIST_FILE}"

  apt_update true
}

select_postgres_major_from_apt() {
  local -a candidates=()
  mapfile -t candidates < <(apt-cache search --names-only '^postgresql-[0-9]+$' \
    | awk -F- '{print $2}' | sort -nr | uniq)
  for major in "${candidates[@]}"; do
    if [[ "${major}" =~ ^[0-9]+$ ]] && [[ "${major}" -ge "${POSTGRES_MIN_VERSION}" ]]; then
      echo "${major}"
      return 0
    fi
  done
  return 1
}

ensure_postgresql() {
  apt_install postgresql postgresql-client
  systemctl enable --now postgresql

  local installed_major
  installed_major="$(postgres_client_major)"
  if [[ "${installed_major}" -ge "${POSTGRES_MIN_VERSION}" ]]; then
    log_info "PostgreSQL client major version ${installed_major} satisfies requirement."
    return
  fi

  if [[ "${SKIP_PGDG_FALLBACK}" == "true" ]]; then
    die "PostgreSQL version ${installed_major} is below required ${POSTGRES_MIN_VERSION}, and PGDG fallback is disabled." 2
  fi

  setup_pgdg_repository

  local target_major
  target_major="$(select_postgres_major_from_apt || true)"
  if [[ -z "${target_major}" ]]; then
    die "Unable to find PostgreSQL >= ${POSTGRES_MIN_VERSION} in apt repositories." 3
  fi

  log_info "Installing PostgreSQL ${target_major} from apt repositories."
  apt_install "postgresql-${target_major}" "postgresql-client-${target_major}"
  systemctl enable --now postgresql

  installed_major="$(postgres_client_major)"
  if [[ "${installed_major}" -lt "${POSTGRES_MIN_VERSION}" ]]; then
    die "PostgreSQL version check failed after installation. Found ${installed_major}, need >= ${POSTGRES_MIN_VERSION}." 3
  fi
}

ensure_redis() {
  apt_install redis-server redis-tools
  systemctl enable --now redis-server

  local major
  major="$(redis_server_major)"
  if [[ "${major}" -lt "${REDIS_MIN_VERSION}" ]]; then
    die "Redis version ${major} is below required ${REDIS_MIN_VERSION}." 3
  fi
}

run_psql_as_postgres() {
  local sql="$1"
  if command -v runuser >/dev/null 2>&1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -tAc "${sql}" postgres
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc "${sql}" postgres
    return
  fi
  die "Neither runuser nor sudo is available to execute PostgreSQL initialization as postgres user." 4
}

initialize_postgresql_objects() {
  local escaped_db_password
  escaped_db_password="$(escape_sql_literal "${DB_PASSWORD}")"

  local role_exists
  role_exists="$(run_psql_as_postgres "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}';" | tr -d '[:space:]')"
  if [[ "${role_exists}" == "1" ]]; then
    log_info "PostgreSQL role '${DB_USER}' exists. Updating password."
    run_psql_as_postgres "ALTER ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${escaped_db_password}';" >/dev/null
  else
    log_info "Creating PostgreSQL role '${DB_USER}'."
    run_psql_as_postgres "CREATE ROLE \"${DB_USER}\" WITH LOGIN PASSWORD '${escaped_db_password}';" >/dev/null
  fi

  local db_exists
  db_exists="$(run_psql_as_postgres "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" | tr -d '[:space:]')"
  if [[ "${db_exists}" == "1" ]]; then
    log_info "PostgreSQL database '${DB_NAME}' exists. Ensuring owner."
    run_psql_as_postgres "ALTER DATABASE \"${DB_NAME}\" OWNER TO \"${DB_USER}\";" >/dev/null
  else
    log_info "Creating PostgreSQL database '${DB_NAME}'."
    run_psql_as_postgres "CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USER}\";" >/dev/null
  fi

  run_psql_as_postgres "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";" >/dev/null

  log_info "Validating PostgreSQL login with the generated credentials."
  if ! PGPASSWORD="${DB_PASSWORD}" psql "host=127.0.0.1 port=5432 user=${DB_USER} dbname=${DB_NAME} sslmode=disable" -tAc "SELECT 1;" >/dev/null; then
    die "Failed to verify PostgreSQL connectivity using user '${DB_USER}' and database '${DB_NAME}'." 4
  fi
}

upsert_redis_config_line() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "${file}"; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|g" "${file}"
  else
    printf "\n%s %s\n" "${key}" "${value}" >> "${file}"
  fi
}

configure_redis_security() {
  local redis_conf="/etc/redis/redis.conf"
  if [[ ! -f "${redis_conf}" ]]; then
    die "Redis config file not found at ${redis_conf}." 4
  fi

  log_info "Configuring Redis requirepass and local bind policy."
  upsert_redis_config_line "${redis_conf}" "bind" "127.0.0.1 ::1"
  upsert_redis_config_line "${redis_conf}" "protected-mode" "yes"
  upsert_redis_config_line "${redis_conf}" "requirepass" "${REDIS_PASSWORD}"

  systemctl restart redis-server

  log_info "Validating Redis authentication."
  if [[ "$(redis-cli -a "${REDIS_PASSWORD}" --no-auth-warning ping 2>/dev/null || true)" != "PONG" ]]; then
    die "Redis authentication test failed." 4
  fi
}

write_env_file() {
  local dir
  dir="$(dirname "${OUTPUT_ENV_FILE}")"
  mkdir -p "${dir}"

  local old_umask
  old_umask="$(umask)"
  umask 077
  cat > "${OUTPUT_ENV_FILE}" <<EOF
# Generated by deploy/install-deps.sh
# Keep this file secure. It contains credentials.
DATABASE_HOST=127.0.0.1
DATABASE_PORT=5432
DATABASE_USER=${DB_USER}
DATABASE_PASSWORD=${DB_PASSWORD}
DATABASE_DBNAME=${DB_NAME}
DATABASE_SSLMODE=disable

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=0
EOF
  umask "${old_umask}"

  chmod 600 "${OUTPUT_ENV_FILE}"
  chown root:root "${OUTPUT_ENV_FILE}"
}

print_summary() {
  cat <<EOF

============================================================
Dependency deployment completed successfully.
============================================================
Distribution:          ${DIST_ID} (${DIST_CODENAME})
PostgreSQL minimum:    ${POSTGRES_MIN_VERSION}
Redis minimum:         ${REDIS_MIN_VERSION}

Generated credentials:
  DATABASE_HOST=127.0.0.1
  DATABASE_PORT=5432
  DATABASE_USER=${DB_USER}
  DATABASE_PASSWORD=${DB_PASSWORD}
  DATABASE_DBNAME=${DB_NAME}
  DATABASE_SSLMODE=disable
  REDIS_HOST=127.0.0.1
  REDIS_PORT=6379
  REDIS_PASSWORD=${REDIS_PASSWORD}
  REDIS_DB=0

Saved to:
  ${OUTPUT_ENV_FILE}

Next steps:
  1) Run deploy/install.sh to install Sub2API binary and service
  2) Open Setup Wizard and use the values above for PostgreSQL and Redis
============================================================
EOF
}

main() {
  parse_args "$@"
  require_root
  require_systemd
  detect_distribution
  confirm_execution

  validate_identifier "${DB_NAME}"
  validate_identifier "${DB_USER}"
  validate_positive_int "${POSTGRES_MIN_VERSION}"

  if [[ -z "${DB_PASSWORD}" ]]; then
    DB_PASSWORD="$(generate_password)"
  fi
  if [[ -z "${REDIS_PASSWORD}" ]]; then
    REDIS_PASSWORD="$(generate_password)"
  fi

  apt_install ca-certificates curl gnupg lsb-release
  ensure_postgresql
  ensure_redis

  initialize_postgresql_objects
  configure_redis_security
  write_env_file
  print_summary
}

main "$@"
