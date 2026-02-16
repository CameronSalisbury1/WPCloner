#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up a local WordPress instance from a production backup using XAMPP (native Windows).

.DESCRIPTION
    This script:
    1. Verifies XAMPP installation (Apache, MySQL/MariaDB, PHP)
    2. Copies backup files to XAMPP's htdocs directory
    3. Patches wp-config.php for the local environment
    4. Creates the database and imports the SQL dump
    5. Replaces production URLs with localhost
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
    Requires XAMPP to be installed. Download from https://www.apachefriends.org/
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
$XamppPath = "C:\xampp"
$HtdocsPath = Join-Path $XamppPath "htdocs"
$MysqlPath = Join-Path $XamppPath "mysql\bin"
$PhpPath = Join-Path $XamppPath "php"

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
$WpPort = $EnvVars["WORDPRESS_PORT"]
$DisableGfNotifications = $EnvVars["DISABLE_GF_NOTIFICATIONS"] -eq "true"
$GfWebhookRedirectHost = $EnvVars["GF_WEBHOOK_REDIRECT_HOST"]
$DisallowFileMods = $EnvVars["DISALLOW_FILE_MODS"] -eq "true"

Write-Host ""
Write-Host "=== WordPress Native Windows Setup (XAMPP) ===" -ForegroundColor Cyan
if ($Force) {
    Write-Host "    [FORCE MODE - Will wipe and recopy from Backup/]" -ForegroundColor Red
}
Write-Host ""

# ─────────────────────────────────────────────
# Step 0: Force mode - wipe existing setup
# ─────────────────────────────────────────────
if ($Force) {
    Write-Host "[0/9] Force mode: Wiping existing setup..." -ForegroundColor Red
    
    $WpDestDir = $HtdocsPath
    $WorkingDbDir = Join-Path $WorkingDir "database"
    $mysqlCmd = Join-Path $MysqlPath "mysql.exe"
    
    # Remove all files from htdocs
    if (Test-Path $WpDestDir) {
        Write-Host "  Removing all files from $WpDestDir ..." -ForegroundColor White
        Get-ChildItem -Path $WpDestDir -Recurse | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  htdocs cleared." -ForegroundColor Green
    } else {
        Write-Host "  htdocs directory not found, skipping." -ForegroundColor DarkGray
    }
    
    # Remove working database directory
    if (Test-Path $WorkingDbDir) {
        Write-Host "  Removing $WorkingDbDir ..." -ForegroundColor White
        Remove-Item $WorkingDbDir -Recurse -Force
        Write-Host "  Database working directory removed." -ForegroundColor Green
    } else {
        Write-Host "  Database directory not found, skipping." -ForegroundColor DarkGray
    }
    
    # Drop the database (need MySQL running for this)
    $mysqlRunning = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
    if ($mysqlRunning) {
        Write-Host "  Dropping database '$DbName'..." -ForegroundColor White
        $dropDbSql = "DROP DATABASE IF EXISTS ``$DbName``;"
        & $mysqlCmd -uroot -e $dropDbSql 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Database dropped." -ForegroundColor Green
        } else {
            Write-Host "  Could not drop database (may not exist)." -ForegroundColor DarkYellow
        }
        
        # Also drop the user to ensure clean state
        Write-Host "  Dropping user '$DbUser'..." -ForegroundColor White
        $dropUserSql = "DROP USER IF EXISTS '$DbUser'@'localhost';"
        & $mysqlCmd -uroot -e $dropUserSql 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  User dropped." -ForegroundColor Green
        } else {
            Write-Host "  Could not drop user (may not exist)." -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "  MySQL not running, skipping database cleanup." -ForegroundColor DarkYellow
        Write-Host "  Start MySQL and re-run with -Force if needed." -ForegroundColor DarkGray
    }
    
    Write-Host ""
}

# ─────────────────────────────────────────────
# Step 1: Pre-flight checks
# ─────────────────────────────────────────────
Write-Host "[1/9] Pre-flight checks..." -ForegroundColor Yellow

