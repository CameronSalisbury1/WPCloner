# WordPress Local Setup - Agent Guidelines

This repository contains PowerShell scripts for setting up a local WordPress development environment from production backups. This guide is designed for AI coding agents working in this codebase.

## Repository Overview

**Purpose**: Deploy production WordPress backups locally using Docker.

**Key Scripts**:
- `setup-docker.ps1` - **Primary script**: Docker-based setup using MySQL 8.0 + WordPress + phpMyAdmin
- `backup.ps1` - Download WordPress files from production SFTP server using WinSCP
- `query.ps1` - Run SQL queries against the local WordPress Docker MySQL instance

**Environment**: Windows-only PowerShell 5.1+ required

## Build/Test Commands

### Running Scripts

```powershell
# Primary setup (Docker)
.\setup-docker.ps1
.\setup-docker.ps1 -Force  # Wipe existing setup and start fresh

# Backup from production
.\backup.ps1              # Sync with deletions (mirror mode)
.\backup.ps1 -NoDelete    # Sync without deleting local files
.\backup.ps1 -DryRun      # Preview changes only

# Run SQL queries
.\query.ps1 "SELECT id, post_title FROM wp_posts LIMIT 10;"
.\query.ps1 -File .\my-query.sql
```

### Environment Configuration

Configuration is managed via `.env` file (not committed). Example structure:

```bash
DB_NAME=wordpress
DB_USER=wordpress
DB_PASSWORD=wordpress
DB_ROOT_PASSWORD=rootpassword
WORDPRESS_PORT=80
PHPMYADMIN_PORT=8081
DISABLE_GF_NOTIFICATIONS=true
GF_WEBHOOK_REDIRECT_HOST=api-uat.waikatotainui.com
GF_WEBHOOK_REDIRECT_HOST_IDS=1,2,3
DISALLOW_FILE_MODS=false
```

### Docker Commands

```bash
docker compose up -d                    # Start containers
docker compose down                     # Stop containers
docker compose down -v                  # Stop and remove DB volume (full reset)
docker compose logs -f db              # Watch DB import progress
docker compose logs -f wordpress       # Watch WordPress logs
```

### Testing Individual Components

**Test database connectivity**:
```powershell
docker compose exec -T db mysql -u<DB_USER> -p<DB_PASSWORD> -e "SELECT 1;"
```

**Test WordPress availability**:
- `http://localhost` (default, port 80)
- `http://localhost:<WORDPRESS_PORT>` if non-default port

**Test phpMyAdmin**:
- `http://localhost:8081`

## Code Style Guidelines

### PowerShell Style

**Script headers**: Always include `#Requires -Version 5.1` and comprehensive `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE` blocks

**Error handling**: Always set `$ErrorActionPreference = "Stop"` at script start

**Variables**:
- Use PascalCase for variables: `$BackupDir`, `$WpConfigPath`, `$DbName`
- Use descriptive names that indicate purpose
- Declare path variables at the top of sections

**Output formatting**:
```powershell
Write-Host "[1/10] Step description..." -ForegroundColor Yellow      # Step headers
Write-Host "  Detail message" -ForegroundColor White                # Details
Write-Host "  Success message" -ForegroundColor Green               # Success
Write-Host "  Warning message" -ForegroundColor DarkYellow          # Warnings
Write-Host "  Error message" -ForegroundColor Red                   # Errors
Write-Host "  Info/debug message" -ForegroundColor DarkGray         # Debug info
```

**Progress indicators**: Use step numbers (e.g., `[1/10]`, `[2/10]`) for multi-step operations

**Separators**: Use visual separators for readability:
```powershell
# ─────────────────────────────────────────────
# Section Name
# ─────────────────────────────────────────────
```

