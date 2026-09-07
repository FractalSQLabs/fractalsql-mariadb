<#
.SYNOPSIS
    easy_install.ps1: the "easy button" for FractalSQL on Windows. One
    command gets you from a bare Windows box (with MariaDB already
    installed) to a running install with reasoning configured.
    PowerShell counterpart to scripts/easy_install.sh (Linux/macOS);
    same design, Windows-native underneath.

.DESCRIPTION
    Detects an installed MariaDB via its Windows Service (registered as
    "MariaDB" by MariaDB Foundation's own installer since 10.4; every
    major this repo supports is 10.6+, so that name is unconditional
    here). -MdbDir overrides detection entirely. Offers to install the
    matching .msi if the FractalSQL plugin itself is missing. Runs the
    same reasoning-provider wizard as easy_install.sh: registers the
    UDFs and agent procedures, configures reasoning via the service's
    environment (there is no GUC/sysvar surface at all, see
    docs/reasoning-setup.md), and runs a smoke test.

    Design differences, all forced by MariaDB's own architecture (see
    scripts/easy_install.sh's header comment for the full rationale,
    identical here):
      - No -PgMajor-style multi-install selector: one binary covers
        every supported major, and there's normally exactly one
        MariaDB Windows Service to target.
      - Every FRACTALSQL_* reasoning setting is a service environment
        variable, never a live-reloadable GUC, so applying any of them
        always means a service restart.
      - mariadb.exe/mysql.exe, not psql.exe. Registration is two plain
        SQL files (sql/install_udf.sql + sql/install_agents.sql), not
        CREATE EXTENSION -- no catalog-version/staleness concept, since
        both scripts are unconditionally idempotent.
      - Verification functions are fractalsql_edition()/fractalsql_version()
        (the fractalsql_ prefix, see sql/install_udf.sql).

    No telemetry. This script never reports usage, provider choice, or
    success or failure anywhere.

.PARAMETER MdbDir
    Top-level MariaDB install directory, e.g. "C:\Program Files\MariaDB 11.4".
    Same convention as build_test.ps1's own -MdbDir. Optional. When
    given, skips service auto-detection and uses this directly.

.PARAMETER Port
    Override the auto-detected port if it guessed wrong.

.PARAMETER RootPassword
    Password for the MariaDB root account. Asked for once (masked) and
    cached in $env:MYSQL_PWD for the rest of the run if not supplied
    here -- unlike the packaged Linux default (root@localhost via
    unix_socket, no password), the Windows MSI sets a root password
    during install.

.PARAMETER Database
    Target database for the agent stored procedures -- must already
    exist. UDFs themselves are server-global (mysql.func) and need no
    database; agent procedures are ordinary stored procedures and do
    (running install_agents.sql with none selected fails with
    "No database selected").

.PARAMETER Provider
    ollama | openai-compatible | skip

.PARAMETER Yes
    Pre-confirm every prompt (needed for CI/non-interactive use).

.PARAMETER NoInstall
    Don't offer to install a missing .msi.

.PARAMETER DryRun
    Print what would happen, change nothing.

.PARAMETER ForceReinstall
    Skip the "already registered" pause before re-running the SQL
    registration scripts.

.PARAMETER Uninstall
    Reverse everything this script can set up.

.PARAMETER Version
    Package version to install. Defaults to this script's own embedded
    version.

.EXAMPLE
    .\easy_install.ps1
    .\easy_install.ps1 -MdbDir "C:\Program Files\MariaDB 11.4" -Provider ollama -Yes
#>

