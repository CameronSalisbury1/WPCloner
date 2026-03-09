#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a local WordPress instance from a production backup using Docker.

.DESCRIPTION
    This script:
    1. Copies wp-content/uploads from Backup/ to uploads/ (the bind-mount source)
    2. Prepares the database import file from Backup/
    3. Patches wp-config.php in memory (read from Backup/, never modifies Backup/)
    4. Starts Docker containers (MySQL, WordPress, phpMyAdmin)
    5. Copies WordPress files from Backup/ directly into the Docker named volume,
       skipping uploads (bind-mounted) and injecting the patched wp-config.php
    6. Waits for the database import to complete
    7. Patches Requests.php timeouts inside the container
    8. Replaces production URLs with localhost
    9. Creates a local admin user and disables 2FA
    10. Disables Gravity Forms notifications (optional)
    11. Redirects webhooks (optional)

    PHP files are served from a named Docker volume (native Linux filesystem speed).
    Only wp-content/uploads is bind-mounted from the Windows host so uploaded media
    remains directly accessible on disk. Backup/ is never modified.

.PARAMETER Force
    Wipes uploads/, database/, and Docker volumes, then recopies everything from Backup/

.PARAMETER ForceDb
    Wipes database/ and the db_data Docker volume, then re-imports the database from Backup/.
    WordPress files in the wp_data volume are left intact.

.PARAMETER ForceFiles
    Wipes the wp_data Docker volume, then recopies WordPress files from Backup/.
    Database is left intact.

.EXAMPLE
    .\setup-docker.ps1

.EXAMPLE
    .\setup-docker.ps1 -Force
    # Wipes everything and starts fresh from Backup/

.EXAMPLE
    .\setup-docker.ps1 -ForceDb
    # Wipes and re-imports the database only (keeps WordPress files)

.EXAMPLE
    .\setup-docker.ps1 -ForceFiles
    # Wipes and recopies WordPress files only (keeps database)
#>

