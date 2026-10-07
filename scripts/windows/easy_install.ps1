<#
.SYNOPSIS
    easy_install.ps1: the "easy button" for FractalSQL on Windows. One
    command gets you from a bare Windows box (with MariaDB already
    installed) to a running install with reasoning configured.
    PowerShell counterpart to scripts/easy_install.sh (Linux/macOS);
    same design, Windows-native underneath.

.DESCRIPTION
    Detects an installed MariaDB via its Windows Service, resolved from
    the server binary's location rather than a hardcoded service name --
    machines with several installs register several services (MariaDB,
    MariaDB11, MariaDB12, ...), so the literal name "MariaDB" is just one
    candidate, and it can belong to a different major than the one you
    meant. -MdbDir overrides detection entirely; -ServiceName overrides
    the service resolution. Offers to install the
    matching .msi if the FractalSQL plugin itself is missing. Runs the
    same reasoning-provider wizard as easy_install.sh: registers the
    UDFs and agent procedures, configures reasoning by writing the
    reasoning_* keys into the daemon's fractalsqld.conf and restarting
    the fractalsqld service (there is no GUC/sysvar surface at all, see
    docs/reasoning-setup.md), and runs a smoke test.

    Design differences, all forced by MariaDB's own architecture (see
    scripts/easy_install.sh's header comment for the full rationale,
    identical here):
      - No multi-install selector parameter: one binary covers
        every supported major, and there's normally exactly one
        MariaDB Windows Service to target.
      - No GUC/sysvar-style config surface exists at all for these
        settings. The wizard writes the nine reasoning_* conf keys
        directly into fractalsqld.conf, the daemon's own config file
        (the -Config file the fractalsqld service was registered with,
        parsed out of the service's ImagePath, falling back to the
        ProgramData default): the keys are reasoning_plugin,
        reasoning_url, reasoning_token, reasoning_model,
        reasoning_allow_plaintext, embed_url, embed_model, think,
        think_provider. Every conf write is followed by re-hardening the
        file's ACL (the daemon's key_file_private gate rejects a conf
        readable by Everyone/Authenticated Users/BUILTIN\Users, and
        C:\ProgramData's default inheritance grants BUILTIN\Users read),
        and the keys are applied by restarting the fractalsqld service;
        there is no Windows fsqlctl/reload client anywhere in the tree.
        The service's registry Environment keeps only the two env-only
        timeout knobs (FSQL_REASONING_HTTP_TIMEOUT_MS /
        FSQL_REASONING_HTTP_LOW_SPEED_SECS, ollama branch only), which
        the same restart applies; that Environment remains the fallback
        channel for anything else an admin sets there by hand.
      - mariadb.exe/mysql.exe (the MariaDB clients). Registration is two
        plain SQL files (sql/install_udf.sql + sql/install_agents.sql),
        not CREATE EXTENSION -- no catalog-version/staleness concept,
        since both scripts are unconditionally idempotent.
      - Verification functions are fractal_edition()/fractal_version()
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

.PARAMETER ServiceName
    Windows Service name to target, e.g. "MariaDB11". Optional: resolved
    automatically from the install being targeted, since machines with
    several MariaDB installs have several services (MariaDB, MariaDB11,
    MariaDB12, ...) and the literal name "MariaDB" belongs to whichever
    install registered it. Only needed when the service can't be matched
    to the install directory another way (custom service names pointing
    outside the install root).

.PARAMETER Database
    Target database for the agent stored procedures -- must already
    exist. UDFs themselves are server-global (mysql.func) and need no
    database; agent procedures are ordinary stored procedures and do
    (running install_agents.sql with none selected fails with
    "No database selected").

.PARAMETER Provider
    ollama | openai-compatible | skip

.PARAMETER TimeoutSecs
    Reasoning request timeout in seconds, applied as the reasoning
    plugin's FSQL_REASONING_HTTP_TIMEOUT_MS (minus 30s for its
    low-speed abort). Default 330, the same cold-start headroom the
    docker-compose demo sets: a local model that isn't loaded yet can
    take minutes before its first token, and the plugin's shorter
    built-in default turns that into a clean NULL. Only set for the
    ollama provider.

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
    [string]$ServiceName,
    [string]$Database,
    [ValidateSet('ollama', 'openai-compatible', 'skip')][string]$Provider,
    [string]$Url,
    [string]$Model,
    [string]$Token,
    [string]$EmbedUrl,
    [string]$EmbedModel,
    [int]$TimeoutSecs = 330,
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
# Resolved from the targeted install by Get-MariaDbTarget (see its
# comments); -ServiceName overrides the resolution. Not hardcoded here:
# machines with several installs have several candidate services.

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
# Single-target detection (no multi-install selector parameter, see
# this file's own .DESCRIPTION): exactly one MariaDB install to target,
# but NOT necessarily one service name. Reasoning config is applied to
# the fractalsqld daemon (conf keys + a restart of that service), so the
# MariaDB service has to be resolved from the install being targeted --
# machines with several installs register several services
# (MariaDB, MariaDB11, MariaDB12, ...) and the literal name "MariaDB"
# belongs to whichever install registered it. -ServiceName overrides the
# resolution when the service can't be matched another way.
function Find-ServiceForDir {
    param([string]$BaseDir)
    $binDir = (Join-Path $BaseDir 'bin').TrimEnd('\').ToLower()
    $found = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -and $_.PathName.ToLower().Contains($binDir)
    })
    return ($found | Select-Object -First 1)
}

