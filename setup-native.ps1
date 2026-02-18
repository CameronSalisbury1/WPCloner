#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a local WordPress instance from a production backup using Laragon.

.DESCRIPTION
    This script:
    1. Verifies Laragon installation and services
    2. Copies backup files to the Laragon www/wordpress directory
    3. Patches wp-config.php for the local environment
    4. Creates the database and imports the SQL dump
    5. Replaces production URLs with wordpress.test
    6. Disables Gravity Forms notifications (optional)
    7. Redirects webhooks (optional)

.PARAMETER Force
    Wipes existing WordPress files and database, then recopies everything from Backup/

.EXAMPLE
    .\setup-native.ps1

.EXAMPLE
    .\setup-native.ps1 -Force
    # Wipes everything and starts fresh from Backup/

.NOTES
    Requires Laragon to be installed and running. Download from https://laragon.org
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkingDir = Split-Path -Parent $ScriptDir  # Parent directory (C:\repos\Tainui\WP)

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
$LaragonRoot = "C:\laragon"
$WpDir = Join-Path $LaragonRoot "www\wordpress"
$LocalDomain = "wordpress.test"

# Auto-detect PHP and MySQL paths
$PhpDir = Get-ChildItem (Join-Path $LaragonRoot "bin\php") | Select-Object -First 1 -ExpandProperty FullName
$MysqlDir = Get-ChildItem (Join-Path $LaragonRoot "bin\mysql\") | Select-Object -First 1 -ExpandProperty FullName
$PhpExe = Join-Path $PhpDir "php.exe"
$MysqlExe = Join-Path $MysqlDir "bin\mysql.exe"

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
$DbRootPassword = $EnvVars["DB_ROOT_PASSWORD"]
$DisableGfNotifications = $EnvVars["DISABLE_GF_NOTIFICATIONS"] -eq "true"
$GfWebhookRedirectHost = $EnvVars["GF_WEBHOOK_REDIRECT_HOST"]
$DisallowFileMods = $EnvVars["DISALLOW_FILE_MODS"] -eq "true"

Write-Host ""
Write-Host "=== WordPress Laragon Setup ===" -ForegroundColor Cyan
if ($Force) {
    Write-Host "    [FORCE MODE - Will wipe and recopy from Backup/]" -ForegroundColor Red
}
Write-Host ""

# ─────────────────────────────────────────────
# Step 0: Force mode - wipe existing setup
# ─────────────────────────────────────────────
if ($Force) {
    Write-Host "[0/9] Force mode: Wiping existing setup..." -ForegroundColor Red
    
    # Remove all files from wordpress directory
    if (Test-Path $WpDir) {
        Write-Host "  Removing all files from $WpDir ..." -ForegroundColor White
        Get-ChildItem -Path $WpDir -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  WordPress directory cleared." -ForegroundColor Green
    } else {
        Write-Host "  WordPress directory not found, skipping." -ForegroundColor DarkGray
    }
    
    # Remove working database directory
    $WorkingDbDir = Join-Path $WorkingDir "database"
    if (Test-Path $WorkingDbDir) {
        Write-Host "  Removing $WorkingDbDir ..." -ForegroundColor White
        Remove-Item $WorkingDbDir -Recurse -Force
        Write-Host "  Database working directory removed." -ForegroundColor Green
    } else {
        Write-Host "  Database directory not found, skipping." -ForegroundColor DarkGray
    }
    
    # Drop the database
    Write-Host "  Dropping database '$DbName'..." -ForegroundColor White
    $dropDbSql = "DROP DATABASE IF EXISTS ``$DbName``;"
    & $MysqlExe -uroot -p"$DbRootPassword" -e $dropDbSql 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Database dropped." -ForegroundColor Green
    } else {
        Write-Host "  Could not drop database (may not exist)." -ForegroundColor DarkYellow
    }
    
    # Also drop the user to ensure clean state
    Write-Host "  Dropping user '$DbUser'..." -ForegroundColor White
    $dropUserSql = "DROP USER IF EXISTS '$DbUser'@'localhost';"
    & $MysqlExe -uroot -p"$DbRootPassword" -e $dropUserSql 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  User dropped." -ForegroundColor Green
    } else {
        Write-Host "  Could not drop user (may not exist)." -ForegroundColor DarkYellow
    }
    
    Write-Host ""
}

