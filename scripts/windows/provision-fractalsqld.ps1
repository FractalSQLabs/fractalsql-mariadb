<#
.SYNOPSIS
Provisions fractalsqld after the FractalSQL MSI's files are staged: generates
the shared HMAC key, writes both config files (resolving allowed_pipe_sid
from whatever account the MariaDB service actually runs as), and registers
+ starts the fractalsqld Windows service.

This is the Windows equivalent of what packaging/scripts/postinst.sh does
for the .deb/.rpm packages -- the MSI itself (fractalsql.wxs) only copies
files, so without this, fractalsqld is never configured or started and
every UDF call fails with "cannot read fractalsql.conf" or "fractalsqld is
not reachable".

Run as a deferred CustomAction from fractalsql.wxs, right after InstallFiles
(see that file's own comments); also safe to run by hand if the automated
install step above couldn't finish the job (the installed README.txt
describes the equivalent manual steps).

Idempotent and best-effort, matching postinst.sh's own philosophy:
  - an existing key or config file is never overwritten (a reinstall or
    MSI repair must not rotate the shared secret or clobber an admin's
    hand-edited config);
  - if the MariaDB service can't be found yet (not installed, or running
    under a name/path this script's detection doesn't recognize), or
    anything else here fails, this prints guidance and exits 0 rather
    than failing -- the MSI has already placed every file correctly
    either way, and the installed README.txt's manual steps still work.

.PARAMETER FractalsqldExe
Full path to the just-installed fractalsqld.exe.