param(
    [string]$MdbDir,
    [int]$Port,
    [string]$RootPassword,
    [string]$Database,
    [ValidateSet('ollama', 'openai-compatible', 'skip')][string]$Provider,
    [string]$Url,
    [string]$Model,
    [string]$Token,
    [string]$EmbedUrl,
    [string]$EmbedModel,
    [string]$Think,
    [string]$ThinkProvider,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$DryRun,
    [switch]$ForceReinstall,
    [switch]$Uninstall,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# --- version -----------------------------------------------------------
$FsqlVersion = '@@FSQL_VERSION@@'
if ($FsqlVersion -eq '@@FSQL_VERSION@@') {
    $srcFile = Join-Path $PSScriptRoot '..\..\src\fractalsql.c'
    if (Test-Path $srcFile) {
        $m = Select-String -Path $srcFile -Pattern '^#define FSQL_VERSION "(.*)"$' | Select-Object -First 1
        if ($m) { $FsqlVersion = $m.Matches[0].Groups[1].Value }
    }
}
if (-not $Version) { $Version = $FsqlVersion }
if (-not $Version) { throw "could not determine a version to install. Pass -Version X.Y.Z" }

$Repo = 'FractalSQLabs/fractalsql-mariadb'
$ServiceName = 'MariaDB'

# --- output helpers ------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor White }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Die   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red; exit 1 }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- prompting -----------------------------------------------------------
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { Write-Ok "$Question -> yes (-Yes)"; return $true }
    try {
        $reply = Read-Host "$Question [Y/n]"
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Yes, or the specific parameter for what you're trying to set."
    }
    return ($reply -eq '' -or $reply -match '^[Yy]')
}

function Prompt-Value {
    param([string]$Question, [string]$Default = '')
    try {
        if ($Default) {
            $reply = Read-Host "$Question [$Default]"
            if (-not $reply) { return $Default }
            return $reply
        } else {
            return Read-Host $Question
        }
    } catch {
        if ($Default) { return $Default }
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass the corresponding parameter."
    }
}

function Prompt-Secret {
    param([string]$Question)
    try {
        $secure = Read-Host $Question -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -RootPassword, or set MYSQL_PWD."
    }
}

function Resolve-RootPassword {
    if ($env:MYSQL_PWD) { return }
    if ($RootPassword) { $env:MYSQL_PWD = $RootPassword; return }
    if (Confirm-Step "Does root@localhost need a password? (the MSI-set default; say no if this is a fresh unix_socket-less test box with no password set)") {
        $env:MYSQL_PWD = Prompt-Secret "Password for MariaDB root"
    }
}

# --- detect ----------------------------------------------------------------
# Single-target detection (no -PgMajor-style multi-install selector, see
# this file's own .DESCRIPTION): exactly one MariaDB Windows Service to
# find, via Win32_Service's PathName (its mariadbd.exe location), the
# same authoritative-over-a-guessed-registry-key approach build_test.ps1
# itself uses for -MdbDir auto-completion. -MdbDir overrides this
# entirely when given.
function Get-MariaDbTarget {
    if ($MdbDir) {
        $exe = Join-Path $MdbDir 'bin\mariadbd.exe'
        if (-not (Test-Path $exe)) { Write-Die "-MdbDir '$MdbDir' doesn't look like a MariaDB install (no bin\mariadbd.exe)" }
        return @{ Dir = $MdbDir; Port = (Get-PortFor $MdbDir) }
    }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Die "no '$ServiceName' Windows Service found. If MariaDB is installed but the service has a different name, or you installed a no-service ZIP archive, pass -MdbDir."
    }
    # PathName looks like: "C:\Program Files\MariaDB 11.4\bin\mariadbd.exe" --defaults-file=...
    $exePath = ($svc.PathName -replace '^"?([^"]+mariadbd\.exe)".*$', '$1')
    if (-not (Test-Path $exePath)) { Write-Die "Service '$ServiceName' PathName didn't resolve to a real mariadbd.exe ($exePath). Pass -MdbDir." }
    $dir = Split-Path (Split-Path $exePath -Parent) -Parent
    return @{ Dir = $dir; Port = (Get-PortFor $dir) }
}

function Get-PortFor {
    param([string]$BaseDir)
    foreach ($ini in @((Join-Path $BaseDir 'data\my.ini'), (Join-Path $BaseDir 'my.ini'))) {
        if (Test-Path $ini) {
            $m = Select-String -Path $ini -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
            if ($m) { return [int]$m.Matches[0].Groups[1].Value }
        }
    }
    return 3306
}