# Check XAMPP installation
if (-not (Test-Path $XamppPath)) {
    Write-Host ""
    Write-Host "  XAMPP not found at $XamppPath" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please install XAMPP first:" -ForegroundColor White
    Write-Host "    1. Download from https://www.apachefriends.org/download.html" -ForegroundColor DarkGray
    Write-Host "    2. Install to C:\xampp (default location)" -ForegroundColor DarkGray
    Write-Host "    3. Run this script again" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}
Write-Host "  XAMPP installation: OK ($XamppPath)" -ForegroundColor Green

# Check MySQL binary
$MysqlExe = Join-Path $MysqlPath "mysql.exe"
if (-not (Test-Path $MysqlExe)) {
    Write-Error "MySQL client not found at $MysqlExe"
    exit 1
}
Write-Host "  MySQL client: OK" -ForegroundColor Green

# Check PHP binary
$PhpExe = Join-Path $PhpPath "php.exe"
if (-not (Test-Path $PhpExe)) {
    Write-Error "PHP not found at $PhpExe"
    exit 1
}

# Get PHP version
$phpVersion = & $PhpExe -v 2>&1 | Select-Object -First 1
if ($phpVersion -match "PHP (\d+\.\d+)") {
    Write-Host "  PHP: OK (v$($Matches[1]))" -ForegroundColor Green
}

# Check if Apache is running
$apacheRunning = Get-Process -Name "httpd" -ErrorAction SilentlyContinue
if (-not $apacheRunning) {
    Write-Host "  Apache: NOT RUNNING" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please start Apache from XAMPP Control Panel before continuing." -ForegroundColor Yellow
    Write-Host "  Run: $XamppPath\xampp-control.exe" -ForegroundColor DarkGray
    Write-Host ""
    
    $response = Read-Host "  Press Enter after starting Apache, or 'q' to quit"
    if ($response -eq 'q') { exit 1 }
    
    $apacheRunning = Get-Process -Name "httpd" -ErrorAction SilentlyContinue
    if (-not $apacheRunning) {
        Write-Error "Apache is still not running. Please start it from XAMPP Control Panel."
        exit 1
    }
}
Write-Host "  Apache: RUNNING" -ForegroundColor Green

# Check if MySQL is running
$mysqlRunning = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
if (-not $mysqlRunning) {
    Write-Host "  MySQL: NOT RUNNING" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Please start MySQL from XAMPP Control Panel before continuing." -ForegroundColor Yellow
    Write-Host "  Run: $XamppPath\xampp-control.exe" -ForegroundColor DarkGray
    Write-Host ""
    
    $response = Read-Host "  Press Enter after starting MySQL, or 'q' to quit"
    if ($response -eq 'q') { exit 1 }
    
    $mysqlRunning = Get-Process -Name "mysqld" -ErrorAction SilentlyContinue
    if (-not $mysqlRunning) {
        Write-Error "MySQL is still not running. Please start it from XAMPP Control Panel."
        exit 1
    }
}
Write-Host "  MySQL: RUNNING" -ForegroundColor Green

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
# Step 2: Copy WordPress files to htdocs root
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "[2/9] Copying WordPress files to XAMPP htdocs root..." -ForegroundColor Yellow

$WpDestDir = $HtdocsPath

