#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a local WordPress instance from a production backup using Docker.

.DESCRIPTION
    This script:
    1. Copies backup files to working directories (never modifies the Backup/ folder)
    2. Patches wp-config.php for the local Docker environment
    3. Starts Docker containers (MariaDB, WordPress, phpMyAdmin)
    4. Waits for the database import to complete

.PARAMETER Force
    If specified, removes existing working copies and recreates them from backup.

.PARAMETER SkipDocker
    If specified, only copies and patches files without starting Docker.

.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -Force
    .\setup.ps1 -SkipDocker
#>

param(
    [switch]$Force,
    [switch]$SkipDocker
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ─────────────────────────────────────────────
# Load .env file
# ─────────────────────────────────────────────
$EnvFile = Join-Path $ScriptDir ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found at $EnvFile"
    exit 1
}

$EnvVars = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $EnvVars[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

$DbName = $EnvVars["DB_NAME"]
$DbUser = $EnvVars["DB_USER"]
$DbPassword = $EnvVars["DB_PASSWORD"]
$WpPort = $EnvVars["WORDPRESS_PORT"]
$PmaPort = $EnvVars["PHPMYADMIN_PORT"]

Write-Host ""
Write-Host "=== WordPress Local Setup ===" -ForegroundColor Cyan
Write-Host ""

# ─────────────────────────────────────────────
# Step 1: Pre-flight checks
# ─────────────────────────────────────────────
Write-Host "[1/6] Pre-flight checks..." -ForegroundColor Yellow

# Check Docker
try {
    $dockerVersion = docker version --format "{{.Server.Version}}" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker not responding" }
    Write-Host "  Docker: OK (v$dockerVersion)" -ForegroundColor Green
}
catch {
    Write-Error "Docker is not running or not installed. Please start Docker Desktop and try again."
    exit 1
}

# Check backup directory
$BackupDir = Join-Path $ScriptDir "Backup"
$BackupWpDir = Join-Path $BackupDir "wordpress"
$BackupDbDir = Join-Path $BackupDir "database"
$BackupDbFile = Join-Path $BackupDbDir "database"

if (-not (Test-Path $BackupWpDir)) {
    Write-Error "Backup WordPress directory not found at: $BackupWpDir"
    exit 1
}
Write-Host "  Backup/wordpress/: OK" -ForegroundColor Green

if (-not (Test-Path $BackupDbFile)) {
    Write-Error "Backup database file not found at: $BackupDbFile"
    exit 1
}
$dbFileSize = (Get-Item $BackupDbFile).Length / 1MB
Write-Host "  Backup/database/database: OK ($([math]::Round($dbFileSize, 0)) MB)" -ForegroundColor Green

# ─────────────────────────────────────────────
# Step 2: Copy backup files
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[2/6] Copying backup files..." -ForegroundColor Yellow

$WorkingWpDir = Join-Path $ScriptDir "wordpress"
$WorkingDbDir = Join-Path $ScriptDir "database"

# Handle WordPress directory
if (Test-Path $WorkingWpDir) {
    if ($Force) {
        Write-Host "  Removing existing wordpress/ directory (-Force)..." -ForegroundColor DarkYellow
        Remove-Item -Path $WorkingWpDir -Recurse -Force
    }
    else {
        Write-Host "  wordpress/ already exists, skipping copy. Use -Force to overwrite." -ForegroundColor DarkYellow
    }
}

if (-not (Test-Path $WorkingWpDir)) {
    Write-Host "  Copying Backup/wordpress/ -> wordpress/ ..." -ForegroundColor White
    Write-Host "  (This may take a while for large uploads)" -ForegroundColor DarkGray

    # Use robocopy for better performance with large directory trees
    # /E = copy subdirectories including empty ones
    # /NFL /NDL /NJH /NJS = suppress file/dir/header/summary logging (less noise)
    # /MT:8 = multi-threaded copy with 8 threads
    $robocopyArgs = @($BackupWpDir, $WorkingWpDir, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/MT:8")
    & robocopy @robocopyArgs | Out-Null

    # Robocopy exit codes: 0-7 are success, 8+ are errors
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed with exit code $LASTEXITCODE"
        exit 1
    }

    Write-Host "  wordpress/ copy complete." -ForegroundColor Green
}

# Handle database directory
if (Test-Path $WorkingDbDir) {
    if ($Force) {
        Write-Host "  Removing existing database/ directory (-Force)..." -ForegroundColor DarkYellow
        Remove-Item -Path $WorkingDbDir -Recurse -Force
    }
    else {
        Write-Host "  database/ already exists, skipping copy. Use -Force to overwrite." -ForegroundColor DarkYellow
    }
}

if (-not (Test-Path $WorkingDbDir)) {
    Write-Host "  Copying Backup/database/ -> database/ ..." -ForegroundColor White

    New-Item -ItemType Directory -Path $WorkingDbDir -Force | Out-Null

    # The SQL file has no extension. MariaDB's docker-entrypoint-initdb.d requires
    # .sql extension to auto-import, so we copy it with the correct extension.
    # We also prepend a USE statement since the dump doesn't specify a database.
    $importSqlPath = Join-Path $WorkingDbDir "import.sql"
    
    # Write the USE statement first, then append the original SQL dump
    $useStatement = "-- Auto-generated by setup.ps1`nUSE ``$DbName``;`n`n"
    Set-Content -Path $importSqlPath -Value $useStatement -NoNewline
    
    # Append the original SQL dump (using raw bytes for performance with large files)
    $sourceStream = [System.IO.File]::OpenRead($BackupDbFile)
    $destStream = [System.IO.File]::Open($importSqlPath, [System.IO.FileMode]::Append)
    try {
        $sourceStream.CopyTo($destStream)
    } finally {
        $sourceStream.Close()
        $destStream.Close()
    }

    Write-Host "  database/ copy complete (with USE $DbName prepended)." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 3: Patch wp-config.php for local Docker
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3/6] Patching wp-config.php for local environment..." -ForegroundColor Yellow

$WpConfigPath = Join-Path $WorkingWpDir "wp-config.php"

if (-not (Test-Path $WpConfigPath)) {
    Write-Error "wp-config.php not found at: $WpConfigPath (was the copy successful?)"
    exit 1
}

$config = Get-Content $WpConfigPath -Raw

# Track what we change
$changes = @()

# --- DB_HOST: localhost -> db (Docker service name) ---
$original = "define('DB_HOST', 'localhost');"
$replacement = "define('DB_HOST', 'db'); // Patched for Docker: was 'localhost'"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_HOST: localhost -> db"
}