**File operations**:
- Use `robocopy` for large directory copies with `/E /NFL /NDL /NJH /NJS /MT:8` flags
- Use stream-based copying for large files: `[System.IO.File]::OpenRead()` / `CopyTo()`
- Always check `$LASTEXITCODE` after external commands
- Handle robocopy exit codes correctly (0-7 = success, 8+ = error)

**Command execution**:
```powershell
# Capture output and check exit code
$result = & $command @args 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Command failed"
}

# Filter unwanted output
$result | ForEach-Object {
    if ($_ -notmatch "Warning.*password") {
        Write-Host "  $_" -ForegroundColor DarkGray
    }
}
```

**String replacements**: Use `.Contains()` checks before `.Replace()` to track changes made

### Comments

- Use inline comments sparingly, prefer self-documenting code
- Add comments for business logic: `// Patched for local: was 'ndshewxtpp'`
- Explain "why" not "what" for non-obvious operations
- Document workarounds and fixes with context

### File Paths

- Always use `Join-Path` for path construction
- Use absolute paths derived from `$ScriptDir` and `$WorkingDir`
- Escape paths in SQL/shell commands: Use backticks for MySQL identifiers

### Configuration Management

**Environment variables**: Load from `.env` file at script start:
```powershell
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
```

**Boolean from env**: `$DisableGfNotifications = $EnvVars["DISABLE_GF_NOTIFICATIONS"] -eq "true"`

### Security

- **Never commit credentials**: Add sensitive config files to `.gitignore`
- Escape passwords when passing to commands: `[Uri]::EscapeDataString($password)`
- Clean up temporary files containing credentials in `finally` blocks
- Redact passwords in output: `DB_PASSWORD: <redacted> -> $DbPassword`

### Git Commit Style

Based on repository history:
- Use imperative mood: "Add HMAC signing", "Fix sql", "Change wp version"
- Keep messages short and descriptive
- No prefixes or emoji
- Focus on what changed, not why (details go in commit body if needed)

## Project-Specific Patterns

### WordPress Configuration Patching

When modifying `wp-config.php`:
1. Read entire file from `Backup/` as raw string (never modify `Backup/`)
2. Apply patches in memory using regex replacements
3. Write patched version to a temp file
4. Inject into the container via `docker cp`
5. Report all changes to user

**Patches applied**:
- `DB_HOST`: any value → `db` (Docker service name)
- Database credentials from production → `.env` values
- `FORCE_SSL_ADMIN`: `true` → `false`
- `WP_CACHE`: `true` → `false`
- `WP_REDIS_DISABLED`: `false` → `true`
- `DISALLOW_FILE_MODS`: set from `.env` value
- `WP_DEBUG`: any → `true`
- `WP_DEBUG_LOG`: any → `true`
- `WP_MEMORY_LIMIT`: any → `2048M`
- `WP_MAX_MEMORY_LIMIT`: any → `2048M`
- Remove `advanced-cache.php` and `object-cache.php` drop-ins
- Append Gravity Flow webhook HMAC signing filter

### Database Operations

**Import workflow**:
1. Create `import.sql` with `USE <database>;` statement prepended
2. Import via MySQL `docker-entrypoint-initdb.d` auto-import (`.sql` extension required)
3. Wait for completion: poll with `SELECT 1 FROM wp_options LIMIT 1;` via TCP (`-h 127.0.0.1`)
   - TCP only becomes available after import finishes and MySQL restarts in normal mode
4. Verify by checking `wp_options` table exists

**URL replacement**:
- Use WP-CLI `search-replace` command (installed inside the container if absent)
- Production URL: `https://waikatotainui.com`
- Local URL: `http://localhost` (or `http://localhost:<PORT>` if non-default)
- Always use `--all-tables --report-changed-only` flags

### Requests.php Timeout Patch

Patch `wp-includes/Requests/src/Requests.php` to increase `timeout` and `connect_timeout` to 120s:
- Read from `Backup/` (never modify `Backup/`)
- Write patched version to temp file
- Inject into container via `docker cp`

### Gravity Forms Configuration