function Get-MariaDbTarget {
    if ($MdbDir) {
        $exe = Join-Path $MdbDir 'bin\mariadbd.exe'
        if (-not (Test-Path $exe)) { Write-Die "-MdbDir '$MdbDir' doesn't look like a MariaDB install (no bin\mariadbd.exe)" }
        $svc = Find-ServiceForDir $MdbDir
        if (-not $svc) {
            Write-Die "no Windows Service runs a server out of '$MdbDir\bin'. If the service exists under a name that can't be matched to this directory, pass -ServiceName."
        }
        $script:ServiceName = $svc.Name
        return @{ Dir = $MdbDir; Port = (Get-PortFor $MdbDir) }
    }
    # No -MdbDir: auto-detect by the server binary, not by the literal
    # service name "MariaDB" -- that name is just one candidate, and on a
    # multi-install machine it can belong to a different major than the
    # one you meant.
    $svcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '[\\/](mariadbd|mysqld)\.exe'
    })
    if (-not $svcs) {
        Write-Die "no MariaDB Windows Service found (nothing runs mariadbd.exe/mysqld.exe). If MariaDB is installed as a no-service ZIP archive, pass -MdbDir."
    }
    if ($svcs.Count -gt 1) {
        Write-Host "Several MariaDB Windows Services found:"
        foreach ($s in $svcs) { Write-Host "  $($s.Name) -> $($s.PathName)" }
        Write-Die "pass -MdbDir <install dir> (or -ServiceName <name>) to pick one."
    }
    $svc = $svcs[0]
    # PathName looks like: "C:\Program Files\MariaDB 11.4\bin\mariadbd.exe" --defaults-file=...
    # (older installs register mysqld.exe; both names are the same binary.)
    $exePath = ($svc.PathName -replace '^"?([^"]+[\\/](mariadbd|mysqld)\.exe)".*$', '$1')
    if (-not (Test-Path $exePath)) { Write-Die "Service '$($svc.Name)' PathName didn't resolve to a real server exe ($exePath). Pass -MdbDir." }
    $dir = Split-Path (Split-Path $exePath -Parent) -Parent
    $script:ServiceName = $svc.Name
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
    try {
        $sqlText = [IO.File]::ReadAllText($Path)
        # install_udf.sql hardcodes SONAME 'fractalsql.so' on every CREATE
        # FUNCTION (the Linux load name). The UDF loader treats a SONAME
        # with an explicit extension as a literal filename, so on Windows
        # that has to be fractalsql.dll -- rewrite at pipe time rather than
        # diverge the file per platform. install_agents.sql is pure SQL/PSM
        # with no SONAME references, so this is a no-op for it.
        $sqlText = $sqlText -replace "SONAME 'fractalsql\.so'", "SONAME 'fractalsql.dll'"
        $proc.StandardInput.Write($sqlText)
        $proc.StandardInput.Close()
    } catch {
        # mariadb.exe exits on the first statement error, which breaks the
        # write pipe above. Fall through: the server's own error text on
        # stderr is the useful diagnostic, not this pipe exception.
    }
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "mariadb.exe (< $Path) failed: $errOut" }
    return $out.Trim()
}

