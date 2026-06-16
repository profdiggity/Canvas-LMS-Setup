# SPDX-FileCopyrightText: 2026 PrivacySafe Foundation Inc.
# SPDX-License-Identifier: MIT
#
# canvas-setup-windows.ps1 — Canvas LMS local development installer for Windows
#
# Part of the Canvas LMS Setup Toolkit by PrivacySafe Foundation Inc.
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
      This script is copyright 2026 PrivacySafe Foundation Inc., MIT License.
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

        # --- Start web and jobs -----------------------------------------------
        Write-Step "Step 8: Starting web and jobs containers"
        Invoke-Compose up -d web jobs
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to start web/jobs" }

        $webWaited = 0
        while ($webWaited -lt 120) {
            Invoke-Compose exec -T web echo "ok" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep 4; $webWaited += 4
            Write-Info "  ${webWaited}s..."
        }
        if ($webWaited -ge 120) { Write-Fail "Web container never became ready. Check: docker compose logs web" }
        Write-Ok "Web container ready"

        # --- Install bundler-multilock once in the running container ----------
        # Canvas requires this Bundler plugin. exec reuses the same running
        # container filesystem — the plugin installed here persists for all
        # subsequent exec calls without reinstalling.
        Write-Info "Installing bundler-multilock plugin..."
        Invoke-Compose exec -T web bundle plugin install bundler-multilock 2>&1 | Out-Null

        # --- Install Ruby gems and frontend assets ----------------------------
        Write-Step "Step 9: Installing Ruby gems and frontend assets  (slow)"
        Invoke-Compose exec -T web ./script/install_assets.sh
        if ($LASTEXITCODE -ne 0) { Write-Fail "install_assets.sh failed — check output above" }
        Write-Ok "Assets installed"

        # --- Database setup ---------------------------------------------------
        Write-Step "Step 10: Creating and seeding the database"
        Invoke-Compose exec -T web bash -c "RAILS_ENV=development bundle exec rake db:create db:initial_setup"
        if ($LASTEXITCODE -ne 0) { Write-Fail "Database setup failed — check output above" }
        Write-Ok "Database created and seeded"

        Invoke-Compose exec -T web bash -c "RAILS_ENV=test bundle exec rake db:migrate" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Test DB migration skipped (non-fatal for normal use)"
        }

        # --- Restart web and jobs ---------------------------------------------
        # Passenger starts before the DB is seeded. Restarting ensures it picks
        # up the fully seeded database and compiled assets from the start.
        Write-Step "Step 11: Restarting web services"
        Invoke-Compose restart web jobs
        if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to restart web/jobs" }
        Write-Ok "web and jobs restarted"

        # --- Wait for Passenger to signal ready -------------------------------
        # Passenger logs "Passenger core online" the instant it has bound its
        # socket. We stream the container logs in a background job and check
        # each line as it arrives — no polling, responds the moment it's ready.
        # --tail 0 ensures we only see lines from after the restart.
        Write-Step "Waiting for Passenger to come online..."
        $passengerReady = $false
        $canvasDir = $CANVAS_DIR   # capture for use inside the job scope

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
                if ($line -match "Passenger core online") {
                    $passengerReady = $true; break
                }
            }
        }
        Stop-Job  $logJob -ErrorAction SilentlyContinue
        Remove-Job $logJob -ErrorAction SilentlyContinue

        if ($passengerReady) {
            Write-Ok "Canvas is live at http://localhost:$Port"
        } else {
            Write-Warn "Passenger did not signal ready within 3 minutes."
            Write-Warn "Canvas may still be starting — check: docker compose logs web"
            Write-Warn "Then try: http://localhost:$Port"
        }

    } finally {
        Pop-Location
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
Write-Host "  Useful commands (run from $CANVAS_DIR):" -ForegroundColor White
Write-Host ""
Write-Host "  Logs:    docker compose -f docker-compose.yml -f docker-compose.override.yml logs -f"
Write-Host "  Stop:    docker compose -f docker-compose.yml -f docker-compose.override.yml down"
Write-Host "  Start:   docker compose -f docker-compose.yml -f docker-compose.override.yml up -d"
Write-Host "  Console: docker compose -f docker-compose.yml -f docker-compose.override.yml exec web bundle exec rails console"
Write-Host ""
Write-Host "  Note: config/security.yml was generated with a random encryption key." -ForegroundColor Yellow
Write-Host "        Never commit that file or share its contents."                   -ForegroundColor Yellow
Write-Host ""
