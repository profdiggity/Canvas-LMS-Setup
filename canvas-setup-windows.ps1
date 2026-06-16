# SPDX-FileCopyrightText: 2026 PrivacySafe Foundation, Inc.
# SPDX-License-Identifier: MIT
#
# canvas-setup-windows.ps1 — Canvas LMS local development installer for Windows
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

<#
.SYNOPSIS
    Canvas LMS local development setup for Windows.

.DESCRIPTION
    Installs and configures a local Canvas LMS instance using Docker Desktop.
    Handles prerequisite checking, cloning, config file generation, and
    database seeding automatically.

    Run this script from an ELEVATED (Administrator) PowerShell prompt,
    or at minimum ensure your user has permission to run Docker commands.

    If you see "running scripts is disabled", run PowerShell as Administrator
    and execute: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

.PARAMETER InstallPath
    Full path where Canvas LMS will be cloned.
    Use a path you own (e.g. C:\canvas-lms or D:\dev\canvas-lms).
    Do not use a path with spaces if you can avoid it.

.PARAMETER Port
    Host port for the Canvas web interface (default: 3000).

.PARAMETER UseMirror
    Use Gitee (code) and a Docker mirror (images) for restricted networks.

.EXAMPLE
    .\canvas-setup-windows.ps1 -InstallPath C:\canvas-lms

.EXAMPLE
    .\canvas-setup-windows.ps1 -InstallPath D:\dev\canvas-lms -Port 8080

.NOTES
    Requirements:
      - Windows 10 (build 19041+) or Windows 11
      - WSL2 enabled (required by Docker Desktop)
      - Docker Desktop 4.x or later, running with WSL2 backend
      - Git for Windows
      - 8 GB+ RAM, 25 GB+ free disk
      - Internet connection

    PLACEHOLDER CREDENTIALS:
      All passwords and keys in this script are placeholders for local dev.
      Do not expose this setup to the internet without changing credentials.
      config/security.yml (generated encryption key) must never be committed.

    COPYRIGHT / LICENSE:
      This script is copyright 2026 PrivacySafe Foundation, Inc., MIT License.
      Canvas LMS is copyright Instructure, Inc., AGPL-3.0 License.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$InstallPath,

    [int]$Port = 3000,

    [switch]$UseMirror
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# =============================================================================
# Configuration
# =============================================================================
$CANVAS_REPO  = "https://github.com/instructure/canvas-lms.git"
$CANVAS_MIRROR = "https://gitee.com/xiong-yuhui/canvas-Lms.git"
$DOCKER_MIRROR = "docker.1ms.run"

$RUBY_IMAGE    = "instructure/ruby-passenger:2.7"
$POSTGIS_IMAGE = "postgis/postgis:14-3.3"   # fallback; overridden after clone
$REDIS_IMAGE   = "redis:alpine"

$CANVAS_DIR = $InstallPath

# =============================================================================
# Logging helpers
# =============================================================================
function Write-Step { param([string]$Msg)
    Write-Host ""
    Write-Host "==> $Msg" -ForegroundColor Cyan
}
function Write-Ok   { param([string]$Msg) Write-Host "  [OK]   $Msg" -ForegroundColor Green  }
function Write-Warn { param([string]$Msg) Write-Host "  [WARN] $Msg" -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host "  -->    $Msg" -ForegroundColor Gray   }
function Write-Fail { param([string]$Msg)
    Write-Host ""
    Write-Host "  [ERROR] $Msg" -ForegroundColor Red
    exit 1
}

# Run a docker compose command against our two compose files.
# Usage: Invoke-Compose exec -T postgres pg_isready -U postgres
function Invoke-Compose {
    & docker compose -f docker-compose.yml -f docker-compose.override.yml @args
}

# Write a UTF-8 file with Unix (LF) line endings.
# Config files are read inside Linux containers — CRLF causes parse errors.
function Write-UnixFile {
    param([string]$Path, [string]$Content)
    $utf8NoBom  = New-Object System.Text.UTF8Encoding $false
    $unixContent = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $unixContent, $utf8NoBom)
}

# =============================================================================
# Banner
# =============================================================================
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Magenta
Write-Host "  Canvas LMS - Windows Local Development Setup"        -ForegroundColor Magenta
Write-Host "=====================================================" -ForegroundColor Magenta
Write-Host ""
Write-Info "Target:  $CANVAS_DIR"
Write-Info "Port:    $Port"
Write-Info "Mirror:  $UseMirror"