# Restart-Service returns when the service reports Running, but mariadbd
# only starts accepting connections some seconds later. Everything this
# script does after a restart talks to the live server, so poll for
# readiness instead of racing it (a connection refused here used to
# surface as a confusing "pipe is being closed" from the client).
function Wait-ServerReady {
    param([string]$Bin, [int]$MdbPort, [int]$TimeoutSecs = 60)
    for ($i = 0; $i -lt $TimeoutSecs; $i++) {
        try {
            Invoke-Mariadb $Bin $MdbPort @('SELECT 1;') | Out-Null
            return $true
        } catch {
            Start-Sleep -Seconds 1
        }
    }
    return $false
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
    # @@plugin_dir reports backslash-escaped paths on Windows
    # ("C:\\Program Files\\..."). The reasoning plugin's loader doesn't
    # resolve that escape, so a reasoning_plugin conf path built
    # from the raw value never loads -- every reasoning call returns a
    # clean NULL with no error and no HTTP attempt. Normalize to single
    # separators before anything consumes it.
    $dir = $dir -replace '\\\\', '\'
    $script:PluginDir = $dir.TrimEnd('\')
}

function Test-Installed {
    return Test-Path (Join-Path $script:PluginDir 'fractalsql.dll')
}

# --- Phase B: install the package (default-on) ------------------------
function Install-MsiPackage {
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
# The nine reasoning_* provider settings are conf keys in fractalsqld.conf,
# the daemon's own config (the -Config file the fractalsqld service was
# registered with): read at daemon startup, applied by restarting the
# service -- there is no Windows reload client anywhere in the tree
# (fsqlctl is POSIX-only). Write-ConfProviderKeys writes them and
# Set-TimeoutEnvAndRestart writes the two env-only FSQL_* timeout knobs to
# the service's registry Environment (read once at daemon startup): the
# same restart applies both, and when the ollama branch sets knobs, the
# conf step defers its restart to that one. mariadbd.exe (and the shim it
# loads) is untouched: no restart, no dropped SQL connections.
#
# Both writes MERGE, not replace:
#  - the conf write is line-keyed: managed-key lines are dropped and,
#     unless byte-identical, re-appended, while every other line
#     (socket_path, hmac_key_file, allowed_pipe_sid, ...) survives
#     verbatim; and the file's DACL is re-restricted after every write
#     with the icacls recipe from provision-fractalsqld.ps1, because the
#     daemon's key_file_private gate refuses a conf DACL that allows
#     Everyone/Authenticated Users/BUILTIN\Users and C:\ProgramData's
#     default inheritance grants BUILTIN\Users read to anything there.
#  - the registry Environment write (a REG_MULTI_SZ *value* -- NOT a
#     subkey -- at HKLM:\SYSTEM\CurrentControlSet\Services\<service>;
#     the service manager only reads the value) preserves every entry
#     this wizard does not manage (e.g. FRACTALSQL_ENTERPRISE_LIB set up
#     by a separate enterprise install); wizard-managed keys overwrite
#     their own old values. A wholesale replace here is what silently
#     disables a previously-working enterprise tier on the next restart.
#     Uninstall used to delete the whole Environment value -- also
#     killing those unmanaged entries -- and now removes only
#     wizard-managed names too (same rationale, applied there).
$script:FractalsqldServiceName = 'fractalsqld'
# Fallback conf path when the service's own registration yields nothing
# usable -- also the standard layout provision-fractalsqld.ps1 writes.
$script:DefaultFractalsqldConf = 'C:\ProgramData\FractalSQL\fractalsqld.conf'

# Superset of every name this wizard (any generation) wrote as a service
# environment entry: the legacy FRACTALSQL_* provider names it used to
# set, plus the two env-only timeout knobs it still sets. One list covers
# both directions: a new run legacy-strips an older generation's entries
# (so the conf file stays the single preferred source for provider
# settings) before merging, and uninstall removes exactly these names and
# never an unmanaged one.
$script:WizardManagedRegistryKeys = @(
    'FRACTALSQL_REASONING_PLUGIN',
    'FRACTALSQL_HTTP_URL',
    'FRACTALSQL_HTTP_TOKEN',
    'FRACTALSQL_HTTP_MODEL',
    'FRACTALSQL_HTTP_ALLOW_PLAINTEXT',
    'FRACTALSQL_HTTP_EMBED_URL',
    'FRACTALSQL_HTTP_EMBED_MODEL',
    'FRACTALSQL_HTTP_THINK',
    'FRACTALSQL_HTTP_THINK_PROVIDER',
    'FSQL_REASONING_HTTP_TIMEOUT_MS',
    'FSQL_REASONING_HTTP_LOW_SPEED_SECS'
)

# The daemon service's conf path, from its own registration
# ('"<exe>" --service -c "<conf>"', written by fractalsqld-service.ps1):
# Win32_Service PathName first, the registry ImagePath as backup, and the
# ProgramData default when the parse fails or the file isn't there.
function Get-FractalsqldConfPath {
    $binPath = $null
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$script:FractalsqldServiceName'" -ErrorAction Stop
        if ($svc) { $binPath = $svc.PathName }
    } catch { }
    if (-not $binPath) {
        try {
            $binPath = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$script:FractalsqldServiceName" -ErrorAction Stop).ImagePath
        } catch { }
    }
    if ($binPath) {
        $m = [regex]::Match($binPath, '-c\s+"([^"]+)"')
        if ($m.Success) {
            $confPath = $m.Groups[1].Value
            if (Test-Path -LiteralPath $confPath) { return $confPath }
            Write-Warn2 "The $script:FractalsqldServiceName service points at conf '$confPath', but that file doesn't exist."
        }
    }
    return $script:DefaultFractalsqldConf
}

# The MariaDB service SID to grant RX on the hardened conf, so the
# daemon's key_file_private gate accepts it after inheritance is cut.
# First choice: the conf's own allowed_pipe_sid line (the provisioner
# wrote it from the MariaDB service's account). Fallback: derive it the
# way provision-fractalsqld.ps1 / install-test.yml do -- the account the
# mariadbd.exe/mysqld.exe service actually runs as, translated to a SID,
# LocalSystem (whose bare name NTAccount can't translate) -> S-1-5-18.
# Prefers the service this wizard already resolved for its target.
# $null means the SID couldn't be determined: the caller still writes the
# conf and applies the three broad grants (those are the ones the gate
# checks anyway, and the conf always carries allowed_pipe_sid when the
# provisioner ran) and leaves the per-service grant to a human check.
function Get-ConfAllowedSid {
    param([string]$ConfPath)

    if ($ConfPath -and (Test-Path -LiteralPath $ConfPath)) {
        try {
            foreach ($line in @(Get-Content -LiteralPath $ConfPath)) {
                if ($line -match '^allowed_pipe_sid\s*=(.*)$') {
                    $sid = $Matches[1].Trim()
                    if ($sid) { return $sid }
                    break
                }
            }
        } catch { }
    }
    $candidates = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '[\\/](mariadbd|mysqld)\.exe'
    })
    if (($candidates.Count -gt 0) -and $script:ServiceName) {
        $prefer = @($candidates | Where-Object { $_.Name -eq $script:ServiceName })
        if ($prefer.Count -gt 0) { $candidates = $prefer }
    }
    if ($candidates.Count -eq 0) { return $null }
    $startName = $candidates[0].StartName
    if ([string]::IsNullOrEmpty($startName) -or $startName -eq 'LocalSystem') {
        return 'S-1-5-18'   # LocalSystem's well-known SID; NTAccount can't translate the bare name
    }
    try {
        return (New-Object System.Security.Principal.NTAccount($startName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return $null
    }
}

# Core conf rewrite, shared by the direct (already-elevated) path and,
# serialized by Write-ConfProviderKeys/Invoke-Uninstall into the elevated
# child process (which defines nothing else from this script) -- so it is
# deliberately self-contained: plain Write-Host, no sibling helpers, no
# $script: variables, only its parameters. It
#   - reads every line of the conf,
#   - drops managed-key lines (a line that would be written back
#     byte-identical is kept in place instead -- the true no-op,
#     skip-if-identical case), plus any duplicate managed-key lines,
#   - appends 'key = value' for every entry not already present,
#     skipping empty values (load_config refuses an empty value on
#     reload),
#   - writes the result back UTF-8 WITHOUT a BOM (load_config reads the
#     first line's key literally; a BOM corrupts it),
#   - and re-restricts the DACL with the provision-fractalsqld.ps1
#     recipe: /inheritance:r, then LocalSystem F, Administrators F,
#     LOCAL SERVICE RX and the MariaDB service SID RX ($Sid may be empty
#     -- the three broad grants are the ones key_file_private checks).
# Returns 0 on success (including "nothing changed"), 1 on failure;
# progress/diagnostics go to the host.
function Set-ConfProviderLines {
    param([string]$ConfPath, [string]$Sid, [string]$Payload)

    try {
        # Write-ConfProviderKeys base64's the payload before handing it
        # here (both directly and via the elevated child's reconstructed
        # copy of this function) specifically so it survives that trip
        # with no quoting hazards. An empty payload (the uninstall-side
        # all-keys-dropped call) decodes back to '', so this is safe for
        # that case too.
        if ($Payload) {
            $Payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))
        }

        # The managed conf keys: exactly what this wizard writes. Ordered
        # matters only conceptually here; the payload drives appends.
        $managed = @(
            'reasoning_plugin',
            'reasoning_url',
            'reasoning_token',
            'reasoning_model',
            'reasoning_allow_plaintext',
            'embed_url',
            'embed_model',
            'think',
            'think_provider'
        )
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($pair in ($Payload -split "`n")) {
            if (-not $pair) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -lt 0) { continue }
            [void]$entries.Add(@{ k = $pair.Substring(0, $eq); v = $pair.Substring($eq + 1) })
        }

        # CR-tolerant split of 'key = value' (trim drops any stray CR).
        $lines = @(Get-Content -LiteralPath $ConfPath)
        $next = New-Object System.Collections.Generic.List[string]
        $present = @{}
        $dropped = New-Object System.Collections.Generic.List[string]
        foreach ($line in $lines) {
            $l = ('' + $line) -replace '\r$', ''
            $eq = $l.IndexOf('=')
            $lhs = ''
            $rhs = ''
            if ($eq -ge 0) { $lhs = $l.Substring(0, $eq).Trim(); $rhs = $l.Substring($eq + 1).Trim() } else { $lhs = $l.Trim() }
            if ($lhs -notin $managed) {
                $next.Add($l)
                continue
            }
            if ($present.ContainsKey($lhs)) {
                $dropped.Add($lhs)   # collapse a duplicate managed line
                continue
            }
            $desired = $null
            foreach ($e in $entries) {
                if ([string]$e.k -eq $lhs) { $desired = [string]$e.v; break }
            }
            if (($null -eq $desired) -or ($desired -eq '')) {
                $dropped.Add($lhs)
                continue
            }
            if ($rhs -eq $desired) {
                $next.Add($l)   # already identical: keep it in place
                $present[$lhs] = $true
            } else {
                $dropped.Add($lhs)
            }
        }
        $appended = 0
        foreach ($e in $entries) {
            $k = [string]$e.k
            $v = [string]$e.v
            if ($v -eq '') { continue }
            if ($present.ContainsKey($k)) { continue }
            $next.Add(('{0} = {1}' -f $k, $v))
            $present[$k] = $true
            $appended++
        }

        if (($dropped.Count -eq 0) -and ($appended -eq 0)) {
            Write-Host "[conf] $ConfPath already carries these keys with these values; nothing written."
            return 0
        }

        foreach ($d in $dropped) { Write-Host "[conf] dropping managed key: $d" }
        foreach ($k in $present.Keys) { Write-Host "[conf] set $k" }

        [IO.File]::WriteAllLines($ConfPath, $next.ToArray(), (New-Object System.Text.UTF8Encoding($false)))

        # Same recipe provision-fractalsqld.ps1 applies after writing this
        # file (see its comments): the daemon refuses a conf DACL that
        # allows Everyone (S-1-1-0), Authenticated Users (S-1-5-11) or
        # BUILTIN\Users (S-1-5-32-545), and rewiring inheritance away is
        # what removes those from a ProgramData-created file.
        $grants = @('*S-1-5-18:(F)', '*S-1-5-32-544:(F)', '*S-1-5-19:(RX)')
        if ($Sid) { $grants += "*$($Sid):(RX)" }
        # The array expands into one icacls argument per element.
        icacls $ConfPath /inheritance:r /grant:r $grants | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[conf] icacls FAILED on $ConfPath (exit $LASTEXITCODE): the daemon refuses a conf readable by Everyone/Authenticated Users/BUILTIN\Users. Fix the DACL by hand before (re)starting the service." -ForegroundColor Red
            return 1
        }
        return 0
    } catch {
        Write-Host ("[conf] failed to rewrite '$ConfPath': " + $_.Exception.Message) -ForegroundColor Red
        return 1
    }
}