# Check if WordPress is already deployed (look for wp-config.php)
$wpConfigCheck = Join-Path $WpDestDir "wp-config.php"
if (Test-Path $wpConfigCheck) {
    Write-Host "  WordPress already deployed to $WpDestDir, skipping copy." -ForegroundColor DarkYellow
} else {
    Write-Host "  Copying Backup/wordpress/ -> $WpDestDir ..." -ForegroundColor White
    Write-Host "  (This may take a while for large uploads)" -ForegroundColor DarkGray

    # Use robocopy for better performance with large directory trees
    # Copy contents of wordpress folder to htdocs root using /E and wildcard file spec
    $robocopyArgs = @($BackupWpDir, $WpDestDir, "*.*", "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/MT:8")
    & robocopy @robocopyArgs | Out-Null

    # Robocopy exit codes: 0-7 are success, 8+ are errors
    if ($LASTEXITCODE -ge 8) {
        Write-Error "robocopy failed with exit code $LASTEXITCODE"
        exit 1
    }

    Write-Host "  WordPress files copied to htdocs root." -ForegroundColor Green
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

$WpConfigPath = Join-Path $WpDestDir "wp-config.php"

if (-not (Test-Path $WpConfigPath)) {
    Write-Error "wp-config.php not found at: $WpConfigPath (was the copy successful?)"
    exit 1
}

$config = Get-Content $WpConfigPath -Raw

# Track what we change
$changes = @()

# --- DB_HOST: localhost stays localhost for native setup ---
# (no change needed, but let's ensure it's localhost)

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
$replacement = "define('DB_HOST', 'localhost'); // Patched for native: was 'db' (Docker)"
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
    (Join-Path $WpDestDir "wp-content\advanced-cache.php"),
    (Join-Path $WpDestDir "wp-content\object-cache.php")
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

# XAMPP MySQL typically has root with no password by default
$mysqlCmd = Join-Path $MysqlPath "mysql.exe"

# Create database
$createDbSql = "CREATE DATABASE IF NOT EXISTS ``$DbName`` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
$result = & $mysqlCmd -uroot -e $createDbSql 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Note: If MySQL has a root password, you may need to configure it." -ForegroundColor Yellow
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

$result = & $mysqlCmd -uroot -e $createUserSql 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  User '$DbUser' created with privileges on '$DbName'." -ForegroundColor Green
} else {
    # User might already exist, try just granting privileges
    $grantSql = "GRANT ALL PRIVILEGES ON ``$DbName``.* TO '$DbUser'@'localhost'; FLUSH PRIVILEGES;"
    & $mysqlCmd -uroot -e $grantSql 2>&1 | Out-Null
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
$tableCount = & $mysqlCmd -uroot -N -e $checkTablesSql 2>&1

if ($tableCount -match "^\d+$" -and [int]$tableCount -gt 0) {
    Write-Host "  Database already has $tableCount tables, skipping import." -ForegroundColor DarkYellow
    Write-Host "  To re-import, drop the database first: mysql -uroot -e ""DROP DATABASE $DbName;""" -ForegroundColor DarkGray
} else {
    $startTime = Get-Date
    
    # Import the SQL file
    & $mysqlCmd -uroot $DbName -e "source $ImportSqlPath" 2>&1 | ForEach-Object {
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
Write-Host "[7/9] Replacing production URLs with localhost..." -ForegroundColor Yellow

$productionUrl = "https://waikatotainui.com"
$localUrl = "http://localhost"

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
    
    # Create a batch wrapper for easier use
    $batchContent = "@echo off`n`"$PhpExe`" `"$wpCliPath`" %*"
    Set-Content -Path $wpCliBat -Value $batchContent
    
    Write-Host "  WP-CLI installed to $wpCliPath" -ForegroundColor Green
}

# Run search-replace using WP-CLI
Write-Host "  Running search-replace: $productionUrl -> $localUrl" -ForegroundColor White

Push-Location $WpDestDir
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
    
    & $mysqlCmd -u"$DbUser" -p"$DbPassword" $DbName -e $gfSql 2>&1 | ForEach-Object {
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
    
    & $mysqlCmd -u"$DbUser" -p"$DbPassword" $DbName -e $webhookSql 2>&1 | ForEach-Object {
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
Write-Host "  WordPress:  http://localhost" -ForegroundColor White
Write-Host "  phpMyAdmin: http://localhost/phpmyadmin" -ForegroundColor White
Write-Host ""
Write-Host "  DB Name:     $DbName" -ForegroundColor DarkGray
Write-Host "  DB User:     $DbUser" -ForegroundColor DarkGray
Write-Host "  DB Password: $DbPassword" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  WordPress files: $WpDestDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Useful commands:" -ForegroundColor DarkGray
Write-Host "    Start XAMPP:  $XamppPath\xampp-control.exe" -ForegroundColor DarkGray
Write-Host "    WP-CLI:       php $wpCliPath --path=`"$WpDestDir`" <command>" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To reset:" -ForegroundColor DarkGray
Write-Host "    1. .\setup-native.ps1 -Force" -ForegroundColor DarkGray
Write-Host "       (or manually: mysql -uroot -e `"DROP DATABASE $DbName;`")" -ForegroundColor DarkGray
Write-Host ""