**Disable notifications** (optional, via `.env`):
```sql
UPDATE wp_gf_form_meta
SET notifications = REPLACE(notifications, '"isActive":true', '"isActive":false')
WHERE notifications LIKE '%isActive%';
```

**Redirect webhooks** (optional, via `.env`):
- If `GF_WEBHOOK_REDIRECT_HOST_IDS` is set (comma-separated form IDs): redirects make.com URLs only for those forms; disables **all** feeds on any other form that has at least one make.com feed
- If `GF_WEBHOOK_REDIRECT_HOST_IDS` is not set: redirects all make.com URLs (legacy behaviour)

```sql
-- Redirect for specified form IDs
UPDATE wp_gf_addon_feed
SET meta = REPLACE(meta, 'hook.us1.make.com', '<GF_WEBHOOK_REDIRECT_HOST>')
WHERE meta LIKE '%hook.us1.make.com%'
AND form_id IN (<GF_WEBHOOK_REDIRECT_HOST_IDS>);

-- Disable ALL feeds on any form that has at least one make.com feed (and isn't in the allowed list)
UPDATE wp_gf_addon_feed
SET is_active = 0
WHERE form_id IN (
    SELECT form_id FROM (
        SELECT DISTINCT form_id FROM wp_gf_addon_feed
        WHERE meta LIKE '%hook.us1.make.com%'
        AND form_id NOT IN (<GF_WEBHOOK_REDIRECT_HOST_IDS>)
    ) AS t
);
```

**HMAC signing**: Automatically appended to `wp-config.php` via heredoc string

## Common Pitfalls

1. **Robocopy exit codes**: Exit codes 0-7 are success, not just 0
2. **MySQL passwords in output**: Filter out password warnings with regex
3. **Large file operations**: Use streaming I/O, not `Get-Content`/`Set-Content`
4. **Docker timing**: Database import can take 20+ minutes; poll via TCP (`-h 127.0.0.1`) not socket
5. **Path separators**: Use `Join-Path`, not manual concatenation with `\`
6. **Script location**: Calculate `$WorkingDir` relative to script, not CWD
7. **DB polling method**: Use `-h 127.0.0.1` to force TCP — MySQL runs with `--skip-networking` during import so socket connections will be refused until the import completes

## File Structure

```
wp-setup/
├── .env                      # Environment config (gitignored)
├── .gitignore               # Excludes Backup/, uploads/, database/, credentials
├── backup.ps1               # SFTP download script
├── query.ps1                # SQL query helper against local Docker MySQL
├── backup-config.json       # SFTP credentials (gitignored)
├── backup.log               # WinSCP transfer log (gitignored)
├── docker-compose.yml       # Docker services definition (MySQL 8.0 + WordPress + phpMyAdmin)
├── setup-docker.ps1         # Primary Docker setup script
└── CLAUDE.md                # This file

Working directories (created by scripts, gitignored):
├── Backup/                  # Production files downloaded by backup.ps1
│   ├── wordpress/          # Production WordPress files
│   └── database/           # Production database dump
├── uploads/                 # wp-content/uploads bind-mounted into Docker
└── database/               # Database with USE statement (working copy, auto-imported)
```

## External Dependencies

- **Docker Desktop**: Required for running MySQL, WordPress, and phpMyAdmin containers
- **WinSCP**: SFTP client for backup.ps1 (auto-installs via winget)
- **WP-CLI**: WordPress command-line tool (auto-downloads inside container if absent)

## Additional Notes

- Scripts are idempotent: can be run multiple times safely
- Use `-Force` flag on `setup-docker.ps1` to wipe uploads/, database/, and Docker volumes and start fresh
- All scripts assume Windows environment with PowerShell 5.1+
- Production server: `waikatotainui.com` (Gravity Flow WordPress site)
- `Backup/` is read-only: scripts read from it but never modify it; all patches go to temp files and are injected via `docker cp`