# --- mariadb.exe plumbing -----------------------------------------------
# ArgumentList (not a raw string) needs no manual argv-escaping, matching
# build_test.ps1's own Mariadb helper pattern.
function Invoke-Mariadb {
    param([string]$Bin, [int]$MdbPort, [string[]]$Sql, [string]$File, [string]$Db)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'mariadb.exe'
    if (-not (Test-Path $psi.FileName)) { $psi.FileName = Join-Path $Bin 'mysql.exe' }
    $argList = @('-h', '127.0.0.1', '-P', "$MdbPort", '-u', 'root', '-N', '-B')
    if ($Db) { $argList += @('-D', $Db) }
    if ($File) { $argList += @('-e', "source $File") }
    foreach ($s in $Sql) { $argList += @('-e', $s) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "mariadb.exe failed: $errOut" }
    return $out.Trim()
}

function Invoke-MariadbFile {
    param([string]$Bin, [int]$MdbPort, [string]$Path, [string]$Db)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $Bin 'mariadb.exe'
    if (-not (Test-Path $psi.FileName)) { $psi.FileName = Join-Path $Bin 'mysql.exe' }
    $argList = @('-h', '127.0.0.1', '-P', "$MdbPort", '-u', 'root')
    if ($Db) { $argList += @('-D', $Db) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write([IO.File]::ReadAllText($Path))
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "mariadb.exe (< $Path) failed: $errOut" }
    return $out.Trim()
}

# plugin_dir comes from a live `SELECT @@plugin_dir` query, not a
# hardcoded 'lib\plugin' guess under the install root. A build-time or
# static guess for a MariaDB plugin directory can differ from the
# server's own live value (see scripts/easy_install.sh's header
# comment for the Linux/macOS case), so this queries live instead.
$script:PluginDir = $null
function Resolve-PluginDir {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $mdbPort = if ($Port) { $Port } else { $Target.Port }
    $dir = Invoke-Mariadb $bin $mdbPort @('SELECT @@plugin_dir;')
    if (-not $dir) { Write-Die "SELECT @@plugin_dir returned nothing" }
    $script:PluginDir = $dir.TrimEnd('\')
}

function Test-Installed {
    return Test-Path (Join-Path $script:PluginDir 'fractalsql.dll')
}

# --- Phase B: install the package (default-on) ------------------------
function Install-Package {
    param($Target)
    if (Test-Installed) { return }
    if ($NoInstall) {
        Write-Die "FractalSQL isn't installed under $($Target.Dir). Grab the matching .msi from https://github.com/$Repo/releases and install it, then re-run this script (or drop -NoInstall)."
    }
    if (-not (Confirm-Step "FractalSQL isn't installed yet. Install it now?")) {
        Write-Die "Nothing to do without installing the package first. Re-run without -NoInstall, or install it yourself from https://github.com/$Repo/releases."
    }

    # FractalSQL-MariaDB-<major>-<version>-x64.msi: the .wxs installs into
    # "MariaDB <major>" (this repo's own directory-name convention,
    # matching the real MariaDB install it's layered onto), so the major
    # has to come from the detected install directory's own name.
    $major = [regex]::Match($Target.Dir, 'MariaDB\s+([\d.]+)').Groups[1].Value
    if (-not $major) { Write-Die "couldn't determine the MariaDB major version from install directory '$($Target.Dir)'. Pass -MdbDir pointing at a 'MariaDB <major>' directory." }
    $asset = "FractalSQL-MariaDB-$major-$Version-x64.msi"
    $assetUrl = "https://github.com/$Repo/releases/download/v$Version/$asset"
    $tmp = Join-Path $env:TEMP "fsql-easy-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msiPath = Join-Path $tmp $asset
        Write-Step "Downloading $asset..."
        Invoke-WebRequest -Uri $assetUrl -OutFile $msiPath -UseBasicParsing
        Write-Step "msiexec /i `"$msiPath`" /quiet /norestart"
        if (-not $DryRun) {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiPath`"", '/quiet', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "msiexec exited with code $($p.ExitCode)" }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Write-Ok "Package installed."
    # The installer drops install_udf.sql/install_agents.sql into
    # share\doc\fractalsql-mariadb\ but does not run them (see
    # docs/getting-started.md) -- Invoke-Wizard's registration step
    # below looks there when a repo checkout isn't available.
}