function Write-ConfProviderKeys {
    # $ConfValues: [ordered] key -> value. $Restart: when the caller also
    # has env-only knobs to set, it passes $false and ITS restart (in
    # Set-TimeoutEnvAndRestart) applies the conf keys -- the daemon
    # restarts once and picks up both halves. Default $true: the conf
    # step's own restart applies them.
    param($ConfValues, [bool]$Restart = $true)

    if (-not (Get-Service -Name $script:FractalsqldServiceName -ErrorAction SilentlyContinue)) {
        Write-Warn2 "No '$script:FractalsqldServiceName' Windows Service found. Register it first: scripts\windows\fractalsqld-service.ps1 -Action install -Exe <path to fractalsqld.exe> -Config <path to fractalsqld.conf>."
        return $false
    }
    $confPath = Get-FractalsqldConfPath
    if (-not (Test-Path -LiteralPath $confPath)) {
        Write-Warn2 "No fractalsqld.conf found at '$confPath' (the fallback default; not written yet). Register the daemon first: scripts\windows\fractalsqld-service.ps1 -Action install -Exe <path to fractalsqld.exe> -Config <path to fractalsqld.conf>."
        return $false
    }

    Write-Step "About to write (conf file '$confPath'):"
    foreach ($k in $ConfValues.Keys) {
        if ($k -eq 'reasoning_token') { Write-Host '  reasoning_token = ***' } else { Write-Host "  $k = $($ConfValues[$k])" }
    }
    $applyMsg = "Apply this configuration? This writes the reasoning_* conf keys into '$confPath', re-hardening the file's ACL after the write (the daemon's key_file_private gate refuses a conf readable by Everyone/Authenticated Users/BUILTIN\Users)."
    if ($Restart) {
        $applyMsg += " The write is applied by a restart of fractalsqld (the daemon fractal_reason/fractal_embed run in), not the MariaDB service -- active SQL connections are undisturbed; an in-flight reasoning/embedding call on the daemon is dropped."
    }
    if (-not (Confirm-Step $applyMsg)) {
        Write-Warn2 "Aborted. Nothing was changed."
        return $false
    }
    $doRestart = $Restart
    if ($doRestart) {
        $doRestart = Confirm-Step "Restart fractalsqld now to apply it?"
        if (-not $doRestart) {
            Write-Warn2 "Not restarted. The conf keys won't take effect until you run: Restart-Service $script:FractalsqldServiceName (as Administrator)"
            return $false
        }
    }

    $sid = Get-ConfAllowedSid $confPath
    if (-not $sid) {
        Write-Warn2 "Couldn't determine the MariaDB service account's SID (no allowed_pipe_sid line in the conf and the fallback derivation failed). Still writing the conf and the three broad grants -- the daemon runs as NT AUTHORITY\LocalService so those usually cover it -- but check the conf's DACL by hand."
    }
    # One line per entry, 'key=value', base64'd for the child process:
    # no quoting hazards, and the token never appears on a command line.
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($k in $ConfValues.Keys) {
        $v = [string]$ConfValues[$k]
        if ($v -eq '') { continue }
        $pairs.Add("$k=$v")
    }
    $payload64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($pairs -join "`n")))

    if (Test-IsAdmin) {
        # Already elevated: run the merge (and, when asked for, the
        # restart) directly.
        try {
            $rc = Set-ConfProviderLines -ConfPath $confPath -Sid $sid -Payload $payload64
            if ($rc -ne 0) { return $false }
            if ($doRestart) { Restart-Service -Name $script:FractalsqldServiceName -Force }
        } catch {
            Write-Warn2 "Could not complete the conf write/restart ($($_.Exception.Message)). Fix '$confPath' by hand and restart $script:FractalsqldServiceName yourself."
            return $false
        }
    } elseif ([Environment]::UserInteractive) {
        # The read-modify-write + icacls all run inside the elevated
        # child: a non-admin can neither read the hardened conf nor
        # icacls it, so the merge logic travels with it -- the definition
        # of Set-ConfProviderLines, serialized here and re-parsed there.
        # -EncodedCommand, not -Command: the serialized body speaks in
        # real double-quoted strings, which the -Command tail would eat.
        Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
        try {
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add("`$ErrorActionPreference = 'Stop'")
            $parts.Add('function Set-ConfProviderLines { ' + ${function:Set-ConfProviderLines}.ToString() + ' }')
            $parts.Add("`$rc = Set-ConfProviderLines -ConfPath '$($confPath.Replace("'", "''"))' -Sid '$sid' -Payload '$payload64'")
            $parts.Add('if ($rc -ne 0) { exit 1 }')
            if ($doRestart) { $parts.Add("Restart-Service -Name '$script:FractalsqldServiceName' -Force") }
            $parts.Add('exit 0')
            $childCode = $parts -join '; '
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
            if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
        } catch {
            Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Run this whole script from an Administrator PowerShell, or edit '$confPath' by hand: set the reasoning_* keys there, re-apply the icacls recipe from scripts\windows\provision-fractalsqld.ps1, and restart $script:FractalsqldServiceName."
            return $false
        }
    } else {
        Write-Warn2 "Skipping: this needs administrator access and there's no interactive session to grant it in. Run this whole script from an Administrator PowerShell, or edit '$confPath' by hand: set the reasoning_* keys there, re-apply the icacls recipe from scripts\windows\provision-fractalsqld.ps1, and restart $script:FractalsqldServiceName."
        return $false
    }

    if ($doRestart) {
        Write-Step "Waiting for $script:FractalsqldServiceName to report Running..."
        $ready = $false
        for ($i = 0; $i -lt 30; $i++) {
            if ((Get-Service -Name $script:FractalsqldServiceName).Status -eq 'Running') { $ready = $true; break }
            Start-Sleep -Seconds 1
        }
        if (-not $ready) {
            Write-Warn2 "$script:FractalsqldServiceName didn't report Running within 30s of the restart. Check the Windows Event Log / its own log file before continuing -- a conf the key_file_private gate rejects is the usual suspect."
            return $false
        }
        Write-Ok "$script:FractalsqldServiceName restarted with the new reasoning config (conf keys)."
        return $true
    }
    # No restart here: the caller's own Set-TimeoutEnvAndRestart restart
    # applies what was just written.
    Write-Ok "Conf keys written to $confPath."
    return $true
}

