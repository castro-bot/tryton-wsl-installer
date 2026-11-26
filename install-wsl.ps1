<#
.SYNOPSIS
    Non-interactive Windows PowerShell launcher for installing Tryton on WSL (Ubuntu/Debian).

.DESCRIPTION
    Automatically installs WSL (if not yet enabled) and the target Ubuntu/Debian distro
    (no manual `wsl --install` or Linux username/password popup required).

    Quick start (default Tryton 7.2):
        irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex

    Install a specific Ubuntu version automatically (e.g. Ubuntu-22.04, Ubuntu-24.04, Ubuntu-26.04):
        $env:WSL_DISTRO = "Ubuntu-22.04"; $env:TRYTON_PORT = "8001"; irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex

    Install a custom-named throwaway distro from a chosen Ubuntu version:
        $env:WSL_BASE_DISTRO = "Ubuntu-24.04"; $env:WSL_DISTRO = "Ubuntu-Tryton-Test"; $env:TRYTON_PORT = "8001"; irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex

    Switch to latest Tryton release:
        $env:TRYTON_SERIES = "latest"; irm https://raw.githubusercontent.com/castro-bot/tryton-wsl-installer/main/install-wsl.ps1 | iex
#>

[CmdletBinding()]
param(
    # Change this default if you want a different Ubuntu release installed on fresh machines
    [string]$BaseDistro = $(if ($env:WSL_BASE_DISTRO) { $env:WSL_BASE_DISTRO } else { "Ubuntu-24.04" }),
    # Target WSL distro name (auto-installed if missing; if empty, uses existing default distro or installs $BaseDistro)
    [string]$Distro = $env:WSL_DISTRO,
    # Linux username created automatically when provisioning a brand-new distro
    [string]$LinuxUser = $env:WSL_USER,

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
function Write-Warn([string]$Msg) { Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err([string]$Msg)  { Write-Host "[ERR ] $Msg" -ForegroundColor Red }

function Get-WslExePath {
    $modern = Join-Path $env:ProgramFiles "WSL\wsl.exe"
    if (Test-Path -LiteralPath $modern) {
        return $modern
    }
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    return $null
}

function Invoke-WslCapture([string[]]$Arguments) {
    $wslExe = Get-WslExePath
    # PowerShell 5.1 throws NativeCommandError on stderr redirects when ErrorActionPreference=Stop.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = (& $wslExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
    $lines = @($output | ForEach-Object { ("$_" -replace "`0", "").TrimEnd() })
    return [PSCustomObject]@{
        ExitCode = $exitCode
        Lines    = $lines
        Text     = ($lines -join "`n").Trim()
    }
}

function Invoke-WslStream([string[]]$Arguments, [string]$StdinText = $null) {
    $wslExe = Get-WslExePath
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($null -ne $StdinText) {
            $StdinText | & $wslExe @Arguments
        } else {
            & $wslExe @Arguments
        }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
}

function Install-WslViaDismAndMsi {
    $rebootRequired = $false

    Write-Info "Enabling required Windows features (Microsoft-Windows-Subsystem-Linux & VirtualMachinePlatform)..."
    foreach ($feature in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            & dism.exe /online /enable-feature "/featurename:$feature" /all /norestart | Out-Host
            $dismExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevPref
        }
        if ($dismExit -eq 3010) {
            $rebootRequired = $true
        } elseif ($dismExit -ne 0) {
            Write-Err "dism.exe failed enabling '$feature' (exit code $dismExit)."
            return [PSCustomObject]@{ Success = $false; RebootRequired = $false; ExitCode = $dismExit }
        }
    }

    # Download and silently install the latest official Microsoft WSL MSI from GitHub
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
    Write-Info "Downloading latest official Microsoft WSL ($arch) installer from GitHub..."

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/WSL/releases/latest" -Headers @{ "User-Agent" = "tryton-wsl-installer" }
    $asset = $release.assets | Where-Object { $_.name -match "^wsl\..*\.$arch\.msi$" } | Select-Object -First 1
    if (-not $asset -or $asset.browser_download_url -notmatch '^https://github\.com/microsoft/WSL/releases/download/') {
        Write-Err "Could not locate official Microsoft WSL .$arch.msi release asset."
        return [PSCustomObject]@{ Success = $false; RebootRequired = $rebootRequired; ExitCode = 1 }
    }

    $msiPath = Join-Path $env:TEMP $asset.name
    try {
        $prevProgress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"
        try {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -UseBasicParsing
        } finally {
            $ProgressPreference = $prevProgress
        }

        $sig = Get-AuthenticodeSignature -FilePath $msiPath
        if ($sig.Status -ne "Valid" -or $sig.SignerCertificate.Subject -notlike "*Microsoft*") {
            Write-Err "Downloaded WSL MSI failed Microsoft Authenticode signature verification ($($sig.Status))."
            return [PSCustomObject]@{ Success = $false; RebootRequired = $rebootRequired; ExitCode = 1 }
        }

        Write-Info "Installing $($asset.name)..."
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "`"$msiPath`"", "/qn", "/norestart") -Wait -PassThru
        if ($proc.ExitCode -eq 3010) {
            $rebootRequired = $true
        } elseif ($proc.ExitCode -ne 0) {
            Write-Err "WSL MSI installation failed (exit code $($proc.ExitCode))."
            return [PSCustomObject]@{ Success = $false; RebootRequired = $rebootRequired; ExitCode = $proc.ExitCode }
        }
    } finally {
        if (Test-Path -LiteralPath $msiPath) {
            Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{ Success = $true; RebootRequired = $rebootRequired; ExitCode = 0 }
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InstalledWslDistros {
    $res = Invoke-WslCapture @("--list", "--quiet")
    if ($res.ExitCode -ne 0) {
        return @()
    }
    return @($res.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Get-OnlineWslDistros {
    $res = Invoke-WslCapture @("--list", "--online")
    if ($res.ExitCode -ne 0) {
        return @()
    }
    $names = @()
    $inTable = $false
    foreach ($line in $res.Lines) {
        $clean = $line.Trim()
        if ($clean -match '^NAME\s+FRIENDLY NAME') {
            $inTable = $true
            continue
        }
        if ($inTable -and $clean -match '^([A-Za-z0-9._-]+)\s+') {
            $names += $Matches[1]
        }
    }
    return $names
}

function Resolve-LinuxUsername([string]$Requested) {
    $candidate = $Requested
    if (-not $candidate -and $env:USERNAME) {
        $candidate = $env:USERNAME.ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    }
    if (-not $candidate -or $candidate -eq "root" -or $candidate -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        $candidate = "tryton"
    }
    return $candidate
}

function Invoke-TrytonWslMain {
    $isDryRun = ($DryRun -or $env:DRY_RUN -eq "1")

    # 1. Validate inputs before touching WSL
    if ($BaseDistro -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Err "Invalid BaseDistro '$BaseDistro'."
        return 1
    }
    if ($Distro -and $Distro -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Err "Invalid Distro '$Distro'."
        return 1
    }
    if ($LinuxUser -and ($LinuxUser -eq "root" -or $LinuxUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$')) {
        Write-Err "Invalid LinuxUser '$LinuxUser'. Use a lowercase Linux username (not root)."
        return 1
    }
    if ($TrytonSeries -ne "latest" -and $TrytonSeries -notmatch '^\d+\.\d+$') {
        Write-Err "Invalid TrytonSeries '$TrytonSeries'. Expected 'latest' or 'X.Y' (e.g. 7.2)."
        return 1
    }
    if ($TrytonPort -lt 1024 -or $TrytonPort -gt 65535) {
        Write-Err "Invalid TrytonPort '$TrytonPort'. Must be between 1024 and 65535."
        return 1
    }
    if ($null -ne $PgPort -and ($PgPort -lt 1 -or $PgPort -gt 65535)) {
        Write-Err "Invalid PgPort '$PgPort'. Must be between 1 and 65535."
        return 1
    }
    if ($PgUser -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
        Write-Err "Invalid PgUser '$PgUser'."
        return 1
    }
    if ($PgDb -notmatch '^[a-z_][a-z0-9_]{0,62}$') {
        Write-Err "Invalid PgDb '$PgDb'."
        return 1
    }
    if ($PgHost -and $PgHost -notmatch '^[a-zA-Z0-9._:-]+$') {
        Write-Err "Invalid PgHost '$PgHost'."
        return 1
    }
    if ($PgHost -and -not $PgPassword) {
        Write-Err "PgPassword is required when PgHost is specified."
        return 1
    }

    # 2. Verify WSL is installed (and auto-install it on clean Windows machines)
    if (-not (Get-WslExePath)) {
        Write-Err "wsl.exe was not found on this Windows machine (requires Windows 10 2004+ or Windows 11)."
        return 1
    }

    # Clean Windows ships a stub System32\wsl.exe; `wsl.exe --status` returns non-zero until WSL is installed.
    $status = Invoke-WslCapture @("--status")
    if ($status.ExitCode -ne 0) {
        Write-Warn "Windows Subsystem for Linux (WSL) is not installed yet on this machine."
        if ($isDryRun) {
            Write-Info "[DRY-RUN] Would install WSL (via wsl.exe --install --no-distribution or DISM + official Microsoft WSL MSI)."
            return 0
        }

        if (-not (Test-IsAdministrator)) {
            Write-Err "Administrator privileges are required to install WSL for the first time."
            Write-Host "Right-click PowerShell -> 'Run as Administrator', then re-run this exact same command." -ForegroundColor Yellow
            return 1
        }

        $rebootNeeded = $false
        Write-Info "Installing WSL automatically..."
        $installExit = Invoke-WslStream @("--install", "--no-distribution")
        if ($installExit -eq 3010) {
            $rebootNeeded = $true
        } elseif ($installExit -ne 0) {
            # Older Windows inbox wsl.exe stubs reject --no-distribution; fall back to DISM + official Microsoft WSL MSI.
            Write-Warn "Inbox wsl.exe stub did not accept --no-distribution; installing WSL via DISM + official Microsoft WSL MSI..."
            $fallback = Install-WslViaDismAndMsi
            if (-not $fallback.Success) {
                return $fallback.ExitCode
            }
            if ($fallback.RebootRequired) {
                $rebootNeeded = $true
            }
        }

        $after = Invoke-WslCapture @("--status")
        if ($rebootNeeded -or $after.ExitCode -ne 0) {
            Write-Ok "WSL has been installed!"
            Write-Warn "Windows requires a reboot to finish enabling WSL2."
            Write-Host "Please reboot Windows, then re-run this exact same command to install $BaseDistro and Tryton." -ForegroundColor Yellow
            return 0
        }

        Write-Ok "WSL is installed and ready!"
    }

    $installedDistros = Get-InstalledWslDistros
    $targetDistro = $Distro
    $provisionedNewDistro = $false
    $effectiveLinuxUser = $null

    if (-not $targetDistro) {
        if ($installedDistros.Count -gt 0) {
            $targetDistro = $installedDistros[0]
            Write-Info "Using existing default WSL distro: $targetDistro"
        } else {
            $targetDistro = $BaseDistro
        }
    }

    # 3. Auto-install target distro if it is not installed yet
    if ($installedDistros -notcontains $targetDistro) {
        $onlineDistros = Get-OnlineWslDistros
        $imageToInstall = $BaseDistro
        if ($onlineDistros -contains $targetDistro -and -not $env:WSL_BASE_DISTRO -and -not $PSBoundParameters.ContainsKey('BaseDistro')) {
            $imageToInstall = $targetDistro
        }

        if ($isDryRun) {
            if ($targetDistro -ne $imageToInstall) {
                Write-Info "[DRY-RUN] Would run: wsl.exe --install $imageToInstall --name $targetDistro --no-launch"
            } else {
                Write-Info "[DRY-RUN] Would run: wsl.exe --install $imageToInstall --no-launch"
            }
            Write-Info "[DRY-RUN] Would bootstrap Linux user '$(Resolve-LinuxUsername $LinuxUser)' and run install.sh."
            return 0
        }

        $installArgs = @("--install", $imageToInstall, "--no-launch")
        if ($targetDistro -ne $imageToInstall) {
            $installArgs = @("--install", $imageToInstall, "--name", $targetDistro, "--no-launch")
        }

        Write-Info "WSL distro '$targetDistro' not found. Installing '$imageToInstall' (non-interactive)..."
        $distroExit = Invoke-WslStream $installArgs
        if ($distroExit -ne 0 -and $distroExit -ne 3010) {
            Write-Err "Failed to install WSL distro '$imageToInstall' (exit code $distroExit)."
            Write-Warn "If Windows just enabled WSL for the first time, reboot Windows and re-run this exact same command."
            return $distroExit
        }

        $installedAfter = Get-InstalledWslDistros
        if ($installedAfter -notcontains $targetDistro) {
            Write-Warn "WSL installed '$targetDistro', but a Windows reboot is required before it can start. Reboot and re-run this command."
            return 0
        }

        $provisionedNewDistro = $true
        $effectiveLinuxUser = Resolve-LinuxUsername $LinuxUser
        Write-Info "Bootstrapping non-root Linux user '$effectiveLinuxUser' inside '$targetDistro'..."

        $bootstrapScript = @'
set -euo pipefail
TARGET_USER="$1"
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$TARGET_USER"
fi
mkdir -p /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" > "/etc/sudoers.d/$TARGET_USER"
chmod 440 "/etc/sudoers.d/$TARGET_USER"
if command -v visudo >/dev/null 2>&1; then
    visudo -cf "/etc/sudoers.d/$TARGET_USER" >/dev/null
fi
cat > /etc/wsl.conf <<EOF
[user]
default=$TARGET_USER

[boot]
systemd=true
EOF
'@ -replace "`r`n", "`n"

        $bootExit = Invoke-WslStream @("-d", $targetDistro, "-u", "root", "--", "bash", "-s", "--", $effectiveLinuxUser) $bootstrapScript
        if ($bootExit -ne 0) {
            Write-Err "Failed to bootstrap Linux user '$effectiveLinuxUser' in '$targetDistro' (exit code $bootExit)."
            return $bootExit
        }

        # Terminate once so /etc/wsl.conf default user & systemd take effect cleanly
        [void](Invoke-WslCapture @("--terminate", $targetDistro))
        Write-Ok "WSL distro '$targetDistro' is ready (default user: $effectiveLinuxUser)."
    } else {
        Write-Info "Using existing WSL distro: $targetDistro"
    }

    # 4. Build environment arguments passed safely to WSL `env`
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
    if ($isDryRun)                          { $envArgs += "DRY_RUN=1" }

    $wslPrefix = @("-d", $targetDistro)
    if ($effectiveLinuxUser) {
        $wslPrefix += @("-u", $effectiveLinuxUser)
    }

    # 5. Obtain install.sh content (from local file for testing, or over HTTPS from GitHub)
    if ($LocalScript) {
        if (-not (Test-Path -LiteralPath $LocalScript)) {
            Write-Err "LocalScript not found: $LocalScript"
            return 1
        }
        Write-Info "Running local installer script inside '$targetDistro': $LocalScript"
        $scriptContent = (Get-Content -LiteralPath $LocalScript -Raw) -replace "`r`n", "`n"
    } else {
        if ($RepoUrl -notmatch '^https://') {
            Write-Err "RepoUrl must use HTTPS."
            return 1
        }
        Write-Info "Downloading installer from $RepoUrl..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $scriptContent = (Invoke-RestMethod -Uri $RepoUrl) -replace "`r`n", "`n"
    }

    # 6. Execute install.sh inside WSL (piped via stdin so paths and CRLF never break)
    $wslArgs = $wslPrefix + @("--", "env") + $envArgs + @("bash", "-s")
    $runExit = Invoke-WslStream $wslArgs $scriptContent
    if ($runExit -ne 0) {
        Write-Err "Tryton installation inside WSL distro '$targetDistro' failed (exit code $runExit)."
        return $runExit
    }

    Write-Ok "Tryton installation finished in WSL distro '$targetDistro'!"
    Write-Host "  View credentials:  wsl -d $targetDistro -- cat ~/tryton/.credentials" -ForegroundColor Gray
    Write-Host "  Start Tryton:      wsl -d $targetDistro -- ~/tryton/start.sh" -ForegroundColor Gray
    if ($provisionedNewDistro) {
        Write-Host "  Remove test distro later:  wsl --unregister $targetDistro" -ForegroundColor Gray
    }

    if ($StartServer -and -not $isDryRun) {
        $targetDir = if ($InstallDir) { $InstallDir } else { '$HOME/tryton' }
        Write-Info "Starting Tryton server in '$targetDistro' (open http://localhost:$TrytonPort in your browser)..."
        $startArgs = $wslPrefix + @("--", "bash", "-lc", "exec `"$targetDir/start.sh`"")
        return (Invoke-WslStream $startArgs)
    }

    return 0
}

$__exitCode = Invoke-TrytonWslMain
if ($PSCommandPath) {
    exit $__exitCode
}
