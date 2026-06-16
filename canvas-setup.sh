#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PrivacySafe Foundation, Inc.
# SPDX-License-Identifier: MIT
#
# canvas-setup.sh - Canvas LMS local development installer for Ubuntu 24.04
#
# Part of the Canvas LMS Setup Toolkit by PrivacySafe Foundation, Inc.
# MIT License - see LICENSE file or https://opensource.org/licenses/MIT
#
# Canvas LMS is open-source software developed by Instructure, Inc. and
# licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
# Source: https://github.com/instructure/canvas-lms
#
# Inspired by original work by swzhang
# https://github.com/swzhangf/Canvas-LMS-Setup
#
# =============================================================================
# Usage:
#   chmod +x canvas-setup.sh
#   ./canvas-setup.sh --install-path ~/canvas-lms
#   sudo ./canvas-setup.sh --install-path /opt/canvas-lms
#   ./canvas-setup.sh --install-path /opt/canvas-lms --port 8080
#   ./canvas-setup.sh --install-path ~/canvas-lms --mirror   # restricted networks
#
# What this script does:
#   1. Installs Docker CE, Git, and Python 3 if missing
#   2. Clones Canvas LMS from GitHub (or a Gitee mirror)
#   3. Patches Dockerfiles for Ubuntu 24.04 / EOL-Debian compatibility
#   4. Writes all required Canvas config files
#   5. Builds and starts the Docker services
#   6. Installs Ruby/JS assets inside the container
#   7. Creates and seeds the database
#
# SECURITY NOTE FOR CONTRIBUTORS:
#   Passwords and keys in this script are PLACEHOLDERS generated at runtime.
#   Do not commit real credentials. The generated security.yml is listed in
#   Canvas's .gitignore and will not be checked in.
#
# Requirements: Ubuntu 24.04, sudo access (or root), 8 GB+ RAM, 20 GB+ disk
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration - edit these defaults or override via flags
# -----------------------------------------------------------------------------
INSTALL_PATH=""
USE_MIRROR=false
PORT=3000

CANVAS_REPO="https://github.com/instructure/canvas-lms.git"
CANVAS_MIRROR="https://gitee.com/xiong-yuhui/canvas-Lms.git"
DOCKER_MIRROR="docker.1ms.run"

# Canvas base images (pinned to what Canvas's Dockerfile expects)
RUBY_IMAGE="instructure/ruby-passenger:2.7"
# Detected dynamically after clone - see detect_postgres_image()
POSTGIS_IMAGE="postgis/postgis:12-2.5"  # fallback only
REDIS_IMAGE="redis:alpine"

# Populated later - the real user even when run with sudo
REAL_USER=""
REAL_HOME=""

# Docker command - may become "sudo docker" if user isn't in the docker group
DOCKER_CMD="docker"

# -----------------------------------------------------------------------------
# Colors / logging
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

log_step() { printf "\n%s==> %s%s\n" "${CYAN}${BOLD}" "$1" "$NC"; }
log_ok()   { printf "  %s[OK]%s   %s\n" "$GREEN"  "$NC" "$1"; }
log_warn() { printf "  %s[WARN]%s %s\n" "$YELLOW" "$NC" "$1"; }
log_err()  { printf "\n  %s[ERROR]%s %s\n" "$RED"  "$NC" "$1" >&2; }
log_info() { printf "  %s-->%s   %s\n"   "$GRAY"   "$NC" "$1"; }

die() { log_err "$1"; exit 1; }

# Wrapper: runs apt/system commands with sudo only when we're not already root
_sudo() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# -----------------------------------------------------------------------------
# Resolve the real (non-root) user even when invoked with sudo.
# We need this for: docker group membership, HOME path, chown.
# -----------------------------------------------------------------------------
resolve_real_user() {
    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        REAL_USER="$SUDO_USER"
        REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    elif [[ "$EUID" -eq 0 ]]; then
        # Genuinely running as root (not via sudo) - use root's home
        REAL_USER="root"
        REAL_HOME="/root"
        log_warn "Running as root directly. Files in $INSTALL_PATH will be owned by root."
        log_warn "This is fine for local testing but not recommended for shared machines."
    else
        REAL_USER="$USER"
        REAL_HOME="$HOME"
    fi
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF

${BOLD}Usage:${NC} $0 --install-path <path> [options]

${BOLD}Options:${NC}
  --install-path PATH   Full path where Canvas LMS will be cloned. Required.
                        e.g. /opt/canvas-lms or ~/canvas-lms
  --port PORT           Host port for Canvas (default: 3000).
  --mirror              Use Gitee + Docker mirror (for restricted networks).
  --help                Show this message.

${BOLD}Examples:${NC}
  $0 --install-path ~/canvas-lms
  sudo $0 --install-path /opt/canvas-lms --port 8080

EOF
    exit 1
}

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-path)
            [[ -z "${2:-}" ]] && die "Missing value for --install-path"
            INSTALL_PATH="$2"; shift 2 ;;
        --port)
            [[ -z "${2:-}" ]] && die "Missing value for --port"
            PORT="$2"; shift 2 ;;
        --mirror)
            USE_MIRROR=true; shift ;;
        --help|-h) usage ;;
        *) die "Unknown option: $1 (run with --help for usage)" ;;
    esac