# =============================================================================
# STEP 1 - Prerequisites
# =============================================================================
function Install-Prerequisites {
    Write-Step "Step 1: Checking prerequisites"

    # Windows version
    $osVer = [System.Environment]::OSVersion.Version
    if ($osVer.Major -lt 10 -or ($osVer.Major -eq 10 -and $osVer.Build -lt 19041)) {
        Write-Warn "Windows build $($osVer.Build) detected. Build 19041 (20H1) or later recommended for WSL2."
    } else {
        Write-Ok "Windows build $($osVer.Build)"
    }

    # RAM check
    $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $ramGB = [math]::Floor($ram / 1GB)
    if ($ramGB -lt 8) {
        Write-Warn "Only ${ramGB} GB RAM detected. 8 GB+ recommended."
        Write-Info "Also ensure Docker Desktop has at least 4 GB allocated:"
        Write-Info "  Docker Desktop -> Settings -> Resources -> Memory"
    } else {
        Write-Ok "RAM: ${ramGB} GB"
    }

    # Disk space
    try {
        $checkPath = if (Test-Path $InstallPath) { $InstallPath } else { Split-Path $InstallPath -Parent }
        if (-not $checkPath -or -not (Test-Path $checkPath)) { $checkPath = "C:\" }
        $drive = Split-Path -Qualifier $checkPath
        $disk  = Get-PSDrive ($drive -replace ':','') -ErrorAction SilentlyContinue
        if ($disk) {
            $freeGB = [math]::Floor($disk.Free / 1GB)
            if ($freeGB -lt 25) {
                Write-Warn "Only ${freeGB} GB free on $drive — Canvas build needs ~25 GB"
            } else {
                Write-Ok "Free disk: ${freeGB} GB"
            }
        }
    } catch { Write-Warn "Could not check disk space — ensure you have 25 GB+ free" }

    # -----------------------------------------------------------------------
    # Git
    # -----------------------------------------------------------------------
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Info "Git not found — attempting to install via winget..."
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Git.Git -e --source winget --silent 2>&1 | Out-Null
            # Refresh PATH so git is found in this session
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("Path","User")
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Fail ("Git is not installed and auto-install failed.`n" +
                        "  Download from: https://git-scm.com/download/win`n" +
                        "  Then re-run this script.")
        }
    }
    Write-Ok "Git: $(git --version)"

    # -----------------------------------------------------------------------
    # Docker Desktop
    # -----------------------------------------------------------------------
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Fail ("Docker Desktop is not installed.`n" +
                    "  Download from: https://www.docker.com/products/docker-desktop/`n" +
                    "  Enable the WSL2 backend during setup, then re-run this script.")
    }

    # Docker Desktop might be installed but not running
    $dockerRunning = $false
    try {
        docker info 2>&1 | Out-Null
        $dockerRunning = ($LASTEXITCODE -eq 0)
    } catch { }

    if (-not $dockerRunning) {
        Write-Info "Docker Desktop is not running — attempting to start it..."
        $dockerExe = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $dockerExe) {
            Start-Process $dockerExe
        } else {
            Write-Fail ("Docker Desktop is installed but the executable was not found at the default path.`n" +
                        "  Please start Docker Desktop manually, wait for 'Engine running', then re-run.")
        }

        Write-Info "Waiting up to 90 seconds for Docker Desktop to start..."
        $waited = 0
        while ($waited -lt 90) {
            Start-Sleep 4; $waited += 4
            Write-Info "  ${waited}s..."
            try {
                docker info 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $dockerRunning = $true; break }
            } catch { }
        }

        if (-not $dockerRunning) {
            Write-Fail ("Docker Desktop did not start within 90 seconds.`n" +
                        "  Start it manually, wait for 'Engine running', then re-run this script.")
        }
    }

    # Verify compose and buildx are present (ship with Docker Desktop 4.x+)
    docker compose version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Docker Compose not found. Update Docker Desktop to version 4.x or later."
    }

    Write-Ok "Docker:         $(docker --version)"
    Write-Ok "Docker Compose: $(docker compose version)"
    Write-Ok "Docker daemon:  running"
}