# ─────────────────────────────────────────────
# Step 1: Pre-flight checks
# ─────────────────────────────────────────────
Write-Host "[1/9] Pre-flight checks..." -ForegroundColor Yellow

# Check if Laragon is installed
if (-not (Test-Path $LaragonRoot)) {
    Write-Host "  Laragon: NOT FOUND" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Laragon not found at $LaragonRoot" -ForegroundColor Yellow
    Write-Host "  Please install Laragon from https://laragon.org" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}
Write-Host "  Laragon: OK (installed at $LaragonRoot)" -ForegroundColor Green

# Check if PHP exists
if (-not (Test-Path $PhpExe)) {
    Write-Error "PHP not found at: $PhpExe"
    exit 1
}

# Check if MySQL exists
if (-not (Test-Path $MysqlExe)) {
    Write-Error "MySQL not found at: $MysqlExe"
    exit 1
}

# Check if wordpress directory is linked
if (-not (Test-Path $WpDir)) {
    Write-Host "  Creating wordpress directory..." -ForegroundColor White
    New-Item -ItemType Directory -Path $WpDir -Force | Out-Null
    Write-Host "  WordPress directory created." -ForegroundColor Green
}

# Check MySQL connectivity
try {
    & $MysqlExe -uroot -p"$DbRootPassword" -e "SELECT 1;" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  MySQL: OK (connection successful)" -ForegroundColor Green
    } else {
        Write-Error "MySQL connection failed. Please ensure Laragon services are running."
        exit 1
    }
} catch {
    Write-Error "MySQL not accessible. Please start Laragon and ensure MySQL service is running."
    exit 1
}

# Get PHP version
$phpVersion = & $PhpExe -v 2>&1 | Select-Object -First 1
if ($phpVersion -match "PHP (\d+\.\d+\.\d+)") {
    Write-Host "  PHP: OK (v$($Matches[1]))" -ForegroundColor Green
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
# Step 2: Copy WordPress files
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[2/9] Copying WordPress files..." -ForegroundColor Yellow

# Check if WordPress is already deployed (look for wp-config.php)
$wpConfigCheck = Join-Path $WpDir "wp-config.php"
if (Test-Path $wpConfigCheck) {
    Write-Host "  WordPress already deployed to $WpDir, skipping copy." -ForegroundColor DarkYellow
} else {
    Write-Host "  Copying Backup/wordpress/ -> $WpDir ..." -ForegroundColor White
    Write-Host "  (This may take a while for large uploads)" -ForegroundColor DarkGray

    # Use robocopy for better performance with large directory trees
    $robocopyArgs = @($BackupWpDir, $WpDir, "*.*", "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/MT:8")
    & robocopy @robocopyArgs | Out-Null

    # Robocopy exit codes: 0-7 are success, 8+ are errors
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed with exit code $LASTEXITCODE"
        exit 1
    }

    Write-Host "  WordPress files copied." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 3: Prepare database import file
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[3/9] Preparing database import file..." -ForegroundColor Yellow

$WorkingDbDir = Join-Path $WorkingDir "database"
$ImportSqlPath = Join-Path $WorkingDbDir "import.sql"

if (Test-Path $ImportSqlPath) {
    Write-Host "  database/import.sql already exists, skipping preparation." -ForegroundColor DarkYellow
} else {
    Write-Host "  Creating database/import.sql with USE statement..." -ForegroundColor White
    
    New-Item -ItemType Directory -Path $WorkingDbDir -Force | Out-Null
    
    # Write the USE statement first, then append the original SQL dump
    $useStatement = "-- Auto-generated by setup-native.ps1`nUSE ``$DbName``;`n`n"
    Set-Content -Path $ImportSqlPath -Value $useStatement -NoNewline
    
    # Append the original SQL dump (using raw bytes for performance with large files)
    $sourceStream = [System.IO.File]::OpenRead($BackupDbFile)
    $destStream = [System.IO.File]::Open($ImportSqlPath, [System.IO.FileMode]::Append)
    try {
        $sourceStream.CopyTo($destStream)
    } finally {
        $sourceStream.Close()
        $destStream.Close()
    }

    Write-Host "  database/import.sql created." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 4: Patch wp-config.php for local environment
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[4/9] Patching wp-config.php for local environment..." -ForegroundColor Yellow

$WpConfigPath = Join-Path $WpDir "wp-config.php"

if (-not (Test-Path $WpConfigPath)) {
    Write-Error "wp-config.php not found at: $WpConfigPath (was the copy successful?)"
    exit 1
}

$config = Get-Content $WpConfigPath -Raw

# Track what we change
$changes = @()

# --- DB_NAME ---
$original = "define('DB_NAME', 'ndshewxtpp');"
$replacement = "define('DB_NAME', '$DbName'); // Patched for local: was 'ndshewxtpp'"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_NAME: ndshewxtpp -> $DbName"
}

# --- DB_USER ---
$original = "define('DB_USER', 'ndshewxtpp');"
$replacement = "define('DB_USER', '$DbUser'); // Patched for local: was 'ndshewxtpp'"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_USER: ndshewxtpp -> $DbUser"
}

