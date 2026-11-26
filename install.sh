#!/usr/bin/env bash
# =============================================================================
# Tryton WSL (Ubuntu/Debian) Non-Interactive Installer
# Repo: https://github.com/castro-bot/tryton-wsl-installer
#
# Quick start (defaults to Tryton 7.2 + local WSL PostgreSQL, zero prompts):
#   curl -fsSL https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh | bash
#
# Switch to latest Tryton release at any time:
#   curl -fsSL https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh | TRYTON_SERIES=latest bash
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configurable defaults (override via environment variables or CLI flags)
# -----------------------------------------------------------------------------
TRYTON_SERIES="${TRYTON_SERIES:-7.2}"          # "7.2", "8.2", or "latest"
INSTALL_DIR="${INSTALL_DIR:-$HOME/tryton}"     # Tryton installation directory
DATA_DIR="${DATA_DIR:-$HOME/db}"               # Tryton filestore directory
TRYTON_PORT="${TRYTON_PORT:-8000}"             # Localhost web/RPC port
TRYTON_ADMIN_EMAIL="${TRYTON_ADMIN_EMAIL:-admin@localhost}"
TRYTON_ADMIN_PASSWORD="${TRYTON_ADMIN_PASSWORD:-}"
TRYTON_LANG="${TRYTON_LANG:-}"                 # Optional language code (e.g. es, fr)
TRYTON_EXTRA_MODULES="${TRYTON_EXTRA_MODULES:-}"

# PostgreSQL settings:
# - Leave PG_HOST empty to auto-install and configure PostgreSQL inside WSL
#   (accessible from Windows clients like pgAdmin/DBeaver at localhost:5432).
# - Set PG_HOST to connect to an external or Windows-hosted PostgreSQL server.
PG_HOST="${PG_HOST:-}"
PG_PORT_EXPLICIT=0
if [[ -n "${PG_PORT:-}" ]]; then PG_PORT_EXPLICIT=1; fi
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-tryton}"
PG_DB="${PG_DB:-tryton}"
PG_PASSWORD="${PG_PASSWORD:-}"

SKIP_APT="${SKIP_APT:-0}"
DRY_RUN="${DRY_RUN:-0}"

# -----------------------------------------------------------------------------
# Logging & cleanup helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${NC} %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error() { printf "${RED}[ERR ]${NC} %s\n" "$*" >&2; }

TEMP_FILES=()
cleanup() {
    local f
    for f in "${TEMP_FILES[@]:-}"; do
        if [[ -n "$f" && -e "$f" ]]; then
            rm -rf -- "$f"
        fi
    done
}
trap cleanup EXIT INT TERM

usage() {
    cat <<'EOF'
Tryton WSL Installer (non-interactive by default)

Usage:
  bash install.sh [OPTIONS]

Options:
  --series <X.Y|latest>   Tryton series to install (default: 7.2)
  --install-dir <path>    Install directory (default: ~/tryton)
  --data-dir <path>       Filestore directory (default: ~/db)
  --port <port>           Tryton HTTP port on localhost (default: 8000)
  --pg-host <host>        Use external PostgreSQL host (skips local PG install)
  --pg-port <port>        PostgreSQL port (default: 5432)
  --pg-user <user>        PostgreSQL user (default: tryton)
  --pg-db <dbname>        PostgreSQL database name (default: tryton)
  --lang <code>           Optional Tryton language to load (e.g. es)
  --skip-apt              Skip apt-get package installation
  --dry-run               Validate settings and preview steps without modifying system
  -h, --help              Show this help message

Environment variables:
  TRYTON_SERIES, INSTALL_DIR, DATA_DIR, TRYTON_PORT, TRYTON_ADMIN_EMAIL,
  TRYTON_ADMIN_PASSWORD, TRYTON_LANG, TRYTON_EXTRA_MODULES,
  PG_HOST, PG_PORT, PG_USER, PG_DB, PG_PASSWORD, SKIP_APT, DRY_RUN
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --series)      TRYTON_SERIES="$2"; shift 2 ;;
            --install-dir) INSTALL_DIR="$2"; shift 2 ;;
            --data-dir)    DATA_DIR="$2"; shift 2 ;;
            --port)        TRYTON_PORT="$2"; shift 2 ;;
            --pg-host)     PG_HOST="$2"; shift 2 ;;
            --pg-port)     PG_PORT="$2"; PG_PORT_EXPLICIT=1; shift 2 ;;
            --pg-user)     PG_USER="$2"; shift 2 ;;
            --pg-db)       PG_DB="$2"; shift 2 ;;
            --lang)        TRYTON_LANG="$2"; shift 2 ;;
            --skip-apt)    SKIP_APT=1; shift ;;
            --dry-run)     DRY_RUN=1; shift ;;
            -h|--help)     usage; exit 0 ;;
            *)
                log_error "Unknown option: $1"
                usage >&2
                exit 1
                ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Strict input validation (allow-list checks)