param(
    [switch]$Force,
    [switch]$ForceDb,
    [switch]$ForceFiles
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkingDir = Split-Path -Parent $ScriptDir  # Parent directory (C:\repos\Tainui\WP)
$ComposeProjName = (Split-Path $ScriptDir -Leaf).ToLower()

# Validate mutually exclusive flags
if (($Force -and $ForceDb) -or ($Force -and $ForceFiles) -or ($ForceDb -and $ForceFiles)) {
    Write-Error "-Force, -ForceDb, and -ForceFiles are mutually exclusive. Specify only one."
    exit 1
}

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
$DisableGfNotifications = $EnvVars["DISABLE_GF_NOTIFICATIONS"] -eq "true"
$GfWebhookRedirectHost = $EnvVars["GF_WEBHOOK_REDIRECT_HOST"]
$DisallowFileMods = $EnvVars["DISALLOW_FILE_MODS"] -eq "true"
$LocalAdminUser = $EnvVars["LOCAL_ADMIN_USER"]
$LocalAdminPassword = $EnvVars["LOCAL_ADMIN_PASSWORD"]
$LocalAdminEmail = if ($EnvVars["LOCAL_ADMIN_EMAIL"]) { $EnvVars["LOCAL_ADMIN_EMAIL"] } else { "$LocalAdminUser@localhost.local" }

Write-Host ""
Write-Host "=== WordPress Local Setup ===" -ForegroundColor Cyan
if ($Force) {
    Write-Host "    [FORCE MODE - Will wipe and recopy everything from Backup/]" -ForegroundColor Red
}
elseif ($ForceDb) {
    Write-Host "    [FORCE DB MODE - Will wipe and re-import database only]" -ForegroundColor Red
}
elseif ($ForceFiles) {
    Write-Host "    [FORCE FILES MODE - Will wipe and recopy WordPress files only]" -ForegroundColor Red
}
Write-Host ""

# ─────────────────────────────────────────────
# Step 0: Force mode - wipe existing setup
# ─────────────────────────────────────────────
if ($Force) {
    Write-Host "[0/11] Force mode: Wiping existing setup..." -ForegroundColor Red

    Push-Location $ScriptDir
    try {
        Write-Host "  Stopping containers and removing volumes..." -ForegroundColor White
        docker compose down -v 2>&1 | Out-Null
        Write-Host "  Containers stopped and volumes removed." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    $UploadsDir = Join-Path $WorkingDir "uploads"
    if (Test-Path $UploadsDir) {
        Write-Host "  Removing uploads/ ..." -ForegroundColor White
        Remove-Item $UploadsDir -Recurse -Force
        Write-Host "  uploads/ removed." -ForegroundColor Green
    }
    else {
        Write-Host "  uploads/ not found, skipping." -ForegroundColor DarkGray
    }

    $WorkingDbDirForce = Join-Path $WorkingDir "database"
    if (Test-Path $WorkingDbDirForce) {
        Write-Host "  Removing database/ ..." -ForegroundColor White
        Remove-Item $WorkingDbDirForce -Recurse -Force
        Write-Host "  database/ removed." -ForegroundColor Green
    }
    else {
        Write-Host "  database/ not found, skipping." -ForegroundColor DarkGray
    }

    Write-Host ""
}
elseif ($ForceDb) {
    Write-Host "[0/11] ForceDb: Wiping database for fresh import..." -ForegroundColor Red

    Push-Location $ScriptDir
    try {
        Write-Host "  Stopping db container..." -ForegroundColor White
        docker compose stop db 2>&1 | Out-Null
        docker compose rm -f db 2>&1 | Out-Null
        Write-Host "  db container stopped." -ForegroundColor Green

        Write-Host "  Removing db_data volume..." -ForegroundColor White
        docker volume rm "${ComposeProjName}_db_data" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  db_data volume removed." -ForegroundColor Green
        }
        else {
            Write-Host "  db_data volume not found, skipping." -ForegroundColor DarkGray
        }
    }
    finally {
        Pop-Location
    }

    $WorkingDbDirForce = Join-Path $WorkingDir "database"
    if (Test-Path $WorkingDbDirForce) {
        Write-Host "  Removing database/ ..." -ForegroundColor White
        Remove-Item $WorkingDbDirForce -Recurse -Force
        Write-Host "  database/ removed." -ForegroundColor Green
    }
    else {
        Write-Host "  database/ not found, skipping." -ForegroundColor DarkGray
    }

    Write-Host ""
}
elseif ($ForceFiles) {
    Write-Host "[0/11] ForceFiles: Wiping WordPress files for fresh copy..." -ForegroundColor Red

    Push-Location $ScriptDir
    try {
        Write-Host "  Stopping wordpress container..." -ForegroundColor White
        docker compose stop wordpress 2>&1 | Out-Null
        docker compose rm -f wordpress 2>&1 | Out-Null
        Write-Host "  wordpress container stopped." -ForegroundColor Green

        Write-Host "  Removing wp_data volume..." -ForegroundColor White
        docker volume rm "${ComposeProjName}_wp_data" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  wp_data volume removed." -ForegroundColor Green
        }
        else {
            Write-Host "  wp_data volume not found, skipping." -ForegroundColor DarkGray
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ""
}

# ─────────────────────────────────────────────
# Step 1: Pre-flight checks
# ─────────────────────────────────────────────
Write-Host "[1/11] Pre-flight checks..." -ForegroundColor Yellow

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
$BackupDir = Join-Path $WorkingDir "Backup"
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
# Step 2: Copy uploads and prepare database
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[2/11] Copying uploads and preparing database..." -ForegroundColor Yellow

$UploadsDir = Join-Path $WorkingDir "uploads"
$WorkingDbDir = Join-Path $WorkingDir "database"
$BackupUploadsDir = Join-Path $BackupWpDir "wp-content\uploads"

# Copy uploads from Backup/ -> uploads/ (bind-mount source for the container)
if (Test-Path $UploadsDir) {
    Write-Host "  uploads/ already exists, skipping copy." -ForegroundColor DarkYellow
}
else {
    if (Test-Path $BackupUploadsDir) {
        Write-Host "  Copying Backup/wordpress/wp-content/uploads/ -> uploads/ ..." -ForegroundColor White
        Write-Host "  (This may take a while for large media libraries)" -ForegroundColor DarkGray

        $robocopyArgs = @($BackupUploadsDir, $UploadsDir, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/MT:8")
        & robocopy @robocopyArgs | Out-Null

        if ($LASTEXITCODE -ge 8) {
            Write-Error "robocopy failed with exit code $LASTEXITCODE"
            exit 1
        }
        Write-Host "  uploads/ copy complete." -ForegroundColor Green
    }
    else {
        Write-Host "  No uploads found in Backup, creating empty uploads/ directory." -ForegroundColor DarkYellow
        New-Item -ItemType Directory -Path $UploadsDir -Force | Out-Null
    }
}

# Handle database directory
if (Test-Path $WorkingDbDir) {
    Write-Host "  database/ already exists, skipping copy." -ForegroundColor DarkYellow
}
else {
    Write-Host "  Copying Backup/database/ -> database/ ..." -ForegroundColor White

    New-Item -ItemType Directory -Path $WorkingDbDir -Force | Out-Null

    # The SQL file has no extension. MySQL's docker-entrypoint-initdb.d requires
    # .sql extension to auto-import, so we copy it with the correct extension.
    # We also prepend a USE statement since the dump doesn't specify a database.
    $importSqlPath = Join-Path $WorkingDbDir "import.sql"

    # Write the USE statement first, then append the original SQL dump
    $useStatement = "-- Auto-generated by setup-docker.ps1`nUSE ``$DbName``;`n`n"
    Set-Content -Path $importSqlPath -Value $useStatement -NoNewline

    # Append the original SQL dump (using raw bytes for performance with large files)
    $sourceStream = [System.IO.File]::OpenRead($BackupDbFile)
    $destStream = [System.IO.File]::Open($importSqlPath, [System.IO.FileMode]::Append)
    try {
        $sourceStream.CopyTo($destStream)
    }
    finally {
        $sourceStream.Close()
        $destStream.Close()
    }

    Write-Host "  database/ copy complete (with USE $DbName prepended)." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 3: Patch wp-config.php for local Docker
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3/11] Patching wp-config.php for local environment..." -ForegroundColor Yellow

# Read from Backup/ - we never modify Backup/
# The patched version is written to a temp file and docker cp'd into the container in Step 5.
$BackupWpConfigPath = Join-Path $BackupWpDir "wp-config.php"
$TempWpConfigPath = Join-Path $env:TEMP "wp-config-docker-patched.php"

if (-not (Test-Path $BackupWpConfigPath)) {
    Write-Error "wp-config.php not found at: $BackupWpConfigPath"
    exit 1
}

$config = Get-Content $BackupWpConfigPath -Raw

# Track what we change
$changes = @()

# --- DB_HOST: -> db (Docker service name) ---
$newConfig = $config -replace "define\s*\(\s*'DB_HOST'\s*,\s*'[^']*'\s*\)\s*;", "define('DB_HOST', 'db'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "DB_HOST -> db"
}

# --- DB_NAME ---
$newConfig = $config -replace "define\s*\(\s*'DB_NAME'\s*,\s*'[^']*'\s*\)\s*;", "define('DB_NAME', '$DbName'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "DB_NAME -> $DbName"
}

# --- DB_USER ---
$newConfig = $config -replace "define\s*\(\s*'DB_USER'\s*,\s*'[^']*'\s*\)\s*;", "define('DB_USER', '$DbUser'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "DB_USER -> $DbUser"
}