# --- DB_PASSWORD ---
$original = "define('DB_PASSWORD', 'taT8QhbkZe');"
$replacement = "define('DB_PASSWORD', '$DbPassword'); // Patched for local: was production password"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_PASSWORD: <redacted> -> $DbPassword"
}

# --- DB_HOST: Make sure it's localhost ---
$original = "define('DB_HOST', 'db');"
$replacement = "define('DB_HOST', 'localhost'); // Patched for Laragon: was 'db' (Docker)"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "DB_HOST: db -> localhost"
}

# --- FORCE_SSL_ADMIN: true -> false (no SSL locally) ---
$original = "define('FORCE_SSL_ADMIN', true);"
$replacement = "define('FORCE_SSL_ADMIN', false); // Patched for local: was true"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "FORCE_SSL_ADMIN: true -> false"
}

# --- WP_CACHE: true -> false (no caching locally) ---
$original = "define( 'WP_CACHE', true );"
$replacement = "define( 'WP_CACHE', false ); // Patched for local: was true"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "WP_CACHE: true -> false"
}

# --- WP_REDIS_DISABLED: false -> true ---
$original = "define( 'WP_REDIS_DISABLED', false );"
$replacement = "define( 'WP_REDIS_DISABLED', true ); // Patched for local: was false"
if ($config.Contains($original)) {
    $config = $config.Replace($original, $replacement)
    $changes += "WP_REDIS_DISABLED: false -> true"
}

# --- DISALLOW_FILE_MODS: based on .env setting ---
$newValue = $DisallowFileMods.ToString().ToLower()
$originalTrue = "define('DISALLOW_FILE_MODS', true);"
$originalFalse = "define('DISALLOW_FILE_MODS', false);"
$replacement = "define('DISALLOW_FILE_MODS', $newValue);"

if ($config.Contains($originalTrue)) {
    $config = $config.Replace($originalTrue, $replacement)
    $changes += "DISALLOW_FILE_MODS: true -> $newValue"
}
elseif ($config.Contains($originalFalse)) {
    $config = $config.Replace($originalFalse, $replacement)
    $changes += "DISALLOW_FILE_MODS: false -> $newValue"
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
    (Join-Path $WpDir "wp-content\advanced-cache.php"),
    (Join-Path $WpDir "wp-content\object-cache.php")
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

// Gravity Flow Webhook HMAC Signing (added by setup-native.ps1)
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
# Step 5: Create database and user
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[5/9] Creating database and user..." -ForegroundColor Yellow

# Create database
$createDbSql = "CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$result = & $MysqlExe -uroot -p"$DbRootPassword" -e $createDbSql 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Error: $result" -ForegroundColor Red
    exit 1
}
Write-Host "  Database '$DbName' created (or already exists)." -ForegroundColor Green

