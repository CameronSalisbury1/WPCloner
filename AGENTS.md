# WordPress Local Setup - Agent Guidelines

This repository contains PowerShell scripts for setting up a local WordPress development environment from production backups. This guide is designed for AI coding agents working in this codebase.

## Repository Overview

**Purpose**: Deploy production WordPress backups locally using either Docker (legacy) or XAMPP (native Windows).

**Key Scripts**:
- `setup-native.ps1` - **Primary script**: Native Windows setup using XAMPP (replaces Docker version)
- `setup.ps1` - Legacy Docker-based setup (deprecated)
- `backup.ps1` - Download WordPress files from production SFTP server using WinSCP

**Environment**: Windows-only PowerShell 5.1+ required

## Build/Test Commands

### Running Scripts

```powershell
# Primary setup (native XAMPP)
.\setup-native.ps1
.\setup-native.ps1 -Force  # Wipe existing setup and start fresh

# Legacy Docker setup (deprecated)
.\setup.ps1

# Backup from production
.\backup.ps1              # Sync with deletions (mirror mode)
.\backup.ps1 -NoDelete    # Sync without deleting local files
.\backup.ps1 -DryRun      # Preview changes only
```

### Environment Configuration

Configuration is managed via `.env` file (not committed). Example structure:

```bash
DB_NAME=wordpress
DB_USER=wordpress
DB_PASSWORD=wordpress
DB_ROOT_PASSWORD=rootpassword
WORDPRESS_PORT=8080
PHPMYADMIN_PORT=8081
DISABLE_GF_NOTIFICATIONS=true
GF_WEBHOOK_REDIRECT_HOST=api-uat.waikatotainui.com
DISALLOW_FILE_MODS=false
```

### Docker Commands (Legacy)

```bash
docker compose up -d                    # Start containers
docker compose down                     # Stop containers
docker compose down -v                  # Stop and remove DB volume (full reset)
docker compose logs -f db              # Watch DB import progress
docker compose logs -f wordpress       # Watch WordPress logs
```

### XAMPP Commands (Native)

```bash
# Start/stop services via XAMPP Control Panel
C:\xampp\xampp-control.exe

# WP-CLI usage
php %USERPROFILE%\.wp-cli\wp-cli.phar --path="C:\xampp\htdocs" <command>

# Direct MySQL access
C:\xampp\mysql\bin\mysql.exe -uroot -e "USE wordpress; SELECT * FROM wp_users;"
```

### Testing Individual Components

**Test database connectivity**:
```powershell
# Native XAMPP
C:\xampp\mysql\bin\mysql.exe -u<DB_USER> -p<DB_PASSWORD> -e "SELECT 1;"

# Docker
docker compose exec -T db mariadb -u<DB_USER> -p<DB_PASSWORD> -e "SELECT 1;"
```

**Test WordPress availability**:
- Native: `http://localhost`
- Docker: `http://localhost:8080`

**Test phpMyAdmin**:
- Native: `http://localhost/phpmyadmin`
- Docker: `http://localhost:8081`

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
Write-Host "[1/9] Step description..." -ForegroundColor Yellow      # Step headers
Write-Host "  Detail message" -ForegroundColor White                # Details
Write-Host "  Success message" -ForegroundColor Green               # Success
Write-Host "  Warning message" -ForegroundColor DarkYellow          # Warnings
Write-Host "  Error message" -ForegroundColor Red                   # Errors
Write-Host "  Info/debug message" -ForegroundColor DarkGray         # Debug info
```

**Progress indicators**: Use step numbers (e.g., `[1/9]`, `[2/9]`) for multi-step operations

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
1. Read entire file as raw string
2. Track changes in an array
3. Use exact string matching with `.Contains()` before `.Replace()`
4. Add inline comments explaining changes
5. Report all changes to user
6. Handle both Docker and native configurations differently

**Docker-specific patches**:
- `DB_HOST`: `localhost` → `db`

**Native-specific patches**:
- `DB_HOST`: `db` → `localhost`

**Common patches**:
- Database credentials from production → `.env` values
- `FORCE_SSL_ADMIN`: `true` → `false`
- `WP_CACHE`: `true` → `false`
- `WP_REDIS_DISABLED`: `false` → `true`
- Remove `advanced-cache.php` and `object-cache.php` drop-ins

### Database Operations

**Import workflow**:
1. Create `import.sql` with `USE <database>;` statement prepended
2. Import using either Docker exec or native MySQL client
3. Wait for completion (Docker: poll with `SELECT 1;`, Native: synchronous)
4. Verify table count before re-importing

**URL replacement**:
- Use WP-CLI `search-replace` command
- Production URL: `https://waikatotainui.com`
- Local URL: `http://localhost` (native) or `http://localhost:<PORT>` (Docker)
- Always use `--all-tables --report-changed-only` flags

### Gravity Forms Configuration

**Disable notifications** (optional, via `.env`):
```sql
UPDATE wp_gf_form_meta 
SET notifications = REPLACE(notifications, '"isActive":true', '"isActive":false') 
WHERE notifications LIKE '%isActive%';
```

**Redirect webhooks** (optional, via `.env`):
```sql
UPDATE wp_gf_addon_feed 
SET meta = REPLACE(meta, 'hook.us1.make.com', '<GF_WEBHOOK_REDIRECT_HOST>') 
WHERE meta LIKE '%hook.us1.make.com%';
```

**HMAC signing**: Automatically injected into `wp-config.php` via heredoc string

## Common Pitfalls

1. **Robocopy exit codes**: Exit codes 0-7 are success, not just 0
2. **MySQL passwords in output**: Filter out password warnings with regex
3. **Large file operations**: Use streaming I/O, not `Get-Content`/`Set-Content`
4. **Docker timing**: Database import can take 20+ minutes, implement proper waiting
5. **Path separators**: Use `Join-Path`, not manual concatenation with `\`
6. **Script location**: Calculate `$WorkingDir` relative to script, not CWD

## File Structure

```
wp-setup/
├── .env                      # Environment config (gitignored)
├── .gitignore               # Excludes Backup/, wordpress/, database/, credentials
├── backup.ps1               # SFTP download script
├── backup-config.json       # SFTP credentials (gitignored)
├── backup.log               # WinSCP transfer log (gitignored)
├── docker-compose.yml       # Docker services definition
├── setup.ps1                # Legacy Docker setup
├── setup-native.ps1         # Primary XAMPP setup
└── AGENTS.md               # This file

Working directories (created by scripts, gitignored):
├── Backup/                  # Production files downloaded by backup.ps1
│   ├── wordpress/          # Production WordPress files
│   └── database/           # Production database dump
├── wordpress/              # Working copy for Docker
└── database/               # Database with USE statement for Docker
```

## External Dependencies

- **XAMPP**: Apache, PHP 8.2, MySQL/MariaDB (for native setup)
- **Docker Desktop**: Required for legacy setup
- **WinSCP**: SFTP client for backup.ps1 (auto-installs via winget)
- **WP-CLI**: WordPress command-line tool (auto-downloads to `~/.wp-cli/`)

## Additional Notes

- The `setup-native.ps1` script is the current recommended approach
- `setup.ps1` (Docker) is maintained for compatibility but not actively developed
- Scripts are idempotent: can be run multiple times safely
- Use `-Force` flag on `setup-native.ps1` to reset completely
- All scripts assume Windows environment with PowerShell 5.1+
- Production server: `waikatotainui.com` (Gravity Flow WordPress site)
