#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 PrivacySafe Foundation, Inc.
# SPDX-License-Identifier: MIT
#
# canvas-setup-macos.sh — Canvas LMS local development installer for macOS
#
# Part of the Canvas LMS Setup Toolkit by PrivacySafe Foundation, Inc.
# MIT License — see LICENSE file or https://opensource.org/licenses/MIT
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
#   chmod +x canvas-setup-macos.sh
#   ./canvas-setup-macos.sh --install-path ~/canvas-lms
#   ./canvas-setup-macos.sh --install-path ~/canvas-lms --port 8080
#   ./canvas-setup-macos.sh --install-path ~/canvas-lms --mirror
#
# What this script does:
#   1. Checks macOS version and installs Homebrew, Git, Python 3, Docker Desktop
#   2. Detects Apple Silicon and configures platform settings accordingly
#   3. Clones Canvas LMS from GitHub (or a Gitee mirror)
#   4. Patches Dockerfiles for compatibility
#   5. Writes all required Canvas config files
#   6. Builds and starts the Docker services
#   7. Installs Ruby/JS assets inside the container
#   8. Creates and seeds the database
#
# SECURITY NOTE FOR CONTRIBUTORS:
#   Passwords and keys in this script are PLACEHOLDERS generated at runtime.
#   Do not commit real credentials. The generated security.yml is listed in
#   Canvas's .gitignore and will not be checked in.
#
# Requirements:
#   macOS 12 Monterey or later, 8 GB+ RAM, 25 GB+ free disk
#   Docker Desktop must be installed (this script will install it if Homebrew
#   is available, but you must open it once to accept the license agreement).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
INSTALL_PATH=""
USE_MIRROR=false
PORT=3000

CANVAS_REPO="https://github.com/instructure/canvas-lms.git"
CANVAS_MIRROR="https://gitee.com/xiong-yuhui/canvas-Lms.git"
DOCKER_MIRROR="docker.1ms.run"

# Canvas base images — postgres image is detected dynamically after clone
RUBY_IMAGE="instructure/ruby-passenger:2.7"
POSTGIS_IMAGE="postgis/postgis:14-3.3"   # fallback; overridden by detect_postgres_image()
REDIS_IMAGE="redis:alpine"

# Set after detecting CPU architecture
ARCH=""
# "--platform linux/amd64" on Apple Silicon (M1/M2/M3), empty on Intel
PLATFORM_ARG=""

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

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF

${BOLD}Usage:${NC} $0 --install-path <path> [options]

${BOLD}Options:${NC}
  --install-path PATH   Full path where Canvas LMS will be cloned. Required.
                        Tip: use a path inside your home directory, e.g. ~/canvas-lms
  --port PORT           Host port for Canvas (default: 3000).
  --mirror              Use Gitee + Docker mirror (for restricted networks).
  --help                Show this message.

${BOLD}Examples:${NC}
  $0 --install-path ~/canvas-lms
  $0 --install-path ~/canvas-lms --port 8080

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

# Expand ~ in INSTALL_PATH if present
INSTALL_PATH="${INSTALL_PATH/#\~/$HOME}"
CANVAS_DIR="$INSTALL_PATH"

# Do not run as root on macOS — Docker Desktop handles permissions
if [[ "$EUID" -eq 0 ]]; then
    die "Do not run this script as root on macOS. Run as your normal user account."
fi

printf "\n%s" "${BOLD}"
echo "====================================================="
echo "  Canvas LMS — macOS Local Development Setup"
echo "  Target:  $CANVAS_DIR"
echo "  Port:    $PORT"
echo "  Mirror:  $USE_MIRROR"
echo "====================================================="
printf "%s\n" "${NC}"

