<#
.SYNOPSIS
    Non-interactive Windows PowerShell launcher for installing Tryton on WSL (Ubuntu/Debian).

.DESCRIPTION
    Supports both one-line remote execution:
        irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex

    And parameterized local or remote execution (including testing in a throwaway WSL distro):
        .\install-wsl.ps1 -Distro Ubuntu-Test -LocalScript .\install.sh
        .\install-wsl.ps1 -TrytonSeries latest

    When invoked via `irm ... | iex`, you can override settings with environment variables
    before piping:
        $env:TRYTON_SERIES = "latest"; irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$Distro = $env:WSL_DISTRO,
    [string]$TrytonSeries = $(if ($env:TRYTON_SERIES) { $env:TRYTON_SERIES } else { "7.2" }),
    [string]$InstallDir = $env:INSTALL_DIR,
    [string]$DataDir = $env:DATA_DIR,
    [int]$TrytonPort = $(if ($env:TRYTON_PORT) { [int]$env:TRYTON_PORT } else { 8000 }),
    [string]$PgHost = $env:PG_HOST,
    [Nullable[int]]$PgPort = $(if ($env:PG_PORT) { [int]$env:PG_PORT } else { $null }),
    [string]$PgUser = $(if ($env:PG_USER) { $env:PG_USER } else { "tryton" }),
    [string]$PgDb = $(if ($env:PG_DB) { $env:PG_DB } else { "tryton" }),
    [string]$PgPassword = $env:PG_PASSWORD,
    [string]$TrytonAdminEmail = $env:TRYTON_ADMIN_EMAIL,
    [string]$TrytonAdminPassword = $env:TRYTON_ADMIN_PASSWORD,
    [string]$TrytonLang = $env:TRYTON_LANG,
    [string]$TrytonExtraModules = $env:TRYTON_EXTRA_MODULES,
    [string]$RepoUrl = "https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install.sh",
    [string]$LocalScript = $env:LOCAL_INSTALL_SCRIPT,
    [switch]$SkipApt,
    [switch]$DryRun,
    [switch]$StartServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info([string]$Msg) { Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host "[ OK ] $Msg" -ForegroundColor Green }
function Write-Err([string]$Msg)  { Write-Host "[ERR ] $Msg" -ForegroundColor Red }

# 1. Verify WSL is installed and has at least one distro
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Err "WSL is not installed on this Windows machine."
    Write-Host "Install WSL + Ubuntu from an elevated PowerShell prompt, reboot, then re-run:"
    Write-Host "  wsl --install -d Ubuntu" -ForegroundColor Yellow
    exit 1
}