# --- DB_NAME ---
$original = "define('DB_NAME', 'ndshewxtpp');"
$replacement = "define('DB_NAME', '$DbName'); // Patched for Docker: was 'ndshewxtpp'"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_NAME: ndshewxtpp -> $DbName"
}

# --- DB_USER ---
$original = "define('DB_USER', 'ndshewxtpp');"
$replacement = "define('DB_USER', '$DbUser'); // Patched for Docker: was 'ndshewxtpp'"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_USER: ndshewxtpp -> $DbUser"
}

# --- DB_PASSWORD ---
$original = "define('DB_PASSWORD', 'taT8QhbkZe');"
$replacement = "define('DB_PASSWORD', '$DbPassword'); // Patched for Docker: was production password"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_PASSWORD: <redacted> -> $DbPassword"
}

# --- FORCE_SSL_ADMIN: true -> false (no SSL locally) ---
$original = "define('FORCE_SSL_ADMIN', true);"
$replacement = "define('FORCE_SSL_ADMIN', false); // Patched for Docker: was true"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "FORCE_SSL_ADMIN: true -> false"
}

# --- WP_CACHE: true -> false (no caching locally) ---
$original = "define( 'WP_CACHE', true );"
$replacement = "define( 'WP_CACHE', false ); // Patched for Docker: was true"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "WP_CACHE: true -> false"
}

# --- WP_REDIS_DISABLED: false -> true ---
$original = "define( 'WP_REDIS_DISABLED', false );"
$replacement = "define( 'WP_REDIS_DISABLED', true ); // Patched for Docker: was false"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "WP_REDIS_DISABLED: false -> true"
}

# Write patched config
Set-Content -Path $WpConfigPath -Value $config -NoNewline

foreach ($change in $changes) {
    Write-Host "  $change" -ForegroundColor Green
}

if ($changes.Count -eq 0) {
    Write-Host "  No changes needed (already patched?)" -ForegroundColor DarkYellow
}

# --- Remove caching drop-ins that reference production paths ---
$filesToRemove = @(
    (Join-Path $WorkingWpDir "wp-content\advanced-cache.php"),
    (Join-Path $WorkingWpDir "wp-content\object-cache.php")
)