# --- DB_PASSWORD ---
$newConfig = $config -replace "define\s*\(\s*'DB_PASSWORD'\s*,\s*'[^']*'\s*\)\s*;", "define('DB_PASSWORD', '$DbPassword'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "DB_PASSWORD -> <set>"
}

# --- FORCE_SSL_ADMIN: false ---
$newConfig = $config -replace "define\s*\(\s*'FORCE_SSL_ADMIN'\s*,\s*(true|false)\s*\)\s*;", "define('FORCE_SSL_ADMIN', false); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "FORCE_SSL_ADMIN -> false"
}

# --- WP_CACHE: false ---
$newConfig = $config -replace "define\s*\(\s*'WP_CACHE'\s*,\s*(true|false)\s*\)\s*;", "define('WP_CACHE', false); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_CACHE -> false"
}

# --- WP_REDIS_DISABLED: true ---
$newConfig = $config -replace "define\s*\(\s*'WP_REDIS_DISABLED'\s*,\s*(true|false)\s*\)\s*;", "define('WP_REDIS_DISABLED', true); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_REDIS_DISABLED -> true"
}

# --- DISALLOW_FILE_MODS: based on .env setting ---
$newValue = $DisallowFileMods.ToString().ToLower()
$newConfig = $config -replace "define\s*\(\s*'DISALLOW_FILE_MODS'\s*,\s*(true|false)\s*\)\s*;", "define('DISALLOW_FILE_MODS', $newValue);"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "DISALLOW_FILE_MODS -> $newValue"
}