# --- Phase C: the wizard -----------------------------------------------
# Every FRACTALSQL_* reasoning setting is a service environment variable,
# read once at mariadbd.exe startup -- there is no GUC/sysvar surface at
# all here (see this file's own .DESCRIPTION).
# A Windows Service's environment lives in the registry
# (HKLM:\SYSTEM\CurrentControlSet\Services\<service>\Environment, a
# REG_MULTI_SZ value), written here via Set-ItemProperty, then
# Restart-Service.
function Set-ReasoningEnvAndRestart {
    param([hashtable]$EnvValues)

    Write-Step "About to set (service environment for '$ServiceName'):"
    foreach ($k in $EnvValues.Keys) {
        if ($k -like '*HTTP_TOKEN*') { Write-Host "  $k=***" } else { Write-Host "  $k=$($EnvValues[$k])" }
    }
    if (-not (Confirm-Step "Apply this configuration? This needs a MariaDB service restart, which drops active connections -- there is no live reload for these.")) {
        Write-Warn2 "Aborted. Nothing was changed."
        return $false
    }
    if ($DryRun) {
        Write-Step "(-DryRun: not actually writing or restarting)"
        return $false
    }

    $doRestart = Confirm-Step "Restart the MariaDB service now to apply it?"

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $regValues = $EnvValues.Keys | ForEach-Object { "$_=$($EnvValues[$_])" }
    $quotedValues = ($regValues | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
    $elevatedCmd = "Set-ItemProperty -Path '$regPath' -Name Environment -Value @($quotedValues) -Type MultiString"
    if ($doRestart) { $elevatedCmd += "; Restart-Service -Name '$ServiceName' -Force" }

    if (Test-IsAdmin) {
        try {
            Invoke-Expression $elevatedCmd
        } catch {
            Write-Warn2 "Could not write the service environment ($($_.Exception.Message)). Set those values by hand under $regPath and restart $ServiceName yourself."
            return $false
        }
    } elseif ([Environment]::UserInteractive) {
        Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
        try {
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd)
            if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
        } catch {
            Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Set the values by hand under $regPath and restart $ServiceName, or re-run this whole script from an Administrator PowerShell."
            return $false
        }
    } else {
        Write-Warn2 "Skipping: this needs administrator access and there's no interactive session to grant it in. Set the values by hand under $regPath and restart $ServiceName, or re-run this whole script from an Administrator PowerShell."
        return $false
    }

    if ($doRestart) {
        Write-Ok "$ServiceName restarted with the new reasoning config."
        return $true
    } else {
        Write-Ok "Environment written."
        Write-Warn2 "Not restarted. The config won't take effect until you run: Restart-Service $ServiceName (as Administrator)"
        return $false
    }
}

