#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a local WordPress instance from a production backup using Docker.

.DESCRIPTION
    This script:
    1. Copies backup files to working directories (never modifies the Backup/ folder)
    2. Patches wp-config.php for the local Docker environment
    3. Starts Docker containers (MySQL, WordPress, phpMyAdmin)
    4. Waits for the database import to complete
    5. Patches Requests.php timeouts
    6. Replaces production URLs with localhost
    7. Disables Gravity Forms notifications (optional)
    8. Redirects webhooks (optional)

.PARAMETER Force
    Wipes existing WordPress files, database directory and Docker DB volume, then recopies everything from Backup/

.EXAMPLE
    .\setup-docker.ps1

.EXAMPLE
    .\setup-docker.ps1 -Force
    # Wipes everything and starts fresh from Backup/
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkingDir = Split-Path -Parent $ScriptDir  # Parent directory (C:\repos\Tainui\WP)

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

Write-Host ""
Write-Host "=== WordPress Local Setup ===" -ForegroundColor Cyan
if ($Force) {
    Write-Host "    [FORCE MODE - Will wipe and recopy from Backup/]" -ForegroundColor Red
}
Write-Host ""

# ─────────────────────────────────────────────
# Step 0: Force mode - wipe existing setup
# ─────────────────────────────────────────────
if ($Force) {
    Write-Host "[0/9] Force mode: Wiping existing setup..." -ForegroundColor Red

    Push-Location $ScriptDir
    try {
        Write-Host "  Stopping containers and removing DB volume..." -ForegroundColor White
        docker compose down -v 2>&1 | Out-Null
        Write-Host "  Containers stopped and DB volume removed." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }

    $WorkingWpDirForce = Join-Path $WorkingDir "wordpress"
    if (Test-Path $WorkingWpDirForce) {
        Write-Host "  Removing wordpress/ ..." -ForegroundColor White
        Remove-Item $WorkingWpDirForce -Recurse -Force
        Write-Host "  WordPress directory removed." -ForegroundColor Green
    }
    else {
        Write-Host "  wordpress/ not found, skipping." -ForegroundColor DarkGray
    }

    $WorkingDbDirForce = Join-Path $WorkingDir "database"
    if (Test-Path $WorkingDbDirForce) {
        Write-Host "  Removing database/ ..." -ForegroundColor White
        Remove-Item $WorkingDbDirForce -Recurse -Force
        Write-Host "  Database directory removed." -ForegroundColor Green
    }
    else {
        Write-Host "  database/ not found, skipping." -ForegroundColor DarkGray
    }

    Write-Host ""
}

# ─────────────────────────────────────────────
# Step 1: Pre-flight checks
# ─────────────────────────────────────────────
Write-Host "[1/9] Pre-flight checks..." -ForegroundColor Yellow

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
# Step 2: Copy backup files
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[2/9] Copying backup files..." -ForegroundColor Yellow

$WorkingWpDir = Join-Path $WorkingDir "wordpress"
$WorkingDbDir = Join-Path $WorkingDir "database"

# Handle WordPress directory
if (Test-Path $WorkingWpDir) {
    Write-Host "  wordpress/ already exists, skipping copy." -ForegroundColor DarkYellow
}
else {
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
Write-Host "[3/9] Patching wp-config.php for local environment..." -ForegroundColor Yellow

$WpConfigPath = Join-Path $WorkingWpDir "wp-config.php"

if (-not (Test-Path $WpConfigPath)) {
    Write-Error "wp-config.php not found at: $WpConfigPath (was the copy successful?)"
    exit 1
}

$config = Get-Content $WpConfigPath -Raw

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

# Re-read the config to check if HMAC code already exists
$currentConfig = Get-Content $WpConfigPath -Raw
if (-not $currentConfig.Contains('gravityflow_webhook_args')) {
    Add-Content -Path $WpConfigPath -Value $hmacCode
    Write-Host "  Added Gravity Flow webhook HMAC signing to wp-config.php" -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 4: Start Docker containers
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[4/9] Starting Docker containers..." -ForegroundColor Yellow

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
Write-Host "[5/9] Waiting for database import to complete..." -ForegroundColor Yellow
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
# Step 6: Patch Requests.php timeouts
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[6/9] Patching wp-includes/Requests/src/Requests.php timeouts to 120s..." -ForegroundColor Yellow

$RequestsPhpPath = Join-Path $WorkingWpDir "wp-includes\Requests\src\Requests.php"
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
        Set-Content -Path $RequestsPhpPath -Value $requestsContent -NoNewline
        foreach ($change in $requestsChanged) {
            Write-Host "  $change" -ForegroundColor Green
        }
    }
    else {
        Write-Host "  No changes needed (already patched?)" -ForegroundColor DarkYellow
    }
}

# ─────────────────────────────────────────────
# Step 7: Install WP-CLI and replace URLs
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[7/9] Replacing production URLs with localhost..." -ForegroundColor Yellow

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
}
else {
    Write-Host "  WARNING: URL replacement may have failed. Check output above." -ForegroundColor Yellow
}

# ─────────────────────────────────────────────
# Step 8: Disable Gravity Forms notifications
# ─────────────────────────────────────────────
Write-Host ""
if ($DisableGfNotifications) {
    Write-Host "[8/9] Disabling Gravity Forms notifications..." -ForegroundColor Yellow

    # Use a here-string to avoid quote escaping issues
    $gfSql = @"
UPDATE wp_gf_form_meta
SET notifications = REPLACE(notifications, '"isActive":true', '"isActive":false')
WHERE notifications LIKE '%isActive%';
"@

    docker compose exec -T db mysql -u"$DbUser" -p"$DbPassword" "$DbName" -e $gfSql 2>&1 | ForEach-Object {
        Write-Host "  $_" -ForegroundColor DarkGray
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Gravity Forms notifications disabled." -ForegroundColor Green
    }
    else {
        Write-Host "  WARNING: Failed to disable Gravity Forms notifications." -ForegroundColor Yellow
    }
}
else {
    Write-Host "[8/9] Skipping Gravity Forms notifications (DISABLE_GF_NOTIFICATIONS=false)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
# Step 9: Redirect Make.com webhooks
# ─────────────────────────────────────────────
Write-Host ""
if ($GfWebhookRedirectHost) {
    Write-Host "[9/9] Redirecting Make.com webhooks to $GfWebhookRedirectHost..." -ForegroundColor Yellow

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
    Write-Host "[9/9] Skipping webhook redirect (GF_WEBHOOK_REDIRECT_HOST not set)" -ForegroundColor DarkYellow
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
Write-Host ""