$rawDistros = (& wsl.exe --list --quiet 2>$null)
$distros = @($rawDistros | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" })
if ($distros.Count -eq 0) {
    Write-Err "No WSL Linux distributions are installed."
    Write-Host "Install Ubuntu first, complete initial user setup, then re-run:"
    Write-Host "  wsl --install -d Ubuntu" -ForegroundColor Yellow
    exit 1
}

if ($Distro) {
    if ($distros -notcontains $Distro) {
        Write-Err "WSL distro '$Distro' not found. Available distros: $($distros -join ', ')"
        exit 1
    }
    Write-Info "Using WSL distro: $Distro"
} else {
    Write-Info "Using default WSL distro: $($distros[0])"
}

# 2. Validate key parameters before forwarding to WSL
if ($TrytonSeries -ne "latest" -and $TrytonSeries -notmatch '^\d+\.\d+$') {
    Write-Err "Invalid TrytonSeries '$TrytonSeries'. Expected 'latest' or 'X.Y' (e.g. 7.2)."
    exit 1
}
if ($TrytonPort -lt 1024 -or $TrytonPort -gt 65535) {
    Write-Err "Invalid TrytonPort '$TrytonPort'. Must be between 1024 and 65535."
    exit 1
}
if ($null -ne $PgPort -and ($PgPort -lt 1 -or $PgPort -gt 65535)) {
    Write-Err "Invalid PgPort '$PgPort'. Must be between 1 and 65535."
    exit 1
}
if ($PgUser -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
    Write-Err "Invalid PgUser '$PgUser'."
    exit 1
}
if ($PgDb -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
    Write-Err "Invalid PgDb '$PgDb'."
    exit 1
}
if ($PgHost -and $PgHost -notmatch '^[a-zA-Z0-9._:-]+$') {
    Write-Err "Invalid PgHost '$PgHost'."
    exit 1
}
if ($PgHost -and -not $PgPassword) {
    Write-Err "PgPassword is required when PgHost is specified."
    exit 1
}

# 3. Build environment arguments passed safely to WSL `env`
$envArgs = @(
    "TRYTON_SERIES=$TrytonSeries",
    "TRYTON_PORT=$TrytonPort",
    "PG_USER=$PgUser",
    "PG_DB=$PgDb"
)
if ($null -ne $PgPort)    { $envArgs += "PG_PORT=$PgPort" }
if ($InstallDir)          { $envArgs += "INSTALL_DIR=$InstallDir" }
if ($DataDir)             { $envArgs += "DATA_DIR=$DataDir" }
if ($PgHost)              { $envArgs += "PG_HOST=$PgHost" }
if ($PgPassword)          { $envArgs += "PG_PASSWORD=$PgPassword" }
if ($TrytonAdminEmail)    { $envArgs += "TRYTON_ADMIN_EMAIL=$TrytonAdminEmail" }
if ($TrytonAdminPassword) { $envArgs += "TRYTON_ADMIN_PASSWORD=$TrytonAdminPassword" }
if ($TrytonLang)          { $envArgs += "TRYTON_LANG=$TrytonLang" }
if ($TrytonExtraModules)  { $envArgs += "TRYTON_EXTRA_MODULES=$TrytonExtraModules" }
if ($SkipApt -or $env:SKIP_APT -eq "1") { $envArgs += "SKIP_APT=1" }
if ($DryRun  -or $env:DRY_RUN  -eq "1") { $envArgs += "DRY_RUN=1" }

$wslPrefix = @()
if ($Distro) {
    $wslPrefix += @("-d", $Distro)
}

# 4. Obtain install.sh content (from local file for testing, or over HTTPS from GitHub)
if ($LocalScript) {
    if (-not (Test-Path -LiteralPath $LocalScript)) {
        Write-Err "LocalScript not found: $LocalScript"
        exit 1
    }
    Write-Info "Running local installer script inside WSL: $LocalScript"
    $scriptContent = (Get-Content -LiteralPath $LocalScript -Raw) -replace "`r`n", "`n"
} else {
    if ($RepoUrl -notmatch '^https://') {
        Write-Err "RepoUrl must use HTTPS."
        exit 1
    }
    Write-Info "Downloading installer from $RepoUrl..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $scriptContent = (Invoke-RestMethod -Uri $RepoUrl) -replace "`r`n", "`n"
}

# 5. Execute install.sh inside WSL (piped via stdin so paths and CRLF never break)
$wslArgs = $wslPrefix + @("--", "env") + $envArgs + @("bash", "-s")
$scriptContent | & wsl.exe @wslArgs
if ($LASTEXITCODE -ne 0) {
    Write-Err "Tryton installation inside WSL failed (exit code $LASTEXITCODE)."
    exit $LASTEXITCODE
}

Write-Ok "WSL Tryton installation finished!"

if ($StartServer -and -not $DryRun) {
    $targetDir = if ($InstallDir) { $InstallDir } else { '$HOME/tryton' }
    Write-Info "Starting Tryton server in WSL (open http://localhost:$TrytonPort in your browser)..."
    $startArgs = $wslPrefix + @("--", "bash", "-lc", "exec `"$targetDir/start.sh`"")
    & wsl.exe @startArgs
}