# -----------------------------------------------------------------------------
validate_inputs() {
    if [[ "$TRYTON_SERIES" != "latest" && ! "$TRYTON_SERIES" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid TRYTON_SERIES='$TRYTON_SERIES'. Expected 'latest' or 'X.Y' (e.g. 7.2)."
        exit 1
    fi

    if [[ ! "$PG_USER" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
        log_error "Invalid PG_USER='$PG_USER'. Use lowercase letters, digits, and underscores."
        exit 1
    fi

    if [[ ! "$PG_DB" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
        log_error "Invalid PG_DB='$PG_DB'. Use lowercase letters, digits, and underscores."
        exit 1
    fi

    if [[ ! "$PG_PORT" =~ ^[0-9]+$ ]] || (( PG_PORT < 1 || PG_PORT > 65535 )); then
        log_error "Invalid PG_PORT='$PG_PORT'. Must be between 1 and 65535."
        exit 1
    fi

    if [[ ! "$TRYTON_PORT" =~ ^[0-9]+$ ]] || (( TRYTON_PORT < 1024 || TRYTON_PORT > 65535 )); then
        log_error "Invalid TRYTON_PORT='$TRYTON_PORT'. Must be between 1024 and 65535."
        exit 1
    fi

    if [[ -n "$PG_HOST" && ! "$PG_HOST" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
        log_error "Invalid PG_HOST='$PG_HOST'."
        exit 1
    fi

    if [[ -n "$TRYTON_LANG" && ! "$TRYTON_LANG" =~ ^[a-zA-Z]{2,3}(_[a-zA-Z]{2})?$ ]]; then
        log_error "Invalid TRYTON_LANG='$TRYTON_LANG'. Expected e.g. 'es' or 'es_EC'."
        exit 1
    fi

    if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "/" || "$INSTALL_DIR" == *".."* ]]; then
        log_error "Invalid INSTALL_DIR='$INSTALL_DIR'."
        exit 1
    fi

    if [[ -z "$DATA_DIR" || "$DATA_DIR" == "/" || "$DATA_DIR" == *".."* ]]; then
        log_error "Invalid DATA_DIR='$DATA_DIR'."
        exit 1
    fi

    if [[ -n "$TRYTON_EXTRA_MODULES" ]]; then
        local mod
        for mod in $TRYTON_EXTRA_MODULES; do
            if [[ ! "$mod" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                log_error "Invalid module name in TRYTON_EXTRA_MODULES: '$mod'."
                exit 1
            fi
        done
    fi

    if [[ -n "$PG_HOST" && -z "$PG_PASSWORD" ]]; then
        log_error "PG_PASSWORD must be set when using an external PostgreSQL server (PG_HOST=$PG_HOST)."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Environment & privilege helpers
# -----------------------------------------------------------------------------
SUDO=""
setup_sudo() {
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            log_error "This script needs root privileges (install sudo or run as root)."
            exit 1
        fi
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Unsupported OS: /etc/os-release not found."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        log_error "Unsupported Linux distribution '${ID:-unknown}'. This installer targets Ubuntu/Debian on WSL."
        exit 1
    fi
    if grep -qi microsoft /proc/version 2>/dev/null; then
        log_info "Detected WSL environment (${PRETTY_NAME:-Ubuntu/Debian})."
    else
        log_warn "Not running inside WSL (${PRETTY_NAME:-Linux}), continuing anyway."
    fi
}

generate_secret() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets, string; alphabet = string.ascii_letters + string.digits; print(''.join(secrets.choice(alphabet) for _ in range(20)))"
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20
        printf '\n'
    else
        log_error "Neither python3 nor openssl is available to generate secure credentials."
        exit 1
    fi
}

# Load previously generated passwords if re-running on the same INSTALL_DIR
load_existing_credentials() {
    local cred_file="$INSTALL_DIR/.credentials"
    if [[ -f "$cred_file" ]]; then
        local existing_pg_pass existing_admin_pass
        existing_pg_pass="$(awk -F'=' '/^PG_PASSWORD=/{sub(/^PG_PASSWORD=/,""); print; exit}' "$cred_file" || true)"
        existing_admin_pass="$(awk -F'=' '/^TRYTON_ADMIN_PASSWORD=/{sub(/^TRYTON_ADMIN_PASSWORD=/,""); print; exit}' "$cred_file" || true)"
        if [[ -z "$PG_PASSWORD" && -n "$existing_pg_pass" ]]; then
            PG_PASSWORD="$existing_pg_pass"
            log_info "Reusing existing PostgreSQL password from $cred_file."
        fi
        if [[ -z "$TRYTON_ADMIN_PASSWORD" && -n "$existing_admin_pass" ]]; then
            TRYTON_ADMIN_PASSWORD="$existing_admin_pass"
            log_info "Reusing existing Tryton admin password from $cred_file."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Step 1: System dependencies
# -----------------------------------------------------------------------------
install_system_packages() {
    if [[ "$SKIP_APT" == "1" ]]; then
        log_info "Skipping apt package installation (SKIP_APT=1)."
        return
    fi

    local pkgs=(
        ca-certificates
        curl
        git
        python3
        python3-venv
        python3-pip
        python3-dev
        build-essential
        libpq-dev
        libxml2-dev
        libxslt1-dev
        libmagic1
        nodejs
        npm
        postgresql-client
    )

    if [[ -z "$PG_HOST" ]]; then
        pkgs+=(postgresql postgresql-contrib)
    fi

    log_info "Installing system packages via apt..."
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] apt-get update && apt-get install -y ${pkgs[*]}"
        return
    fi

    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    log_ok "System packages installed."
}

# -----------------------------------------------------------------------------
# Step 2: Resolve Tryton series (7.2 or latest)
# -----------------------------------------------------------------------------
RESOLVED_SERIES=""
resolve_tryton_series() {
    if [[ "$TRYTON_SERIES" == "latest" ]]; then
        log_info "Resolving latest stable Tryton series from PyPI..."
        local latest_ver
        latest_ver="$(curl --proto '=https' --tlsv1.2 -fsSL https://pypi.org/pypi/trytond/json | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['version'])")"
        if [[ ! "$latest_ver" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
            log_error "Could not parse latest trytond version from PyPI: '$latest_ver'."
            exit 1
        fi
        RESOLVED_SERIES="${BASH_REMATCH[1]}"
        log_ok "Resolved latest Tryton series: ${RESOLVED_SERIES} (trytond ${latest_ver})."
    else
        RESOLVED_SERIES="$TRYTON_SERIES"
        log_info "Using Tryton series: ${RESOLVED_SERIES}."
    fi
}

# -----------------------------------------------------------------------------
# Step 3: PostgreSQL setup (local WSL default OR external host)
# -----------------------------------------------------------------------------
detect_local_pg_port() {
    # If the user did not explicitly override PG_PORT and pg_createcluster
    # assigned a non-5432 port (e.g. 5433 when another WSL2 distro holds 5432),
    # detect this distro's actual cluster port.
    if [[ "${PG_PORT_EXPLICIT:-0}" == "1" ]]; then
        return
    fi
    if command -v pg_lsclusters >/dev/null 2>&1; then
        local detected_port
        detected_port="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1 {print $3}')"
        if [[ -n "$detected_port" && "$detected_port" =~ ^[0-9]+$ && "$detected_port" != "$PG_PORT" ]]; then
            log_warn "Local PostgreSQL cluster in this distro is configured on port ${detected_port} (port ${PG_PORT} was already in use). Using port ${detected_port}."
            PG_PORT="$detected_port"
        fi
    fi
}

start_local_postgres() {
    detect_local_pg_port

    if pg_isready -h 127.0.0.1 -p "$PG_PORT" >/dev/null 2>&1; then
        log_ok "Local PostgreSQL is already running on localhost:${PG_PORT}."
        return
    fi

    log_info "Starting local PostgreSQL service..."
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        $SUDO systemctl enable postgresql >/dev/null 2>&1 || true
        $SUDO systemctl start postgresql
    else
        $SUDO service postgresql start
    fi

    local attempts=0
    until pg_isready -h 127.0.0.1 -p "$PG_PORT" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if (( attempts >= 15 )); then
            log_error "PostgreSQL did not become ready on localhost:${PG_PORT}."
            log_warn "If Windows already has PostgreSQL running on port 5432, retry with PG_PORT=5433 or set PG_HOST to connect to it."
            exit 1
        fi
        sleep 1
    done
    log_ok "Local PostgreSQL is ready on localhost:${PG_PORT}."
}

ensure_pg_password_auth() {
    # Ensure localhost TCP connections accept scram-sha-256/md5 password auth
    # (so Tryton and Windows clients like pgAdmin/DBeaver connect to localhost:5432).
    local hba_file
    hba_file="$($SUDO -u postgres psql -p "$PG_PORT" -tAc "SHOW hba_file;" 2>/dev/null || true)"
    if [[ -z "$hba_file" || ! -f "$hba_file" ]]; then
        return
    fi

    if ! $SUDO grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+(scram-sha-256|md5)' "$hba_file"; then
        log_info "Enabling password authentication for 127.0.0.1/32 in $hba_file..."
        printf '\n# Added by tryton-wsl-installer for localhost TCP clients\nhost all all 127.0.0.1/32 scram-sha-256\nhost all all ::1/128 scram-sha-256\n' | $SUDO tee -a "$hba_file" >/dev/null
        $SUDO -u postgres psql -p "$PG_PORT" -c "SELECT pg_reload_conf();" >/dev/null
    fi
}

setup_postgres() {
    if [[ -n "$PG_HOST" ]]; then
        log_info "External PostgreSQL mode: ${PG_HOST}:${PG_PORT} (db=${PG_DB}, user=${PG_USER})."
        if [[ "$DRY_RUN" == "1" ]]; then
            log_info "[DRY-RUN] Would verify connectivity to ${PG_HOST}:${PG_PORT}."
            return
        fi
        if ! pg_isready -h "$PG_HOST" -p "$PG_PORT" >/dev/null 2>&1; then
            log_error "Cannot reach PostgreSQL at ${PG_HOST}:${PG_PORT}."
            log_warn "If connecting to Windows PostgreSQL from WSL2, ensure Windows postgresql.conf has listen_addresses = '*', pg_hba.conf allows the WSL subnet, and Windows Firewall allows TCP port ${PG_PORT}."
            exit 1
        fi
        log_ok "External PostgreSQL at ${PG_HOST}:${PG_PORT} is reachable."
        return
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would start local WSL PostgreSQL and ensure role '${PG_USER}' and database '${PG_DB}' exist."
        return
    fi

    start_local_postgres
    ensure_pg_password_auth

    log_info "Configuring least-privilege PostgreSQL role '${PG_USER}' and database '${PG_DB}'..."
    # Parameterized psql variables via heredoc prevent SQL injection on identifiers/literals.
    local role_exists
    role_exists="$($SUDO -u postgres psql -p "$PG_PORT" -tA -v pg_user="$PG_USER" <<'SQL'
SELECT 1 FROM pg_roles WHERE rolname = :'pg_user';
SQL
)"
    if [[ "$role_exists" == "1" ]]; then
        $SUDO -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 \
            -v pg_user="$PG_USER" \
            -v pg_pass="$PG_PASSWORD" <<'SQL' >/dev/null
ALTER ROLE :"pg_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pg_pass';
SQL
    else
        $SUDO -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 \
            -v pg_user="$PG_USER" \
            -v pg_pass="$PG_PASSWORD" <<'SQL' >/dev/null
CREATE ROLE :"pg_user" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pg_pass';
SQL
    fi

    local db_exists
    db_exists="$($SUDO -u postgres psql -p "$PG_PORT" -tA -v pg_db="$PG_DB" <<'SQL'
SELECT 1 FROM pg_database WHERE datname = :'pg_db';
SQL
)"
    if [[ "$db_exists" != "1" ]]; then
        $SUDO -u postgres psql -p "$PG_PORT" -v ON_ERROR_STOP=1 \
            -v pg_db="$PG_DB" \
            -v pg_user="$PG_USER" <<'SQL' >/dev/null
CREATE DATABASE :"pg_db" OWNER :"pg_user" ENCODING 'UTF8';
SQL
    else
        log_info "Database '${PG_DB}' already exists; preserving existing data."
    fi

    log_ok "PostgreSQL role '${PG_USER}' and database '${PG_DB}' are ready."
}

# -----------------------------------------------------------------------------
# Step 4: Python venv + Tryton Server (trytond)
# -----------------------------------------------------------------------------
install_tryton_server() {
    local venv_dir="$INSTALL_DIR/.venv"
    local pip_packages=("trytond==${RESOLVED_SERIES}.*" "psycopg2-binary")

    if [[ -n "$TRYTON_EXTRA_MODULES" ]]; then
        local mod
        for mod in $TRYTON_EXTRA_MODULES; do
            pip_packages+=("$mod")
        done
    fi

    log_info "Installing Tryton server (${RESOLVED_SERIES}.*) into ${venv_dir}..."
    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] python3 -m venv '${venv_dir}' && pip install ${pip_packages[*]}"
        return
    fi

    mkdir -p "$INSTALL_DIR" "$DATA_DIR"
    chmod 700 "$DATA_DIR"

    if [[ ! -d "$venv_dir" ]]; then
        python3 -m venv "$venv_dir"
    fi

    "$venv_dir/bin/pip" install --quiet --upgrade pip wheel
    "$venv_dir/bin/pip" install --quiet "${pip_packages[@]}"

    local installed_ver
    installed_ver="$("$venv_dir/bin/trytond" --version)"
    log_ok "Installed ${installed_ver}."
}

# -----------------------------------------------------------------------------
# Step 5: Tryton Web Client (tryton-sao)
# Handles both 7.2 (bower_components) and 8.x/latest (node_modules).
# -----------------------------------------------------------------------------
install_tryton_sao() {
    local sao_dir="$INSTALL_DIR/tryton-sao"
    local sao_url="https://downloads.tryton.org/${RESOLVED_SERIES}/tryton-sao-last.tgz"

    log_info "Installing tryton-sao web client from ${sao_url}..."
    if [[ "$DRY_RUN" == "1" ]]; then
        curl --proto '=https' --tlsv1.2 -fsSI "$sao_url" >/dev/null
        log_ok "[DRY-RUN] Verified ${sao_url} is reachable."
        return
    fi

    local tmp_tgz
    tmp_tgz="$(mktemp /tmp/tryton-sao-XXXXXX.tgz)"
    TEMP_FILES+=("$tmp_tgz")

    curl --proto '=https' --tlsv1.2 -fsSL "$sao_url" -o "$tmp_tgz"

    # Guard against path traversal / absolute paths in downloaded archive
    if tar -tzf "$tmp_tgz" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        log_error "Refusing to extract archive with unsafe paths: ${sao_url}"
        exit 1
    fi

    rm -rf "$sao_dir"
    mkdir -p "$sao_dir"
    tar -xzf "$tmp_tgz" -C "$sao_dir" --strip-components=1

    log_info "Installing tryton-sao frontend dependencies..."
    (
        cd "$sao_dir"
        export GIT_TERMINAL_PROMPT=0
        if [[ -f bower.json ]]; then
            # Tryton <= 7.x uses bower_components
            npm install --omit=dev --no-audit --no-fund --ignore-scripts --silent
            if [[ "$(id -u)" -eq 0 ]]; then
                ./node_modules/.bin/bower install --allow-root --config.interactive=false >/dev/null
            else
                ./node_modules/.bin/bower install --config.interactive=false >/dev/null
            fi
        else
            # Tryton 8.x+ loads runtime dependencies directly from node_modules
            npm install --omit=dev --no-audit --no-fund --silent
        fi

        if [[ ! -f dist/tryton-sao.js ]]; then
            log_info "Building tryton-sao dist assets with grunt..."
            npm install --no-audit --no-fund --ignore-scripts --silent
            npx grunt >/dev/null
        fi
    )

    log_ok "tryton-sao installed at ${sao_dir}."
}

# -----------------------------------------------------------------------------
# Step 6: Configuration, credentials file, DB init, and helper scripts
# -----------------------------------------------------------------------------
configure_and_init_tryton() {
    local conf_file="$INSTALL_DIR/trytond.conf"
    local cred_file="$INSTALL_DIR/.credentials"
    local effective_pg_host="${PG_HOST:-localhost}"

    if [[ "$DRY_RUN" == "1" ]]; then
        log_info "[DRY-RUN] Would write ${conf_file} (localhost:${TRYTON_PORT}), initialize DB '${PG_DB}', and create start.sh/update.sh."
        return
    fi

    # URL-encode PostgreSQL username & password safely
    local encoded_user encoded_pass
    encoded_user="$(PG_RAW="$PG_USER" python3 -c "import os, urllib.parse; print(urllib.parse.quote(os.environ['PG_RAW'], safe=''))")"
    encoded_pass="$(PG_RAW="$PG_PASSWORD" python3 -c "import os, urllib.parse; print(urllib.parse.quote(os.environ['PG_RAW'], safe=''))")"

    # Write trytond.conf (localhost only; mode 600)
    (
        umask 077
        cat > "$conf_file" <<EOF
[database]
uri = postgresql://${encoded_user}:${encoded_pass}@${effective_pg_host}:${PG_PORT}/
path = ${DATA_DIR}

[web]
listen = localhost:${TRYTON_PORT}
root = ${INSTALL_DIR}/tryton-sao
EOF
    )
    chmod 600 "$conf_file"

    # Write local credentials summary (mode 600; never logged publicly)
    (
        umask 077
        cat > "$cred_file" <<EOF
# Generated by tryton-wsl-installer (chmod 600)
TRYTON_URL=http://localhost:${TRYTON_PORT}
TRYTON_SERIES=${RESOLVED_SERIES}
TRYTON_DB=${PG_DB}
TRYTON_ADMIN_USER=admin
TRYTON_ADMIN_EMAIL=${TRYTON_ADMIN_EMAIL}
TRYTON_ADMIN_PASSWORD=${TRYTON_ADMIN_PASSWORD}

PG_HOST=${effective_pg_host}
PG_PORT=${PG_PORT}
PG_DB=${PG_DB}
PG_USER=${PG_USER}
PG_PASSWORD=${PG_PASSWORD}
EOF
    )
    chmod 600 "$cred_file"

    # Initialize / update Tryton database non-interactively via TRYTONPASSFILE
    local pass_file
    pass_file="$(mktemp /tmp/tryton-pass-XXXXXX)"
    TEMP_FILES+=("$pass_file")
    chmod 600 "$pass_file"
    printf '%s\n' "$TRYTON_ADMIN_PASSWORD" > "$pass_file"

    log_info "Initializing Tryton database '${PG_DB}' (this may take a minute)..."
    local admin_args=(
        -c "$conf_file"
        -d "$PG_DB"
        --all
        --email "$TRYTON_ADMIN_EMAIL"
    )
    if [[ -n "$TRYTON_LANG" ]]; then
        admin_args+=(-l "$TRYTON_LANG")
    fi

    TRYTONPASSFILE="$pass_file" "$INSTALL_DIR/.venv/bin/trytond-admin" "${admin_args[@]}"
    rm -f -- "$pass_file"
    log_ok "Tryton database '${PG_DB}' initialized."

    # Helper script: start.sh
    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
EOF
    if [[ -z "$PG_HOST" ]]; then
        cat >> "$INSTALL_DIR/start.sh" <<EOF
if ! pg_isready -h 127.0.0.1 -p ${PG_PORT} >/dev/null 2>&1; then
    echo "[INFO] Starting local PostgreSQL..."
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        sudo systemctl start postgresql
    else
        sudo service postgresql start
    fi
fi
EOF
    fi
    cat >> "$INSTALL_DIR/start.sh" <<EOF
echo "[INFO] Starting Tryton server at http://localhost:${TRYTON_PORT} (Ctrl+C to stop)..."
exec "\$INSTALL_DIR/.venv/bin/trytond" -c "\$INSTALL_DIR/trytond.conf" --dev "\$@"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    # Helper script: update.sh
    cat > "$INSTALL_DIR/update.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec "\$INSTALL_DIR/.venv/bin/trytond-admin" -c "\$INSTALL_DIR/trytond.conf" -d "${PG_DB}" --all -vv "\$@"
EOF
    chmod +x "$INSTALL_DIR/update.sh"

    log_ok "Helper scripts created: ${INSTALL_DIR}/start.sh and ${INSTALL_DIR}/update.sh"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    validate_inputs
    setup_sudo
    check_os

    load_existing_credentials
    if [[ -z "$PG_PASSWORD" ]]; then
        PG_PASSWORD="$(generate_secret)"
    fi
    if [[ -z "$TRYTON_ADMIN_PASSWORD" ]]; then
        TRYTON_ADMIN_PASSWORD="$(generate_secret)"
    fi

    install_system_packages
    resolve_tryton_series
    setup_postgres
    install_tryton_server
    install_tryton_sao
    configure_and_init_tryton

    printf '\n'
    log_ok "Tryton ${RESOLVED_SERIES} installation complete!"
    cat <<EOF

Next steps:
  1. Start Tryton server:
       ${INSTALL_DIR}/start.sh

  2. Open the web client in your Windows browser:
       http://localhost:${TRYTON_PORT}

  3. View your generated Tryton admin & PostgreSQL credentials:
       cat ${INSTALL_DIR}/.credentials

  4. Connect from Windows PostgreSQL clients (pgAdmin / DBeaver / DataGrip):
       Host: localhost   Port: ${PG_PORT}   Database: ${PG_DB}   User: ${PG_USER}
       (Password is stored in ${INSTALL_DIR}/.credentials)
EOF
}

main "$@"