foreach ($file in $filesToRemove) {
    if (Test-Path $file) {
        Remove-Item $file -Force
        $fileName = Split-Path $file -Leaf
        Write-Host "  Removed wp-content/$fileName (production caching drop-in)" -ForegroundColor Green
    }
}

# ─────────────────────────────────────────────
# Step 4: Start Docker containers
# ─────────────────────────────────────────────
if ($SkipDocker) {
    Write-Host ""
    Write-Host "[4/6] Skipping Docker start (-SkipDocker)" -ForegroundColor DarkYellow
    Write-Host "[5/6] Skipping health check (-SkipDocker)" -ForegroundColor DarkYellow
    Write-Host "[6/6] Skipping URL replacement (-SkipDocker)" -ForegroundColor DarkYellow
}
else {
    Write-Host ""
    Write-Host "[4/6] Starting Docker containers..." -ForegroundColor Yellow

    Push-Location $ScriptDir
    try {
        docker compose up -d 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker compose up failed"
            exit 1
        }
        Write-Host "  Containers started." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    # ─────────────────────────────────────────────
    # Step 5: Wait for database to be ready
    # ─────────────────────────────────────────────
    Write-Host ""
    Write-Host "[5/6] Waiting for database import to complete..." -ForegroundColor Yellow
    Write-Host "  The $([math]::Round($dbFileSize, 0)) MB SQL dump may take several minutes to import." -ForegroundColor DarkGray
    Write-Host "  You can monitor progress with: docker compose logs -f db" -ForegroundColor DarkGray
    Write-Host ""

    $maxAttempts = 120  # 120 * 10s = 20 minutes max wait
    $attempt = 0
    $ready = $false

    while (-not $ready -and $attempt -lt $maxAttempts) {
        $attempt++
        try {
            $result = docker compose exec -T db mariadb -u"$DbUser" -p"$DbPassword" -e "SELECT 1;" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ready = $true
            }
            else {
                Write-Host "  Attempt $attempt/$maxAttempts - DB not ready yet, waiting 10s..." -ForegroundColor DarkGray
                Start-Sleep -Seconds 10
            }
        }
        catch {
            Write-Host "  Attempt $attempt/$maxAttempts - DB not ready yet, waiting 10s..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 10
        }
    }

    if (-not $ready) {
        Write-Host ""
        Write-Host "  WARNING: Database did not become ready within 20 minutes." -ForegroundColor Red
        Write-Host "  The import may still be running. Check with:" -ForegroundColor Red
        Write-Host "    docker compose logs -f db" -ForegroundColor White
        Write-Host ""
    } else {
        # ─────────────────────────────────────────────
        # Step 6: Install WP-CLI and replace URLs
        # ─────────────────────────────────────────────
        Write-Host ""
        Write-Host "[6/6] Replacing production URLs with localhost..." -ForegroundColor Yellow
        
        $productionUrl = "https://waikatotainui.com"
        $localUrl = "http://localhost:$WpPort"
        
        # Install WP-CLI if not present, then run search-replace
        $wpCliScript = @"
if ! command -v wp &> /dev/null; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi
wp --allow-root search-replace '$productionUrl' '$localUrl' --all-tables --report-changed-only
"@
        
        docker compose exec -T wordpress bash -c $wpCliScript 2>&1 | ForEach-Object { 
            Write-Host "  $_" -ForegroundColor DarkGray 
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  URL replacement complete: $productionUrl -> $localUrl" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: URL replacement may have failed. Check output above." -ForegroundColor Yellow
        }
    }
}

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  WordPress:  http://localhost:$WpPort" -ForegroundColor White
Write-Host "  phpMyAdmin: http://localhost:$PmaPort" -ForegroundColor White
Write-Host ""
Write-Host "  DB Name:     $DbName" -ForegroundColor DarkGray
Write-Host "  DB User:     $DbUser" -ForegroundColor DarkGray
Write-Host "  DB Password: $DbPassword" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "    docker compose logs -f db          # Watch DB import progress" -ForegroundColor DarkGray
Write-Host "    docker compose logs -f wordpress   # Watch WordPress logs" -ForegroundColor DarkGray
Write-Host "    docker compose down                # Stop containers" -ForegroundColor DarkGray
Write-Host "    docker compose down -v             # Stop and remove DB volume (full reset)" -ForegroundColor DarkGray
Write-Host "    .\setup.ps1 -Force                 # Re-copy from backup and re-patch" -ForegroundColor DarkGray
Write-Host ""