# =============================================================================
# STEP 2 - Clone Canvas LMS
# =============================================================================
function Copy-CanvasSource {
    Write-Step "Step 2: Cloning Canvas LMS"

    if (Test-Path (Join-Path $CANVAS_DIR ".git")) {
        Write-Warn "Repository already exists at $CANVAS_DIR — skipping clone"
        return
    }

    if (Test-Path $CANVAS_DIR) {
        Write-Fail "$CANVAS_DIR exists but is not a git repo. Remove it and re-run."
    }

    New-Item -Path $CANVAS_DIR -ItemType Directory -Force | Out-Null

    $repo = if ($UseMirror) { $CANVAS_MIRROR } else { $CANVAS_REPO }
    Write-Info "Cloning from: $repo"

    git clone $repo $CANVAS_DIR
    if ($LASTEXITCODE -ne 0) {
        $hint = if (-not $UseMirror) { " Try again with -UseMirror if GitHub is slow." } else { "" }
        Write-Fail "Clone failed.$hint"
    }
    Write-Ok "Canvas LMS cloned"
}

# =============================================================================
# STEP 2b - Detect the correct postgres image from Canvas's own Dockerfile
# =============================================================================
function Get-PostgresImage {
    $pgDf   = Join-Path $CANVAS_DIR "docker-compose\postgres\Dockerfile"
    $dcYml  = Join-Path $CANVAS_DIR "docker-compose.yml"
    $fallback = "postgis/postgis:14-3.3"

    if (-not (Test-Path $pgDf)) {
        Write-Warn "postgres Dockerfile not found — defaulting to postgis:14-3.3"
        return $fallback
    }

    $dfText = Get-Content $pgDf -Raw

    # Collect ARG defaults from Dockerfile
    $argDefaults = @{}
    foreach ($m in [regex]::Matches($dfText, '(?m)^ARG\s+(\w+)(?:=(\S+))?')) {
        $name    = $m.Groups[1].Value
        $default = $m.Groups[2].Value
        if ($default) { $argDefaults[$name] = $default }
    }

    # Also collect build args from the postgres service in docker-compose.yml
    if (Test-Path $dcYml) {
        $dcText = Get-Content $dcYml -Raw
        $inPostgres = $false; $inArgs = $false
        foreach ($line in ($dcText -split "`n")) {
            $s = $line.Trim()
            if ($s -match '^postgres\s*:')        { $inPostgres = $true;  $inArgs = $false }
            elseif ($inPostgres -and $s -match '^\w' -and $s -notmatch '^postgres') { $inPostgres = $false; $inArgs = $false }
            elseif ($inPostgres -and $s -eq 'args:') { $inArgs = $true }
            elseif ($inArgs) {
                if ($s -match '^[-\s]*(\w+)\s*[=:]\s*(\S+)') {
                    $argDefaults[$Matches[1]] = $Matches[2].Trim('"''')
                } elseif ($s -and $s -notmatch '^-') { $inArgs = $false }
            }
        }
    }

    # Extract FROM line
    $fromMatch = [regex]::Match($dfText, '(?m)^FROM\s+(\S+)')
    if (-not $fromMatch.Success) {
        Write-Warn "Could not read FROM line — defaulting to postgis:14-3.3"
        return $fallback
    }

    # Resolve any $VAR or ${VAR} references using collected ARG defaults
    $fromVal  = $fromMatch.Groups[1].Value
    $resolved = [regex]::Replace($fromVal, '\$\{?(\w+)\}?', {
        param($m)
        $v = $m.Groups[1].Value
        if ($argDefaults.ContainsKey($v)) { $argDefaults[$v] } else { "" }
    })

    if ($resolved -notmatch '\$' -and ($resolved -match '/' -or $resolved -match ':')) {
        Write-Info "Canvas postgres image resolved: $resolved"
        return $resolved.Trim()
    }

    Write-Warn "Could not resolve postgres image from Dockerfile — defaulting to postgis:14-3.3"
    return $fallback
}