# --- WP_DEBUG: true ---
$newConfig = $config -replace "define\s*\(\s*'WP_DEBUG'\s*,\s*(true|false)\s*\)\s*;", "define('WP_DEBUG', true); // Patched for Docker: debug enabled"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_DEBUG -> true"
}

# --- WP_DEBUG_LOG: true ---
$newConfig = $config -replace "define\s*\(\s*'WP_DEBUG_LOG'\s*,\s*(true|false)\s*\)\s*;", "define('WP_DEBUG_LOG', true); // Patched for Docker: debug log enabled"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_DEBUG_LOG -> true"
}

# --- WP_MEMORY_LIMIT: 2048M ---
$newConfig = $config -replace "define\s*\(\s*'WP_MEMORY_LIMIT'\s*,\s*'[^']*'\s*\)\s*;", "define('WP_MEMORY_LIMIT', '2048M'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_MEMORY_LIMIT -> 2048M"
}

# --- WP_MAX_MEMORY_LIMIT: 2048M ---
$newConfig = $config -replace "define\s*\(\s*'WP_MAX_MEMORY_LIMIT'\s*,\s*'[^']*'\s*\)\s*;", "define('WP_MAX_MEMORY_LIMIT', '2048M'); // Patched for Docker"
if ($newConfig -ne $config) {
    $config = $newConfig
    $changes += "WP_MAX_MEMORY_LIMIT -> 2048M"
}

# Write patched config to temp file (docker cp'd into the container in Step 5)
Set-Content -Path $TempWpConfigPath -Value $config -NoNewline

foreach ($change in $changes) {
    Write-Host "  $change" -ForegroundColor Green
}

if ($changes.Count -eq 0) {
    Write-Host "  No changes needed (already patched?)" -ForegroundColor DarkYellow
}

# --- Add Gravity Flow webhook HMAC signing to wp-config.php ---
$hmacCode = @'