# Create user and grant privileges
$createUserSql = @"
CREATE USER IF NOT EXISTS '$DbUser'@'localhost' IDENTIFIED BY '$DbPassword';
GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost';
FLUSH PRIVILEGES;
"@

$result = & $MysqlExe -uroot -p"$DbRootPassword" -e $createUserSql 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  User '$DbUser' created with privileges on '$DbName'." -ForegroundColor Green
} else {
    # User might already exist, try just granting privileges
    $grantSql = "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost'; FLUSH PRIVILEGES;"
    & $MysqlExe -uroot -p"$DbRootPassword" -e $grantSql 2>&1 | Out-Null
    Write-Host "  User '$DbUser' privileges updated." -ForegroundColor Green
}

# ─────────────────────────────────────────────
# Step 6: Import database
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[6/9] Importing database..." -ForegroundColor Yellow
Write-Host "  Importing $([math]::Round($dbFileSize, 0)) MB SQL dump. This may take several minutes..." -ForegroundColor DarkGray

# Check if database already has tables (skip import if so)
$checkTablesSql = "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DbName';"
$tableCountRaw = & $MysqlExe -uroot -p"$DbRootPassword" -N -e $checkTablesSql 2>&1
# Extract the numeric result (2>&1 may produce an array mixing stderr and stdout)
$tableCount = ($tableCountRaw | Select-Object -Last 1).ToString().Trim()

if ($tableCount -match "^\d+$" -and [int]$tableCount -gt 0) {
    Write-Host "  Database already has $tableCount tables, skipping import." -ForegroundColor DarkYellow
    Write-Host "  To re-import, use: .\setup-native.ps1 -Force" -ForegroundColor DarkGray
} else {
    $startTime = Get-Date
    
    # Import the SQL file
    & $MysqlExe -uroot -p"$DbRootPassword" $DbName -e "source $ImportSqlPath" 2>&1 | ForEach-Object {
        if ($_ -match "ERROR") {
            Write-Host "  $_" -ForegroundColor Red
        }
    }
    
    if ($LASTEXITCODE -eq 0) {
        $duration = (Get-Date) - $startTime
        Write-Host "  Database imported successfully in $([math]::Round($duration.TotalMinutes, 1)) minutes." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Database import may have encountered errors." -ForegroundColor Yellow
    }
}

# ─────────────────────────────────────────────
# Step 7: Install WP-CLI and replace URLs
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[7/9] Replacing production URLs with $LocalDomain..." -ForegroundColor Yellow

$productionUrl = "https://waikatotainui.com"
$localUrl = "http://$LocalDomain"

# Check if WP-CLI is installed
$wpCliPath = Join-Path $env:USERPROFILE ".wp-cli\wp-cli.phar"
$wpCliBat = Join-Path $env:USERPROFILE ".wp-cli\wp.bat"

if (-not (Test-Path $wpCliPath)) {
    Write-Host "  Installing WP-CLI..." -ForegroundColor White
    
    $wpCliDir = Join-Path $env:USERPROFILE ".wp-cli"
    New-Item -ItemType Directory -Path $wpCliDir -Force | Out-Null
    
    # Download WP-CLI
    $wpCliUrl = "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    Invoke-WebRequest -Uri $wpCliUrl -OutFile $wpCliPath -UseBasicParsing
    
    Write-Host "  WP-CLI installed to $wpCliPath" -ForegroundColor Green
}

# Run search-replace using WP-CLI with Laragon's PHP
Write-Host "  Running search-replace: $productionUrl -> $localUrl" -ForegroundColor White