done

[[ -z "$INSTALL_PATH" ]] && die "--install-path is required"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number (got: $PORT)"
[[ "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "--port must be 1-65535"

resolve_real_user

CANVAS_DIR="$INSTALL_PATH"

printf "\n%s" "${BOLD}"
echo "====================================================="
echo "  Canvas LMS - Local Development Setup"
echo "  Target:  $CANVAS_DIR"
echo "  Port:    $PORT"
echo "  Mirror:  $USE_MIRROR"
echo "  User:    $REAL_USER"
echo "====================================================="
printf "%s\n" "${NC}"

# =============================================================================
# STEP 1 - Install prerequisites
# =============================================================================
install_prerequisites() {
    log_step "Step 1: Checking and installing prerequisites"

    # OS check
    if grep -q 'VERSION_ID="24.04"' /etc/os-release 2>/dev/null; then
        log_ok "Ubuntu 24.04 detected"
    else
        log_warn "Ubuntu 24.04 not confirmed - continuing, but results may vary"
    fi

    # Memory check
    if command -v free &>/dev/null; then
        local mem_gb
        mem_gb=$(free -g | awk '/^Mem:/{print $2}')
        if [[ "${mem_gb:-0}" -lt 8 ]]; then
            log_warn "Only ${mem_gb} GB RAM - 8 GB+ recommended. Builds may be slow or OOM."
        else
            log_ok "RAM: ${mem_gb} GB"
        fi
    fi

    # Disk check - check the target install path's filesystem
    local check_path="$INSTALL_PATH"
    [[ -d "$check_path" ]] || check_path="$(dirname "$check_path")"
    [[ -d "$check_path" ]] || check_path="/"
    local free_gb
    free_gb=$(df -BG --output=avail "$check_path" | tail -1 | tr -d 'G ')
    if [[ "${free_gb:-0}" -lt 20 ]]; then
        log_warn "Only ${free_gb} GB free - Canvas build needs ~20 GB"
    else
        log_ok "Free disk: ${free_gb} GB"
    fi

    # ------------------------------------------------------------------
    # Git & Python3
    # ------------------------------------------------------------------
    local basic_missing=()
    command -v git     &>/dev/null || basic_missing+=("git")
    command -v python3 &>/dev/null || basic_missing+=("python3")

    if [[ ${#basic_missing[@]} -gt 0 ]]; then
        log_info "Installing: ${basic_missing[*]}"
        _sudo apt-get update -qq
        _sudo apt-get install -y "${basic_missing[@]}"
    fi

    log_ok "Git:     $(git --version)"
    log_ok "Python3: $(python3 --version)"

    # ------------------------------------------------------------------
    # Docker CE - use Docker's official APT repo, not Ubuntu GNU/Linux's docker.io.
    # docker.io is stale and lacks docker-buildx-plugin / docker-compose-plugin.
    # ------------------------------------------------------------------
    local docker_ok=false
    if command -v docker &>/dev/null \
        && docker compose version &>/dev/null 2>&1 \
        && docker buildx version &>/dev/null 2>&1; then
        docker_ok=true
    fi

    # Also try sudo docker in case it's installed but not in PATH for this user
    if [[ "$docker_ok" == false ]] && sudo docker compose version &>/dev/null 2>&1; then
        docker_ok=true
        DOCKER_CMD="sudo docker"
        log_info "Docker found via sudo - will use 'sudo docker' for this session"
    fi

    if [[ "$docker_ok" == false ]]; then
        log_info "Docker CE not found - installing from Docker's official APT repo"

        # Strip any conflicting Ubuntu GNU/Linux-packaged docker variants
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 \
                   podman-docker containerd runc; do
            if dpkg -l "$pkg" &>/dev/null 2>&1; then
                log_info "Removing conflicting package: $pkg"
                _sudo apt-get remove -y "$pkg" || true
            fi
        done

        _sudo apt-get update -qq
        _sudo apt-get install -y ca-certificates curl gnupg lsb-release

        # Docker's official GPG key - modern /etc/apt/keyrings method
        _sudo install -m 0755 -d /etc/apt/keyrings
        _sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        _sudo chmod a+r /etc/apt/keyrings/docker.asc

        # Add Docker's stable APT repo
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | _sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        _sudo apt-get update -qq
        _sudo apt-get install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        _sudo systemctl enable --now docker
        log_ok "Docker CE installed and started"
    fi

    # ------------------------------------------------------------------
    # Docker group / access
    #
    # We never force a logout. Instead:
    #   - If already root or in docker group → use "docker" directly
    #   - Otherwise → add to group AND use "sudo docker" for this session
    #     so the script completes without requiring a re-login
    # ------------------------------------------------------------------
    if [[ "$EUID" -eq 0 ]]; then
        # Root can always talk to Docker
        DOCKER_CMD="docker"
    elif groups "$REAL_USER" 2>/dev/null | grep -qw docker; then
        DOCKER_CMD="docker"
        log_ok "User '$REAL_USER' is in the docker group"
    else
        log_info "Adding '$REAL_USER' to the docker group..."
        _sudo usermod -aG docker "$REAL_USER"
        # Use sudo docker for the rest of this run - no logout needed
        DOCKER_CMD="sudo docker"
        log_warn "Added '$REAL_USER' to the docker group."
        log_warn "For future sessions, log out and back in to use docker without sudo."
        log_warn "This install will continue using 'sudo docker' automatically."
    fi

    # Final reachability check
    if ! $DOCKER_CMD info &>/dev/null; then
        _sudo systemctl start docker || true
        sleep 2
        $DOCKER_CMD info &>/dev/null \
            || die "Docker daemon is not reachable even with '$DOCKER_CMD'.\nTry: sudo systemctl start docker"
    fi

    log_ok "Docker:         $($DOCKER_CMD --version)"
    log_ok "Docker Compose: $($DOCKER_CMD compose version)"
    log_ok "Docker Buildx:  $($DOCKER_CMD buildx version)"
    log_ok "Docker daemon:  running"

    # Write the postgres image resolver script used by detect_postgres_image()
    cat > /tmp/canvas_resolve_pg.py << 'RESOLVER'
import sys, re
from pathlib import Path

df_text = Path(sys.argv[1]).read_text()
dc_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None

# Collect ARG defaults from Dockerfile
args = {}
for m in re.finditer(r"^ARG\s+(\w+)(?:=(\S+))?", df_text, re.MULTILINE):
    name, default = m.group(1), m.group(2)
    if default:
        args[name] = default.strip()

# Collect build args from docker-compose.yml postgres service
if dc_path and dc_path.exists():
    dc_text = dc_path.read_text()
    in_postgres = False
    in_args = False
    for line in dc_text.splitlines():
        s = line.strip()
        if re.match(r"^postgres\s*:", s):
            in_postgres = True; in_args = False
        elif in_postgres and re.match(r"^\w", s) and not s.startswith("postgres"):
            in_postgres = False; in_args = False
        elif in_postgres and s == "args:":
            in_args = True
        elif in_args:
            m2 = re.match(r"[-\s]*(\w+)\s*[=:]\s*(\S+)", s)
            if m2:
                args[m2.group(1)] = m2.group(2).strip("\"'")
            elif s and not s.startswith("-"):
                in_args = False

from_m = re.search(r"^FROM\s+(\S+)", df_text, re.MULTILINE)
if not from_m:
    sys.exit(1)

resolved = re.sub(r"\$\{?(\w+)\}?", lambda m: args.get(m.group(1), ""), from_m.group(1))

if "$" not in resolved and ("/" in resolved or ":" in resolved):
    print(resolved.strip())
else:
    sys.exit(1)
RESOLVER

}

# =============================================================================
# STEP 2 - Clone Canvas LMS
# =============================================================================
clone_canvas() {
    log_step "Step 2: Cloning Canvas LMS"

    if [[ -d "$CANVAS_DIR/.git" ]]; then
        log_warn "Repository already exists at $CANVAS_DIR - skipping clone"
        return 0
    fi

    if [[ -e "$CANVAS_DIR" ]]; then
        die "$CANVAS_DIR exists but is not a git repo. Remove it and re-run."
    fi

    # Create CANVAS_DIR with elevated permissions (needed for system paths like
    # /opt), then hand ownership to the real user so git clone can write into it.
    _sudo mkdir -p "$CANVAS_DIR"
    if [[ "$REAL_USER" != "root" ]]; then
        _sudo chown "$REAL_USER:$REAL_USER" "$CANVAS_DIR"
    fi

    local repo="$CANVAS_REPO"
    [[ "$USE_MIRROR" == true ]] && repo="$CANVAS_MIRROR"

    log_info "Cloning from: $repo"
    # Clone as the real user so all files are owned correctly for the container.
    if [[ "$EUID" -eq 0 && "$REAL_USER" != "root" ]]; then
        sudo -u "$REAL_USER" git clone "$repo" "$CANVAS_DIR"
    else
        git clone "$repo" "$CANVAS_DIR"
    fi || {
        log_err "Clone failed."
        [[ "$USE_MIRROR" == false ]] && log_info "Try again with --mirror if GitHub is slow or unavailable."
        exit 1
    }

    log_ok "Canvas LMS cloned"
}


# =============================================================================
# STEP 2b - Detect the correct postgres image from Canvas's own Dockerfile
# =============================================================================
detect_postgres_image() {
    local pg_df="$CANVAS_DIR/docker-compose/postgres/Dockerfile"

    if [[ ! -f "$pg_df" ]]; then
        log_warn "postgres Dockerfile not found - defaulting to postgis:14-3.3"
        POSTGIS_IMAGE="postgis/postgis:14-3.3"
        return 0
    fi

    # Canvas uses variable FROM lines e.g. "FROM $POSTGRESIMAGE:$POSTGRES"
    # We must resolve ARG defaults to get the real image name.
    # If unresolvable, fall back to postgis:14-3.3 (current Canvas requirement).
    local resolved
    resolved="$(python3 /tmp/canvas_resolve_pg.py "$pg_df" "$CANVAS_DIR/docker-compose.yml" 2>/dev/null || true)"

    if [[ -n "$resolved" ]]; then
        log_info "Canvas postgres image resolved: $resolved"
        POSTGIS_IMAGE="$resolved"
    else
        log_warn "Could not resolve postgres image from Dockerfile - using postgis:14-3.3"
        POSTGIS_IMAGE="postgis/postgis:14-3.3"
    fi
    log_ok "Postgres image: $POSTGIS_IMAGE"
}


# =============================================================================
# STEP 2c - Detect the correct Ruby/Passenger image from Canvas's Dockerfile
# =============================================================================
detect_ruby_image() {
    local dockerfile="$CANVAS_DIR/Dockerfile"

    if [[ ! -f "$dockerfile" ]]; then
        log_warn "Canvas Dockerfile not found - keeping fallback Ruby image: $RUBY_IMAGE"
        return 0
    fi

    # Canvas Dockerfile has:  ARG RUBY=3.4
    #                         FROM instructure/ruby-passenger:$RUBY-jammy
    local ruby_ver
    ruby_ver="$(grep -m1 '^ARG RUBY=' "$dockerfile" | cut -d= -f2 | tr -d '"' | tr -d "'")"

    if [[ -z "$ruby_ver" ]]; then
        log_warn "Could not read Ruby version from Canvas Dockerfile - keeping: $RUBY_IMAGE"
        return 0
    fi

    local detected="instructure/ruby-passenger:${ruby_ver}-jammy"
    if [[ "$detected" != "$RUBY_IMAGE" ]]; then
        log_info "Canvas requires Ruby image: $detected (was: $RUBY_IMAGE)"
        RUBY_IMAGE="$detected"
    fi
    log_ok "Ruby image: $RUBY_IMAGE"
}

# =============================================================================
# STEP 3 - Patch Dockerfiles only when the cloned Canvas files actually need it
#
# Current Canvas uses a generated main Dockerfile and a postgres:14 service image.
# Those should not be rewritten for old apt-key or Debian archive workarounds.
# The archive workaround is only applied when the detected postgres base image is
# one of the old EOL Debian based PostGIS images.
# =============================================================================
apply_patches() {
    log_step "Step 3: Checking Dockerfiles for compatibility patches"

    local main_df="$CANVAS_DIR/Dockerfile"
    if [[ -f "$main_df" ]]; then
        if grep -q 'deb.nodesource.com/node_.*signed-by=' "$main_df" 2>/dev/null; then
            log_ok "Main Dockerfile uses modern NodeSource keyring - no patch needed"
        else
            log_warn "Main Dockerfile does not match the current generated format - leaving unchanged"
        fi
    else
        log_warn "Main Dockerfile not found - skipping"
    fi

    local pg_df="$CANVAS_DIR/docker-compose/postgres/Dockerfile"
    if [[ ! -f "$pg_df" ]]; then
        log_warn "Postgres Dockerfile not found - skipping"
        return 0
    fi

    case "$POSTGIS_IMAGE" in
        postgis/postgis:12-2.5|postgis/postgis:12-3.*|postgis/postgis:13-3.*)
            log_info "Old PostGIS base image detected: $POSTGIS_IMAGE"
            ;;
        *)
            log_ok "Postgres image $POSTGIS_IMAGE does not need Debian archive patching"
            return 0
            ;;
    esac

    python3 - "$pg_df" <<'PYEOF'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if "archive.debian.org" in text and "99no-check-valid-until" in text:
    print("  Postgres Dockerfile already patched")
    sys.exit(0)

archive_block = (
    'RUN set -eux; \\\n'
    '    mkdir -p /etc/apt/apt.conf.d; \\\n'
    '    echo \'Acquire::Check-Valid-Until "false";\' '
    '> /etc/apt/apt.conf.d/99no-check-valid-until; \\\n'
    '    for f in /etc/apt/sources.list \\\n'
    '              /etc/apt/sources.list.d/*.list \\\n'
    '              /etc/apt/sources.list.d/*.sources; do \\\n'
    '        [ -e "$$f" ] || continue; \\\n'
    '        sed -i \\\n'
    '            -e "s|http://deb.debian.org/debian|http://archive.debian.org/debian|g" \\\n'
    '            -e "s|https://deb.debian.org/debian|http://archive.debian.org/debian|g" \\\n'
    '            -e "s|http://security.debian.org/debian-security|http://archive.debian.org/debian-security|g" \\\n'
    '            -e "s|https://security.debian.org/debian-security|http://archive.debian.org/debian-security|g" \\\n'
    '            -e "/buster-updates/d" \\\n'
    '            -e "/bullseye-updates/d" \\\n'
    '            -e "/bookworm-updates/d" \\\n'
    '            "$$f" 2>/dev/null || true; \\\n'
    '    done\n'
)

text = re.sub(r'(^FROM[^\n]*\n)', r'\1' + archive_block + '\n', text, count=1, flags=re.MULTILINE)
path.write_text(text)
print("  Patched old PostGIS Dockerfile")
PYEOF
    log_ok "Postgres Dockerfile"
}

# =============================================================================
# STEP 4 - Write Canvas config files
#
# PLACEHOLDER CREDENTIALS - local dev only.
# DO NOT use these in any environment accessible from the internet.
#
#   DB password   : set in database.yml and the postgres container env
#   Admin password: set in docker-compose.override.yml for first-run seeding
#   Encryption key: generated fresh from /dev/urandom on each fresh install
#
# config/*.yml is already in Canvas's .gitignore - these files will not be
# committed if you fork canvas-lms.
# =============================================================================
configure_canvas() {
    log_step "Step 4: Writing Canvas config files"

    # Create config dir FIRST, then copy - previously the copy ran before the
    # mkdir, silently failed, and left config files missing.
    mkdir -p "$CANVAS_DIR/config"

    local example_dir="$CANVAS_DIR/docker-compose/config"
    if [[ -d "$example_dir" ]]; then
        log_info "Copying example configs from docker-compose/config/"
        cp "$example_dir"/*.yml "$CANVAS_DIR/config/" 2>/dev/null || true
        log_ok "Example configs copied"
    else
        log_warn "docker-compose/config/ not found - writing configs from scratch"
    fi

    # Random 64-hex-char encryption key - unique per installation, never stored
    # in source control. PLACEHOLDER: any 20+ char string works for dev.
    local enc_key
    # tr reads from /dev/urandom (infinite); head closes the pipe after 64 chars,
    # causing SIGPIPE (exit 141). The || true suppresses that under set -euo pipefail.
    enc_key="$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64 || true)"

    # PLACEHOLDER DB password - local only, matches the postgres service.
    # Change this if you ever expose port 5432 outside localhost.
    # PLACEHOLDER: must match Canvas postgres image init script which creates
    # the canvas role with this password. Do not change without also rebuilding
    # the postgres image with a matching password.
    local db_pass="sekret"

    # PLACEHOLDER admin credentials - first-run seed values only.
    # Canvas will use these to create the initial admin account.
    local admin_email="admin@canvas.local"
    local admin_pass="ChangeMe_AfterSetup_1!"

    # database.yml
    cat > "$CANVAS_DIR/config/database.yml" <<EOF
# PLACEHOLDER: password is for local dev only. Change if exposing postgres.
development:
  adapter: postgresql
  encoding: utf8
  database: canvas_development
  host: postgres
  username: canvas
  password: ${db_pass}
  timeout: 5000
test:
  adapter: postgresql
  encoding: utf8
  database: canvas_test
  host: postgres
  username: canvas
  password: ${db_pass}
  timeout: 5000
EOF
    log_ok "config/database.yml"

    # domain.yml
    cat > "$CANVAS_DIR/config/domain.yml" <<'EOF'
development:
  domain: localhost
  ssl: false
test:
  domain: localhost
  ssl: false
EOF
    log_ok "config/domain.yml"

    # security.yml - encryption_key is the only valid key here.
    # PLACEHOLDER: generated at install time. Never commit this file.
    cat > "$CANVAS_DIR/config/security.yml" <<EOF
# PLACEHOLDER: encryption_key is randomly generated at install time.
# Never commit this file or share this value.
development:
  encryption_key: "${enc_key}"
test:
  encryption_key: "test_${enc_key}"
EOF
    log_ok "config/security.yml"

    # outgoing_mail.yml - required for Canvas to boot without errors.
    # PLACEHOLDER: localhost:25 is a no-op; no mail is actually delivered.
    if [[ ! -f "$CANVAS_DIR/config/outgoing_mail.yml" ]]; then
        cat > "$CANVAS_DIR/config/outgoing_mail.yml" <<'EOF'
# PLACEHOLDER: local dev mail sink. Replace with real SMTP for shared installs.
development:
  address: localhost
  port: 25
  domain: localhost
  outgoing_address: canvas@localhost
  default_name: "Canvas LMS (local dev)"
EOF
        log_ok "config/outgoing_mail.yml"
    else
        log_ok "config/outgoing_mail.yml (already exists - not overwritten)"
    fi

    # redis.yml - always write this to guarantee correct format.
    # Canvas changed 'servers:' to 'url:' in Nov 2023. We overwrite any copied
    # example to ensure we always have the right key regardless of Canvas version.
    cat > "$CANVAS_DIR/config/redis.yml" <<'EOF'
development:
  url: redis://redis:6379
test:
  url: redis://redis:6379
EOF
    log_ok "config/redis.yml"

    # cache_store.yml
    # MUST use memory_store here, not redis_store. Canvas loads cache_store.yml
    # during Rails environment init which happens even for db:create. If redis_store
    # is set, Canvas tries to connect to Redis before the DB exists and crashes.
    # After `docker compose up -d` the app runs fine with redis_store - but for
    # the setup rake tasks, memory_store is required to avoid the chicken-and-egg.
    cat > "$CANVAS_DIR/config/cache_store.yml" <<'EOF'
development:
  cache_store: memory_store
test:
  cache_store: memory_store
EOF
    log_ok "config/cache_store.yml"

    # docker-compose.override.yml
    # PLACEHOLDER credentials below are local dev only.
    cat > "$CANVAS_DIR/docker-compose.override.yml" <<EOF
# Generated by canvas-setup.sh - do not commit this file.
# PLACEHOLDER credentials below are for local development only.
services:
  web:
    restart: unless-stopped
    environment:
      RAILS_ENV: development
      DISABLE_SPRING: 1
      # PLACEHOLDER: change these after first login
      CANVAS_LMS_ADMIN_EMAIL: "${admin_email}"
      CANVAS_LMS_ADMIN_PASSWORD: "${admin_pass}"
      CANVAS_LMS_ACCOUNT_NAME: "Canvas Local Dev"
      CANVAS_LMS_STATS_COLLECTION: opt_out
    ports:
      - "${PORT}:80"
    volumes:
      - .:/usr/src/app
      - canvas_gems:/home/docker/.gem
      - canvas_bundle:/home/docker/.bundle
    depends_on:
      - postgres
      - redis
  jobs:
    restart: unless-stopped
    environment:
      RAILS_ENV: development
      DISABLE_SPRING: 1
    volumes:
      - .:/usr/src/app
      - canvas_gems:/home/docker/.gem
      - canvas_bundle:/home/docker/.bundle
    depends_on:
      - postgres
      - redis
  postgres:
    restart: unless-stopped
    ports:
      - "127.0.0.1:5432:5432"
  redis:
    restart: unless-stopped
    ports:
      - "127.0.0.1:6379:6379"

volumes:
  # canvas_gems persists GEM_HOME (/home/docker/.gem/\$RUBY) across container
  # recreations so bundle install does not need to re-run from scratch.
  canvas_gems:
  # canvas_bundle persists BUNDLE_APP_CONFIG (/home/docker/.bundle) including
  # bundler plugins such as bundler-multilock.
  canvas_bundle:

EOF
    log_ok "docker-compose.override.yml"

    # Expose to the final summary
    GENERATED_ADMIN_EMAIL="$admin_email"
    GENERATED_ADMIN_PASS="$admin_pass"
}

# =============================================================================
# STEP 5 - Pull base Docker images
# =============================================================================
pull_images() {
    log_step "Step 5: Pulling Docker base images"

    _pull_and_tag() {
        local src="$1" dst="$2"
        log_info "Pulling: $src"
        $DOCKER_CMD pull "$src" || die "Failed to pull $src"
        [[ "$src" != "$dst" ]] && $DOCKER_CMD tag "$src" "$dst"
        log_ok "$dst"
    }

    if [[ "$USE_MIRROR" == true ]]; then
        log_info "Using Docker mirror: $DOCKER_MIRROR"
        # Mirror: pre-pull all images including Ruby (resolved above)
        _pull_and_tag "$DOCKER_MIRROR/$RUBY_IMAGE"          "$RUBY_IMAGE"
        _pull_and_tag "$DOCKER_MIRROR/$POSTGIS_IMAGE"       "$POSTGIS_IMAGE"
        _pull_and_tag "$DOCKER_MIRROR/library/$REDIS_IMAGE" "$REDIS_IMAGE"
    else
        # Non-mirror: Ruby base image is fetched by "docker compose build --pull"
        # so we only need to pre-pull postgres and redis here.
        log_info "Pulling postgres and redis (Ruby image fetched during build)"
        _pull_and_tag "$POSTGIS_IMAGE" "$POSTGIS_IMAGE"
        _pull_and_tag "$REDIS_IMAGE"   "$REDIS_IMAGE"
    fi
}

# =============================================================================
# STEP 6 - Build images, start services, install assets, seed database
#
# Follows the official Canvas Docker dev setup sequence from:
#   doc/docker/developing_with_docker.md
# =============================================================================
build_and_start() {
    cd "$CANVAS_DIR"
    local dc="$DOCKER_CMD compose -f docker-compose.yml -f docker-compose.override.yml"

    # --- Build ----------------------------------------------------------------
    local host_uid
    host_uid="$(id -u "$REAL_USER" 2>/dev/null || echo "0")"

    log_step "Step 6: Building Docker images  (first run takes 10-30 min)"
    if [[ "$host_uid" == "0" ]]; then
        log_info "Building as root - skipping USER_ID remapping"
        $dc build --pull || die "Docker build failed"
    else
        log_info "Building with USER_ID=${host_uid} (user: $REAL_USER)"
        $dc build --pull --build-arg USER_ID="${host_uid}" || die "Docker build failed"
    fi
    log_ok "Build complete"

    # --- Start everything -----------------------------------------------------
    # Canvas's docker-compose.yml defines no named volumes for gems, so gems
    # must live in the container's own filesystem. We therefore:
    #   1. Start all services with up -d (web container starts, Passenger fails
    #      initially because gems aren't installed - that's expected).
    #   2. Run ALL setup (bundle install, assets, DB) via exec in the RUNNING
    #      container. Gems are installed into that container's filesystem.
    #   3. Signal Passenger to reload via tmp/restart.txt - no container
    #      restart, so the filesystem (and gems) are preserved.
    #   4. restart:unless-stopped means Docker restarts the same container on
    #      reboot, preserving its filesystem - gems survive indefinitely.
    log_step "Step 7: Starting all services"
    $dc up -d || die "Failed to start services"
    log_ok "All services started"

    # --- Wait for PostgreSQL --------------------------------------------------
    log_step "Waiting for PostgreSQL..."
    local waited=0
    until $dc exec -T postgres pg_isready -U postgres &>/dev/null; do
        sleep 3; waited=$((waited + 3))
        log_info "  ${waited}s..."
        [[ $waited -ge 120 ]] && die "PostgreSQL never started. Check: $dc logs postgres"
    done
    log_ok "PostgreSQL accepting connections"

    sleep 5
    log_info "Ensuring canvas database role exists..."
    $dc exec -T postgres psql -U postgres -c "
        DO \$\$ BEGIN
            IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'canvas') THEN
                CREATE ROLE canvas SUPERUSER CREATEDB LOGIN PASSWORD 'sekret';
            ELSE
                ALTER ROLE canvas WITH SUPERUSER CREATEDB LOGIN PASSWORD 'sekret';
            END IF;
        END \$\$;
    " || die "Failed to create canvas postgres role"
    log_ok "canvas role ready"

    # --- Wait for web container to accept exec --------------------------------
    log_step "Step 8: Waiting for web container..."
    local web_waited=0
    until $dc exec -T web echo "ok" &>/dev/null; do
        sleep 3; web_waited=$((web_waited + 3))
        log_info "  ${web_waited}s..."
        [[ $web_waited -ge 120 ]] && die "Web container never became ready"
    done
    log_ok "Web container ready"

    # --- All setup in the running container -----------------------------------
    # Running via exec means gems install into the running container's
    # filesystem and stay there. No run --rm = no ephemeral container = no
    # lost gems. Passenger's initial failure (no gems yet) is harmless.
    log_step "Step 9: Installing assets and seeding database  (slow - 20-40 min)"
    $dc exec -T web bash -c "
        set -e

        echo '--- Installing bundler-multilock plugin ---'
        bundle plugin install bundler-multilock || true

        echo '--- Installing Ruby gems and frontend assets ---'
        ./script/install_assets.sh

        echo '--- Creating and seeding the database ---'
        RAILS_ENV=development bundle exec rake db:create db:initial_setup

        echo '--- Migrating test database ---'
        RAILS_ENV=test bundle exec rake db:migrate || true
    " || die "Setup failed - check output above"
    log_ok "Assets installed and database seeded"

    # --- Reload Canvas without restarting the container ----------------------
    # touch tmp/restart.txt tells Passenger to reload the Rails app in-place.
    # The container keeps running, the filesystem (and gems) are preserved.
    # This is the key difference from a container restart, which would lose gems.
    log_step "Step 10: Reloading Canvas (Passenger restart)"
    $dc exec -T web touch tmp/restart.txt
    log_ok "Passenger reload triggered"

    # --- Wait for Passenger to signal ready -----------------------------------
    log_step "Waiting for Passenger to come online..."
    local passenger_ready=false
    while IFS= read -r log_line; do
        if [[ "$log_line" == *"Passenger core online"* ]]; then
            passenger_ready=true
            break
        fi
    done < <(timeout 180 $dc logs --follow --tail 0 web 2>&1 || true)

    if [[ "$passenger_ready" == true ]]; then
        log_ok "Passenger online"
    else
        log_warn "Passenger signal not seen - Canvas may still be loading"
    fi

    # --- Verify HTTP ----------------------------------------------------------
    log_step "Verifying HTTP on port ${PORT}..."
    local http_waited=0
    until curl -s --connect-timeout 3 -o /dev/null "http://localhost:${PORT}" &>/dev/null; do
        sleep 3; http_waited=$((http_waited + 3))
        log_info "  ${http_waited}s..."
        if [[ $http_waited -ge 120 ]]; then
            log_warn "Port ${PORT} not responding after 120s."
            log_warn "Check: $dc logs --tail 40 web"
            break
        fi
    done
    [[ $http_waited -lt 120 ]] && log_ok "Canvas is live at http://localhost:${PORT}"
}


# =============================================================================
# STEP A - Configure UFW firewall
#
# Docker bypasses UFW by directly manipulating iptables. This means Canvas's
# web port is reachable from the network even if UFW has no explicit rule.
# We add a rule anyway so the firewall's own rule list is consistent and
# auditable, and so tools that inspect UFW rules see Canvas listed.
#
# Postgres (5432) and Redis (6379) are bound to 127.0.0.1 only in our
# override - they are never exposed externally regardless of UFW.
# =============================================================================
configure_firewall() {
    log_step "Step A: Firewall (UFW)"

    if ! command -v ufw &>/dev/null; then
        log_info "UFW not installed - no firewall configuration needed"
        return 0
    fi

    local ufw_status
    ufw_status=$(_sudo ufw status 2>/dev/null | head -1 || true)

    if echo "$ufw_status" | grep -q "inactive"; then
        log_info "UFW is installed but inactive - no rules needed"
        return 0
    fi

    # UFW is active - add explicit allow rule for the Canvas web port
    log_info "UFW is active - adding allow rule for port ${PORT}/tcp"
    _sudo ufw allow "${PORT}/tcp" comment "Canvas LMS web" 2>/dev/null \
        || log_warn "Could not add UFW rule - you may need to run: sudo ufw allow ${PORT}/tcp"

    log_ok "UFW: port ${PORT}/tcp allowed"
    log_info "Note: Docker bypasses UFW via iptables, so Canvas is already reachable."
    log_info "      The rule above makes the allowance explicit and auditable."
    log_info "      Postgres/Redis are bound to 127.0.0.1 - never exposed externally."
}

# =============================================================================
# STEP B - Create and enable a systemd service for Canvas LMS
#
# Three-layer persistence on reboot:
#
#   Layer 1 - docker.service enabled:
#     Docker daemon starts automatically on every boot.
#     (Done in Step 1 via: systemctl enable docker)
#
#   Layer 2 - restart: unless-stopped in docker-compose.override.yml:
#     If Docker restarts or the machine crashes, Docker automatically
#     restarts any container that was running (not explicitly stopped).
#     This covers unexpected reboots where systemd doesn't cleanly stop things.
#
#   Layer 3 - canvas-lms.service (this step):
#     A proper systemd unit that starts Canvas after Docker and the network
#     are fully ready. Provides clean systemctl management:
#       sudo systemctl start   canvas-lms
#       sudo systemctl stop    canvas-lms
#       sudo systemctl restart canvas-lms
#       sudo systemctl status  canvas-lms
#       sudo systemctl disable canvas-lms   # stop auto-starting on boot
#
#   ExecStop uses "docker compose stop" (not "down") so containers are
#   stopped but not removed. Layer 2 then handles crash recovery if Docker
#   restarts without systemd involvement.
# =============================================================================
create_systemd_service() {
    log_step "Step B: Creating canvas-lms systemd service"

    local docker_bin
    docker_bin="$(command -v docker || echo "/usr/bin/docker")"

    local service_path="/etc/systemd/system/canvas-lms.service"

    _sudo tee "$service_path" > /dev/null << EOF
# canvas-lms.service - managed by canvas-setup.sh
# Canvas LMS install: ${CANVAS_DIR}
[Unit]
Description=Canvas LMS (Docker Compose)
Documentation=https://github.com/instructure/canvas-lms
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${CANVAS_DIR}

# Start: bring all Canvas containers up (idempotent - safe if already running)
ExecStart=${docker_bin} compose \\
    -f docker-compose.yml \\
    -f docker-compose.override.yml \\
    up -d

# Stop: stop containers without removing them, so Docker's restart:unless-stopped
# policy can recover from crashes without needing this service to run first.
ExecStop=${docker_bin} compose \\
    -f docker-compose.yml \\
    -f docker-compose.override.yml \\
    stop

# Reload: restart web and jobs only (leaves postgres/redis untouched)
ExecReload=${docker_bin} compose \\
    -f docker-compose.yml \\
    -f docker-compose.override.yml \\
    restart web jobs

StandardOutput=journal
StandardError=journal

# Canvas startup includes Rails boot + asset loading - allow plenty of time
TimeoutStartSec=300
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF

    _sudo systemctl daemon-reload
    _sudo systemctl enable canvas-lms \
        || die "Failed to enable canvas-lms.service"

    log_ok "Service file: $service_path"
    log_ok "canvas-lms.service enabled - Canvas will start automatically on every boot"
}

# =============================================================================
# Main
# =============================================================================
install_prerequisites
clone_canvas
detect_postgres_image
detect_ruby_image
apply_patches
configure_canvas
pull_images
build_and_start
configure_firewall
create_systemd_service

# =============================================================================
# Done
# =============================================================================
printf "\n%s" "${BOLD}${GREEN}"
echo "====================================================="
echo "  Canvas LMS is ready!"
echo "====================================================="
printf "%s\n\n" "${NC}"
echo "  URL:      http://localhost:${PORT}"
echo "  Email:    ${GENERATED_ADMIN_EMAIL}"
echo "  Password: ${GENERATED_ADMIN_PASS}"
echo ""
printf "  %sCHANGE THE PASSWORD after your first login.%s\n" "$YELLOW" "$NC"
echo ""
echo "  ── Managing Canvas ──────────────────────────────────"
echo ""
echo "  Start:   sudo systemctl start canvas-lms"
echo "  Stop:    sudo systemctl stop  canvas-lms"
echo "  Restart: sudo systemctl restart canvas-lms"
echo "  Status:  sudo systemctl status canvas-lms"
echo "  Disable auto-start: sudo systemctl disable canvas-lms"
echo ""
echo "  ── Logs and console ─────────────────────────────────"
echo "  cd $CANVAS_DIR"
echo ""
echo "  Logs:    $DOCKER_CMD compose -f docker-compose.yml -f docker-compose.override.yml logs -f"
echo "  Console: $DOCKER_CMD compose -f docker-compose.yml -f docker-compose.override.yml exec web bundle exec rails console"
echo ""
printf "  %sNote:%s config/security.yml was generated with a random encryption key.\n" "$YELLOW" "$NC"
echo "        Never commit that file or share its contents."
echo ""