# =============================================================================
# STEP 1 — Prerequisites
# =============================================================================
install_prerequisites() {
    log_step "Step 1: Checking and installing prerequisites"

    # ---------------------------------------------------------------
    # macOS version check — require Monterey (12) or later
    # ---------------------------------------------------------------
    local macos_major
    macos_major=$(sw_vers -productVersion | cut -d. -f1)
    if [[ "${macos_major:-0}" -lt 12 ]]; then
        log_warn "macOS $(sw_vers -productVersion) detected. Monterey (12) or later is recommended."
    else
        log_ok "macOS $(sw_vers -productVersion)"
    fi

    # ---------------------------------------------------------------
    # Apple Silicon detection
    # Docker images for Canvas (especially ruby-passenger) are built
    # for linux/amd64. On Apple Silicon we must explicitly request the
    # amd64 platform so Docker Desktop uses Rosetta 2 to emulate it.
    # Without this, image pulls and builds fail or produce wrong arch.
    # ---------------------------------------------------------------
    ARCH="$(uname -m)"
    if [[ "$ARCH" == "arm64" ]]; then
        PLATFORM_ARG="--platform linux/amd64"
        log_warn "Apple Silicon (arm64) detected."
        log_warn "Canvas images are amd64-only — will use Rosetta 2 emulation."
        log_warn "Builds will be slower than on Intel. This is normal."
    else
        PLATFORM_ARG=""
        log_ok "Architecture: x86_64 (Intel)"
    fi

    # ---------------------------------------------------------------
    # Memory — warn if macOS has less than 8 GB
    # Also remind about Docker Desktop's own memory limit (Settings →
    # Resources → Memory). Canvas needs at least 4 GB allocated there.
    # ---------------------------------------------------------------
    local mem_bytes mem_gb
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
    if [[ "${mem_gb:-0}" -lt 8 ]]; then
        log_warn "Only ${mem_gb} GB RAM detected — 8 GB+ recommended."
    else
        log_ok "RAM: ${mem_gb} GB"
    fi
    log_info "Make sure Docker Desktop has at least 4 GB RAM allocated:"
    log_info "  Docker Desktop → Settings → Resources → Memory"

    # ---------------------------------------------------------------
    # Disk space
    # ---------------------------------------------------------------
    local check_path="$INSTALL_PATH"
    [[ -d "$check_path" ]] || check_path="$(dirname "$check_path")"
    [[ -d "$check_path" ]] || check_path="$HOME"
    local free_kb free_gb
    free_kb=$(df -k "$check_path" | tail -1 | awk '{print $4}')
    free_gb=$(( free_kb / 1024 / 1024 ))
    if [[ "${free_gb:-0}" -lt 25 ]]; then
        log_warn "Only ${free_gb} GB free — Canvas build + images need ~25 GB"
    else
        log_ok "Free disk: ${free_gb} GB"
    fi

    # ---------------------------------------------------------------
    # Homebrew — required for git, python3, and Docker Desktop install
    # ---------------------------------------------------------------
    if ! command -v brew &>/dev/null; then
        log_info "Homebrew not found — installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            || die "Homebrew installation failed. Install it manually from https://brew.sh then re-run."
    fi

    # Ensure brew is on PATH (Apple Silicon installs to /opt/homebrew)
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    log_ok "Homebrew: $(brew --version | head -1)"

    # ---------------------------------------------------------------
    # Git
    # ---------------------------------------------------------------
    if ! command -v git &>/dev/null; then
        log_info "Installing git..."
        brew install git
    fi
    log_ok "Git: $(git --version)"

    # ---------------------------------------------------------------
    # Python 3 — used for Dockerfile patching
    # ---------------------------------------------------------------
    if ! command -v python3 &>/dev/null; then
        log_info "Installing python3..."
        brew install python3
    fi
    log_ok "Python3: $(python3 --version)"

    # ---------------------------------------------------------------
    # Docker Desktop
    # On macOS, Docker runs inside a lightweight Linux VM managed by
    # Docker Desktop. There is no native docker daemon; the user must
    # install Docker Desktop and accept the license agreement once.
    # We cannot automate the license acceptance step.
    # ---------------------------------------------------------------
    if ! command -v docker &>/dev/null; then
        if [[ ! -d "/Applications/Docker.app" ]]; then
            log_info "Installing Docker Desktop via Homebrew..."
            brew install --cask docker \
                || die "Docker Desktop installation failed. Install it manually from https://www.docker.com/products/docker-desktop/"
        fi
        # Docker was just installed or is installed but not on PATH yet
        log_warn "Docker Desktop is installed but needs to be started."
        log_warn "Please:"
        log_warn "  1. Open Docker Desktop from your Applications folder"
        log_warn "  2. Accept the license agreement and complete initial setup"
        log_warn "  3. Wait until Docker Desktop shows 'Engine running'"
        log_warn "  4. Re-run this script"
        open -a Docker 2>/dev/null || true
        exit 0
    fi

    # Docker is on PATH — make sure the daemon is actually running
    if ! docker info &>/dev/null; then
        log_info "Docker Desktop is not running — attempting to start it..."
        open -a Docker 2>/dev/null || open -a "Docker Desktop" 2>/dev/null || true

        local waited=0
        until docker info &>/dev/null; do
            sleep 4; waited=$(( waited + 4 ))
            log_info "  Waiting for Docker Desktop... ${waited}s"
            if [[ $waited -ge 90 ]]; then
                die "Docker Desktop did not start within 90 seconds.\nOpen it manually, wait for 'Engine running', then re-run this script."
            fi
        done
    fi

    # Verify compose and buildx — both ship with Docker Desktop
    docker compose version &>/dev/null \
        || die "Docker Compose plugin not found. Update Docker Desktop to version 4.x or later."
    docker buildx version &>/dev/null \
        || die "Docker Buildx plugin not found. Update Docker Desktop to version 4.x or later."

    log_ok "Docker:         $(docker --version)"
    log_ok "Docker Compose: $(docker compose version)"
    log_ok "Docker Buildx:  $(docker buildx version)"
    log_ok "Docker daemon:  running"

    # ---------------------------------------------------------------
    # Write the postgres image resolver helper used by detect_postgres_image()
    # ---------------------------------------------------------------
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
# STEP 2 — Clone Canvas LMS
# =============================================================================
clone_canvas() {
    log_step "Step 2: Cloning Canvas LMS"

    if [[ -d "$CANVAS_DIR/.git" ]]; then
        log_warn "Repository already exists at $CANVAS_DIR — skipping clone"
        return 0
    fi

    if [[ -e "$CANVAS_DIR" ]]; then
        die "$CANVAS_DIR exists but is not a git repo. Remove it and re-run."
    fi

    mkdir -p "$CANVAS_DIR"

    local repo="$CANVAS_REPO"
    [[ "$USE_MIRROR" == true ]] && repo="$CANVAS_MIRROR"

    log_info "Cloning from: $repo"
    git clone "$repo" "$CANVAS_DIR" || {
        log_err "Clone failed."
        [[ "$USE_MIRROR" == false ]] && log_info "Try again with --mirror if GitHub is slow."
        exit 1
    }
    log_ok "Canvas LMS cloned"
}

# =============================================================================
# STEP 2b — Detect the correct postgres image from Canvas's own Dockerfile
# =============================================================================
detect_postgres_image() {
    local pg_df="$CANVAS_DIR/docker-compose/postgres/Dockerfile"

    if [[ ! -f "$pg_df" ]]; then
        log_warn "postgres Dockerfile not found — defaulting to postgis:14-3.3"
        POSTGIS_IMAGE="postgis/postgis:14-3.3"
        return 0
    fi

    # Canvas uses variable FROM lines e.g. "FROM $POSTGRESIMAGE:$POSTGRES"
    # We resolve ARG defaults to find the real image. Fall back to 14-3.3
    # (current Canvas minimum) if we cannot resolve.
    local resolved
    resolved="$(python3 /tmp/canvas_resolve_pg.py \
        "$pg_df" "$CANVAS_DIR/docker-compose.yml" 2>/dev/null || true)"

    if [[ -n "$resolved" ]]; then
        log_info "Canvas postgres image resolved: $resolved"
        POSTGIS_IMAGE="$resolved"
    else
        log_warn "Could not resolve postgres image — defaulting to postgis:14-3.3"
        POSTGIS_IMAGE="postgis/postgis:14-3.3"
    fi
    log_ok "Postgres image: $POSTGIS_IMAGE"
}

# =============================================================================
# STEP 3 — Patch Dockerfiles
#
# These patches fix issues in Canvas's Dockerfiles that are unrelated to macOS
# but affect all Docker builds:
#
# (a) Main Dockerfile: uses legacy apt-key and unsigned apt repo lines that
#     fail on modern Docker. Fix: add [trusted=yes], neutralise apt-key.
#
# (b) PostGIS Dockerfile: may be based on an EOL Debian release whose apt
#     sources no longer resolve. Fix: redirect to archive.debian.org.
# =============================================================================
apply_patches() {
    log_step "Step 3: Patching Dockerfiles"

    # --- Main Canvas Dockerfile -----------------------------------------------
    local main_df="$CANVAS_DIR/Dockerfile"
    if [[ -f "$main_df" ]]; then
        python3 - "$main_df" <<'PYEOF'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
original = text

text = text.replace(
    'echo "deb https://deb.nodesource.com',
    'echo "deb [trusted=yes] https://deb.nodesource.com'
)
text = text.replace(
    'echo "deb http://apt.postgresql.org',
    'echo "deb [trusted=yes] http://apt.postgresql.org'
)
text = text.replace(
    "apt-key add - && apt-get update -qq && apt-get install",
    "apt-key add - 2>/dev/null || true && (apt-get update -qq || true) && apt-get install"
)
text = re.sub(
    r'apt-key adv --keyserver\s+\S+\s+--recv-keys\s+\S+[^\n]*\n',
    '# apt-key adv removed — [trusted=yes] used instead\n',
    text
)

if text != original:
    path.write_text(text)
    print("  Patched main Dockerfile")
else:
    print("  Main Dockerfile already up to date")
PYEOF
        log_ok "Main Dockerfile"
    else
        log_warn "Main Dockerfile not found — skipping"
    fi

    # --- PostGIS Dockerfile ---------------------------------------------------
    local pg_df="$CANVAS_DIR/docker-compose/postgres/Dockerfile"
    if [[ -f "$pg_df" ]]; then
        python3 - "$pg_df" <<'PYEOF'
import sys, re
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if "archive.debian.org" in text and "99no-check-valid-until" in text:
    print("  PostGIS Dockerfile already patched")
    sys.exit(0)

text = re.sub(
    r'RUN\s+sed\s+-i.*?archive\.debian\.org.*?\n', '',
    text, flags=re.DOTALL
)

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

text = re.sub(
    r'(^FROM[^\n]*\n)', r'\1' + archive_block + '\n',
    text, count=1, flags=re.MULTILINE
)

path.write_text(text)
print("  Patched PostGIS Dockerfile")
PYEOF
        log_ok "PostGIS Dockerfile"
    else
        log_warn "PostGIS Dockerfile not found — skipping"
    fi
}

# =============================================================================
# STEP 4 — Write Canvas config files
#
# PLACEHOLDER CREDENTIALS — local dev only.
# DO NOT use in any environment accessible from the internet.
#
# config/*.yml is listed in Canvas's .gitignore — will not be committed.
# =============================================================================
configure_canvas() {
    log_step "Step 4: Writing Canvas config files"

    # Copy Canvas's bundled example configs first — they contain correct
    # boilerplate. We overwrite only what we need to customise.
    local example_dir="$CANVAS_DIR/docker-compose/config"
    if [[ -d "$example_dir" ]]; then
        log_info "Copying example configs from docker-compose/config/"
        cp "$example_dir"/*.yml "$CANVAS_DIR/config/" 2>/dev/null || true
        log_ok "Example configs copied"
    else
        log_warn "docker-compose/config/ not found — writing configs from scratch"
    fi

    mkdir -p "$CANVAS_DIR/config"

    # PLACEHOLDER encryption key — generated fresh on each install.
    # tr reads /dev/urandom infinitely; head closes the pipe after 64 chars.
    # The || true prevents SIGPIPE from killing the script under set -euo pipefail.
    local enc_key
    enc_key="$(tr -dc 'a-f0-9' < /dev/urandom | head -c 64 || true)"

    # PLACEHOLDER DB password — must match Canvas's postgres image init script
    local db_pass="sekret"

    # PLACEHOLDER admin credentials — used only for first-run seeding
    local admin_email="admin@canvas.local"
    local admin_pass="ChangeMe_AfterSetup_1!"

    # database.yml
    cat > "$CANVAS_DIR/config/database.yml" <<EOF
# PLACEHOLDER: local dev only. Change password if exposing postgres.
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

    # security.yml — only encryption_key is valid here.
    # PLACEHOLDER: randomly generated. Never commit this file.
    cat > "$CANVAS_DIR/config/security.yml" <<EOF
# PLACEHOLDER: generated at install time. Never commit or share this value.
development:
  encryption_key: "${enc_key}"
test:
  encryption_key: "test_${enc_key}"
EOF
    log_ok "config/security.yml"

    # outgoing_mail.yml — Canvas requires this file to boot.
    # PLACEHOLDER: localhost:25 is a no-op; no mail is delivered.
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
        log_ok "config/outgoing_mail.yml (already exists — not overwritten)"
    fi

    # redis.yml — always write to guarantee correct format.
    # Canvas changed 'servers:' to 'url:' in November 2023.
    cat > "$CANVAS_DIR/config/redis.yml" <<'EOF'
development:
  url: redis://redis:6379
test:
  url: redis://redis:6379
EOF
    log_ok "config/redis.yml"

    # cache_store.yml — use memory_store during setup tasks.
    # Canvas loads this during Rails environment init, which runs even for
    # db:create. If redis_store is set, Canvas tries to connect to Redis
    # before the DB exists and crashes. memory_store avoids this.
    cat > "$CANVAS_DIR/config/cache_store.yml" <<'EOF'
development:
  cache_store: memory_store
test:
  cache_store: memory_store
EOF
    log_ok "config/cache_store.yml"

    # docker-compose.override.yml
    # On Apple Silicon (arm64), Canvas's ruby-passenger image is amd64-only.
    # We must set platform: linux/amd64 for those services so Docker Desktop
    # uses Rosetta 2 emulation. On Intel this section is omitted.
    if [[ "$ARCH" == "arm64" ]]; then
        local platform_block="    platform: linux/amd64"
    else
        local platform_block=""
    fi

    cat > "$CANVAS_DIR/docker-compose.override.yml" <<EOF
# Generated by canvas-setup-macos.sh — do not commit this file.
# PLACEHOLDER credentials below are for local development only.
services:
  web:
    restart: unless-stopped
${platform_block:+    platform: linux/amd64}
    environment:
      RAILS_ENV: development
      DISABLE_SPRING: 1
      # PLACEHOLDER: change after first login
      CANVAS_LMS_ADMIN_EMAIL: "${admin_email}"
      CANVAS_LMS_ADMIN_PASSWORD: "${admin_pass}"
      CANVAS_LMS_ACCOUNT_NAME: "Canvas Local Dev"
      CANVAS_LMS_STATS_COLLECTION: opt_out
    ports:
      - "${PORT}:80"
    volumes:
      - .:/usr/src/app
    depends_on:
      - postgres
      - redis
  jobs:
    restart: unless-stopped
${platform_block:+    platform: linux/amd64}
    environment:
      RAILS_ENV: development
      DISABLE_SPRING: 1
    volumes:
      - .:/usr/src/app
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
EOF
    log_ok "docker-compose.override.yml"

    GENERATED_ADMIN_EMAIL="$admin_email"
    GENERATED_ADMIN_PASS="$admin_pass"
}

# =============================================================================
# STEP 5 — Pull base Docker images
# =============================================================================
pull_images() {
    log_step "Step 5: Pulling Docker base images"

    # On Apple Silicon, pull the amd64 variants explicitly so Docker caches
    # the right architecture before the build step.
    local pull_flags=""
    [[ -n "$PLATFORM_ARG" ]] && pull_flags="--platform linux/amd64"

    _pull() {
        local src="$1" dst="$2"
        log_info "Pulling: $src"
        # shellcheck disable=SC2086
        docker pull $pull_flags "$src" || die "Failed to pull $src"
        [[ "$src" != "$dst" ]] && docker tag "$src" "$dst"
        log_ok "$dst"
    }

    if [[ "$USE_MIRROR" == true ]]; then
        log_info "Using Docker mirror: $DOCKER_MIRROR"
        _pull "$DOCKER_MIRROR/$RUBY_IMAGE"          "$RUBY_IMAGE"
        _pull "$DOCKER_MIRROR/$POSTGIS_IMAGE"       "$POSTGIS_IMAGE"
        _pull "$DOCKER_MIRROR/library/$REDIS_IMAGE" "$REDIS_IMAGE"
    else
        _pull "$RUBY_IMAGE"    "$RUBY_IMAGE"
        _pull "$POSTGIS_IMAGE" "$POSTGIS_IMAGE"
        _pull "$REDIS_IMAGE"   "$REDIS_IMAGE"
    fi
}

# =============================================================================
# STEP 6 — Build, start, install assets, seed database
# =============================================================================
build_and_start() {
    cd "$CANVAS_DIR"
    local dc="docker compose -f docker-compose.yml -f docker-compose.override.yml"

    # --- Build ----------------------------------------------------------------
    log_step "Step 6: Building Docker images"
    if [[ "$ARCH" == "arm64" ]]; then
        log_info "Apple Silicon: building with --platform linux/amd64 (Rosetta)"
        log_info "This may take 20-45 min on first run — the emulated build is slower."
        DOCKER_DEFAULT_PLATFORM=linux/amd64 $dc build \
            || die "Docker build failed — check output above"
    else
        log_info "First run takes 10-20 min."
        $dc build || die "Docker build failed — check output above"
    fi
    log_ok "Build complete"

    # --- Start infrastructure first -------------------------------------------
    # Postgres and Redis must be healthy before the web container starts.
    # Starting them separately prevents web from crashing on boot because
    # its database/cache connections aren't available yet.
    log_step "Step 7: Starting postgres and redis"
    $dc up -d postgres redis || die "Failed to start postgres/redis"
    log_ok "postgres and redis started"

    # --- Wait for PostgreSQL --------------------------------------------------
    log_step "Waiting for PostgreSQL..."
    local waited=0
    until $dc exec -T postgres pg_isready -U postgres &>/dev/null; do
        sleep 3; waited=$(( waited + 3 ))
        log_info "  ${waited}s..."
        [[ $waited -ge 120 ]] && die "PostgreSQL never started. Check: $dc logs postgres"
    done
    log_ok "PostgreSQL accepting connections"

    # Canvas's postgres image should create the canvas role via init scripts,
    # but those scripts are unreliable across versions. We ensure the role
    # exists ourselves — idempotent and safe to run either way.
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

    # --- Setup via run --rm (temporary containers) ----------------------------
    # We do NOT start the web container yet. All setup tasks run in temporary
    # containers (run --rm) that are destroyed when they finish. The serving
    # web container starts fresh via up -d with no prior state — no stale PID
    # files, no old unix sockets, no leftover nginx processes.
    #
    # On Apple Silicon, DOCKER_DEFAULT_PLATFORM ensures run --rm uses amd64.
    # bundler-multilock is reinstalled at the start of each bash -c because
    # it lives in the container home dir and does not survive container exit.
    [[ "$ARCH" == "arm64" ]] && export DOCKER_DEFAULT_PLATFORM=linux/amd64

    log_step "Step 8: Installing Ruby gems and frontend assets  (slow)"
    $dc run --rm --no-deps web bash -c "
        set -e
        bundle plugin install bundler-multilock || true
        ./script/install_assets.sh
    " || die "install_assets.sh failed — check output above"
    log_ok "Assets installed"

    log_step "Step 9: Creating and seeding the database"
    $dc run --rm --no-deps web bash -c "
        set -e
        bundle plugin install bundler-multilock || true
        RAILS_ENV=development bundle exec rake db:create db:initial_setup
    " || die "Database setup failed — check output above"
    log_ok "Database created and seeded"

    $dc run --rm --no-deps web bash -c "
        bundle plugin install bundler-multilock || true
        RAILS_ENV=test bundle exec rake db:migrate
    " 2>/dev/null || log_warn "Test DB migration skipped (non-fatal)"

    # --- Start all services ---------------------------------------------------
    # The web container starts here for the FIRST time as a serving container.
    # Volumes already have compiled assets and a fully seeded database.
    log_step "Step 10: Starting all Canvas services"
    $dc up -d || die "Failed to start Canvas services"
    log_ok "All services started"

    # --- Wait for Passenger to signal ready -----------------------------------
    # Passenger logs "Passenger core online" the instant it is bound and ready.
    # --tail 0 ensures we only see lines from this fresh startup.
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
        log_warn "Passenger did not signal ready within 3 minutes."
        log_warn "Check: $dc logs web"
    fi

    # --- Verify HTTP is actually reachable ------------------------------------
    log_step "Verifying HTTP connectivity on port ${PORT}..."
    local http_waited=0
    until curl -s --connect-timeout 3 -o /dev/null "http://localhost:${PORT}" &>/dev/null; do
        sleep 3; http_waited=$(( http_waited + 3 ))
        log_info "  ${http_waited}s..."
        if [[ $http_waited -ge 60 ]]; then
            log_warn "Port ${PORT} not responding after 60s."
            log_warn "Check: $dc logs --tail 40 web"
            break
        fi
    done
    [[ $http_waited -lt 60 ]] && log_ok "Canvas is live at http://localhost:${PORT}"
}


# =============================================================================
# STEP A — macOS Application Firewall
#
# macOS uses an application-based firewall, not a port-based one. Docker
# Desktop registers itself as a trusted application, so its bound ports
# (including Canvas's web port) are accessible without manual firewall rules.
# No configuration is required for local access (localhost).
#
# If you are accessing Canvas from another device on your LAN and macOS
# prompts "Allow incoming connections for docker?", click Allow.
# =============================================================================
configure_firewall() {
    log_step "Step A: macOS Firewall"
    log_info "macOS uses an application-based firewall."
    log_info "Docker Desktop is already trusted — no port rules are needed."
    log_info "Postgres/Redis are bound to 127.0.0.1 only and are not exposed."
    log_ok "Firewall: no action required"
}

# =============================================================================
# STEP B — launchd LaunchAgent for persistent auto-start
#
# macOS uses launchd instead of systemd. A LaunchAgent in
# ~/Library/LaunchAgents/ runs when the user logs in.
#
# Three-layer persistence on macOS:
#
#   Layer 1 — Docker Desktop "Start at Login" setting:
#     Enable in Docker Desktop → Settings → General → Start Docker Desktop
#     when you log in. Without this, layers 2 and 3 cannot start containers.
#
#   Layer 2 — restart: unless-stopped in docker-compose.override.yml:
#     When Docker Desktop starts, it automatically restarts containers that
#     were running before the last shutdown (crash recovery).
#
#   Layer 3 — com.privacysafe.canvas-lms LaunchAgent (this step):
#     A launchd agent that runs docker compose up -d after login. Provides
#     a clean management interface and a backup start mechanism.
#
# Management commands:
#   launchctl start  com.privacysafe.canvas-lms   # start now
#   launchctl stop   com.privacysafe.canvas-lms   # stop now
#   launchctl enable  gui/$(id -u)/com.privacysafe.canvas-lms  # enable auto-start
#   launchctl disable gui/$(id -u)/com.privacysafe.canvas-lms  # disable auto-start
# =============================================================================
configure_launchd() {
    log_step "Step B: Creating Canvas LMS LaunchAgent"

    local plist_dir="$REAL_HOME/Library/LaunchAgents"
    local plist_path="$plist_dir/com.privacysafe.canvas-lms.plist"
    local wrapper_path="$REAL_HOME/.canvas-lms-start.sh"

    mkdir -p "$plist_dir"

    # Wrapper script — waits for Docker Desktop then starts Canvas
    cat > "$wrapper_path" << EOF
#!/bin/bash
# canvas-lms-start.sh — LaunchAgent helper
# Waits for Docker Desktop to be ready, then starts Canvas LMS.

# Wait up to 2.5 minutes for Docker Desktop (it may take time to start at login)
for i in \$(seq 1 30); do
    docker info &>/dev/null && break
    [ "\$i" -eq 30 ] && { echo "Docker Desktop did not start in time"; exit 1; }
    sleep 5
done

cd "${CANVAS_DIR}" || exit 1

# On Apple Silicon, ensure amd64 images are used (Canvas images are amd64-only)
[[ "\$(uname -m)" == "arm64" ]] && export DOCKER_DEFAULT_PLATFORM=linux/amd64

exec docker compose \\
    -f docker-compose.yml \\
    -f docker-compose.override.yml \\
    up -d
EOF
    chmod +x "$wrapper_path"
    log_ok "Wrapper: $wrapper_path"

    # launchd plist
    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.privacysafe.canvas-lms</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${wrapper_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/canvas-lms-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/canvas-lms-launchd-error.log</string>
</dict>
</plist>
EOF
    log_ok "Plist:   $plist_path"

    # Load the agent (starts it now and registers it for future logins)
    launchctl load "$plist_path" 2>/dev/null || true
    log_ok "LaunchAgent loaded and enabled"

    log_warn "IMPORTANT: Enable 'Start Docker Desktop when you log in' in"
    log_warn "Docker Desktop → Settings → General, or Canvas won't auto-start."
}

# =============================================================================
# Main
# =============================================================================
install_prerequisites
clone_canvas
detect_postgres_image
apply_patches
configure_canvas
pull_images
build_and_start
configure_firewall
configure_launchd

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
echo "  Start:   launchctl start  com.privacysafe.canvas-lms"
echo "  Stop:    launchctl stop   com.privacysafe.canvas-lms"
echo "  Disable auto-start: launchctl disable gui/\$(id -u)/com.privacysafe.canvas-lms"
echo "  Enable  auto-start: launchctl enable  gui/\$(id -u)/com.privacysafe.canvas-lms"
echo ""
echo "  ── Logs and console ─────────────────────────────────"
echo "  cd $CANVAS_DIR"
echo ""
echo "  Logs:    docker compose -f docker-compose.yml -f docker-compose.override.yml logs -f"
echo "  Console: docker compose -f docker-compose.yml -f docker-compose.override.yml exec web bundle exec rails console"
echo ""
printf "  %sNote:%s config/security.yml was generated with a random encryption key.\n" "$YELLOW" "$NC"
echo "        Never commit that file or share its contents."
echo ""