// Gravity Flow Webhook HMAC Signing (added by setup-docker.ps1)
// Only run if WordPress functions are available (skip during WP-CLI bootstrap)
if ( function_exists( 'add_filter' ) ) {
    add_filter( 'gravityflow_webhook_args', function( $args, $entry, $current_step ) {
        $secret = 'wt-webhook-secret-2024-hmac-signing';

        // Get the body - check what format it's in
        $body = isset( $args['body'] ) ? $args['body'] : '';

        // Convert to string if it's an array (this might be the issue!)
        if ( is_array( $body ) ) {
            error_log( '[GF HMAC DEBUG] Body is an ARRAY - converting to query string' );
            error_log( '[GF HMAC DEBUG] Array keys: ' . implode( ', ', array_keys( $body ) ) );
            $body = http_build_query( $body );
        } else {
            error_log( '[GF HMAC DEBUG] Body is already a STRING' );
        }

        // Log body details for debugging
        error_log( '[GF HMAC DEBUG] Body length: ' . strlen( $body ) );
        error_log( '[GF HMAC DEBUG] Body first 200 chars: ' . substr( $body, 0, 200 ) );
        error_log( '[GF HMAC DEBUG] Body last 50 chars: ' . substr( $body, -50 ) );

        // Compute HMAC
        $signature = hash_hmac( 'sha256', $body, $secret );

        // Log the computed signature
        error_log( '[GF HMAC DEBUG] Computed signature: ' . $signature );
        error_log( '[GF HMAC DEBUG] Full header value: sha256=' . $signature );

        // Set headers
        $args['headers']['X-Hub-Signature-256'] = 'sha256=' . $signature;
        $args['headers']['X-atanga'] = 'haumaru';

        // Important: Ensure the body that gets sent is the SAME as what we computed HMAC on
        $args['body'] = $body;

        // Log what we're about to send
        error_log( '[GF HMAC DEBUG] Final args body type: ' . gettype( $args['body'] ) );
        error_log( '[GF HMAC DEBUG] Final args body length: ' . strlen( $args['body'] ) );

        return $args;
    }, 10, 4 );
}
'@

# Append HMAC code to the temp file if not already present
$currentConfig = Get-Content $TempWpConfigPath -Raw
if (-not $currentConfig.Contains('gravityflow_webhook_args')) {
    Add-Content -Path $TempWpConfigPath -Value $hmacCode
    Write-Host "  Added Gravity Flow webhook HMAC signing to wp-config.php" -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 4: Start Docker containers
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[4/11] Starting Docker containers..." -ForegroundColor Yellow

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
# Step 5: Copy WordPress files into Docker volume
# ─────────────────────────────────────────────
# PHP files are served from the named Docker volume (wp_data) which lives on the
# Linux filesystem inside Docker - far faster than a Windows bind-mount.
# Only wp-content/uploads remains as a bind-mount so media is accessible on the host.
Write-Host ""
Write-Host "[5/11] Copying WordPress files into Docker volume..." -ForegroundColor Yellow

# Check if the volume already has WP files (idempotent re-runs)
$wpIndexCheck = docker compose exec -T wordpress test -f /var/www/html/wp-config.php 2>&1
$wpAlreadyCopied = ($LASTEXITCODE -eq 0)

if ($wpAlreadyCopied) {
    Write-Host "  WordPress files already present in Docker volume, skipping copy." -ForegroundColor DarkYellow
}
else {
    Write-Host "  Copying Backup/wordpress/ directly into container..." -ForegroundColor White
    Write-Host "  (This may take a minute)" -ForegroundColor DarkGray

    $containerId = docker compose ps -q wordpress

    # Copy everything at the root of Backup/wordpress/ except wp-content (handled separately)
    Get-ChildItem -Path $BackupWpDir | Where-Object { $_.Name -ne "wp-content" } | ForEach-Object {
        docker cp "$($_.FullName)" "${containerId}:/var/www/html/" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker cp failed for $($_.Name)"
            exit 1
        }
    }

    # Copy wp-content subdirectories individually, skipping uploads.
    # uploads is bind-mounted from the host so it doesn't belong in the Docker volume.
    docker compose exec -T wordpress mkdir -p /var/www/html/wp-content 2>&1 | Out-Null
    Get-ChildItem -Path (Join-Path $BackupWpDir "wp-content") | Where-Object { $_.Name -ne "uploads" } | ForEach-Object {
        docker cp "$($_.FullName)" "${containerId}:/var/www/html/wp-content/" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "docker cp failed for wp-content/$($_.Name)"
            exit 1
        }
    }

    # Inject the patched wp-config.php (Backup/ version was read-only; temp file has all patches)
    docker cp $TempWpConfigPath "${containerId}:/var/www/html/wp-config.php" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker cp failed for wp-config.php"
        exit 1
    }
    Write-Host "  Injected patched wp-config.php." -ForegroundColor Green

    # Remove production caching drop-ins that would break the local environment
    foreach ($dropin in @("wp-content/advanced-cache.php", "wp-content/object-cache.php")) {
        $dropinExists = docker compose exec -T wordpress test -f "/var/www/html/$dropin" 2>&1
        if ($LASTEXITCODE -eq 0) {
            docker compose exec -T wordpress rm -f "/var/www/html/$dropin" 2>&1 | Out-Null
            Write-Host "  Removed $dropin (production caching drop-in)" -ForegroundColor Green
        }
    }

    # Remove production environment monitor mu-plugin (phones home for unauthorized deployments)
    $coreHooksPath = "wp-content/mu-plugins/core-hooks.php"
    docker compose exec -T wordpress test -f "/var/www/html/$coreHooksPath" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        docker compose exec -T wordpress rm -f "/var/www/html/$coreHooksPath" 2>&1 | Out-Null
        Write-Host "  Removed $coreHooksPath (production environment monitor)" -ForegroundColor Green
    }

    # Fix ownership so Apache/PHP can read the files
    docker compose exec -T wordpress chown -R www-data:www-data /var/www/html 2>&1 | Out-Null

    Write-Host "  WordPress files copied into Docker volume (uploads excluded - served via bind-mount)." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 6: Wait for database to be ready
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[6/11] Waiting for database import to complete..." -ForegroundColor Yellow
Write-Host "  The $([math]::Round($dbFileSize, 0)) MB SQL dump may take several minutes to import." -ForegroundColor DarkGray
Write-Host "  You can monitor progress with: docker compose logs -f db" -ForegroundColor DarkGray
Write-Host ""

