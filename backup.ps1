#Requires -Version 5.1
<#
.SYNOPSIS
    Syncs WordPress files from remote SFTP server to local Backup/wordpress/ directory.

.DESCRIPTION
    Uses WinSCP to mirror the remote WordPress installation to the local backup.
    Only downloads new/changed files and optionally deletes local files that 
    no longer exist on the server.

.PARAMETER ConfigFile
    Path to a config file with SFTP credentials. If not specified, uses backup-config.json
    in the same directory as this script.

.PARAMETER NoDelete
    If specified, does not delete local files that are missing from the server.
    By default, deletions ARE synced (mirror mode).

.PARAMETER DryRun
    Preview what would be transferred without making changes.

.EXAMPLE
    .\backup.ps1                    # Sync with deletions
    .\backup.ps1 -NoDelete          # Sync without deleting local files
    .\backup.ps1 -DryRun            # Preview only
#>

param(
    [string]$ConfigFile,
    [switch]$NoDelete,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WorkingDir = Split-Path -Parent $ScriptDir  # Parent directory (C:\repos\Tainui\WP)

# ─────────────────────────────────────────────
# Check/Install WinSCP
# ─────────────────────────────────────────────

function Find-WinSCP {
    # Check common installation paths
    $paths = @(
        "${env:ProgramFiles}\WinSCP\WinSCP.com",
        "${env:ProgramFiles(x86)}\WinSCP\WinSCP.com",
        "${env:LOCALAPPDATA}\Programs\WinSCP\WinSCP.com"
    )
    
    foreach ($path in $paths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Try PATH
    $inPath = Get-Command "WinSCP.com" -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }
    
    return $null
}

$WinSCPPath = Find-WinSCP

if (-not $WinSCPPath) {
    Write-Host ""
    Write-Host "WinSCP is not installed." -ForegroundColor Yellow
    Write-Host ""
    $install = Read-Host "Install WinSCP via winget? (Y/n)"
    
    if ($install -eq "" -or $install -match "^[Yy]") {
        Write-Host "Installing WinSCP..." -ForegroundColor Cyan
        winget install WinSCP.WinSCP --silent --accept-package-agreements --accept-source-agreements
        
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to install WinSCP. Please install manually from https://winscp.net/"
            exit 1
        }
        
        # Find it again after install
        $WinSCPPath = Find-WinSCP
        if (-not $WinSCPPath) {
            Write-Host ""
            Write-Host "WinSCP installed but not found in expected paths." -ForegroundColor Yellow
            Write-Host "Please restart your terminal and try again, or specify the path manually." -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "WinSCP installed successfully." -ForegroundColor Green
    } else {
        Write-Host "WinSCP is required. Please install from https://winscp.net/" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "=== WordPress SFTP Backup ===" -ForegroundColor Cyan
Write-Host "Using WinSCP: $WinSCPPath" -ForegroundColor DarkGray
Write-Host ""

# ─────────────────────────────────────────────
# Load or create configuration
# ─────────────────────────────────────────────

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $ScriptDir "backup-config.json"
}

$config = $null

if (Test-Path $ConfigFile) {
    Write-Host "Loading config from: $ConfigFile" -ForegroundColor DarkGray
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
} else {
    Write-Host "No config file found. Let's create one." -ForegroundColor Yellow
    Write-Host ""
    
    $host_ = Read-Host "SFTP Host/IP"
    $port = Read-Host "SFTP Port [22]"
    if (-not $port) { $port = "22" }
    $username = Read-Host "SFTP Username"
    $securePassword = Read-Host "SFTP Password" -AsSecureString
    $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
    
    # Fixed remote path for this WordPress installation
    $remotePath = "/public_html/apps/wordpress"
    
    $config = @{
        host = $host_
        port = [int]$port
        username = $username
        password = $password
        remotePath = $remotePath
    }
    
    # Save config
    $config | ConvertTo-Json | Set-Content $ConfigFile
    Write-Host ""
    Write-Host "Config saved to: $ConfigFile" -ForegroundColor Green
    
    # Add to .gitignore if it exists
    $gitignorePath = Join-Path $ScriptDir ".gitignore"
    if (Test-Path $gitignorePath) {
        $gitignore = Get-Content $gitignorePath -Raw
        if (-not $gitignore.Contains("backup-config.json")) {
            Add-Content $gitignorePath "`nbackup-config.json"
            Write-Host "Added backup-config.json to .gitignore" -ForegroundColor DarkGray
        }
    } else {
        Set-Content $gitignorePath "backup-config.json`n"
        Write-Host "Created .gitignore with backup-config.json" -ForegroundColor DarkGray
    }
    
    # Convert hashtable to object for consistent access
    $config = [PSCustomObject]$config
}

# ─────────────────────────────────────────────
# Get password if not saved
# ─────────────────────────────────────────────

$password = $config.password
if (-not $password) {
    $securePassword = Read-Host "SFTP Password for $($config.username)@$($config.host)" -AsSecureString
    $password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    )
}

# ─────────────────────────────────────────────
# Build WinSCP script
# ─────────────────────────────────────────────

$localPath = Join-Path $WorkingDir "Backup\wordpress"

# Ensure local directory exists
if (-not (Test-Path $localPath)) {
    New-Item -ItemType Directory -Path $localPath -Force | Out-Null
}

# Escape password for WinSCP (special chars need URL encoding)
$escapedPassword = [Uri]::EscapeDataString($password)

# Build synchronize options
$syncOptions = "-mirror"
if ($NoDelete) {
    $syncOptions = ""
}
if ($DryRun) {
    $syncOptions += " -preview"
}

# WinSCP script content
$winscpScript = @"
option batch abort
option confirm off
open sftp://$($config.username):$escapedPassword@$($config.host):$($config.port)/ -hostkey=*
synchronize local $syncOptions "$localPath" "$($config.remotePath)"
exit
"@

# Write to temp file (WinSCP reads script from file)
$scriptFile = Join-Path $env:TEMP "winscp_backup_$(Get-Random).txt"
Set-Content -Path $scriptFile -Value $winscpScript

# ─────────────────────────────────────────────
# Run WinSCP
# ─────────────────────────────────────────────

Write-Host "Syncing from: $($config.username)@$($config.host):$($config.remotePath)" -ForegroundColor White
Write-Host "          to: $localPath" -ForegroundColor White
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN] No files will be transferred" -ForegroundColor Yellow
    Write-Host ""
}

if ($NoDelete) {
    Write-Host "Mode: Sync (new/changed files only, no deletions)" -ForegroundColor DarkGray
} else {
    Write-Host "Mode: Mirror (new/changed files + delete removed files)" -ForegroundColor DarkGray
}
Write-Host ""

try {
    & $WinSCPPath /script="$scriptFile" /log="$ScriptDir\backup.log"
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        Write-Host ""
        Write-Host "=== Backup Complete ===" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "WinSCP exited with code $exitCode. Check backup.log for details." -ForegroundColor Red
    }
} finally {
    # Clean up script file (contains password)
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Log file: $ScriptDir\backup.log" -ForegroundColor DarkGray
Write-Host ""
