#Requires -Version 5.1
<#
.SYNOPSIS
    Run a SQL query against the local WordPress Docker MySQL instance.

.DESCRIPTION
    Reads credentials from the .env file and executes the given SQL query
    via docker exec against the running DB container (default: wp-setup-db-1,
    or override with DB_CONTAINER in .env).

.PARAMETER Query
    The SQL query string to execute.

.PARAMETER File
    Path to a .sql file to execute instead of an inline query.

.EXAMPLE
    .\query.ps1 "SELECT id, title FROM wp_gf_form WHERE id IN (28, 31);"

.EXAMPLE
    .\query.ps1 -File .\my-query.sql
#>
param(
    [Parameter(Position = 0)]
    [string]$Query,

    [Parameter()]
    [string]$File
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ─────────────────────────────────────────────
# Load .env
# ─────────────────────────────────────────────
$EnvFile = Join-Path $ScriptDir ".env"
if (-not (Test-Path $EnvFile)) {
    Write-Error ".env file not found at $EnvFile"
    exit 1
}

$Env = @{}
Get-Content $EnvFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#")) {
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $Env[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
}

$DbUser     = $Env["DB_USER"]
$DbPassword = $Env["DB_PASSWORD"]
$DbName     = $Env["DB_NAME"]

if (-not $DbUser -or -not $DbPassword -or -not $DbName) {
    Write-Error "Missing DB_USER, DB_PASSWORD, or DB_NAME in .env"
    exit 1
}

# ─────────────────────────────────────────────
# Build and run query
# ─────────────────────────────────────────────
$PrevPref = $ErrorActionPreference
$ErrorActionPreference = "Continue"

if ($File) {
    $FilePath = Resolve-Path $File
    Write-Host "Running query from file: $FilePath" -ForegroundColor DarkGray
    $Sql = Get-Content $FilePath -Raw
}
elseif ($Query) {
    Write-Host "Query: $Query" -ForegroundColor DarkGray
    $Sql = $Query
}
else {
    Write-Error "Provide a query string or -File path."
    exit 1
}

$ContainerName = if ($Env["DB_CONTAINER"]) { $Env["DB_CONTAINER"] } else { "wp-setup-db-1" }

$Sql | docker exec -i "$ContainerName" mysql --silent -u"$DbUser" -p"$DbPassword" "$DbName" 2>&1 `
    | Where-Object { $_ -notmatch "Using a password on the command line" }

$ErrorActionPreference = $PrevPref