# The uninstall-side half of the conf cleanup: the same filter as
# Write-ConfProviderKeys, no appends (an empty payload = every managed
# key line dropped), the file itself kept, and the DACL re-restricted
# only if lines were actually removed (the same skip-if-identical rule).
# Direct (already-elevated) path only: the non-admin cleanup rides
# Invoke-Uninstall's single elevated child, which serializes
# Set-ConfProviderLines itself with an empty payload.
function Remove-ConfProviderKeys {
    param([string]$ConfPath, [string]$Sid)
    $rc = Set-ConfProviderLines -ConfPath $ConfPath -Sid $Sid -Payload ''
    return ($rc -eq 0)
}

function Set-TimeoutEnvAndRestart {
    # INPUT: only the two env-only FSQL_* timeout knobs -- the reasoning
    # provider settings went to the daemon's conf file instead (see this
    # file's .DESCRIPTION). NOTE: when the wizard just wrote conf keys,
    # THIS function's restart is the one that applies them (the conf is
    # read by the daemon at startup), so don't drop the restart here.
    # Still a MERGE: entries already on the service that this wizard does
    # not manage (e.g. FRACTALSQL_ENTERPRISE_LIB set up by a separate
    # enterprise install) are preserved; wizard keys overwrite their own
    # old values. A wholesale replace here is what silently disables a
    # previously-working enterprise tier on the next restart. Before the
    # merge, entries an OLDER generation of this wizard wrote (the legacy
    # FRACTALSQL_* names, $script:WizardManagedRegistryKeys) are
    # legacy-stripped -- uninstall used to nuke the whole Environment
    # value (and every unmanaged entry with it) and now preserves those
    # too, matching this.
    param($EnvValues)

    if (-not (Get-Service -Name $script:FractalsqldServiceName -ErrorAction SilentlyContinue)) {
        Write-Warn2 "No '$script:FractalsqldServiceName' Windows Service found. Register it first: scripts\windows\fractalsqld-service.ps1 -Action install -Exe <path to fractalsqld.exe> -Config <path to fractalsqld.conf>."
        return $false
    }

    Write-Step "About to set (service environment for '$script:FractalsqldServiceName'):"
    foreach ($k in $EnvValues.Keys) {
        if ($k -like '*HTTP_TOKEN*') { Write-Host "  $k=***" } else { Write-Host "  $k=$($EnvValues[$k])" }
    }
    $applyMsg = "Apply this configuration? This merges those FSQL_* timeout entries into the fractalsqld service's registry environment."
    if (-not (Confirm-Step $applyMsg)) {
        Write-Warn2 "Aborted. Nothing was changed."
        return $false
    }

    $doRestart = Confirm-Step "Restart $script:FractalsqldServiceName now to apply it (this restart also applies any reasoning_* conf keys just written -- one restart, both sources)?"
    if (-not $doRestart) {
        Write-Warn2 "Not restarted. Neither the conf keys nor the timeout knobs will take effect until you run: Restart-Service $script:FractalsqldServiceName (as Administrator)"
        return $false
    }

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$script:FractalsqldServiceName"
    $existing = @()
    try {
        $existing = @(Get-ItemProperty $regPath -ErrorAction Stop).Environment
    } catch { }
    $kept = @()
    foreach ($entry in $existing) {
        if (-not $entry) { continue }
        $name = $entry.Split('=', 2)[0]
        if ($script:WizardManagedRegistryKeys -contains $name) {
            if (@($EnvValues.Keys) -notcontains $name) {
                # A legacy FRACTALSQL_* name this wizard wrote (or an old
                # timeout knob): strip it, not refresh it -- the conf
                # file is the preferred source now.
                Write-Warn2 "dropping wizard-managed legacy entry: $name"
            }
            continue
        }
        $kept += $entry
    }
    if ($kept.Count -gt 0) {
        Write-Step ("Preserving existing service-environment entries this wizard does not manage: " +
            (($kept | ForEach-Object { $_.Split('=', 2)[0] }) -join ', '))
    }
    $regValues = $kept + @($EnvValues.Keys | ForEach-Object { "$_=$($EnvValues[$_])" })
    $quotedValues = ($regValues | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
    $elevatedCmd = "Set-ItemProperty -Path '$regPath' -Name Environment -Value @($quotedValues) -Type MultiString"
    if ($doRestart) { $elevatedCmd += "; Restart-Service -Name '$script:FractalsqldServiceName' -Force" }

    if (Test-IsAdmin) {
        # Already elevated: run the cmdlets directly.
        try {
            Set-ItemProperty -Path $regPath -Name Environment -Value ([string[]]$regValues) -Type MultiString
            Restart-Service -Name $script:FractalsqldServiceName -Force
        } catch {
            Write-Warn2 "Could not write the service environment ($($_.Exception.Message)). Set those values by hand under $regPath and restart $script:FractalsqldServiceName yourself."
            return $false
        }
    } elseif ([Environment]::UserInteractive) {
        Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
        try {
            $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $elevatedCmd)
            if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
        } catch {
            Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Set the values by hand under $regPath and restart $script:FractalsqldServiceName, or re-run this whole script from an Administrator PowerShell."
            return $false
        }
    } else {
        Write-Warn2 "Skipping: this needs administrator access and there's no interactive session to grant it in. Set the values by hand under $regPath and restart $script:FractalsqldServiceName, or re-run this whole script from an Administrator PowerShell."
        return $false
    }

    Write-Step "Waiting for $script:FractalsqldServiceName to report Running..."
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        if ((Get-Service -Name $script:FractalsqldServiceName).Status -eq 'Running') { $ready = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $ready) {
        Write-Warn2 "$script:FractalsqldServiceName didn't report Running within 30s of the restart. Check the Windows Event Log / its own log file before continuing -- a conf the key_file_private gate rejects is the usual suspect."
        return $false
    }
    Write-Ok "$script:FractalsqldServiceName restarted with the new reasoning config (timeout knobs + conf keys from this run)."
    return $true
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

    # Provider settings go into the daemon's conf file as reasoning_*
    # conf keys (preferred source, see this file's .DESCRIPTION); the
    # service's registry Environment gets only the env-only FSQL_*
    # timeout knobs, ollama branch only.
    $confValues = [ordered]@{}
    $envValues = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Ollama chat URL" "http://localhost:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = Prompt-Value "Ollama embeddings URL" "http://localhost:11434/v1/embeddings" }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $confValues['reasoning_plugin'] = $pluginDll
            $confValues['reasoning_url'] = $Url
            $confValues['reasoning_allow_plaintext'] = '1'
            $confValues['reasoning_model'] = $Model
            $confValues['embed_url'] = $EmbedUrl
            $confValues['embed_model'] = $EmbedModel
            $confValues['think'] = $Think
            $confValues['think_provider'] = $ThinkProvider
            # Cold-start headroom for a local Ollama: a model that isn't
            # loaded yet can take minutes before its first token, and the
            # plugin's shorter built-in default turns that into a clean
            # NULL. Same values docker-compose.yml sets for the same
            # reason (330000ms / 300s). These two are env-only knobs
            # (they live in the service's registry Environment, not the
            # conf file), so they ride the one restart below too.
            $envValues['FSQL_REASONING_HTTP_TIMEOUT_MS'] = "$($TimeoutSecs * 1000)"
            $envValues['FSQL_REASONING_HTTP_LOW_SPEED_SECS'] = "$([Math]::Max(1, $TimeoutSecs - 30))"
        }
        'openai-compatible' {
            if (-not $Url) { $Url = Prompt-Value "Chat completions URL" }
            if (-not $Url) { Write-Die "a URL is required for a cloud/OpenAI-compatible endpoint" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked, never logged)" }
            $confValues['reasoning_plugin'] = $pluginDll
            $confValues['reasoning_url'] = $Url
            $confValues['reasoning_token'] = $Token
            $confValues['reasoning_model'] = $Model
            if ($Url -notlike 'https://*') {
                Write-Warn2 "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            }
        }
        'skip' {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
        }
    }

    $applied = $false
    if ($Provider -ne 'skip') {
        if ($DryRun) {
            Write-Step "About to write (conf file '$(Get-FractalsqldConfPath)', reasoning keys):"
            foreach ($k in $confValues.Keys) {
                if ($k -eq 'reasoning_token') { Write-Host '  reasoning_token = ***' } else { Write-Host "  $k = $($confValues[$k])" }
            }
            if ($envValues.Count -gt 0) {
                Write-Step "About to set (service environment for '$script:FractalsqldServiceName', env-only timeout knobs):"
                foreach ($k in $envValues.Keys) { Write-Host "  $k=$($envValues[$k])" }
            }
            Write-Warn2 "(-DryRun: not actually writing anything). Conf keys take effect at the service restart (no Windows fsqlctl)."
        } else {
            # Conf keys first (the preferred source). When there are
            # env-only knobs to set too, the conf step defers its restart
            # to Set-TimeoutEnvAndRestart below: that restart is the one
            # that applies the conf keys, so the daemon restarts once and
            # picks up both halves.
            $applied = Write-ConfProviderKeys $confValues -Restart (-not ($envValues.Count -gt 0))
            if ($envValues.Count -gt 0) {
                if (-not $applied) {
                    Write-Warn2 "The reasoning_* conf keys were not written (see the warning above), so they won't be applied even by the restart below."
                }
                $applied = $applied -and (Set-TimeoutEnvAndRestart $envValues)
            }
        }
    }

    Write-Step "Registering UDFs + agent procedures..."
    $already = ''
    try { $already = Invoke-Mariadb $bin $mdbPort @("SELECT 1 FROM mysql.func WHERE name='fractal_edition';") } catch { $already = '' }
    if ($already -and -not $ForceReinstall) {
        if (-not (Confirm-Step "fractal_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?")) {
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
        $ed = Invoke-Mariadb $bin $mdbPort @('SELECT fractal_edition();') -Db $Database
        $ver = Invoke-Mariadb $bin $mdbPort @('SELECT fractal_version();') -Db $Database
        Write-Ok "fractal_edition() = $ed, fractal_version() = $ver"
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
            Write-Warn2 "Reasoning config wasn't applied (a step was declined or failed above), so skipping the smoke test. fractal_reason() will use whatever config the daemon already has."
        }
    }

    Write-Host ""
    Write-Host "You're set up. Where next:" -ForegroundColor Green
    Write-Host "  - docs/starter-kits.md: industry-specific runnable examples"
    Write-Host "  - docs/api-agency.md: the 16 built-in agents, full reference"
    Write-Host "  - docs/composition-guide.md: build your own agent"
    Write-Host "  - Re-run this script anytime to switch providers or models. It's"
    Write-Host "    safe: it rewrites the reasoning_* keys in the daemon's conf"
    Write-Host "    file and restarts the fractalsqld service (there's no Windows"
    Write-Host "    fsqlctl). The service's registry Environment now holds only"
    Write-Host "    the FSQL_* timeout knobs -- the env fallback channel for"
    Write-Host "    anything else an admin sets there."
}