function Invoke-Wizard {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $mdbPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-RootPassword

    if (-not $Database) { $Database = Prompt-Value "Target database for the agent stored procedures (must already exist; UDFs themselves don't need one)" }
    if (-not $Database) { Write-Die "a target database is required to register the agent procedures. Pass -Database <name>." }
    $dbExists = Invoke-Mariadb $bin $mdbPort @("SHOW DATABASES LIKE '$($Database -replace "'", "''")';")
    if ($dbExists -ne $Database) { Write-Die "database '$Database' doesn't exist. Create it first (CREATE DATABASE $Database;), then re-run with -Database $Database." }

    if (-not $Provider) {
        Write-Step "Reasoning provider:"
        Write-Host "  1) Local Ollama"
        Write-Host "  2) Cloud / OpenAI-compatible endpoint"
        Write-Host "  3) Skip: search-only install, configure reasoning later"
        $choice = Prompt-Value "Choice" "1"
        $Provider = switch ($choice) { '1' { 'ollama' } '2' { 'openai-compatible' } default { 'skip' } }
    }

    # Live plugin_dir (resolved once in main via Resolve-PluginDir), not a
    # hardcoded 'lib\plugin' guess under the install root -- see this
    # file's own Resolve-PluginDir comment for why.
    $pluginDll = Join-Path $script:PluginDir 'fractalsql-reasoning-http.dll'

    $envValues = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Ollama chat URL" "http://localhost:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = Prompt-Value "Ollama embeddings URL" "http://localhost:11434/v1/embeddings" }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $envValues['FRACTALSQL_REASONING_PLUGIN'] = $pluginDll
            $envValues['FRACTALSQL_HTTP_URL'] = $Url
            $envValues['FRACTALSQL_HTTP_ALLOW_PLAINTEXT'] = '1'
            $envValues['FRACTALSQL_HTTP_MODEL'] = $Model
            $envValues['FRACTALSQL_HTTP_EMBED_URL'] = $EmbedUrl
            $envValues['FRACTALSQL_HTTP_EMBED_MODEL'] = $EmbedModel
            $envValues['FRACTALSQL_HTTP_THINK'] = $Think
            $envValues['FRACTALSQL_HTTP_THINK_PROVIDER'] = $ThinkProvider
        }
        'openai-compatible' {
            if (-not $Url) { $Url = Prompt-Value "Chat completions URL" }
            if (-not $Url) { Write-Die "a URL is required for a cloud/OpenAI-compatible endpoint" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked, never logged)" }
            $envValues['FRACTALSQL_REASONING_PLUGIN'] = $pluginDll
            $envValues['FRACTALSQL_HTTP_URL'] = $Url
            $envValues['FRACTALSQL_HTTP_TOKEN'] = $Token
            $envValues['FRACTALSQL_HTTP_MODEL'] = $Model
            if ($Url -notlike 'https://*') {
                Write-Warn2 "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            }
        }
        'skip' {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_explore work with no model."
        }
    }

    $applied = $false
    if ($Provider -ne 'skip') {
        if ($DryRun) {
            Write-Step "About to set (service environment for '$ServiceName'):"
            foreach ($k in $envValues.Keys) {
                if ($k -like '*HTTP_TOKEN*') { Write-Host "  $k=***" } else { Write-Host "  $k=$($envValues[$k])" }
            }
            Write-Step "(-DryRun: not actually applying)"
        } else {
            $applied = Set-ReasoningEnvAndRestart $envValues
        }
    }

    Write-Step "Registering UDFs + agent procedures..."
    $already = ''
    try { $already = Invoke-Mariadb $bin $mdbPort @("SELECT 1 FROM mysql.func WHERE name='fractalsql_edition';") } catch {}
    if ($already -and -not $ForceReinstall) {
        if (-not (Confirm-Step "fractalsql_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?")) {
            Write-Die "Nothing to do. Re-run with -ForceReinstall to skip this pause."
        }
    }
    if ($DryRun) {
        Write-Step "(-DryRun: not actually running sql\install_udf.sql or sql\install_agents.sql)"
    } else {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $udfSql = Join-Path $repoRoot 'sql\install_udf.sql'
        $agentsSql = Join-Path $repoRoot 'sql\install_agents.sql'
        if (-not (Test-Path $udfSql)) {
            # Release .msi layout: share\doc\fractalsql-mariadb\ under the
            # MariaDB install root (see docs/getting-started.md).
            $udfSql = Join-Path $Target.Dir 'share\doc\fractalsql-mariadb\install_udf.sql'
            $agentsSql = Join-Path $Target.Dir 'share\doc\fractalsql-mariadb\install_agents.sql'
        }
        if (-not (Test-Path $udfSql)) { Write-Die "install_udf.sql not found in a repo checkout or under $($Target.Dir)\share\doc\fractalsql-mariadb\. Run this from an extracted release or a repo checkout." }
        Invoke-MariadbFile $bin $mdbPort $udfSql -Db $Database | Out-Null
        Invoke-MariadbFile $bin $mdbPort $agentsSql -Db $Database | Out-Null
        Write-Ok "UDFs + agent procedures registered."
    }

    if (-not $DryRun) {
        $ed = Invoke-Mariadb $bin $mdbPort @('SELECT fractalsql_edition();') -Db $Database
        $ver = Invoke-Mariadb $bin $mdbPort @('SELECT fractalsql_version();') -Db $Database
        Write-Ok "fractalsql_edition() = $ed, fractalsql_version() = $ver"
        if ($ver -ne $Version) {
            Write-Warn2 "That's not $Version, the version this script expected. The installed fractalsql.dll itself is out of date. Reinstall the current .msi from https://github.com/$Repo/releases over this install to actually update it, then re-run this script."
        }
        if ($Provider -ne 'skip' -and $applied -and (Confirm-Step "Run a live reasoning smoke test (SELECT fractal_reason(CONNECTION_ID(), 'say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time.")) {
            try {
                $reply = Invoke-Mariadb $bin $mdbPort @("SELECT fractal_reason(CONNECTION_ID(), 'say ok');") -Db $Database
                Write-Host "  $reply"
            } catch {
                Write-Warn2 "That failed. If it looks like a timeout on a slow/cold local model, see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            }
        } elseif ($Provider -ne 'skip' -and -not $applied) {
            Write-Warn2 "Reasoning config wasn't applied (restart declined or failed), so skipping the smoke test. fractal_reason() will use whatever config the service already has."
        }
    }

    Write-Host ""
    Write-Host "You're set up. Where next:" -ForegroundColor Green
    Write-Host "  - docs/starter-kits.md: industry-specific runnable examples"
    Write-Host "  - docs/api-agency.md: the 16 built-in agents, full reference"
    Write-Host "  - docs/composition-guide.md: build your own agent"
    Write-Host "  - Re-run this script anytime to switch providers or models. It's"
    Write-Host "    safe, but every change needs a service restart to take effect."
}

# --- -Uninstall ---------------------------------------------------------
function Invoke-Uninstall {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $mdbPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-RootPassword
    Write-Step "This will reset FRACTALSQL_* reasoning env vars and restart the MariaDB service."

    if (Confirm-Step "Reset reasoning config now?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually resetting)"
        } else {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
            $elevatedCmd = "Remove-ItemProperty -Path '$regPath' -Name Environment -ErrorAction SilentlyContinue; Restart-Service -Name '$ServiceName' -Force"
            if (Test-IsAdmin) {
                Invoke-Expression $elevatedCmd
            } elseif ([Environment]::UserInteractive) {
                Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd) | Out-Null
            } else {
                Write-Warn2 "Skipping: needs administrator access. Remove the Environment value under $regPath and restart $ServiceName by hand."
            }
            Write-Ok "Reasoning env vars reset."
        }
    }

    if (Confirm-Step "Also drop the fractalsql UDFs (deletes any dependent objects too)?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually dropping)"
        } else {
            $dropSql = Invoke-Mariadb $bin $mdbPort @("SELECT CONCAT('DROP FUNCTION IF EXISTS ', name, ';') FROM mysql.func WHERE dl='fractalsql.dll';")
            if ($dropSql) { Invoke-Mariadb $bin $mdbPort @($dropSql) | Out-Null }
            Write-Ok "UDFs dropped. Agent procedures (fractal_agent_*) aren't UDFs and aren't tracked in mysql.func -- drop them via sql\install_agents.sql's own DROP PROCEDURE list, or by hand."
        }
    }

    Write-Host "  To remove the package: uninstall 'FractalSQL for MariaDB' from Windows Settings > Apps, or msiexec /x <product code>"
}

# --- main ------------------------------------------------------------------
$target = Get-MariaDbTarget
Write-Step "Targeting MariaDB at $($target.Dir) (port $(if ($Port) { $Port } else { $target.Port }))"

if ($Uninstall) {
    Invoke-Uninstall $target
    exit 0
}

# Resolve-PluginDir needs a live connection (SELECT @@plugin_dir), so the
# root password has to be in hand first -- both ahead of Install-Package,
# which itself depends on $script:PluginDir via Test-Installed.
Resolve-RootPassword
Resolve-PluginDir $target
Write-Step "Plugin directory (live @@plugin_dir): $script:PluginDir"

Install-Package $target
Invoke-Wizard $target