Push-Location $WpDir
try {
    $result = & $PhpExe $wpCliPath search-replace $productionUrl $localUrl --all-tables --report-changed-only 2>&1
    $result | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  URL replacement complete." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: URL replacement may have failed. Check output above." -ForegroundColor Yellow
    }
} finally {
    Pop-Location
}

# ─────────────────────────────────────────────
# Step 8: Disable Gravity Forms notifications
# ─────────────────────────────────────────────
Write-Host ""
if ($DisableGfNotifications) {
    Write-Host "[8/9] Disabling Gravity Forms notifications..." -ForegroundColor Yellow
    
    $gfSql = "UPDATE wp_gf_form_meta SET notifications = REPLACE(notifications, '`"isActive`":true', '`"isActive`":false') WHERE notifications LIKE '%isActive%';"
    
    & $MysqlExe -u"$DbUser" -p"$DbPassword" $DbName -e $gfSql 2>&1 | ForEach-Object {
        if ($_ -notmatch "Warning.*password") {
            Write-Host "  $_" -ForegroundColor DarkGray
        }
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Gravity Forms notifications disabled." -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to disable Gravity Forms notifications." -ForegroundColor Yellow
    }
} else {
    Write-Host "[8/9] Skipping Gravity Forms notifications (DISABLE_GF_NOTIFICATIONS=false)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
# Step 9: Redirect Make.com webhooks
# ─────────────────────────────────────────────
Write-Host ""
if ($GfWebhookRedirectHost) {
    Write-Host "[9/9] Redirecting Make.com webhooks to $GfWebhookRedirectHost..." -ForegroundColor Yellow
    
    $webhookSql = "UPDATE wp_gf_addon_feed SET meta = REPLACE(meta, 'hook.us1.make.com', '$GfWebhookRedirectHost') WHERE meta LIKE '%hook.us1.make.com%';"
    
    & $MysqlExe -u"$DbUser" -p"$DbPassword" $DbName -e $webhookSql 2>&1 | ForEach-Object {
        if ($_ -notmatch "Warning.*password") {
            Write-Host "  $_" -ForegroundColor DarkGray
        }
    }
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Webhooks redirected: hook.us1.make.com -> $GfWebhookRedirectHost" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Failed to redirect webhooks." -ForegroundColor Yellow
    }
} else {
    Write-Host "[9/9] Skipping webhook redirect (GF_WEBHOOK_REDIRECT_HOST not set)" -ForegroundColor DarkYellow
}

# ─────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "  WordPress:  http://$LocalDomain" -ForegroundColor White
Write-Host "              (Laragon auto-creates virtual hosts for folders in www/)" -ForegroundColor DarkGray
Write-Host "              (or http://localhost/wordpress if .test domain doesn't work)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Note: If $LocalDomain doesn't work:" -ForegroundColor DarkYellow
Write-Host "        1. Restart Laragon to trigger auto virtual host creation" -ForegroundColor DarkGray
Write-Host "        2. Or right-click Laragon > Apache > Virtual Hosts > Auto create" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  DB Name:     $DbName" -ForegroundColor DarkGray
Write-Host "  DB User:     $DbUser" -ForegroundColor DarkGray
Write-Host "  DB Password: $DbPassword" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  WordPress files: $WpDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "    WP-CLI:       $PhpExe $wpCliPath --path=`"$WpDir`" <command>" -ForegroundColor DarkGray
Write-Host "    MySQL CLI:    $MysqlExe -u$DbUser -p$DbPassword $DbName" -ForegroundColor DarkGray
Write-Host "    Laragon:      Start via Laragon Control Panel" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To reset:" -ForegroundColor DarkGray
Write-Host "    1. .\setup-native.ps1 -Force" -ForegroundColor DarkGray
Write-Host "       (or manually: $MysqlExe -uroot -p`"$DbRootPassword`" -e `"DROP DATABASE $DbName;`")" -ForegroundColor DarkGray
Write-Host ""