# --- -Uninstall ---------------------------------------------------------
function Invoke-Uninstall {
    param($Target)
    $bin = Join-Path $Target.Dir 'bin'
    $mdbPort = if ($Port) { $Port } else { $Target.Port }
    Resolve-RootPassword
    Write-Step "This will strip the wizard's reasoning_* conf keys from the daemon's fractalsqld.conf (the file itself is kept and its ACL re-hardened only if they were found) and remove the two FSQL_* timeout knobs -- plus any legacy FRACTALSQL_* names earlier generations wrote -- from the fractalsqld service's registry Environment, preserving every non-wizard entry, then restart fractalsqld (not the MariaDB service)."

    if (Confirm-Step "Reset reasoning config now?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually resetting)"
        } elseif (-not (Get-Service -Name $script:FractalsqldServiceName -ErrorAction SilentlyContinue)) {
            Write-Warn2 "No '$script:FractalsqldServiceName' Windows Service found; nothing to reset."
        } else {
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$script:FractalsqldServiceName"

            # Registry half: HKLM service keys are world-readable, so the
            # filter runs here and only the write-back is elevated.
            # Remove exactly the wizard-managed names, keep the rest.
            $existing = @()
            try { $existing = @(Get-ItemProperty $regPath -ErrorAction Stop).Environment } catch { }
            $kept = @()
            foreach ($entry in $existing) {
                if (-not $entry) { continue }
                if ($script:WizardManagedRegistryKeys -contains $entry.Split('=', 2)[0]) { continue }
                $kept += $entry
            }
            if ($kept.Count -gt 0) {
                Write-Step ("Preserving non-wizard registry entries: " +
                    (($kept | ForEach-Object { $_.Split('=', 2)[0] }) -join ', '))
            } elseif ($existing.Count -gt 0) {
                Write-Step "Every Environment entry was a wizard-managed one; the value will be removed."
            }
            $quotedValues = ''
            if ($kept.Count -gt 0) {
                $quotedValues = ($kept | ForEach-Object { "'$($_ -replace "'", "''")'" }) -join ','
            }

            # Conf half: resolve the path (existence check needs no read
            # access) and the SID here; if the hardened conf denies even
            # reading to this token, Get-ConfAllowedSid falls back to the
            # MariaDB-service derivation, which needs no read either.
            $confPath = Get-FractalsqldConfPath
            $confExists = Test-Path -LiteralPath $confPath
            $sid = ''
            if ($confExists) { $sid = Get-ConfAllowedSid $confPath }

            if ((-not $confExists) -and ($kept.Count -eq 0)) {
                Write-Warn2 "Nothing found to reset: no conf at '$confPath' and no wizard-managed registry Environment entries."
            } elseif (Test-IsAdmin) {
                # Already elevated: run both halves directly.
                try {
                    if ($confExists) {
                        if (-not (Remove-ConfProviderKeys $confPath $sid)) {
                            Write-Warn2 "The conf cleanup at '$confPath' didn't succeed (see the message above); check the file by hand."
                        }
                    }
                    if ($kept.Count -gt 0) {
                        Set-ItemProperty -Path $regPath -Name Environment -Value ([string[]]$kept) -Type MultiString
                    } else {
                        Remove-ItemProperty -Path $regPath -Name Environment -ErrorAction SilentlyContinue
                    }
                    Restart-Service -Name $script:FractalsqldServiceName -Force
                    Write-Ok "Reasoning conf keys and wizard-managed environment entries reset."
                } catch {
                    Write-Warn2 "Could not complete the reset ($($_.Exception.Message)). Remove the reasoning_* lines from '$confPath' and the Environment value under $regPath by hand, then restart $script:FractalsqldServiceName."
                }
            } elseif ([Environment]::UserInteractive) {
                Write-Step "This needs administrator access. Windows will show a permission prompt. Accept it to continue."
                # One elevated child does all three halves (one UAC
                # prompt): the conf strip (Set-ConfProviderLines
                # serialized from this script, empty payload = drop only),
                # the registry write-back, and the restart.
                try {
                    $childParts = New-Object System.Collections.Generic.List[string]
                    $childParts.Add("`$ErrorActionPreference = 'Stop'")
                    if ($confExists) {
                        $childParts.Add('function Set-ConfProviderLines { ' + ${function:Set-ConfProviderLines}.ToString() + ' }')
                        $childParts.Add("`$rc = Set-ConfProviderLines -ConfPath '$($confPath.Replace("'", "''"))' -Sid '$sid' -Payload ''")
                        $childParts.Add('if ($rc -ne 0) { exit 1 }')
                    }
                    if ($kept.Count -gt 0) {
                        $childParts.Add("Set-ItemProperty -Path '$regPath' -Name Environment -Value @($quotedValues) -Type MultiString")
                    } else {
                        $childParts.Add("Remove-ItemProperty -Path '$regPath' -Name Environment -ErrorAction SilentlyContinue")
                    }
                    $childParts.Add("Restart-Service -Name '$script:FractalsqldServiceName' -Force")
                    $childCode = $childParts -join '; '
                    # -EncodedCommand, not -Command: the serialized body
                    # speaks in real double-quoted strings, which the
                    # -Command tail would eat.
                    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCode))
                    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
                        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc)
                    if ($p.ExitCode -ne 0) { throw "elevated step exited with code $($p.ExitCode)" }
                    Write-Ok "Reasoning conf keys and wizard-managed environment entries reset."
                } catch {
                    Write-Warn2 "Couldn't complete this as administrator ($($_.Exception.Message)). Remove the reasoning_* lines from '$confPath' and the Environment value under $regPath by hand, then restart $script:FractalsqldServiceName."
                }
            } else {
                Write-Warn2 "Skipping: needs administrator access and there's no interactive session to grant it in. Remove the reasoning_* lines from '$confPath' and the Environment value under $regPath by hand, then restart $script:FractalsqldServiceName."
            }
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
# root password has to be in hand first -- both ahead of Install-MsiPackage,
# which itself depends on $script:PluginDir via Test-Installed.
Resolve-RootPassword
Resolve-PluginDir $target
Write-Step "Plugin directory (live @@plugin_dir): $script:PluginDir"

Install-MsiPackage $target
Invoke-Wizard $target