$maxAttempts = 120  # 120 * 10s = 20 minutes max wait
$attempt = 0
$ready = $false

while (-not $ready -and $attempt -lt $maxAttempts) {
    $attempt++
    try {
        # -h 127.0.0.1 forces TCP (not socket). During init, MySQL runs with
        # --skip-networking so TCP is refused. TCP only becomes available after
        # the import has finished and MySQL has restarted in normal mode.
        # Checking wp_options confirms the SQL dump actually imported successfully.
        $result = docker compose exec -T db mysql -h 127.0.0.1 -u"$DbUser" -p"$DbPassword" "$DbName" -e "SELECT 1 FROM wp_options LIMIT 1;" 2>&1
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
    exit 1
}

# ─────────────────────────────────────────────
# Step 7: Patch Requests.php timeouts
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[7/11] Patching wp-includes/Requests/src/Requests.php timeouts to 120s..." -ForegroundColor Yellow

$RequestsPhpPath = Join-Path $BackupWpDir "wp-includes\Requests\src\Requests.php"
if (-not (Test-Path $RequestsPhpPath)) {
    Write-Host "  Requests.php not found at: $RequestsPhpPath, skipping." -ForegroundColor DarkYellow
}
else {
    $requestsContent = Get-Content $RequestsPhpPath -Raw
    $requestsChanged = @()

    foreach ($key in @('timeout', 'connect_timeout')) {
        $newContent = $requestsContent -replace "('$key'\s*=>\s*)\d+(\s*,)", '${1}120${2}'
        if ($newContent -ne $requestsContent) {
            $requestsContent = $newContent
            $requestsChanged += "$key -> 120"
        }
    }

    if ($requestsChanged.Count -gt 0) {
        # Write to a temp file (Backup/ is read-only) and docker cp into the container
        $TempRequestsPath = Join-Path $env:TEMP "Requests-patched.php"
        Set-Content -Path $TempRequestsPath -Value $requestsContent -NoNewline
        $containerId = docker compose ps -q wordpress
        docker cp $TempRequestsPath "${containerId}:/var/www/html/wp-includes/Requests/src/Requests.php" 2>&1 | Out-Null
        foreach ($change in $requestsChanged) {
            Write-Host "  $change" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  No changes needed (already patched?)" -ForegroundColor DarkYellow
    }
}

# ─────────────────────────────────────────────
# Step 8: Install WP-CLI and replace URLs
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[8/11] Replacing production URLs with localhost..." -ForegroundColor Yellow

$productionUrl = "https://waikatotainui.com"
$localUrl = if ($WpPort -eq "80") { "http://localhost" } else { "http://localhost:$WpPort" }

# Install WP-CLI if not present, then run search-replace
$wpCliScript = @"
if ! command -v wp &> /dev/null; then
    curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
fi
wp --allow-root search-replace '$productionUrl' '$localUrl' --all-tables --report-changed-only \
  --skip-tables=wp_gf_entry,wp_gf_entry_meta,wp_gravitysmtp_events,wp_redirection_404,wp_redirection_logs,wp_stream_meta,wp_wfhits,wp_wfnotifications,wp_wpr_above_the_fold,wp_wpr_lazy_render_content,wp_wpr_rocket_cache,wp_wsal_metadata,wp_wsal_occurrences
"@

docker compose exec -T wordpress bash -c $wpCliScript 2>&1 | ForEach-Object {
    Write-Host "  $_" -ForegroundColor DarkGray
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "  URL replacement complete: $productionUrl -> $localUrl" -ForegroundColor Green
}
else {
    Write-Host "  WARNING: URL replacement may have failed. Check output above." -ForegroundColor Yellow
}

# ─────────────────────────────────────────────
# Step 9: Create local admin user and disable 2FA
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[9/11] Creating local admin user and disabling 2FA..." -ForegroundColor Yellow

if (-not $LocalAdminUser -or -not $LocalAdminPassword) {
    Write-Host "  Skipping: LOCAL_ADMIN_USER or LOCAL_ADMIN_PASSWORD not set in .env" -ForegroundColor DarkYellow
}
else {
    # Create or update local admin user via WP-CLI
    $createUserScript = @"
if wp --allow-root user get '$LocalAdminUser' > /dev/null 2>&1; then
    wp --allow-root user update '$LocalAdminUser' --user_pass='$LocalAdminPassword' --role=administrator
    echo "Updated existing user: $LocalAdminUser"
else
    wp --allow-root user create '$LocalAdminUser' '$LocalAdminEmail' --role=administrator --user_pass='$LocalAdminPassword'
    echo "Created new user: $LocalAdminUser"
fi
"@

    docker compose exec -T wordpress bash -c $createUserScript 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Local admin user '$LocalAdminUser' ready." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to create/update local admin user." -ForegroundColor Yellow
    }

    # Disable 2FA for the local admin user by removing their Wordfence login-security secret.
    # Wordfence stores per-user 2FA in wp_wfls_2fa_secrets; a missing row means no 2FA active.
    $TempDisable2faPath = Join-Path $env:TEMP "disable-2fa.php"
    $disable2faScript = @"
<?php
global `$wpdb;
`$user = get_user_by('login', '$LocalAdminUser');
if (!`$user) { echo "User '$LocalAdminUser' not found\n"; exit(1); }
`$table = `$wpdb->prefix . 'wfls_2fa_secrets';
`$deleted = `$wpdb->delete(`$table, ['user_id' => `$user->ID]);
echo `$deleted === false
    ? "No 2FA record found for $LocalAdminUser (already clear)\n"
    : "Removed Wordfence 2FA for $LocalAdminUser ({`$deleted} record(s))\n";
"@

    Set-Content -Path $TempDisable2faPath -Value $disable2faScript -NoNewline

    $containerId = docker compose ps -q wordpress
    docker cp $TempDisable2faPath "${containerId}:/tmp/disable-2fa.php" 2>&1 | Out-Null

    docker compose exec -T wordpress wp --allow-root eval-file /tmp/disable-2fa.php 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }

    docker compose exec -T wordpress rm -f /tmp/disable-2fa.php 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Wordfence 2FA cleared for '$LocalAdminUser'." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to clear Wordfence 2FA." -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────
# Step 10: Disable Gravity Forms notifications
# ─────────────────────────────────────────────
Write-Host ""
if ($DisableGfNotifications) {
    Write-Host "[10/11] Disabling Gravity Forms notifications..." -ForegroundColor Yellow

    # Use WP-CLI + PHP to properly handle notifications that lack an isActive field
    # (they default to active in GF but won't be caught by a simple string replace).
    # Single-quoted heredoc so PowerShell doesn't expand $wpdb, $rows, etc.
    $TempGfPhpPath = Join-Path $env:TEMP "gf-disable-notifications.php"
    $gfPhpScript = @'
<?php
global $wpdb;
$rows = $wpdb->get_results("SELECT form_id, notifications FROM {$wpdb->prefix}gf_form_meta WHERE notifications IS NOT NULL AND notifications != ''");
$updated = 0;
foreach ($rows as $row) {
    $notifications = json_decode($row->notifications, true);
    if (!is_array($notifications)) continue;
    $changed = false;
    foreach ($notifications as $id => &$notification) {
        if (!array_key_exists('isActive', $notification) || $notification['isActive'] !== false) {
            $notification['isActive'] = false;
            $changed = true;
        }
    }
    unset($notification);
    if ($changed) {
        $wpdb->update(
            "{$wpdb->prefix}gf_form_meta",
            ['notifications' => wp_json_encode($notifications)],
            ['form_id' => $row->form_id]
        );
        $updated++;
    }
}
echo "Updated $updated form(s)\n";
'@

    Set-Content -Path $TempGfPhpPath -Value $gfPhpScript -NoNewline

    $containerId = docker compose ps -q wordpress
    docker cp $TempGfPhpPath "${containerId}:/tmp/gf-disable-notifications.php" 2>&1 | Out-Null

    docker compose exec -T wordpress wp --allow-root eval-file /tmp/gf-disable-notifications.php 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }

    docker compose exec -T wordpress rm -f /tmp/gf-disable-notifications.php 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Gravity Forms notifications disabled." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to disable Gravity Forms notifications." -ForegroundColor Yellow
    }
}
else {
    Write-Host "[10/11] Skipping Gravity Forms notifications (DISABLE_GF_NOTIFICATIONS=false)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
# Step 11: Redirect Make.com webhooks
# ─────────────────────────────────────────────
Write-Host ""
if ($GfWebhookRedirectHost) {
    Write-Host "[11/11] Redirecting Make.com webhooks to $GfWebhookRedirectHost..." -ForegroundColor Yellow

    # Use a here-string to avoid quote escaping issues
    $webhookSql = @"
UPDATE wp_gf_addon_feed
SET meta = REPLACE(meta, 'hook.us1.make.com', '$GfWebhookRedirectHost')
WHERE meta LIKE '%hook.us1.make.com%';
"@

    docker compose exec -T db mysql -u"$DbUser" -p"$DbPassword" "$DbName" -e $webhookSql 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Webhooks redirected: hook.us1.make.com -> $GfWebhookRedirectHost" -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to redirect webhooks." -ForegroundColor Yellow
    }
}
else {
    Write-Host "[11/11] Skipping webhook redirect (GF_WEBHOOK_REDIRECT_HOST not set)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
$localDisplayUrl = if ($WpPort -eq "80") { "http://localhost" } else { "http://localhost:$WpPort" }
Write-Host "  WordPress:  $localDisplayUrl" -ForegroundColor White
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
Write-Host "    docker compose down -v             # Stop and remove all volumes (full reset)" -ForegroundColor DarkGray
Write-Host ""