.PARAMETER MariaDbMajor
Optional MariaDB major-version string (e.g. "11.4"). Used only to
disambiguate when the machine hosts MORE than one mariadbd/mysqld
Windows service: the service whose install path matches this version
wins. The MSI always passes it (it knows which MariaDB major it was
built against, see fractalsql.wxs's $(var.MARIADB_MAJOR)); without it
the first matching service found is used, right for single-install
machines.
#>
param(
    [Parameter(Mandatory = $true)][string]$FractalsqldExe,
    [string]$MariaDbMajor = ''
)

function Write-Log { param([string]$Msg) Write-Host "[provision-fractalsqld] $Msg" }

$fsqlDir   = 'C:\ProgramData\FractalSQL'
$fsqldConf = Join-Path $fsqlDir 'fractalsqld.conf'
$fsqlConf  = Join-Path $fsqlDir 'fractalsql.conf'
$keyPath   = Join-Path $fsqlDir 'hmac.key'
# Named-pipe convention fractalsqld.c expects (FSQ_PIPE_PREFIX): a plain
# config-file line, not a PowerShell-escaped string -- single quotes
# below keep every backslash literal.
$pipeLine  = 'socket_path = \\.\pipe\fractalsqld'
$giveUp    = 'See the installed README.txt to finish this by hand.'

try {
    New-Item -ItemType Directory -Force -Path $fsqlDir | Out-Null

    if (-not (Test-Path -LiteralPath $keyPath)) {
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $hmacHex = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
        Set-Content -LiteralPath $keyPath -Value $hmacHex -NoNewline -Encoding ascii
        Write-Log "Generated $keyPath"
    } else {
        Write-Log "$keyPath already exists, keeping it."
    }

    # Whichever running service hosts mariadbd.exe/mysqld.exe -- not
    # assumed to be named "MariaDB": MariaDB's own installer lets the
    # user pick any service name. On a machine holding several MariaDB
    # installs at once -- confirmed live, the detection below picked
    # the wrong one, granting the key and the pipe to service X's SID
    # while the tested server ran as service Y's -- -MariaDbMajor
    # prefers the one matching the MariaDB major this MSI was built
    # against.
    $candidates = Get-CimInstance Win32_Service | Where-Object {
        $_.PathName -match '(mariadbd|mysqld)\.exe'
    }
    if (-not $candidates) {
        Write-Log "No running mariadbd/mysqld Windows service found yet -- skipping config and service setup. $giveUp"
        exit 0
    }
    $mdbSvc = $null
    if ($MariaDbMajor) {
        $mdbSvc = $candidates | Where-Object { $_.PathName -match [regex]::Escape("MariaDB $($MariaDbMajor)") } | Select-Object -First 1
        if (-not $mdbSvc) {
            Write-Log "No service in 'MariaDB $($MariaDbMajor)' install path found (candidates: $($candidates.Name -join ', ')); using the first one found."
        }
    }
    if (-not $mdbSvc) {
        $mdbSvc = $candidates | Select-Object -First 1
        if ($candidates.Count -gt 1) {
            Write-Log "Multiple services host mariadbd/mysqld ($($candidates.Name -join ', ')); picked '$($mdbSvc.Name)'. If that's the wrong MariaDB install, run again with -MariaDbMajor."
        }
    }

    # allowed_pipe_sid must be the account mariadbd (and so the shim
    # loaded inside it) actually runs as, not whatever account is
    # installing this package -- see fractalsqld-service.ps1's own
    # header comment for why.
    $startName = $mdbSvc.StartName
    if ([string]::IsNullOrEmpty($startName) -or $startName -eq 'LocalSystem') {
        $sid = 'S-1-5-18'   # LocalSystem's well-known SID; NTAccount can't translate the bare name
    } else {
        try {
            $sid = (New-Object System.Security.Principal.NTAccount($startName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        } catch {
            Write-Log "Couldn't resolve a SID for '$startName' ($($_.Exception.Message)) -- skipping config and service setup. $giveUp"
            exit 0
        }
    }
    Write-Log "MariaDB service '$($mdbSvc.Name)' runs as '$startName' (SID $sid)."

    if (-not (Test-Path -LiteralPath $fsqldConf)) {
        @($pipeLine, "hmac_key_file = $keyPath", "allowed_pipe_sid = $sid") |
            Set-Content -LiteralPath $fsqldConf -Encoding ascii
        Write-Log "Wrote $fsqldConf"
    } else {
        Write-Log "$fsqldConf already exists, keeping it."
    }
    if (-not (Test-Path -LiteralPath $fsqlConf)) {
        @($pipeLine, "hmac_key_file = $keyPath") |
            Set-Content -LiteralPath $fsqlConf -Encoding ascii
        Write-Log "Wrote $fsqlConf"
    } else {
        Write-Log "$fsqlConf already exists, keeping it."
    }

    # Restrict the key and config files' ACLs: the Windows equivalent of
    # the Linux postinst chmod 600 on the key. The daemon refuses to
    # start if hmac.key is readable by Everyone, Authenticated Users or
    # BUILTIN\Users (key_file_private() in service/daemon/fractalsqld.c),
    # and ProgramData's default inheritance grants BUILTIN\Users RX to
    # every file created here -- confirmed live, the service exited at
    # once with "service-specific error: Incorrect function" and logged
    # exactly that key-permission complaint. Applied on every run, not
    # just on first write, so a reinstall or repair also fixes an
    # over-permissive key left behind by an older provisioner. The
    # per-service SID grants are needed and allowed:
    #   - LOCAL SERVICE runs the daemon (reads the key + fractalsqld.conf)
    #   - the MariaDB service account's shim inside mariadbd reads the
    #     key (to sign pipe requests) and fractalsql.conf
    # key_file_private() only reacts to the three broad groups, not to
    # individual service SIDs.
    $hardened = @(
        @{ Path = $keyPath; Grant = @('*S-1-5-18:(F)', '*S-1-5-32-544:(F)', '*S-1-5-19:(RX)', "*$($sid):(RX)") },
        @{ Path = $fsqldConf; Grant = @('*S-1-5-18:(F)', '*S-1-5-32-544:(F)', '*S-1-5-19:(RX)', "*$($sid):(RX)") },
        @{ Path = $fsqlConf; Grant = @('*S-1-5-18:(F)', '*S-1-5-32-544:(F)', "*$($sid):(RX)") }
    )
    foreach ($entry in $hardened) {
        # The array expands into one icacls argument per element.
        icacls $entry.Path /inheritance:r /grant:r $entry.Grant | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not restrict the ACL on $entry.Path (icacls exit $LASTEXITCODE); the daemon will refuse the key until this is fixed by hand. $giveUp"
        }
    }

    if (-not (Get-Service -Name fractalsqld -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path -LiteralPath $FractalsqldExe)) {
            Write-Log "FractalsqldExe '$FractalsqldExe' doesn't exist -- skipping service registration. $giveUp"
            exit 0
        }
        # [System.IO.Path]::GetDirectoryName(), not Split-Path -Parent:
        # confirmed live, Split-Path -LiteralPath $x -Parent throws
        # "Parameter set cannot be resolved using the specified named
        # parameters" on at least one real machine/PowerShell edition
        # -- the plain .NET API does the same thing with no cmdlet
        # parameter-set involved at all.
        $serviceScript = Join-Path ([System.IO.Path]::GetDirectoryName($FractalsqldExe)) 'fractalsqld-service.ps1'
        if (-not (Test-Path -LiteralPath $serviceScript)) {
            Write-Log "fractalsqld-service.ps1 not found next to '$FractalsqldExe' (expected at '$serviceScript') -- skipping service registration. $giveUp"
            exit 0
        }
        # Direct call, no nested powershell.exe/Start-Process: we are
        # already running inside a PowerShell host (launched by the
        # CustomAction in fractalsql.wxs), so there is no reason to
        # spawn a second one just to run a sibling .ps1 -- and doing
        # so was actively wrong: it surfaced a confusing, unrelated
        # "Parameter set cannot be resolved" error instead of the
        # real one (confirmed live: calling fractalsqld-service.ps1
        # directly with the exact same arguments, bypassing any
        # wrapper, raised the correct, specific error -- here, "Access
        # is denied" from New-Service, i.e. the caller wasn't
        # elevated, nothing to do with argument passing at all).
        # fractalsqld-service.ps1 sets $ErrorActionPreference = 'Stop'
        # itself, so a real failure (New-Service, Set-ItemProperty,
        # ...) throws here and is caught by the try/catch below.
        & $serviceScript -Action install -Exe $FractalsqldExe -Config $fsqldConf
    } else {
        Write-Log "Service 'fractalsqld' already exists, leaving its registration alone."
    }

    try {
        # -ErrorAction Stop: Start-Service failure is a non-terminating
        # error by default, so without this the catch never fired and
        # the script went on to claim success ("service started") right
        # after a visible Start-Service error (confirmed live on a
        # reinstall run).
        #
        # Stop first when already running: on a reinstall the daemon must
        # restart anyway to load the freshly installed exe (the old image
        # keeps running otherwise) and to rebuild its pipe security
        # descriptor from the config, rather than keep the pre-reinstall
        # one.
        if ((Get-Service -Name fractalsqld -ErrorAction Stop).Status -eq 'Running') {
            Stop-Service -Name fractalsqld -ErrorAction Stop
        }
        Start-Service -Name fractalsqld -ErrorAction Stop
        Write-Log "fractalsqld service started."
    } catch {
        # A start failure with "Access is denied" most often means the
        # service account (NT AUTHORITY\LocalService) cannot read/execute
        # the exe itself, e.g. when the binary sits in a user-profile
        # directory whose ACL grants nothing to service accounts (the
        # normal MSI installdir under Program Files is universally
        # readable, so this bites only manual/alternative layouts).
        $msg = $_.Exception.Message
        $aclHint = if ($msg -match 'Access is denied|Win32Exception \(5\)') {
            "If '$FractalsqldExe' is outside Program Files, the service account needs read/execute on it: icacls <dir> /grant *S-1-5-19:(OI)(CI)RX /T. "
        } else { '' }
        Write-Log "fractalsqld service installed but failed to start ($msg). ${aclHint}$giveUp"
    }
} catch {
    Write-Log "Unexpected error ($($_.Exception.Message)). $giveUp"
}
exit 0