# =============================================================================
# STEP 3 - Patch Dockerfiles
#
# These patches fix issues inside Canvas's Docker images unrelated to Windows:
#
# (a) Main Dockerfile: uses legacy apt-key and unsigned apt repo lines that
#     fail in modern Docker builds. Fix: add [trusted=yes], neutralise apt-key.
#
# (b) PostGIS Dockerfile: may be based on an EOL Debian release whose apt
#     sources no longer resolve. Fix: redirect to archive.debian.org.
# =============================================================================
function Update-Dockerfiles {
    Write-Step "Step 3: Patching Dockerfiles"

    # --- Main Canvas Dockerfile -----------------------------------------------
    $mainDf = Join-Path $CANVAS_DIR "Dockerfile"
    if (Test-Path $mainDf) {
        $text = Get-Content $mainDf -Raw
        $orig = $text

        $text = $text -replace 'echo "deb https://deb\.nodesource\.com',
                                'echo "deb [trusted=yes] https://deb.nodesource.com'
        $text = $text -replace 'echo "deb http://apt\.postgresql\.org',
                                'echo "deb [trusted=yes] http://apt.postgresql.org'
        $text = $text -replace 'apt-key add - && apt-get update -qq && apt-get install',
                                'apt-key add - 2>/dev/null || true && (apt-get update -qq || true) && apt-get install'
        # Remove keyserver fetches — they time out or fail in modern environments
        $text = [regex]::Replace($text,
            'apt-key adv --keyserver\s+\S+\s+--recv-keys\s+\S+[^\n]*\n',
            "# apt-key adv removed -- [trusted=yes] used instead`n")

        if ($text -ne $orig) {
            Write-UnixFile $mainDf $text
            Write-Ok "Main Dockerfile patched"
        } else {
            Write-Ok "Main Dockerfile already up to date"
        }
    } else {
        Write-Warn "Main Dockerfile not found — skipping"
    }

    # --- PostGIS Dockerfile ---------------------------------------------------
    $pgDf = Join-Path $CANVAS_DIR "docker-compose\postgres\Dockerfile"
    if (Test-Path $pgDf) {
        $text = Get-Content $pgDf -Raw

        if ($text -match "archive\.debian\.org" -and $text -match "99no-check-valid-until") {
            Write-Ok "PostGIS Dockerfile already patched"
        } else {
            # Remove any previous incomplete patch
            $text = [regex]::Replace($text, 'RUN\s+sed\s+-i.*?archive\.debian\.org.*?\n', '', 'Singleline')

            $archiveBlock = @'

RUN set -eux; \
    mkdir -p /etc/apt/apt.conf.d; \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    for f in /etc/apt/sources.list \
              /etc/apt/sources.list.d/*.list \
              /etc/apt/sources.list.d/*.sources; do \
        [ -e "$f" ] || continue; \
        sed -i \
            -e "s|http://deb.debian.org/debian|http://archive.debian.org/debian|g" \
            -e "s|https://deb.debian.org/debian|http://archive.debian.org/debian|g" \
            -e "s|http://security.debian.org/debian-security|http://archive.debian.org/debian-security|g" \
            -e "s|https://security.debian.org/debian-security|http://archive.debian.org/debian-security|g" \
            -e "/buster-updates/d" \
            -e "/bullseye-updates/d" \
            -e "/bookworm-updates/d" \
            "$f" 2>/dev/null || true; \
    done

'@
            # Insert after the first FROM line
            $text = [regex]::Replace($text, '(?m)(^FROM[^\n]*\n)', "`$1$archiveBlock")
            Write-UnixFile $pgDf $text
            Write-Ok "PostGIS Dockerfile patched"
        }
    } else {
        Write-Warn "PostGIS Dockerfile not found — skipping"
    }
}

# =============================================================================
# STEP 4 - Write Canvas config files
#
# PLACEHOLDER CREDENTIALS — local dev only.
# DO NOT expose to the internet without changing these values.
# config/*.yml is in Canvas's .gitignore and will not be committed.
# =============================================================================
function Set-CanvasConfig {
    Write-Step "Step 4: Writing Canvas config files"

    $configDir   = Join-Path $CANVAS_DIR "config"
    $exampleDir  = Join-Path $CANVAS_DIR "docker-compose\config"

    # Copy Canvas's bundled example configs first — they have correct boilerplate.
    # We then overwrite only what we need to customise.
    if (Test-Path $exampleDir) {
        Write-Info "Copying example configs from docker-compose/config/"
        Get-ChildItem "$exampleDir\*.yml" | ForEach-Object {
            Copy-Item $_.FullName $configDir -Force
        }
        Write-Ok "Example configs copied"
    } else {
        Write-Warn "docker-compose/config/ not found — writing configs from scratch"
    }

    if (-not (Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }

    # PLACEHOLDER: encryption key generated fresh on each install using
    # a cryptographic RNG. Never hardcoded, never stored in source control.
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(32)
    $rng.GetBytes($bytes)
    $encKey = ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join ''

    # PLACEHOLDER DB password — matches Canvas's postgres image init script.
    $dbPass    = "sekret"
    # PLACEHOLDER admin credentials — used for first-run seeding only.
    $adminEmail = "admin@canvas.local"
    $adminPass  = "ChangeMe_AfterSetup_1!"

    # database.yml
    Write-UnixFile (Join-Path $configDir "database.yml") @"
# PLACEHOLDER: local dev only. Change password if exposing postgres.
development:
  adapter: postgresql
  encoding: utf8
  database: canvas_development
  host: postgres
  username: canvas
  password: $dbPass
  timeout: 5000
test:
  adapter: postgresql
  encoding: utf8
  database: canvas_test
  host: postgres
  username: canvas
  password: $dbPass
  timeout: 5000
"@
    Write-Ok "config/database.yml"

    # domain.yml
    Write-UnixFile (Join-Path $configDir "domain.yml") @'
development:
  domain: localhost
  ssl: false
test:
  domain: localhost
  ssl: false
'@
    Write-Ok "config/domain.yml"

    # security.yml — only encryption_key is a valid Canvas key here.
    # PLACEHOLDER: randomly generated. Never commit this file.
    Write-UnixFile (Join-Path $configDir "security.yml") @"
# PLACEHOLDER: generated at install time. Never commit or share this value.
development:
  encryption_key: "$encKey"
test:
  encryption_key: "test_$encKey"
"@
    Write-Ok "config/security.yml"

    # outgoing_mail.yml — Canvas requires this file to boot without errors.
    # PLACEHOLDER: localhost:25 is a no-op; no mail is actually delivered.
    $mailFile = Join-Path $configDir "outgoing_mail.yml"
    if (-not (Test-Path $mailFile)) {
        Write-UnixFile $mailFile @'
# PLACEHOLDER: local dev mail sink. Replace with real SMTP for shared installs.
development:
  address: localhost
  port: 25
  domain: localhost
  outgoing_address: canvas@localhost
  default_name: "Canvas LMS (local dev)"
'@
        Write-Ok "config/outgoing_mail.yml"
    } else {
        Write-Ok "config/outgoing_mail.yml (already exists — not overwritten)"
    }

    # redis.yml — always write to guarantee correct format.
    # Canvas changed 'servers:' to 'url:' in November 2023.
    Write-UnixFile (Join-Path $configDir "redis.yml") @'
development:
  url: redis://redis:6379
test:
  url: redis://redis:6379
'@
    Write-Ok "config/redis.yml"

    # cache_store.yml — use memory_store during setup rake tasks.
    # Canvas loads this during Rails environment init, which happens even for
    # db:create. redis_store causes a connection crash before the DB exists.
    Write-UnixFile (Join-Path $configDir "cache_store.yml") @'
development:
  cache_store: memory_store
test:
  cache_store: memory_store
'@
    Write-Ok "config/cache_store.yml"

    # docker-compose.override.yml — port mapping, env vars, volume mounts.
    # PLACEHOLDER credentials below are local dev only.
    Write-UnixFile (Join-Path $CANVAS_DIR "docker-compose.override.yml") @"
# Generated by canvas-setup-windows.ps1 -- do not commit this file.
# PLACEHOLDER credentials below are for local development only.
services:
  web:
    restart: unless-stopped
    environment:
      RAILS_ENV: development
      DISABLE_SPRING: 1
      # PLACEHOLDER: change these after first login
      CANVAS_LMS_ADMIN_EMAIL: "$adminEmail"
      CANVAS_LMS_ADMIN_PASSWORD: "$adminPass"
      CANVAS_LMS_ACCOUNT_NAME: "Canvas Local Dev"
      CANVAS_LMS_STATS_COLLECTION: opt_out
    ports:
      - "${Port}:80"
    volumes:
      - .:/usr/src/app
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
"@
    Write-Ok "docker-compose.override.yml"

    # Return credentials for the final summary
    return @{ Email = $adminEmail; Password = $adminPass }
}

# =============================================================================
# STEP 5 - Pull base Docker images
# =============================================================================
function Get-DockerImages {
    Write-Step "Step 5: Pulling Docker base images"

    function Pull-And-Tag {
        param([string]$Src, [string]$Dst)
        Write-Info "Pulling: $Src"
        docker pull $Src
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to pull $Src" }
        if ($Src -ne $Dst) {
            docker tag $Src $Dst
        }
        Write-Ok $Dst
    }

    if ($UseMirror) {
        Write-Info "Using Docker mirror: $DOCKER_MIRROR"
        Pull-And-Tag "$DOCKER_MIRROR/$RUBY_IMAGE"          $RUBY_IMAGE
        Pull-And-Tag "$DOCKER_MIRROR/$POSTGIS_IMAGE"       $POSTGIS_IMAGE
        Pull-And-Tag "$DOCKER_MIRROR/library/$REDIS_IMAGE" $REDIS_IMAGE
    } else {
        Pull-And-Tag $RUBY_IMAGE    $RUBY_IMAGE
        Pull-And-Tag $POSTGIS_IMAGE $POSTGIS_IMAGE
        Pull-And-Tag $REDIS_IMAGE   $REDIS_IMAGE
    }
}

# =============================================================================
# STEP 6 - Build images, start services, install assets, seed database
# =============================================================================
function Start-Canvas {
    Push-Location $CANVAS_DIR
    try {

        # --- Build ------------------------------------------------------------
        Write-Step "Step 6: Building Docker images  (first run: 15-30 min)"
        Invoke-Compose build
        if ($LASTEXITCODE -ne 0) { Write-Fail "Docker build failed — check output above" }
        Write-Ok "Build complete"

        # --- Start postgres and redis FIRST -----------------------------------
        # Starting all services at once risks web crashing before postgres is
        # ready. We start the DB and cache layer first, wait for them, then
        # start the app containers.
        Write-Step "Step 7: Starting postgres and redis"
        Invoke-Compose up -d postgres redis
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to start postgres/redis" }
        Write-Ok "postgres and redis started"

        # --- Wait for PostgreSQL ----------------------------------------------
        Write-Step "Waiting for PostgreSQL..."
        $waited = 0
        while ($waited -lt 120) {
            Invoke-Compose exec -T postgres pg_isready -U postgres 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep 3; $waited += 3
            Write-Info "  ${waited}s..."
        }
        if ($waited -ge 120) { Write-Fail "PostgreSQL never started. Check: docker compose logs postgres" }
        Write-Ok "PostgreSQL accepting connections"

        # Canvas's postgres image should create the canvas role via init scripts,
        # but those scripts are unreliable across versions. We create/update the
        # role ourselves — idempotent and safe to run either way.
        Start-Sleep 5
        Write-Info "Ensuring canvas database role exists..."
        Invoke-Compose exec -T postgres psql -U postgres -c @"
DO `$`$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'canvas') THEN
        CREATE ROLE canvas SUPERUSER CREATEDB LOGIN PASSWORD 'sekret';
    ELSE
        ALTER ROLE canvas WITH SUPERUSER CREATEDB LOGIN PASSWORD 'sekret';
    END IF;
END `$`$;
"@
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to create canvas postgres role" }
        Write-Ok "canvas role ready"

        # --- Setup via run --rm (temporary containers) ------------------------
        # We do NOT start the web container yet. All setup tasks run in
        # temporary containers (run --rm) that are destroyed when they finish.
        # The serving web container starts fresh via up -d with no prior state.
        # bundler-multilock is reinstalled per-container since it lives in the
        # container home dir and does not persist across container exits.
        # All setup steps in one container — gems from install_assets.sh
        # (including git-sourced gems like authlogic) remain available for
        # rake tasks. Separate run --rm calls destroy the gem cache on exit.
        Write-Step "Step 8: Installing assets and seeding database  (slow — 15-30 min)"
        Invoke-Compose run --rm --no-deps web bash -c (
            "set -e; " +
            "echo '--- Installing bundler-multilock plugin ---'; " +
            "bundle plugin install bundler-multilock || true; " +
            "echo '--- Installing Ruby gems and frontend assets ---'; " +
            "./script/install_assets.sh; " +
            "echo '--- Creating and seeding the database ---'; " +
            "RAILS_ENV=development bundle exec rake db:create db:initial_setup; " +
            "echo '--- Migrating test database ---'; " +
            "RAILS_ENV=test bundle exec rake db:migrate || true"
        )
        if ($LASTEXITCODE -ne 0) { Write-Fail "Setup failed — check output above" }
        Write-Ok "Assets installed and database seeded"

        # --- Start all services -----------------------------------------------
        # The web container starts here for the FIRST time as a serving
        # container — no stale PID files, no old unix sockets, nothing.
        Write-Step "Step 10: Starting all Canvas services"
        Invoke-Compose up -d
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to start Canvas services" }
        Write-Ok "All services started"

        # --- Wait for Passenger to signal ready -------------------------------
        Write-Step "Waiting for Passenger to come online..."
        $passengerReady = $false
        $canvasDir = $CANVAS_DIR

        $logJob = Start-Job -ScriptBlock {
            Set-Location $using:canvasDir
            & docker compose -f docker-compose.yml -f docker-compose.override.yml `
                logs --follow --tail 0 web 2>&1
        }

        $deadline = [DateTime]::Now.AddSeconds(180)
        while ([DateTime]::Now -lt $deadline -and -not $passengerReady) {
            Start-Sleep -Seconds 1
            $lines = Receive-Job $logJob -ErrorAction SilentlyContinue
            foreach ($line in ($lines -split "`n")) {
                if ($line -match "Passenger core online") { $passengerReady = $true; break }
            }
        }
        Stop-Job  $logJob -ErrorAction SilentlyContinue
        Remove-Job $logJob -ErrorAction SilentlyContinue

        if ($passengerReady) {
            Write-Ok "Passenger online"
        } else {
            Write-Warn "Passenger did not signal ready within 3 minutes."
            Write-Warn "Check: docker compose logs web"
        }

        # --- Verify HTTP is actually reachable --------------------------------
        Write-Step "Verifying HTTP connectivity on port $Port..."
        $httpWaited = 0
        $httpOk = $false
        while ($httpWaited -lt 60) {
            try {
                Invoke-WebRequest -Uri "http://localhost:$Port" `
                    -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop | Out-Null
                $httpOk = $true; break
            } catch { }
            Start-Sleep 3; $httpWaited += 3
            Write-Info "  ${httpWaited}s..."
        }
        if ($httpOk) {
            Write-Ok "Canvas is live at http://localhost:$Port"
        } else {
            Write-Warn "Port $Port not responding after 60s."
            Write-Warn "Check: docker compose -f docker-compose.yml -f docker-compose.override.yml logs --tail 40 web"
        }

    } finally {
        Pop-Location
    }
}


# =============================================================================
# STEP A - Windows Firewall
#
# Docker Desktop on Windows uses WSL2, which handles port forwarding. Windows
# Firewall may block inbound connections on the Canvas port from the network.
# We add an explicit inbound allow rule for the web port.
#
# Postgres (5432) and Redis (6379) are bound to 127.0.0.1 only — never
# exposed externally regardless of firewall settings.
# =============================================================================
function Set-CanvasFirewall {
    Write-Step "Step A: Windows Firewall"

    $ruleName = "Canvas LMS (port $Port)"

    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "Firewall: rule for port $Port already exists"
        return
    }

    try {
        New-NetFirewallRule `
            -DisplayName  $ruleName `
            -Description  "Canvas LMS local development — port $Port" `
            -Direction    Inbound `
            -Protocol     TCP `
            -LocalPort    $Port `
            -Action       Allow `
            -Profile      Private, Domain `
            | Out-Null
        Write-Ok "Windows Firewall: inbound TCP $Port allowed (Private + Domain profiles)"
        Write-Info "Postgres/Redis are bound to 127.0.0.1 — not exposed externally."
    } catch {
        Write-Warn "Could not create firewall rule (may need Administrator): $_"
        Write-Warn "Run manually: New-NetFirewallRule -DisplayName '$ruleName' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow"
    }
}

# =============================================================================
# STEP B - Task Scheduler auto-start task
#
# Windows has no systemd or launchd. We use Task Scheduler to start Canvas
# automatically when the user logs in.
#
# Three-layer persistence on Windows:
#
#   Layer 1 - Docker Desktop starts with Windows:
#     Docker Desktop is configured to start automatically by default.
#     Verify: Docker Desktop -> Settings -> General -> Start Docker Desktop
#     when you log in.
#
#   Layer 2 - restart: unless-stopped in docker-compose.override.yml:
#     When Docker Desktop starts, it automatically restarts containers that
#     were running before the last shutdown (crash recovery).
#
#   Layer 3 - Task Scheduler task (this step):
#     Runs "docker compose up -d" at login as a backup and management tool.
#     docker compose up -d is idempotent — safe to run even if containers
#     are already running from Layer 2.
#
# Management:
#   Start:   Start-ScheduledTask -TaskPath "\PrivacySafe" -TaskName "Canvas LMS"
#   Stop:    Stop-ScheduledTask  -TaskPath "\PrivacySafe" -TaskName "Canvas LMS"
#   Disable: Disable-ScheduledTask -TaskPath "\PrivacySafe" -TaskName "Canvas LMS"
#   Enable:  Enable-ScheduledTask  -TaskPath "\PrivacySafe" -TaskName "Canvas LMS"
#   Or open Task Scheduler and navigate to PrivacySafe\Canvas LMS
# =============================================================================
function Register-CanvasStartupTask {
    Write-Step "Step B: Registering Canvas LMS startup task"

    $taskPath = "\PrivacySafe\"
    $taskName = "Canvas LMS"
    $dockerBin = (Get-Command docker -ErrorAction SilentlyContinue)?.Source
    if (-not $dockerBin) { $dockerBin = "docker" }

    # Create the task folder if it doesn't exist
    try {
        $scheduler = New-Object -ComObject Schedule.Service
        $scheduler.Connect()
        $root = $scheduler.GetFolder("\")
        try { $root.GetFolder("PrivacySafe") | Out-Null }
        catch { $root.CreateFolder("PrivacySafe") | Out-Null }
    } catch { Write-Warn "Could not create Task Scheduler folder (non-fatal)" }

    $action = New-ScheduledTaskAction `
        -Execute         $dockerBin `
        -Argument        "compose -f docker-compose.yml -f docker-compose.override.yml up -d" `
        -WorkingDirectory $CANVAS_DIR

    # Trigger at logon of the current user
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

    # Retry 3 times with 1-minute gaps in case Docker Desktop hasn't started yet
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -RestartCount       3 `
        -RestartInterval    (New-TimeSpan -Minutes 1) `
        -MultipleInstances  IgnoreNew

    try {
        Register-ScheduledTask `
            -TaskPath   $taskPath `
            -TaskName   $taskName `
            -Description "Starts Canvas LMS Docker containers at login" `
            -Action     $action `
            -Trigger    $trigger `
            -Settings   $settings `
            -RunLevel   Highest `
            -Force      | Out-Null

        Write-Ok "Task Scheduler: '\PrivacySafe\Canvas LMS' registered"
        Write-Ok "Canvas will start automatically when you log in"
    } catch {
        Write-Warn "Could not register scheduled task (may need Administrator): $_"
        Write-Warn "Canvas will still auto-start via Docker's restart:unless-stopped policy."
    }
}

# =============================================================================
# Main
# =============================================================================
Install-Prerequisites
Copy-CanvasSource
$POSTGIS_IMAGE = Get-PostgresImage   # override with detected version
Update-Dockerfiles
$creds = Set-CanvasConfig
Get-DockerImages
Start-Canvas
Set-CanvasFirewall
Register-CanvasStartupTask

# =============================================================================
# Done
# =============================================================================
Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  Canvas LMS is ready!"                               -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  URL:      http://localhost:$Port"                   -ForegroundColor Cyan
Write-Host "  Email:    $($creds.Email)"                          -ForegroundColor Cyan
Write-Host "  Password: $($creds.Password)"                       -ForegroundColor Cyan
Write-Host ""
Write-Host "  CHANGE THE PASSWORD after your first login."        -ForegroundColor Yellow
Write-Host ""
Write-Host "  Managing Canvas:" -ForegroundColor White
Write-Host ""
Write-Host "  Start:   Start-ScheduledTask  -TaskPath '\PrivacySafe' -TaskName 'Canvas LMS'"
Write-Host "  Stop:    Stop-ScheduledTask   -TaskPath '\PrivacySafe' -TaskName 'Canvas LMS'"
Write-Host "  Disable auto-start: Disable-ScheduledTask -TaskPath '\PrivacySafe' -TaskName 'Canvas LMS'"
Write-Host "  Enable  auto-start: Enable-ScheduledTask  -TaskPath '\PrivacySafe' -TaskName 'Canvas LMS'"
Write-Host ""
Write-Host "  Logs and console (run from $CANVAS_DIR):" -ForegroundColor White
Write-Host ""
Write-Host "  Logs:    docker compose -f docker-compose.yml -f docker-compose.override.yml logs -f"
Write-Host "  Console: docker compose -f docker-compose.yml -f docker-compose.override.yml exec web bundle exec rails console"
Write-Host ""
Write-Host "  Note: config/security.yml was generated with a random encryption key." -ForegroundColor Yellow
Write-Host "        Never commit that file or share its contents."                   -ForegroundColor Yellow
Write-Host ""
