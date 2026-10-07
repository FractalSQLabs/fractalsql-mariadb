<#
.SYNOPSIS
    build_test.ps1: Windows port of build_test.sh's gate matrix for
    fractalsql-mariadb.

.DESCRIPTION
    SPDX-License-Identifier: Apache-2.0
    SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

    Direct line-by-line translation of build_test.sh, NOT independently
    verified against a real Windows box (this was written and validated
    against a real MariaDB 11.4 Linux container; build_test.sh's own
    header/report documents that end-to-end run. This .ps1 has only been
    checked for PowerShell syntax validity where a pwsh interpreter was
    reachable, not run against real mariadbd.exe/mariadb.exe binaries).
    Treat every claim below as "translated with intent preserved," not
    "confirmed working on Windows" until a real CI run (windows-gate-
    matrix in .github/workflows/build-test.yml) exercises it. A direct
    line-by-line Windows translation of this harness needed multiple real-hardware fixes
    beyond the naive translation (MSVC argv quoting, path-canonicalization
    direction, PowerShell 7.3+ native-stderr-as-terminating-error).
    Expect this port needs an equivalent debugging pass on a real run --
    the newly-added gates below (everything except 01/02/06/11/19) are
    LESS battle tested than those five, which already carried real-run-
    shaped caveats of their own (see each gate's own comments). The
    05/07/08/14-18 group specifically is the newest and least exercised:
    ported in a second pass after 03/04/10/12/13/20-28 landed, using the
    SAME restart-based reasoning-plugin-swap and privilege-grant patterns,
    but with no independent Windows validation of its own beyond that.

    Now covers 01 build, 02 smoke, 03 schema_context, 04 text_to_sql,
    05 evil_overread, 06 crash_recovery, 07 evil_lying_length, 08 authz,
    10 dos_and_injection, 11 scout, 12 soak, 13 vectorizer_embed,
    14 retry, 15 embed, 16 embed_authz, 17 embed_soak, 18 embed_crash,
    19 sfs_bounds, 20 analytics, 21 diversify, 22 vector_tier,
    23 cognition, 24 agents, 25 enterprise (dormant-path),
    26 enterprise_active, 27 enterprise_connect, 28 enterprise_signature,
    29 think (FRACTALSQL_HTTP_THINK* -> FSQL_REASONING_HTTP_THINK* bridge),
    31 sql_agent_savepoint (fractal_sql_agent's auto_execute SAVEPOINT/
    ROLLBACK TO SAVEPOINT safety net, via a marker-routed mock_llm.py
    reply), 32 new_primitives (the newest analytics/vector-math UDFs:
    change_point_detect, periodogram, state_fingerprint, cycle_detect,
    tda_persistence_diagram, optimize_subset, lp_distance,
    quantize_int8/binary, hamming_distance -- known-answer asserted),
    33 conf_gate (the daemon conf's privacy gate + the providers' loud
    validation at daemon startup only -- fsqlctl itself is POSIX-only;
    mirrors build_test.sh gate 33's startup-side cases), 34 reasoning_
    conf_live (reasoning_url's conf-live rotation -- NOT POSIX-only
    after all, see below), 35 enterprise_mock (a throwaway, self-signed
    mock enterprise .dll compiled at test time, same tests\mock_
    enterprise_core.c as fractalsql-postgresql's own port), 36
    morphology_metrics (the four Analytics-tier mesh/graph UDFs,
    known-answer/edge-case asserted)
    -- full parity with build_test.sh's DEFAULT_GATES (01-25, 29, 31,
    32, 33, 34, 35, 36, all of 05/07/08/14-18 included and unconditional
    there too) plus its three opt-in enterprise gates (26-28).
    Gates 34/35 were long believed POSIX-only here (fsqlctl, the reload
    client, genuinely is) until it turned out gate 29's own (d) sub-case
    already has a Windows-native substitute: service\tests\
    reload_probe_w.c speaks the daemon's OP_RELOAD wire frame directly
    over the named pipe (built on the fly via clang-cl, see Build-
    ReloadProbe) -- the reload PATH is cross-platform, only fsqlctl
    itself (AF_UNIX, getopt) is not. That note sat stale in this header
    for a while; treat any remaining "POSIX-only" claim below with the
    same suspicion until it's been re-checked against what the daemon
    protocol actually requires, not just against what fsqlctl happens
    to assume. Gate 09 (a non-superuser SQL-SET privilege-escalation
    check against a server system variable) is intentionally NOT
    ported -- MariaDB's reasoning-plugin config is env-var-only, read
    once at mariadbd startup, so that whole vulnerability class (a SQL
    statement changing which native code loads into every backend) does
    not exist on this port; see build_test.sh's own comment at the same
    spot for the full reasoning. This file's coverage is a known,
    evolving target, not a claim of permanent parity -- re-diff against
    build_test.sh's own gate_NN_* function list when in doubt.

    Reasoning-tier gates (04, 05, 07, 13, 14, 15, 16, 17, 18,
    20's fractal_optimize_portfolio audit-log path is community-only so
    needs nothing extra, 23, 24) need the SAME mock-LLM infrastructure
    build_test.sh's mdb_setup wires up: fractalsql-reasoning-http.dll
    copied into the plugin dir, scripts\ci\mock_llm.py started as a
    background process, and FRACTALSQL_REASONING_PLUGIN/HTTP_URL/
    HTTP_EMBED_URL/HTTP_ALLOW_PLAINTEXT set in mariadbd's process
    environment BEFORE it starts (read once, lazily, per process -- same
    as every other FRACTALSQL_* knob on this port). Gates 05/07/08/14/
    15/18 additionally need five more reasoning-VFS-ABI test-fixture
    DLLs (evil_nonterminating, evil_lying_length, evil_crash_reasoning,
    evil_embed, retry_reasoning -- tests\*.c, pure C against the shared
    fractalsql_sql.h with no mysql.h dependency), compiled fresh into
    the plugin dir on every Mdb-Setup call the same way evil_crash.dll
    already was. Swap-ReasoningPlugin/Restore-ReasoningPlugin (restart-
    based, since FRACTALSQL_REASONING_PLUGIN has no live-reload) are the
    general-purpose helpers gates 05/07/08/14/15/16/18 all use; gate 18
    additionally needs Restart-ReasoningPluginInPlace, a no-datadir-wipe
    variant, since its entire point is proving data survives a real
    crash + in-place respawn (see that function's own comment). None of
    this infrastructure existed in this file before this pass; it
    assumes `python` (falling back to `python3`) is on PATH, which is
    true for GitHub Actions' windows-latest runners but
    NOT independently verified for every possible Windows dev box --
    flagged, not assumed silently.

.PARAMETER MdbDir
    Path to an extracted MariaDB Windows binaries tree (the directory
    containing bin\mariadbd.exe, bin\mariadb.exe, include\mysql\mysql.h).
    Mandatory by design: the caller always names the exact tree under
    test, with no PATH-search fallback to guess wrong silently -- this
    matches this repo's own release.yml build-windows-msi
    job's deps\mariadb\root layout (archive.mariadb.org
    mariadb-<VER>-winx64.zip).

.PARAMETER MdbMajor
    Target major (e.g. "11.4"). Mandatory, same rationale as -MdbDir:
    MdbDir already pins the exact binaries, but every dist\ output path
    and datadir/port/plugin-dir naming below keys off this value, so
    (unlike the prior default of "11.4") a caller testing against, say,
    10.6 binaries can no longer forget to pass it and silently get
    10.6's binaries labeled and ported as if they were 11.4.

.PARAMETER TimeoutMult
    Scales gate 06's respawn-poll budget. Default 1, auto-bumped to 3
    under -Asan/-Ubsan unless passed explicitly.

.PARAMETER VcpkgRoot
    vcpkg install root, for OpenSSL (src\fractalsql_enterprise.c's
    ent_verify_signature() needs openssl/evp.h and libcrypto.lib --
    see scripts\windows\build.bat's own Prerequisites comment for the
    full wolfSSL-vs-OpenSSL rationale). Same convention as
    fractalsql-reasoning-http's scripts\build-windows.ps1 -VcpkgRoot:
    defaults to $env:VCPKG_ROOT / $env:VCPKG_INSTALLATION_ROOT / C:\vcpkg
    (in that order) when omitted. Passed through to build.bat via
    $env:VCPKG_ROOT, which builds the daemon's OpenSSL link.

.PARAMETER Asan
    Builds fractalsqld.exe with cl.exe /fsanitize=address into a separate
    dist\windows-asan\ tree and runs the same gates against it. The shim
    stays plain. Copies the ASan runtime DLL next to the exe.

.PARAMETER Ubsan
    Same, for fractalsqld.exe built with clang-cl -fsanitize=undefined into
    dist\windows-ubsan\.

.PARAMETER Fuzz
    Gate 30 only -- libFuzzer smoke via clang-cl against
    src\fractalsql_parse.c's 3 hand-rolled parsers (parse_vector_csv,
    parse_corpus, parse_index_csv). No cluster, no extension DLL. Set
    FSQL_FUZZ_TIME (seconds per target, default 30) to run longer than
    the pre-push smoke budget.

.PARAMETER Gate
    Run a single gate by number instead of the default set.

.PARAMETER Quick
    Gates 01, 02 only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MdbDir,
    [Parameter(Mandatory = $true)][ValidateSet('10.6', '10.11', '11.4', '12.3')][string]$MdbMajor,
    [int]$TimeoutMult = 1,
    [string]$VcpkgRoot = "",
    [switch]$Asan,
    [switch]$Ubsan,
    [switch]$Fuzz,
    [string]$Gate = "",
    [switch]$Quick,
    [switch]$Coverage
)

if ($Asan -and $Ubsan) {
    throw "-Asan and -Ubsan are mutually exclusive -- each rebuilds its own separate dist\ tree. Run one at a time."
}

$ErrorActionPreference = "Stop"
# PowerShell 7.3+ can treat ANY native-command stderr write as a
# terminating error under $ErrorActionPreference = 'Stop' -- regardless
# of the writing program's own actual severity level. mariadbd.exe and
# mariadb.exe send NOTICE/WARNING/ERROR all to stderr; without this, a
# routine "NOTICE: table ... does not exist, skipping" from a plain
# DROP TABLE IF EXISTS throws and aborts the whole script (a confirmed
# real-hardware fix). This script regex-matches expected output text
# explicitly wherever it needs to detect a real failure -- it doesn't
# rely on PowerShell's automatic error handling for native commands.
$PSNativeCommandUseErrorActionPreference = $false
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Here

# Mirrors build_test.sh's DEFAULT_GATES (01-25) exactly, minus 05/07/08/
# 14-18 (not yet ported here, see .DESCRIPTION). 26/27/28 are opt-in in
# bash (need a licensed enterprise .so this public repo doesn't ship) and
# stay opt-in here too -- NOT added to $DefaultGates, same as bash never
# adds them to DEFAULT_GATES.
# Deliberate deviation from build_test.sh's own DEFAULT_GATES (which
# stops at 25 then 29, so gates 26/27/28 -- the opt-in enterprise gates
# -- print nothing at all on a community run): 26/27/28 are included
# here so a default run visibly prints their [SKIP] lines
# ("[SKIP] N enterprise*: skipped (community edition; no fractalsql-
# enterprise-sovereign-c.* shared lib in include/)"), instead of
# silently omitting the opt-in gates from the transcript.
$DefaultGates = @("01","02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","31","32","33","34","35","36")
$QuickGates   = @("01", "02")
$FuzzGates    = @("30")

if ($Asan -or $Ubsan) { if (-not $PSBoundParameters.ContainsKey('TimeoutMult')) { $TimeoutMult = 3 } }

# Discovery order: PATH -> vswhere-resolved VC\Tools\Llvm\x64\bin\clang-cl.exe
# -> standalone LLVM. Throws instead of skipping -- -Ubsan/-Fuzz being
# passed at all means the caller wants it to actually run.
function Find-ClangCl {
    $candidate = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $VsWhere) {
        $vsPath = & $VsWhere -latest -products * -property installationPath 2>$null
        if ($vsPath) {
            $vsClang = Join-Path $vsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'
            if (Test-Path $vsClang) { return $vsClang }
        }
    }
    $standalone = 'C:\Program Files\LLVM\bin\clang-cl.exe'
    if (Test-Path $standalone) { return $standalone }
    throw "-Ubsan/-Fuzz requested but clang-cl.exe not found (checked PATH, VS's 'C++ Clang tools for Windows' component, standalone LLVM)."
}
$script:ClangCl = $null
if ($Ubsan -or $Fuzz) {
    $script:ClangCl = Find-ClangCl
    Write-Host "Using clang-cl: $script:ClangCl"
}

# Same VCPKG_ROOT/VCPKG_INSTALLATION_ROOT/C:\vcpkg fallback chain as
# scripts\windows\build.bat's own resolution, but -VcpkgRoot (this
# script's own parameter, matching fractalsql-reasoning-http's
# scripts\build-windows.ps1 -VcpkgRoot) wins when passed explicitly.
function Resolve-VcpkgRoot {
    if ($VcpkgRoot -ne "") { return $VcpkgRoot }
    if ($env:VCPKG_ROOT) { return $env:VCPKG_ROOT }
    if ($env:VCPKG_INSTALLATION_ROOT) { return $env:VCPKG_INSTALLATION_ROOT }
    return "C:\vcpkg"
}

# OpenSSL (static, x64-windows-static triplet): see build.bat's own
# Prerequisites comment for the full wolfSSL-vs-OpenSSL rationale.
function Resolve-OpenSslDir {
    $root = Resolve-VcpkgRoot
    $dir = Join-Path $root "installed\x64-windows-static"
    if (-not (Test-Path (Join-Path $dir "include\openssl\evp.h"))) {
        throw "OpenSSL headers not found under $dir -- run: $root\vcpkg.exe install openssl:x64-windows-static (see scripts\windows\build.bat's own Prerequisites comment)"
    }
    return $dir
}

# dist\ subdir convention: -Asan/-Ubsan each get their own tree, never
# touching the normal release build's output.
$DistSubdir = if ($Asan) { "dist\windows-asan\mdb$MdbMajor" }
              elseif ($Ubsan) { "dist\windows-ubsan\mdb$MdbMajor" }
              else { "dist\windows\mdb$MdbMajor" }
$Dll = Join-Path $Here "$DistSubdir\fractalsql.dll"
$DaemonExe = Join-Path $Here "$DistSubdir\fractalsqld.exe"

$script:Failed = $false
function Pass([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Failed = $true }
function Skip([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

# Reads a text file that a still-running process may have open for
# writing (e.g. Start-Process -RedirectStandardError on a daemon this
# script hasn't stopped yet). [IO.File]::ReadAllText / Get-Content both
# open with the default, exclusive-of-writers share mode, which throws
# "being used by another process" the moment the target is a live
# redirect handle -- confirmed live (gate 33's Boot-Probe hit exactly
# this reading $log while the daemon it had just detected as
# successfully listening was still running). [System.IO.FileShare]::
# ReadWrite mirrors how `tail -f`/this repo's own POSIX log_mark/
# log_from reads a live daemon's log with no such restriction.
function Read-LogShared([string]$Path) {
    if (-not (Test-Path $Path)) { return "" }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        return $sr.ReadToEnd()
    } finally {
        $fs.Dispose()
    }
}

# --- locate MariaDB binaries -------------------------------------------
# -MdbDir is mandatory (see its PARAMETER block above) -- no PATH-search
# fallback to guess wrong silently.
function Get-MdbBin {
    $bin = Join-Path $MdbDir "bin"
    if (Test-Path (Join-Path $bin "mariadbd.exe")) { return $bin }
    return $null
}

$script:Bin = $null
$script:DataDir = $null
$script:PlugDir = $null
$script:MariadbdLog = $null
$script:MockLog = $null
$script:LogsDumped = $false
$script:Port = 0
$script:MariadbExe = $null
$script:MariadbdExe = $null
$script:RespawnJob = $null
$script:CrashSo = $null
$script:MockLlmProc = $null
$script:MockLlmPort = 0

function Get-MdbCflags {
    # No mariadb_config.exe on Windows -- the MSVC-headers-only path
    # this repo's own scripts\windows\build.bat uses is
    # -I<mariadb>\include\mysql. Reused here identically.
    # Returned as an ARRAY of separate argv elements ('-I', dir), never a
    # single pre-quoted string: confirmed on the first real Windows run
    # that the embedded-quote form ('-I"C:\Program Files\MariaDB 11.4\..."')
    # reaches cl.exe as one mangled token under PowerShell 7's native
    # argument passing, and the compile dies with C1083 "mysql.h: No such
    # file or directory" -- a confirmed real-hardware argv-quoting fix.
    # Both cl.exe and the gcc fallback accept the -I + separate-dir form
    # as-is.
    return @('-I', "$MdbDir\include\mysql")
}

# Compiles one reasoning-VFS-ABI test fixture (tests\*.c, pure C against
# fractalsql_sql.h, no mysql.h needed) into $script:PlugDir. Same cl.exe/
# gcc fallback as the evil_crash_udf.c compile step in Mdb-Setup. Returns
# the output path on success, $null on failure (caller decides whether
# that's fatal). $IncDirs is an array of include DIRECTORIES, passed to
# the compiler as separate '-I', dir argv pairs -- one quoted string
# carrying multiple '-I"..."dirs' reaches cl.exe as a single mangled
# token under PowerShell 7's native argument passing (same real-hardware
# argv-quoting class as Get-MdbCflags' comment below), and a compile that
# can't see its headers "succeeds" silently into no .dll at all.
function Compile-FsqlFixture([string]$SourceRelPath, [string]$OutName, [string[]]$IncDirs) {
    $out = "$script:PlugDir\$OutName"
    $incArgs = @()
    foreach ($d in $IncDirs) { $incArgs += '-I'; $incArgs += $d }
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) {
        # /DEF: tests\windows\fractalsql-test-plugin.def -- cl /LD exports
        # NOTHING from a DLL by default (unlike an ELF .so on Linux), so
        # without the export table LoadLibrary succeeds but
        # GetProcAddress("fsql_reasoning_init") fails, and every
        # plugin-swap gate fails with a load error rather than the
        # behavior it's actually testing. Same convention as the shipped
        # fractalsql-reasoning-http.def (see the .def's own header).
        & cl.exe /LD /Fe:$out @incArgs "$Here\$SourceRelPath" /link "/DEF:$Here\tests\windows\fractalsql-test-plugin.def" 2>&1 | Out-Null
    } else {
        & gcc -shared -o $out @incArgs "$Here\$SourceRelPath" 2>&1 | Out-Null
    }
    if (Test-Path $out) { return $out } else { return $null }
}

# Restart mariadbd with FRACTALSQL_REASONING_PLUGIN pointed at
# $PluginPath instead of the real HTTP wrapper -- mirrors build_test.sh's
# mdb_swap_reasoning_plugin, restart-based (not a live set) since
# FRACTALSQL_REASONING_PLUGIN is a process environment variable read
# once at mariadbd.exe startup, the same constraint gates 26/27/28
# already work around for FRACTALSQL_ENTERPRISE_LIB. Extra env
# assignments (e.g. FRACTALSQL_TEXT_TO_SQL_USE_REVIEW-equivalents) can
# be set by the caller before calling this, same restart, since they're
# read the same way. Returns Mdb-Setup's own exit code.
function Swap-ReasoningPlugin([string]$PluginPath) {
    Mdb-Teardown
    $env:FRACTALSQL_REASONING_PLUGIN = $PluginPath
    return (Mdb-Setup $MdbMajor)
}

# Restores the real HTTP-wrapper reasoning plugin + mock LLM server --
# the baseline every OTHER gate in this suite assumes -- and clears any
# text-to-sql env overrides a gate set. Call at the end of every gate
# that used Swap-ReasoningPlugin.
function Restore-ReasoningPlugin {
    Mdb-Teardown
    Remove-Item Env:\FRACTALSQL_REASONING_PLUGIN, Env:\FRACTALSQL_TEXT_TO_SQL_USE_REVIEW, `
        Env:\FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS, Env:\FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS, `
        Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue
    Mdb-Setup $MdbMajor | Out-Null
}

# Gate 18 ONLY: restore the real reasoning plugin the same way gate 06's
# crash-recovery supervisor itself would -- kill mariadbd and relaunch it
# against the SAME $script:DataDir/Port/PlugDir, no wipe, no re-run of
# install_udf.sql (routines already persisted in this datadir from the
# Mdb-Setup call that started it). Restore-ReasoningPlugin is wrong for
# this one gate specifically: it calls Mdb-Setup, which unconditionally
# wipes $script:DataDir -- fine for every other plugin-swap gate, but
# gate 18's entire point is proving data survives a real crash + in-
# place respawn, so wiping it immediately afterward would destroy the
# very state being tested. $script:PlugDir already has fractalsql-
# reasoning-http.dll in it regardless of which plugin FRACTALSQL_
# REASONING_PLUGIN pointed at (Mdb-Setup copies it in unconditionally,
# before ever reading that env var) -- mirrors build_test.sh's own
# mdb_restart_inplace_reasoning_plugin (see its comment there for the
# live-confirmed rationale on the bash side; not independently
# reconfirmed on Windows here). Sets the env var BEFORE starting a FRESH
# background job -- a job already running does not pick up a later
# $env: change (each respawn inside an existing job's while-loop is a
# child of THAT job's process, whose environment was captured once at
# Start-Job time, not continuously synced with the parent) -- so the OLD
# job must be stopped and a NEW one started, not reused.
function Restart-ReasoningPluginInPlace([string]$PluginPath) {
    $env:FRACTALSQL_REASONING_PLUGIN = $PluginPath
    if ($script:RespawnJob) { Stop-Job $script:RespawnJob -ErrorAction SilentlyContinue; Remove-Job $script:RespawnJob -Force -ErrorAction SilentlyContinue }
    Get-Process mariadbd -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$script:Bin*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    if (-not (Start-Fsqd "$($script:Port)")) { return 2 }
    Start-MariadbSupervisor
    for ($i = 0; $i -lt (30 * $TimeoutMult); $i++) {
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" >$null 2>&1
        if ($LASTEXITCODE -eq 0) { return 0 }
        Start-Sleep -Milliseconds 500
    }
    return 2
}

# Every client invocation in this file passes --skip-ssl-verify-server-
# cert (confirmed live, first real Windows run): mariadb.exe emits
# "WARNING: option --ssl-verify-server-cert is disabled, because of an
# insecure passwordless login." to stderr on EVERY passwordless (and
# this harness's TCP-only connections are all passwordless -- the bash
# original connects via Unix socket, which doesn't trigger it) connect,
# and 2>&1 merges that into every captured result: -eq comparisons fail
# ("WARNING: ...\n2.0.0" != "2.0.0"), -match/-notmatch pick up array
# semantics with spurious truthiness, and worst, the warning TEXT gets
# interpolated into follow-up SQL ("WHERE vectorizer_id=WARNING: option
# ..." -> ERROR 1064). Passing the skip flag explicitly means the
# client never "helpfully" disables it for us, and the warning never
# fires (verified against a live server: flag present -> no stderr).
function Invoke-Mariadb {
    param([string[]]$SqlArgs, [switch]$AsFile, [string]$SqlText)
    if ($AsFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $tmp -Value $SqlText -NoNewline
        try {
            # PowerShell has no bash-style `< $tmp` stdin redirection (it's
            # reserved/unsupported syntax, not silently ignored -- this was
            # a real parse error, caught by Parser.ParseFile, not a runtime
            # guess). Get-Content piped in is the native equivalent.
            $out = Get-Content -Path $tmp -Raw | & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N 2>&1
        } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
        return $out
    } else {
        return & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $SqlArgs[0] 2>&1
    }
}

# Find a runnable python launcher. GitHub Actions' windows-latest runners
# carry `python` on PATH; `python3` is the fallback for a dev box set up
# the Linux-conventional way. Returns $null if neither is found (callers
# SKIP the gates that need it rather than fail).
function Get-PythonExe {
    $c = Get-Command python -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $c = Get-Command python3 -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Wait-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutSeconds = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($HostName, $Port)
            $client.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    return $false
}

# --- fractalsqld (the daemon) -------------------------------------
# mariadbd loads only the shim (fractalsql.dll). Every UDF body, the
# reasoning plugin loader and the enterprise loader run in fractalsqld.exe,
# started before mariadbd so the first FractalSQL call finds the pipe. The
# daemon inherits the reasoning/enterprise/ledger environment that is set
# when it starts, the same way build_test.sh's daemon_start does.
$script:FsqdProc = $null
$script:FsqdConf = $null
$script:FsqdKey  = $null
$script:FsqdLog  = $null
$script:FsqdPipe = $null

function Stop-Fsqd {
    if ($script:FsqdProc) {
        Stop-Process -Id $script:FsqdProc.Id -Force -ErrorAction SilentlyContinue
        $script:FsqdProc = $null
    }
    foreach ($f in @($script:FsqdKey, $script:FsqdConf)) {
        if ($f) { Remove-Item -Force $f -ErrorAction SilentlyContinue }
    }
    Remove-Item Env:\FRACTALSQL_CONFIG -ErrorAction SilentlyContinue
}

# Starts fractalsqld.exe on a fresh per-tag pipe with a fresh HMAC key.
# Returns $true once the daemon logs that it is listening, $false if it
# exits first or never comes up.
function Start-Fsqd([string]$Tag) {
    Stop-Fsqd
    $script:FsqdPipe = "\\.\pipe\fsql_bt_${Tag}_$PID"
    $script:FsqdKey  = "$env:TEMP\fractalsql_bt_fsqd_$Tag.key"
    $script:FsqdConf = "$env:TEMP\fractalsql_bt_fsqd_$Tag.conf"
    $script:FsqdLog  = "$env:TEMP\fractalsql_bt_fsqd_$Tag.log"
    Remove-Item -Force $script:FsqdLog -ErrorAction SilentlyContinue

    $keyHex = -join ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32) | ForEach-Object { $_.ToString('x2') })
    Set-Content -Path $script:FsqdKey -Value $keyHex -NoNewline -Encoding ascii
    Set-Content -Path $script:FsqdConf -Encoding ascii -Value @(
        "socket_path = $($script:FsqdPipe)",
        "hmac_key_file = $($script:FsqdKey)"
    )

    $env:FRACTALSQL_CONFIG = $script:FsqdConf
    $script:FsqdProc = Start-Process -FilePath $script:DaemonExe `
        -ArgumentList @("-c", "`"$($script:FsqdConf)`"") `
        -RedirectStandardError $script:FsqdLog -RedirectStandardOutput "$($script:FsqdLog).out" `
        -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt (100 * $TimeoutMult); $i++) {
        if ($script:FsqdProc.HasExited) { return $false }
        if ((Test-Path $script:FsqdLog) -and (Select-String -Path $script:FsqdLog -Pattern 'listening on' -Quiet)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Mdb-Setup {
    param([string]$Major)
    $script:Bin = Get-MdbBin
    if (-not $script:Bin) { return 1 }
    $script:MariadbdExe = Join-Path $script:Bin "mariadbd.exe"
    $script:MariadbExe  = Join-Path $script:Bin "mariadb.exe"
    $installDb = Join-Path $script:Bin "mariadb-install-db.exe"
    if (-not (Test-Path $installDb)) { $installDb = Join-Path $script:Bin "mysql_install_db.exe" }
    if (-not (Test-Path $installDb)) { return 2 }

    $suffix = ($Major -replace '\.', '_')
    $script:DataDir = "$env:TEMP\fractalsql_bt_data_$suffix"
    $script:PlugDir = "$env:TEMP\fractalsql_bt_plugin_$suffix"
    $script:Port = 13300 + ([int]($Major -replace '\D', '') % 100)
    Remove-Item -Recurse -Force $script:DataDir -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $script:PlugDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:PlugDir | Out-Null

    # Fresh mariadbd stderr log once per setup, HERE (where $suffix is in
    # scope): the supervisor below is re-entered from gate scope on plugin
    # swaps and must only append, so a respawn leaves the previous
    # attempt's diagnostics in the file for the Mdb-Teardown FAIL dump.
    $script:MariadbdLog = "$($script:DataDir)_mariadbd.log"
    Remove-Item -Force $script:MariadbdLog -ErrorAction SilentlyContinue

    Copy-Item $Dll "$script:PlugDir\fractalsql.dll" -ErrorAction Stop

    # Evil crash UDF -- compiled with cl.exe (MSVC), same toolchain
    # release.yml's build-windows-msi job already requires
    # (ilammy/msvc-dev-cmd). Falls back to gcc/clang if present (e.g. a
    # local MSYS2 dev box) since cl.exe may not be on PATH outside a
    # "Developer PowerShell" session.
    $script:CrashSo = "$script:PlugDir\evil_crash.dll"
    $cflags = Get-MdbCflags
    $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($cl) {
        # /DEF: needed here (and nowhere in build_test.sh's flow) because
        # MSVC exports no plain C symbols from a /LD build by default --
        # tests\windows\evil_crash_udf.def's own header has the full
        # account. The gcc fallback below needs no equivalent: gcc
        # -shared exports everything, the same default build_test.sh
        # relies on.
        & cl.exe /LD /Fe:$script:CrashSo @cflags "$Here\tests\evil_crash_udf.c" `
            /link "/DEF:$Here\tests\windows\evil_crash_udf.def" 2>&1 | Out-Null
    } else {
        & gcc -shared -o $script:CrashSo @cflags "$Here\tests\evil_crash_udf.c" 2>&1 | Out-Null
    }
    if (-not (Test-Path $script:CrashSo)) { return 2 }

    # Reasoning-VFS-ABI-level test fixtures for gates 05/07/14/15/18 (see
    # tests/*.c's own file headers): pure C against the shared vendored
    # fractalsql_sql.h, needs neither mysql.h nor $cflags (mirrors
    # build_test.sh's mdb_setup 1:1, including "recompiled every setup
    # call since teardown wipes the whole plugin dir"). $script:*So
    # variables are read later by the gates that swap to them.
    #
    # evil_nonterminating uses tests\windows\evil_nonterminating_plugin_
    # win.c, NOT tests\evil_nonterminating_plugin.c: the shared one is
    # POSIX-only by its own header's admission (mmap/mprotect --
    # sys/mman.h has no MSVC equivalent), so the Windows fixture ports
    # the same guard-page technique with VirtualAlloc/VirtualProtect.
    $fsqlIncDirs = @("$Here\include\windows-x86_64", "$Here\include")
    $script:EvilReasoningSo  = Compile-FsqlFixture "tests\windows\evil_nonterminating_plugin_win.c" "evil_nonterminating.dll" $fsqlIncDirs
    $script:LyingSo          = Compile-FsqlFixture "tests\evil_lying_length_plugin.c"   "evil_lying_length.dll"   $fsqlIncDirs
    $script:CrashReasoningSo = Compile-FsqlFixture "tests\evil_crash_plugin.c"          "evil_crash_reasoning.dll" $fsqlIncDirs
    $script:EvilEmbedSo      = Compile-FsqlFixture "tests\evil_embed_plugin.c"          "evil_embed.dll"          $fsqlIncDirs
    $script:RetrySo          = Compile-FsqlFixture "tests\windows\retry_reasoning_plugin_win.c" "retry_reasoning.dll"     $fsqlIncDirs
    $script:ThinkSo          = Compile-FsqlFixture "tests\think_reasoning_plugin.c"     "think_reasoning.dll"     $fsqlIncDirs
    if (-not ($script:EvilReasoningSo -and $script:LyingSo -and $script:CrashReasoningSo -and $script:EvilEmbedSo -and $script:RetrySo -and $script:ThinkSo)) { return 2 }

    # Reasoning-tier gates (04 GENERATE, 13 embed, 23 cognition, 24
    # agents' route_task) dispatch through the real fractalsql-
    # reasoning-http.dll plugin against a deterministic local mock
    # (scripts\ci\mock_llm.py), exercising the FULL real path, not a
    # fake in-process substitute -- mirrors build_test.sh's mdb_setup
    # 1:1. Must be wired BEFORE mariadbd starts: FRACTALSQL_REASONING_
    # PLUGIN/HTTP_URL/HTTP_EMBED_URL are read once, lazily, from
    # mariadbd's OWN process environment. If python is not found, this
    # does NOT fail setup outright (community-only gates should still
    # run) -- it leaves the reasoning env vars unset, and gates 04/13/
    # 23/24 will fail individually with a clear "connection refused"-
    # shaped error rather than mysteriously; a cleaner per-gate SKIP for
    # that specific case is a possible follow-up, not done here to keep
    # this change's shape a faithful mirror of the bash original (which
    # also treats a missing mock as a hard setup failure, just via a
    # different code path -- python3 is a listed apt dependency there).
    #
    # $env:FRACTALSQL_REASONING_PLUGIN is defaulted ONLY if not already
    # set (mirrors bash's ${FRACTALSQL_REASONING_PLUGIN:-$PLUGDIR/...}):
    # Swap-ReasoningPlugin sets it BEFORE calling this function, and
    # this must not stomp that override with the real HTTP plugin path.
    $reasoningDll = "$Here\include\windows-x86_64\fractalsql-reasoning-http.dll"
    $hadReasoningPluginOverride = [bool]$env:FRACTALSQL_REASONING_PLUGIN
    if (Test-Path $reasoningDll) {
        Copy-Item $reasoningDll "$script:PlugDir\fractalsql-reasoning-http.dll" -ErrorAction SilentlyContinue
        $py = Get-PythonExe
        if ($py) {
            $script:MockLlmPort = 18300 + ([int]($Major -replace '\D', '') % 100)
            $mockLog = "$env:TEMP\fractalsql_bt_mockllm_$suffix.log"
            $script:MockLog = $mockLog
            # Quote each argument: Start-Process -ArgumentList joins the
            # array with spaces WITHOUT quoting, and $Here contains a
            # space on real dev boxes ("C:\Users\Daniel Gardiner\..."),
            # so python received "C:\Users\Daniel" as its script name and
            # choked on a VC-redist log it found there (confirmed: the
            # mock's .err log held a SyntaxError for exactly that), the
            # server never came up, and gates 04/07/13/23 all failed
            # "generate dispatch failed"/NULL with no visible cause.
            $script:MockLlmProc = Start-Process -FilePath $py `
                -ArgumentList @("`"$Here\scripts\ci\mock_llm.py`"", "$script:MockLlmPort") `
                -RedirectStandardOutput $mockLog -RedirectStandardError "$mockLog.err" `
                -PassThru -WindowStyle Hidden
            if (Wait-TcpPort -HostName "127.0.0.1" -Port $script:MockLlmPort -TimeoutSeconds 10) {
                if (-not $hadReasoningPluginOverride) {
                    $env:FRACTALSQL_REASONING_PLUGIN = "$script:PlugDir\fractalsql-reasoning-http.dll"
                }
                $env:FRACTALSQL_HTTP_URL           = "http://127.0.0.1:$($script:MockLlmPort)/v1/chat/completions"
                $env:FRACTALSQL_HTTP_EMBED_URL     = "http://127.0.0.1:$($script:MockLlmPort)/v1/embeddings"
                $env:FRACTALSQL_HTTP_ALLOW_PLAINTEXT = "1"
            }
        }
    }

    # --auth-root-authentication-method=normal: passwordless, non-
    # socket-only root (mirrors build_test.sh's own mdb_setup exactly).
    # Load-bearing now that Start-MariadbSupervisor no longer passes
    # --skip-grant-tables (see that function's comment) -- without this,
    # root auth on a fresh Windows datadir is not guaranteed passwordless.
    #
    # CAVEAT, confirmed on the first real Windows run (11.4): MariaDB's
    # Windows mariadb-install-db.exe does NOT accept this option at all
    # ("unknown variable 'auth-root-authentication-method=normal'",
    # exit 7) -- it is a Linux mysql_install_db wrapper option. The
    # Windows installer's own default already creates root with an
    # empty password and mysql_native_password, which is exactly the
    # posture the flag asks for, so the fallback below (wipe + retry
    # without the flag) is behaviorally equivalent on Windows. The
    # flag-first attempt is kept for any future toolchain that does
    # accept it. Install-db's output goes to a TEMP log instead of
    # being swallowed (Out-Null), so a genuinely slow-but-failing
    # install is diagnosable without re-running this function by hand.
    $installDbLog = "$env:TEMP\fractalsql_bt_installdb_$suffix.log"
    & $installDb --datadir=$script:DataDir --auth-root-authentication-method=normal > $installDbLog 2>&1
    if (-not (Test-Path "$script:DataDir\mysql")) {
        # Retry without the flag on a CLEAN datadir -- a failed attempt
        # may have left a partial tree the installer would refuse to
        # re-init.
        Remove-Item -Recurse -Force $script:DataDir -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
        & $installDb --datadir=$script:DataDir > $installDbLog 2>&1
    }
    if (-not (Test-Path "$script:DataDir\mysql")) { return 2 }

    if (-not (Start-Fsqd $suffix)) {
        Write-Host "    fractalsqld did not start, see $script:FsqdLog"
        return 2
    }
    Start-MariadbSupervisor
    for ($i = 0; $i -lt (30 * $TimeoutMult); $i++) {
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" >$null 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($LASTEXITCODE -ne 0) { return 2 }

    # fractalsql_bt is the fixed database every gate connects to (mirrors
    # build_test.sh's own MARIADB=(... -D fractalsql_bt) array) -- must
    # exist before install_udf.sql runs (that file has no CREATE DATABASE
    # of its own) and before any gate's -D fractalsql_bt connection.
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -e "CREATE DATABASE IF NOT EXISTS fractalsql_bt;" 2>&1 | Out-Null

    # install_udf.sql hardcodes SONAME 'fractalsql.so' on every CREATE
    # FUNCTION -- the Linux filename, correct for build_test.sh's own
    # `mariadb ... < sql/install_udf.sql` invocation (confirmed on this
    # run: every CREATE failed with "Can't find the library
    # 'fractalsql.so'" and the batch aborted at the first one, leaving
    # ZERO routines registered and every later gate failing with
    # ERROR 1305 "does not exist"). On Windows the same DLL is
    # fractalsql.dll, so rewrite the SONAME at pipe time rather than
    # forking a Windows-only copy of the whole SQL file. install_
    # agents.sql has no SONAME references (pure SQL/PSM, confirmed by
    # grep), so it needs no equivalent treatment.
    # install_udf.sql hardcodes SONAME 'fractalsql.so' on every CREATE
    # FUNCTION -- the Linux filename, correct for build_test.sh's own
    # `mariadb ... < sql/install_udf.sql` invocation (confirmed on this
    # run: every CREATE failed with "Can't find the library
    # 'fractalsql.so'" and the batch aborted at the first one, leaving
    # ZERO routines registered and every later gate failing with
    # ERROR 1305 "does not exist"). On Windows the same DLL is
    # fractalsql.dll, so rewrite the SONAME at pipe time rather than
    # forking a Windows-only copy of the whole SQL file. install_
    # agents.sql has no SONAME references (pure SQL/PSM, confirmed by
    # grep), so it needs no equivalent treatment.
    #
    # Unlike the first version of this port, install failures are NOT
    # swallowed with Out-Null: each file's output goes to a TEMP log
    # (mirroring bash's own /tmp/fractalsql_bt_setup log) and a nonzero
    # client exit code fails setup outright (return 2), the same way
    # build_test.sh's mdb_setup does with its || return 2. Silent
    # swallowing is what let the SONAME bug above reach every runtime
    # gate as thirty-odd ERROR 1305s instead of one clean setup failure.
    $setupLog = "$env:TEMP\fractalsql_bt_setup_$suffix.log"
    $installSql = Get-Content "$Here\sql\install_udf.sql" -Raw
    $installSql = $installSql -replace "SONAME 'fractalsql\.so'", "SONAME 'fractalsql.dll'"
    $installSql | & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt > $setupLog 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "    install_udf.sql failed, see $setupLog"; return 2 }

    # install_agents.sql registers the Agency-tier procedures gate 24
    # needs (mirrors build_test.sh's own mdb_setup -- the first version
    # of this port missed it entirely, so gate 24's CALLs would have
    # failed "PROCEDURE ... does not exist" even after the SONAME fix).
    Get-Content "$Here\sql\install_agents.sql" -Raw | & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt >> $setupLog 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Host "    install_agents.sql failed, see $setupLog"; return 2 }
    return 0
}

function Start-MariadbSupervisor {
    # Manual respawn loop -- see this script's top-of-file note on why
    # there is no Windows-service-based equivalent attempted here.
    # NO --skip-grant-tables (unlike an earlier version of this file):
    # gates 08/16 test REAL privilege enforcement (a low-priv user
    # correctly blocked from data it has no GRANT on) -- skip-grant-
    # tables would make every such assertion pass for the wrong reason
    # (no privilege checking happening at all), not a faithful port of
    # build_test.sh's own mdb_setup, which never uses that flag either.
    # Root auth instead relies on --auth-root-authentication-method=
    # normal at mariadb-install-db time (see Mdb-Setup), the same
    # passwordless-root setup bash's mdb_setup uses.
    #
    # mariadbd's stderr is captured to a TEMP log, NOT Out-Null'd: on
    # Windows (no datadir <hostname>.err by default) mariadbd's stderr
    # is the only place the vendored reasoning plugin's own diagnostics
    # land ("fractalsql-reasoning-http: ..."), and gate failures used to
    # surface as bare NULLs with zero visible cause because that channel
    # was thrown away here (mdb10.6 gate 04 burned on exactly this).
    # Appended per (re)start with a marker line, so a respawn leaves the
    # previous attempt's output in the file. Mdb-Teardown prints the
    # tail of this log when any gate FAILed. Named after $script:DataDir
    # (not $suffix): Restart-ReasoningPluginInPlace calls this function
    # from gate scope, where Mdb-Setup's local $suffix is not in view.
    $script:MariadbdLog = "$($script:DataDir)_mariadbd.log"
    $script:RespawnJob = Start-Job -ScriptBlock {
        param($mariadbdExe, $dataDir, $port, $plugDir, $logFile)
        while ($true) {
            ("--- mariadbd start $(Get-Date -Format o) ---") | Add-Content $logFile
            & $mariadbdExe --datadir=$dataDir --port=$port --plugin-dir=$plugDir `
                --bind-address=127.0.0.1 2>&1 | Add-Content $logFile
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $script:MariadbdExe, $script:DataDir, $script:Port, $script:PlugDir, $script:MariadbdLog
}

function Mdb-Teardown {
    # On any gate FAIL, print the tails of the two diagnostic logs the
    # teardown is about to (or is the only place that) has: mariadbd's
    # captured stderr (the vendored reasoning plugin's "fractalsql-
    # reasoning-http: ..." lines -- the ONLY cause record for a bare-
    # NULL gate failure, see Start-MariadbSupervisor's comment) and the
    # mock LLM server's stderr. Done here, not at the final summary,
    # because Mdb-Teardown runs (twice, from Run-Gates and the top-level
    # finally) before the script exits; by then the plugin-dir/datadir
    # deletion below would have destroyed the evidence. Run-Gates and
    # the top-level finally BOTH call teardown, so guard the dump to
    # fire once (the first call still has both processes alive).
    if ($script:Failed -and -not $script:LogsDumped) {
        $script:LogsDumped = $true
        foreach ($log in @($script:MariadbdLog, $script:FsqdLog, "$script:MockLog.err")) {
            if ($log -and (Test-Path $log)) {
                Write-Host "`n--- tail of $log ---"
                Get-Content $log -Tail 40 | ForEach-Object { Write-Host "  $_" }
            }
        }
    }
    if ($script:RespawnJob) { Stop-Job $script:RespawnJob -ErrorAction SilentlyContinue; Remove-Job $script:RespawnJob -Force -ErrorAction SilentlyContinue }
    Get-Process mariadbd -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$script:Bin*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Fsqd
    # Sweep the gate-33 boot-probe daemons too: they run from this repo's
    # own dist exe, so a run interrupted between Start-Process and
    # Boot-Probe's stop would otherwise keep the exe locked and break
    # every later build with an unresolved link error.
    Get-Process fractalsqld -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$script:DaemonExe*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($script:MockLlmProc) {
        Stop-Process -Id $script:MockLlmProc.Id -Force -ErrorAction SilentlyContinue
        $script:MockLlmProc = $null
    }
    Start-Sleep -Seconds 1
    # -ErrorAction SilentlyContinue only suppresses runtime errors, not
    # parameter-binding validation -- a null -Path (Mdb-Setup can bail
    # out, e.g. rc=1 "mariadbd.exe not found", before these are ever
    # assigned) throws ParameterBindingValidationException regardless,
    # since this runs unconditionally from the script's top-level
    # `finally`. Guard against that case explicitly.
    if ($script:DataDir) { Remove-Item -Recurse -Force $script:DataDir -ErrorAction SilentlyContinue }
    if ($script:PlugDir) { Remove-Item -Recurse -Force $script:PlugDir -ErrorAction SilentlyContinue }
}

# --- gates ---------------------------------------------------------------

# --- gate 01: build --------------------------------------------------
# /fsanitize=address links the dynamic ASan runtime, which must sit next to
# the instrumented exe. Copy it from the installed MSVC toolset.
function Copy-AsanRuntime([string]$OutDir) {
    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $roots = @()
    if (Test-Path $VsWhere) {
        $vsPath = & $VsWhere -latest -products * -property installationPath 2>$null
        if ($vsPath) { $roots += (Join-Path $vsPath 'VC\Tools\MSVC') }
    }
    foreach ($r in $roots) {
        $dll = Get-ChildItem -Path $r -Recurse -Filter 'clang_rt.asan_dynamic-x86_64.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($dll) { Copy-Item $dll.FullName $OutDir -Force; return }
    }
    throw "clang_rt.asan_dynamic-x86_64.dll not found under the MSVC toolset (install the 'MSVC ... ASan' component)"
}
# Calls scripts\windows\build.bat, which builds both fractalsql.dll
# (shim) and fractalsqld.exe (daemon). MARIADB_DIR/
# MARIADB_MAJOR/OUT_DIR/VCPKG_ROOT are env-var-driven per that script's own
# header.
function Gate-01-Build {
    Write-Host "  building..."
    Push-Location $Here
    try {
        # Sanitizers instrument fractalsqld.exe only: it is where the adapter
        # code runs. The shim stays plain.
        Remove-Item Env:\CC_DAEMON, Env:\CRT_FLAG, Env:\SAN_FLAGS -ErrorAction SilentlyContinue
        if ($Asan) {
            $env:SAN_FLAGS = '/fsanitize=address /Zi'
        } elseif ($Ubsan) {
            $env:CC_DAEMON = $script:ClangCl
            $env:CRT_FLAG  = '/MD'
            $env:SAN_FLAGS = '-fsanitize=undefined'
        }
        $env:MARIADB_DIR   = $MdbDir
        $env:MARIADB_MAJOR = $MdbMajor
        $env:OUT_DIR       = Split-Path -Parent $Dll
        if ($VcpkgRoot -ne "") { $env:VCPKG_ROOT = $VcpkgRoot }
        try {
            & "$Here\scripts\windows\build.bat"
            if ($LASTEXITCODE -ne 0) { Fail "01 build"; return $false }
        } finally {
            Remove-Item Env:\CC_DAEMON, Env:\CRT_FLAG, Env:\SAN_FLAGS -ErrorAction SilentlyContinue
        }
        if ($Asan) { Copy-AsanRuntime (Split-Path -Parent $Dll) }
    } finally { Pop-Location }
    if (-not (Test-Path $Dll)) { Fail "01 build: $Dll not produced"; return $false }
    if (-not (Test-Path $DaemonExe)) { Fail "01 build: $DaemonExe not produced"; return $false }
    Pass "01 build (shim + fractalsqld.exe$(if ($Asan) { ', ASan' } elseif ($Ubsan) { ', UBSan' }))"
    return $true
}

# Windows port of build_test.sh's Gate 30 (--fuzz). No live cluster
# needed -- same as gate 01, this builds and briefly runs standalone
# .exe's linking src\fractalsql_parse.c + src\fractalsql_interrupt.c
# (mysql.h-free by design, see the header comments) + one libFuzzer
# driver each, nothing else. Uses $script:ClangCl (resolved by
# -Fuzz/-Ubsan's shared Find-ClangCl call above), retargeted at this
# repo's own 3 parse functions
# (parse_vector_csv/parse_corpus/parse_index_csv).
function Gate-30-FuzzSmoke {
    $fuzzDir = Join-Path $Here 'dist\windows-fuzz'
    if (Test-Path $fuzzDir) { Remove-Item -Recurse -Force $fuzzDir }
    New-Item -ItemType Directory -Force -Path $fuzzDir | Out-Null

    $srcParse     = Join-Path $Here 'src\fractalsql_parse.c'
    $srcInterrupt = Join-Path $Here 'src\fractalsql_interrupt.c'
    $srcDir   = Join-Path $Here 'src'
    $fuzzTime = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { '30' }

    # clang-cl defaults to /MD, so -fsanitize=address links against
    # clang_rt.asan_dynamic-x86_64.dll -- without this DLL's directory
    # on PATH, the built .exe fails to even start (STATUS_DLL_NOT_FOUND).
    $clangResourceDir = $null
    try { $clangResourceDir = (& $script:ClangCl -print-resource-dir 2>$null | Select-Object -First 1) } catch { <# best-effort #> }
    if ($clangResourceDir) {
        $sanRtDir = Join-Path $clangResourceDir 'lib\windows'
        if (Test-Path $sanRtDir) { $env:PATH = "$sanRtDir;$env:PATH" }
    }

    foreach ($target in @('parse_vector_csv', 'parse_corpus', 'parse_index_csv')) {
        $bin    = Join-Path $fuzzDir "fuzz_$target.exe"
        $driver = Join-Path $Here "tests\fuzz\fuzz_$target.c"
        $corpus = Join-Path $Here "tests\fuzz\corpus_$target"

        $compileArgs = @(
            '-O1', '-Zi', '-fsanitize=fuzzer,address',
            "-I$srcDir",
            $srcParse, $srcInterrupt, $driver,
            "/Fe$bin"
        )
        & $script:ClangCl @compileArgs
        if ($LASTEXITCODE -ne 0) {
            Fail "30 fuzz_smoke: $target -- build failed (exit $LASTEXITCODE)"
            continue
        }

        $fuzzPsi = New-Object System.Diagnostics.ProcessStartInfo
        $fuzzPsi.FileName = $bin
        foreach ($a in @("-max_total_time=$fuzzTime", '-print_final_stats=1', $corpus)) {
            $fuzzPsi.ArgumentList.Add($a)
        }
        # symbolize=0: a pre-push smoke run, not a crash-triage session --
        # a crash still saves its input to disk for offline repro. Cheap
        # insurance against the external-symbolizer-subprocess hang class
        # this repo's own build_test.sh fuzz gate found and fixed on Linux
        # (see that script's gate_30_fuzz_smoke comment) -- untested
        # whether Windows' llvm-symbolizer path hits the same issue, but
        # harmless either way.
        $fuzzPsi.EnvironmentVariables["ASAN_OPTIONS"] = "detect_leaks=0:symbolize=0"
        $fuzzPsi.EnvironmentVariables["UBSAN_OPTIONS"] = "symbolize=0"
        $fuzzPsi.RedirectStandardOutput = $true
        $fuzzPsi.RedirectStandardError  = $true
        $fuzzPsi.UseShellExecute = $false
        $fuzzProc = [System.Diagnostics.Process]::Start($fuzzPsi)
        $fuzzOutTask = $fuzzProc.StandardOutput.ReadToEndAsync()
        $fuzzErrTask = $fuzzProc.StandardError.ReadToEndAsync()
        $fuzzProc.WaitForExit()
        $fuzzOut = $fuzzOutTask.Result
        $fuzzErr = $fuzzErrTask.Result

        if ($fuzzProc.ExitCode -eq 0) {
            $execsMatch = [regex]::Match($fuzzErr, 'stat::number_of_executed_units:\s*(\d+)')
            $execs = if ($execsMatch.Success) { $execsMatch.Groups[1].Value } else { '?' }
            Pass "30 fuzz_smoke: $target -- ${fuzzTime}s clean ($execs execs, no crash)"
        } else {
            $logPath = Join-Path $fuzzDir "fuzz_${target}_crash.log"
            ($fuzzOut + "`n" + $fuzzErr) | Out-File -FilePath $logPath -Encoding utf8
            Fail "30 fuzz_smoke: $target -- crash/hang found (exit $($fuzzProc.ExitCode)), see $logPath"
        }
        Remove-Item -Force $bin -ErrorAction SilentlyContinue
    }
}

function Gate-02-Smoke {
    # src\fractalsql.c defines the version via a macro, not a literal:
    #   #define FSQL_VERSION "2.0.0"          (line ~74)
    #   static const char kVersion[] = FSQL_VERSION;   (UDF body)
    # The first version of this check grepped kVersion's (macro) line and
    # always got an empty $wantVer, failing the comparison even after the
    # server was actually returning the right version.
    $verLine = Select-String -Path "$Here\src\fractalsql.c" -Pattern '#define FSQL_VERSION "(.*)"' | Select-Object -First 1
    $wantVer = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { "" }
    $wantVer = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { "" }
    $ver = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_version();" 2>&1
    if ($ver -eq $wantVer) { Pass "02 smoke: version=$ver" } else { Fail "02 smoke: version='$ver' (want $wantVer)" }

    $ed = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_edition();" 2>&1
    if ($ed -and $ed -notmatch "ERROR") { Pass "02 smoke: edition=$ed" } else { Fail "02 smoke: edition='$ed'" }

    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e `
        "SELECT fractal_search('[[1,0],[0,1],[0.6,0.8]]', '[0.6,0.8]', 3, '{\`"iterations\`":50,\`"population_size\`":30}');" 2>&1
    if ($r -match '"best_point"') { Pass "02 smoke: fractal_search returns best_point" } else { Fail "02 smoke: fractal_search='$r'" }
}

function Gate-03-SchemaContext {
    $sql = @"
DROP TABLE IF EXISTS bt_orders, bt_customers;
CREATE TABLE bt_customers (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  name VARCHAR(100) NOT NULL COMMENT 'Customer full name'
) COMMENT='Registered customers';
CREATE TABLE bt_orders (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  customer_id BIGINT NOT NULL,
  FOREIGN KEY (customer_id) REFERENCES bt_customers(id)
);
CALL fractal_schema_context(NULL, @ctx);
SELECT @ctx;
"@
    $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e $sql 2>&1
    $outStr = ($out -join "`n")

    if ($outStr -match "bt_customers") { Pass "03 schema_context: table name present" } else { Fail "03 schema_context: table name missing: $outStr" }
    if ($outStr -match "Registered customers") { Pass "03 schema_context: table comment present" } else { Fail "03 schema_context: table comment missing" }
    if ($outStr -match "Customer full name") { Pass "03 schema_context: column comment present" } else { Fail "03 schema_context: column comment missing" }
    if ($outStr -match "(?i)FOREIGN KEY") { Pass "03 schema_context: foreign key present" } else { Fail "03 schema_context: foreign key missing" }

    $err = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e `
        "CALL fractal_schema_context('[\`"nonexistent_bt_table\`"]', @c2);" 2>&1
    $errStr = ($err -join "`n")
    if ($errStr -match "(?i)not found or not visible") { Pass "03 schema_context: nonexistent table SIGNALs cleanly" } else { Fail "03 schema_context: expected a clean SIGNAL, got: $errStr" }
}

function Gate-04-TextToSql {
    $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_text_to_sql('irrelevant -- mock always replies the same', NULL, @s, @e);
SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');
"@ 2>&1
    $line = ($out -join "`n").Trim() -split "`t"
    $sqlOut = if ($line.Length -ge 1) { $line[0] } else { "" }
    $errOut = if ($line.Length -ge 2) { $line[1] } else { "" }
    # '^SELECT 1' regex, not a whole-field -eq: the fence-stripper leaves
    # the candidate's trailing newline on @s (bash's `read -r sql err`
    # whitespace-split hid that by collapsing $sql to the first token
    # "SELECT"), so an anchored prefix is the right whole-value match.
    if ($sqlOut -match '^SELECT 1') { Pass "04 text_to_sql: GENERATE/ALLOWLIST/EXPLAIN round trip returned real SQL" } else { Fail "04 text_to_sql: expected 'SELECT 1', got sql='$sqlOut' err='$errOut'" }

    $a1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT 1'), '<PASS>');" 2>&1
    if ($a1 -eq "<PASS>") { Pass "04 text_to_sql: plain SELECT passes allowlist" } else { Fail "04 text_to_sql: expected plain SELECT to pass, got: $a1" }

    $a2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('DROP TABLE bt_customers'), '<PASS>');" 2>&1
    if ($a2 -ne "<PASS>") { Pass "04 text_to_sql: DDL rejected by allowlist" } else { Fail "04 text_to_sql: expected DROP TABLE to be rejected" }
}

# tests/evil_nonterminating_plugin.c: a
# reasoning-VFS generate() that claims a response but never NUL-
# terminates the buffer it hands back. Proves the three call sites that
# read a plugin's response (fractal_text_to_sql's GENERATE step,
# fractal_reason, fractal_t2s_review) don't read past a real allocation
# based on an untrusted plugin's claim. Each call site needs its OWN
# restart (the evil plugin's per-call-site behavior is stateful across
# the whole process, mirrored from build_test.sh's own three separate
# Swap-ReasoningPlugin calls, not a guess).
function Gate-05-EvilOverread {
    $rc = Swap-ReasoningPlugin $script:EvilReasoningSo
    if ($rc -ne 0) { Fail "05 evil_overread: plugin swap did not take effect"; Restore-ReasoningPlugin; return }
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_text_to_sql('q', NULL, @s, @e); SELECT @s, @e;" 2>&1
    $up1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up1 -eq "1") { Pass "05 evil_overread: GENERATE path (fractal_text_to_sql) survived" } else { Fail "05 evil_overread: GENERATE path -- mariadbd did not survive: $r" }

    $rc = Swap-ReasoningPlugin $script:EvilReasoningSo
    if ($rc -ne 0) { Fail "05 evil_overread: plugin swap (reason) did not take effect"; Restore-ReasoningPlugin; return }
    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1
    $up2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up2 -eq "1") { Pass "05 evil_overread: bare fractal_reason() survived" } else { Fail "05 evil_overread: bare fractal_reason() -- mariadbd did not survive: $r2" }

    $rc = Swap-ReasoningPlugin $script:EvilReasoningSo
    if ($rc -ne 0) { Fail "05 evil_overread: plugin swap (review) did not take effect"; Restore-ReasoningPlugin; return }
    $r3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1');" 2>&1
    $up3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up3 -eq "1") { Pass "05 evil_overread: fractal_t2s_review() survived" } else { Fail "05 evil_overread: fractal_t2s_review() -- mariadbd did not survive: $r3" }

    Restore-ReasoningPlugin
}

# Same three call sites as gate 05, but the adversarial claim is a
# lying response_len_out (32 MiB, over a real 8-byte buffer) instead of
# a missing NUL terminator (tests/evil_lying_length_plugin.c).
# MariaDB's UDF ABI has no SQL-visible error text for
# this class of rejection, so the assertion is "result IS NULL,
# mariadbd still up" -- mirrors build_test.sh's own posture exactly,
# not a weaker Windows-specific substitute.
function Gate-07-EvilLyingLength {
    $rc = Swap-ReasoningPlugin $script:LyingSo
    if ($rc -ne 0) { Fail "07 evil_lying_length: plugin swap did not take effect"; Restore-ReasoningPlugin; return }
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_text_to_sql('q', NULL, @s, @e); SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1
    $up1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up1 -ne "1") { Fail "07 evil_lying_length: GENERATE path -- mariadbd did not survive: $r" }
    elseif ($r -match "<NULL>") { Pass "07 evil_lying_length: GENERATE path rejected cleanly (out_sql NULL, no crash)" }
    else { Fail "07 evil_lying_length: GENERATE path -- expected a clean rejection, got: $r" }

    $rc = Swap-ReasoningPlugin $script:LyingSo
    if ($rc -ne 0) { Fail "07 evil_lying_length: plugin swap (reason) did not take effect"; Restore-ReasoningPlugin; return }
    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_reason(CONNECTION_ID(), 'q'), '<NULL>');" 2>&1
    $up2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up2 -ne "1") { Fail "07 evil_lying_length: bare fractal_reason() -- mariadbd did not survive: $r2" }
    elseif ($r2 -eq "<NULL>") { Pass "07 evil_lying_length: bare fractal_reason() rejected cleanly" }
    else { Fail "07 evil_lying_length: bare fractal_reason() -- expected NULL, got: $r2" }

    $rc = Swap-ReasoningPlugin $script:LyingSo
    if ($rc -ne 0) { Fail "07 evil_lying_length: plugin swap (review) did not take effect"; Restore-ReasoningPlugin; return }
    $r3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1'), '<NULL>');" 2>&1
    $up3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($up3 -ne "1") { Fail "07 evil_lying_length: fractal_t2s_review() -- mariadbd did not survive: $r3" }
    elseif ($r3 -eq "<NULL>") { Pass "07 evil_lying_length: fractal_t2s_review() rejected cleanly" }
    else { Fail "07 evil_lying_length: fractal_t2s_review() -- expected NULL, got: $r3" }

    Restore-ReasoningPlugin
}

# fractal_schema_context's privilege boundary. GRANT statements copied
# verbatim (intent) from build_test.sh's own gate_08 -- that file's
# comment documents two hard-won, confirmed-live requirements (db-scoped
# EXECUTE, not routine-scoped; CREATE TEMPORARY TABLES for the
# procedure's own working-set temp table), both preserved here exactly.
# ONE deliberate platform adaptation, not a blind copy: the account host
# pattern. build_test.sh creates 'bt_lowpriv'@'localhost', correct for
# ITS Unix-socket connection; this harness has no Unix socket at all
# (TCP-only, --host=127.0.0.1 throughout), so 'user'@'localhost' would
# be a real ambiguity risk (MariaDB's 'localhost' host-matching is a
# Unix-socket-connection convention, not guaranteed to match a TCP
# connection to 127.0.0.1). Using 'user'@'127.0.0.1' instead --
# matching the actual connection host this harness uses everywhere else
# -- preserves the GRANT logic's intent without inheriting a Linux-
# socket-specific assumption that doesn't hold here.
function Gate-08-Authz {
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DROP TABLE IF EXISTS bt_secret;
CREATE TABLE bt_secret (id BIGINT PRIMARY KEY AUTO_INCREMENT, ssn VARCHAR(20)) COMMENT='PII - restricted';
DROP USER IF EXISTS 'bt_lowpriv'@'127.0.0.1';
CREATE USER 'bt_lowpriv'@'127.0.0.1';
GRANT EXECUTE, CREATE TEMPORARY TABLES ON fractalsql_bt.* TO 'bt_lowpriv'@'127.0.0.1';
FLUSH PRIVILEGES;
'@ 2>&1 | Out-Null

    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_lowpriv -D fractalsql_bt -N -e "CALL fractal_schema_context('[\`"bt_secret\`"]', @c); SELECT @c;" 2>&1
    if ($r -match "ssn") { Fail "08 authz: low-priv user saw bt_secret's columns (info disclosure): $r" }
    elseif ($r -match "(?i)not found|not visible|does not exist") { Pass "08 authz: low-priv user correctly blocked from bt_secret" }
    else { Fail "08 authz: unexpected result: $r" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -e "GRANT SELECT ON fractalsql_bt.bt_secret TO 'bt_lowpriv'@'127.0.0.1'; FLUSH PRIVILEGES;" 2>&1 | Out-Null
    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_lowpriv -D fractalsql_bt -N -e "CALL fractal_schema_context('[\`"bt_secret\`"]', @c); SELECT @c;" 2>&1
    if ($r2 -match "ssn") { Pass "08 authz: SELECT grant restores visibility" } else { Fail "08 authz: granted user still blocked: $r2" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -e "DROP USER IF EXISTS 'bt_lowpriv'@'127.0.0.1'; DROP TABLE IF EXISTS bt_secret;" 2>&1 | Out-Null
}

function Gate-06-CrashRecovery {
    $crashSetupSql = @"
CREATE DATABASE IF NOT EXISTS bt;
USE bt;
CREATE TABLE IF NOT EXISTS canary (id INT PRIMARY KEY, note VARCHAR(32)) ENGINE=InnoDB;
INSERT INTO canary VALUES (1, 'canary') ON DUPLICATE KEY UPDATE note='canary';
DROP FUNCTION IF EXISTS bt_evil_crash;
CREATE FUNCTION bt_evil_crash RETURNS INTEGER SONAME 'evil_crash.dll';
"@
    $crashSetupOut = $crashSetupSql | & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt 2>&1
    # A failed CREATE here (e.g. the fixture DLL exporting nothing --
    # exactly what happened on the first real Windows run, before
    # tests\windows\evil_crash_udf.def existed) must NOT be swallowed:
    # otherwise the SELECT below fails ERROR 1305, no crash occurs, and
    # the respawn/canary assertions below it pass for the wrong reason.
    if ($crashSetupOut -match "ERROR") { Fail "06 crash_recovery: bt_evil_crash setup failed: $crashSetupOut"; return }

    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT bt_evil_crash();" 2>&1
    if ($r -match "Lost connection|gone away|can't connect") { Pass "06 crash_recovery: triggering connection dropped as expected" }
    else { Fail "06 crash_recovery: expected the connection to drop, got: $r" }

    $up = $false
    for ($i = 0; $i -lt (30 * $TimeoutMult); $i++) {
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT 1;" >$null 2>&1
        if ($LASTEXITCODE -eq 0) { $up = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if ($up) { Pass "06 crash_recovery: supervisor respawned mariadbd" } else { Fail "06 crash_recovery: mariadbd did not come back" }

    if ($up) {
        $n = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT note FROM bt.canary WHERE id=1;" 2>&1
        if ($n -eq "canary") { Pass "06 crash_recovery: prior committed data intact after recovery" }
        else { Fail "06 crash_recovery: canary row wrong/missing after recovery: '$n'" }
    } else {
        Fail "06 crash_recovery: mariadbd never came back"
    }
}

function Gate-10-DosAndInjection {
    $r1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT 1; DROP TABLE bt_customers'), '<PASS>');" 2>&1
    if ($r1 -ne "<PASS>") { Pass "10 dos_and_injection: stacked statement rejected" } else { Fail "10 dos_and_injection: expected stacked-statement rejection" }

    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT * FROM bt_customers INTO OUTFILE ''/tmp/x'''), '<PASS>');" 2>&1
    if ($r2 -ne "<PASS>") { Pass "10 dos_and_injection: INTO OUTFILE rejected" } else { Fail "10 dos_and_injection: expected INTO OUTFILE rejection" }

    $r3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('WITH cte AS (SELECT id FROM bt_customers) DELETE FROM bt_customers WHERE id IN (SELECT id FROM cte)'), '<PASS>');" 2>&1
    if ($r3 -ne "<PASS>") { Pass "10 dos_and_injection: CTE-feeding-DELETE rejected" } else { Fail "10 dos_and_injection: expected CTE-feeding-DELETE rejection" }
}

function Gate-11-Scout {
    $corpus = "[" + (("[1,0,0]," * 20) + ("[0,1,0]," * 20) + ("[0,0,1]," * 20)).TrimEnd(",") + "]"
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e `
        "SELECT fractal_search_explore('$corpus', '[1,0,0]', '{\`"population_size\`":24,\`"iterations\`":12}');" 2>&1
    if ($r -match '"population"') { Pass "11 scout: fractal_search_explore returns a population array" } else { Fail "11 scout: fractal_search_explore='$r'" }
    # NOTE: no jq-equivalent population-size/dispersion check on Windows
    # yet (build_test.sh uses `jq`, conditionally skipped if absent; the
    # same skip-if-absent behavior would apply here via ConvertFrom-Json,
    # not yet wired).
}

function Gate-12-Soak {
    $ok = $true
    $lastOut = ""
    for ($i = 0; $i -lt 30; $i++) {
        $lastOut = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_search('[[1,0,0],[0,1,0],[0,0,1]]', '[0.6,0.8,0]', 2, '{}');" 2>&1
        if ($lastOut -notmatch '"best_point"') { $ok = $false; break }
    }
    if ($ok) { Pass "12 soak: 30x fractal_search all returned a valid result" } else { Fail "12 soak: a soak iteration failed: $lastOut" }
}

function Gate-13-VectorizerEmbed {
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_docs;
CREATE TABLE bt_docs (id BIGINT PRIMARY KEY AUTO_INCREMENT, content TEXT, embedding TEXT);
CALL fractal_vectorizer_create('bt_docs', 'content', 'embedding', NULL, @vid);
INSERT INTO bt_docs (content) VALUES ('hello world');
CALL fractal_vectorizer_process_queue(10, 600);
"@ 2>&1 | Out-Null

    $emb = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT embedding FROM bt_docs WHERE id=1;" 2>&1
    if ($emb -match "0\.1") { Pass "13 vectorizer_embed: process_queue wrote back the mock embedding" } else { Fail "13 vectorizer_embed: expected an embedding containing 0.1, got: $emb" }

    $direct = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_embed(CONNECTION_ID(), 'test input');" 2>&1
    if ($direct -match "0\.1") { Pass "13 vectorizer_embed: fractal_embed() direct call works" } else { Fail "13 vectorizer_embed: fractal_embed() unexpected: $direct" }
}

# Retry-with-feedback: fractal_text_to_sql's own internal attempt loop,
# driven by FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS. tests/retry_reasoning_
# plugin.c returns a rejected DDL statement on
# GENERATE call 1, then "SELECT 1" on call 2.
function Gate-14-Retry {
    $env:FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS = "2"
    $env:FSQL_REASONING_HTTP_RESPONSE_MODE = "code"
    # $Here, not $env:TEMP: the win retry fixture
    # (tests\windows\retry_reasoning_plugin_win.c) dumps attempt-2's
    # prompt to the path this gate exports below, read by the fixture
    # via getenv. NOT a bare-relative filename -- mariadbd.exe CHDIRS
    # TO THE DATADIR at startup (observed
    # in-process: a UDF's fopen("relative.txt") landed in the datadir
    # even though Start-Process was launched from the repo root), so a
    # relative name would resolve into the per-run datadir this script
    # wipes at teardown. The env var carries the ABSOLUTE path instead;
    # it must be set BEFORE the Swap-ReasoningPlugin restart so the
    # restarted mariadbd inherits it and the swapped-in fixture's getenv
    # sees it.
    $retryPrompt = "$Here\fractalsql_bt_retry_prompt.txt"
    Remove-Item $retryPrompt -ErrorAction SilentlyContinue
    $env:FRACTALSQL_BT_RETRY_PROMPT_FILE = $retryPrompt
    $rc = Swap-ReasoningPlugin $script:RetrySo
    if ($rc -ne 0) { Fail "14 retry: plugin swap did not take effect"; Remove-Item Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue; Remove-Item Env:\FRACTALSQL_BT_RETRY_PROMPT_FILE -ErrorAction SilentlyContinue; Restore-ReasoningPlugin; return }

    $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_text_to_sql('q', NULL, @s, @e);
SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');
"@ 2>&1
    $fields = ($out -join "`n").Trim() -split "`t"
    $sqlOut = if ($fields.Length -ge 1) { $fields[0] } else { "" }
    $errOut = if ($fields.Length -ge 2) { $fields[1] } else { "" }
    # "SELECT 1", not "SELECT": build_test.sh's `read -r sql err` splits
    # its tab-converted line on ALL whitespace, so its $sql is only the
    # first token ("SELECT"); this port splits on the tab, so the first
    # field is the whole candidate ("SELECT 1").
    if ($sqlOut -eq "SELECT 1") { Pass "14 retry: succeeded on 2nd attempt after 1st was rejected" } else { Fail "14 retry: expected eventual success (SELECT 1...), got sql='$sqlOut' err='$errOut'" }

    $prompt = Get-Content $retryPrompt -ErrorAction SilentlyContinue -Raw
    if ($prompt -match "(?i)rejected") { Pass "14 retry: attempt-1 rejection reason fed back into attempt-2 prompt" } else { Fail "14 retry: retry prompt missing feedback text: '$prompt'" }

    Remove-Item Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue
    Remove-Item Env:\FRACTALSQL_BT_RETRY_PROMPT_FILE -ErrorAction SilentlyContinue
    Restore-ReasoningPlugin
}

# THINK bridge: FRACTALSQL_HTTP_THINK/_THINK_PROVIDER/_NATIVE_URL/
# _NUM_CTX -> FSQL_REASONING_HTTP_THINK/_THINK_PROVIDER/_NATIVE_URL/
# _NUM_CTX. tests/think_reasoning_plugin.c echoes back whatever actually
# landed in its own process environment. Config is read once per
# mariadbd process and cached for its lifetime, so each scenario needs
# its own Swap-ReasoningPlugin restart.
function Gate-29-Think {
    # (a) unset -> nothing reaches the plugin.
    $rc = Swap-ReasoningPlugin $script:ThinkSo
    if ($rc -ne 0) { Fail "29 think: plugin swap did not take effect"; Restore-ReasoningPlugin; return }
    $out1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1
    $out1 = ($out1 -join "`n")
    if ($out1 -match "THINK=\(unset\)" -and $out1 -match "THINK_PROVIDER=\(unset\)" -and $out1 -match "NATIVE_URL=\(unset\)" -and $out1 -match "NUM_CTX=\(unset\)") {
        Pass "29 think: THINK unset -> no THINK-related env var reaches the plugin"
    } else { Fail "29 think: expected all 4 vars (unset), got: $out1" }
    Restore-ReasoningPlugin

    # (d, live) conf live-reload, mirroring build_test.sh's (d): the conf
    # file -- the preferred provider source -- carries the same 4 keys the
    # daemon's environment does NOT carry; an OP_RELOAD frame pushes them
    # into the RUNNING daemon without any restart, and the next
    # fractal_reason call re-loads the echo plugin and reports the values,
    # which can only have come from the reload. The frame client is
    # service\tests\reload_probe_w.c (fsqlctl itself is a POSIX-only CLI,
    # but the daemon-side RELOAD is cross-platform). A full restart would
    # defeat the proof -- the values must survive with no teardown here.
    if (-not $script:ClangCl) {
        # Mirrors Get-PythonExe's skip pattern: probe build requires a
        # compiler; (a)-(c) above still cover the env fallback.
        try { $script:ClangCl = Find-ClangCl } catch { $script:ClangCl = $null }
    }
    if (-not $script:ClangCl) {
        Skip "29 think: (d) conf live-reload: no clang-cl.exe to build reload_probe_w"
    } else {
        $probe = "$env:TEMP\fractalsql_bt_reload_probe_w.exe"
        # /D_CRT_SECURE_NO_WARNINGS mirrors build.bat's own cl.exe defines
        # (this repo compiles plain fopen/stdio on Windows everywhere).
        & $script:ClangCl -O2 "/D_CRT_SECURE_NO_WARNINGS" (Join-Path $Here 'service\tests\reload_probe_w.c') "/Fe$probe"
        if ($LASTEXITCODE -ne 0) {
            Skip "29 think: (d) conf live-reload: reload_probe_w build failed (exit $LASTEXITCODE)"
        } else {
            $confBackup = "$($script:FsqdConf).bak"
            $rc = Swap-ReasoningPlugin $script:ThinkSo
            if ($rc -ne 0) {
                Fail "29 think: (d) plugin swap did not take effect"
                Remove-Item -Force $confBackup -ErrorAction SilentlyContinue
                Restore-ReasoningPlugin
                return
            }
            Copy-Item $script:FsqdConf $confBackup -Force
            Add-Content -Path $script:FsqdConf -Encoding ascii -Value @(
                "think = low",
                "think_provider = conf-live-think",
                "think_native_url = http://127.0.0.1:9/api/chat",
                "think_num_ctx = 2048")
            $rd1 = & $probe $script:FsqdPipe $script:FsqdKey 2>&1
            $rd1 = ($rd1 -join "`n")
            if ($LASTEXITCODE -eq 0 -and $rd1 -match 'reloaded') {
                Pass "29 think: reload accepts live provider keys (named-pipe OP_RELOAD)"
            } else {
                Fail "29 think: reload_probe_w RELOAD rc/err: rc=$LASTEXITCODE out=$rd1"
            }
            $outd1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1
            $outd1 = ($outd1 -join "`n")
            if ($outd1 -match "THINK=low" -and $outd1 -match "THINK_PROVIDER=conf-live-think" -and $outd1 -match [regex]::Escape("NATIVE_URL=http://127.0.0.1:9/api/chat") -and $outd1 -match "NUM_CTX=2048") {
                Pass "29 think: reload pushed the conf think keys into the RUNNING daemon (no restart)"
            } else {
                Fail "29 think: reload did not take effect live, got: $outd1"
            }

            # (d, live) removing the keys reverts the tier to the boot-env
            # fallback -- here unset -- on the next dispatch.
            Copy-Item $confBackup $script:FsqdConf -Force
            $rd2 = & $probe $script:FsqdPipe $script:FsqdKey 2>&1
            $rd2 = ($rd2 -join "`n")
            if ($LASTEXITCODE -eq 0 -and $rd2 -match 'reloaded') {
                Pass "29 think: reload with the think keys removed"
            } else {
                Fail "29 think: removal reload rc/err: rc=$LASTEXITCODE out=$rd2"
            }
            $outd2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1
            $outd2 = ($outd2 -join "`n")
            if ($outd2 -match "THINK=\(unset\)") {
                Pass "29 think: removing the conf keys reverts THINK to unset on the next call"
            } else {
                Fail "29 think: expected reversion to (unset), got: $outd2"
            }
            Remove-Item $confBackup -ErrorAction SilentlyContinue
            Restore-ReasoningPlugin
        }
    }

    # (b) configured -> the bridge carries every value through.
    $env:FRACTALSQL_HTTP_THINK = "medium"
    $env:FRACTALSQL_HTTP_THINK_PROVIDER = "ollama"
    $env:FRACTALSQL_HTTP_NATIVE_URL = "http://127.0.0.1:11434/api/chat"
    $env:FRACTALSQL_HTTP_NUM_CTX = "8192"
    $rc = Swap-ReasoningPlugin $script:ThinkSo
    if ($rc -ne 0) {
        Fail "29 think: plugin swap did not take effect (configured)"
        Remove-Item Env:\FRACTALSQL_HTTP_THINK, Env:\FRACTALSQL_HTTP_THINK_PROVIDER, Env:\FRACTALSQL_HTTP_NATIVE_URL, Env:\FRACTALSQL_HTTP_NUM_CTX -ErrorAction SilentlyContinue
        Restore-ReasoningPlugin; return
    }
    $out2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1
    $out2 = ($out2 -join "`n")
    if ($out2 -match "THINK=medium" -and $out2 -match "THINK_PROVIDER=ollama" -and $out2 -match [regex]::Escape("NATIVE_URL=http://127.0.0.1:11434/api/chat") -and $out2 -match "NUM_CTX=8192") {
        Pass "29 think: configured THINK/THINK_PROVIDER/NATIVE_URL/NUM_CTX all reach the plugin"
    } else { Fail "29 think: expected all 4 configured values in plugin output, got: $out2" }

    # (c) embed tier: THINK still configured, must never reach fractal_embed
    # (apply_embed_env_locked's explicit unsetenv). FRACTALSQL_HTTP_EMBED_URL
    # is already exported by Mdb-Setup itself. fractal_embed() runs the
    # plugin's response through parse_vector_csv(), so the KEY=value text
    # the reason-tier checks above grep for would just fail to parse as a
    # vector -- the query text "EMBED_PROBE" tells think_reasoning_plugin.c
    # to answer with a 4-element 1/0-per-var numeric vector instead. The
    # whole-vector equality mirrors build_test.sh's own gate 29 exactly
    # ([0,0,0,0] = all four THINK-related vars unset in the embed tier).
    $out3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_embed(CONNECTION_ID(), 'EMBED_PROBE');" 2>&1
    $out3 = ($out3 -join "`n")
    if ($out3 -eq "[0,0,0,0]") {
        Pass "29 think: fractal_embed never sees THINK even when configured for the chat tiers"
    } else { Fail "29 think: THINK leaked into the embed tier: $out3" }

    Remove-Item Env:\FRACTALSQL_HTTP_THINK, Env:\FRACTALSQL_HTTP_THINK_PROVIDER, Env:\FRACTALSQL_HTTP_NATIVE_URL, Env:\FRACTALSQL_HTTP_NUM_CTX -ErrorAction SilentlyContinue
    Restore-ReasoningPlugin
}

# The daemon conf's privacy gate (key_file_private + validate_cfg) and
# the providers' loud validation (validate_provider_cfg), at daemon
# startup. build_test.sh's gate 33 also covers reload-side refusals;
# fsqlctl is a POSIX-only client, so this mirror covers the startup
# side, which shares the same two validators:
#   (a) a conf DACL granting Everyone -> the daemon refuses to boot,
#       naming the file's grants on its stderr log;
#   (b) the provisioner-recipe DACL (inheritance off: SYSTEM +
#       Administrators + LOCAL SERVICE + the invoking user) boots and
#       listens -- the same recipe install-time ACLs apply;
#   (c) bad provider values refuse the boot too, each naming the key
#       in the log (mirrors build_test.sh gate 33's (c) loud refusals);
#   (d) an unknown key warns and does not block the boot.
function Gate-33-ConfGate {
    $tag   = "g33"
    $pipe  = "\\.\pipe\fsql_bt_${tag}_$PID"
    $key   = "$env:TEMP\fractalsql_bt_fsqd_${tag}.key"
    $conf  = "$env:TEMP\fractalsql_bt_fsqd_${tag}.conf"
    $log   = "$env:TEMP\fractalsql_bt_fsqd_${tag}.log"
    $ownSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    # The exact four-grant recipe provision-fractalsqld.ps1 ships: the
    # daemon runs as LOCAL SERVICE in production, the invoking user here
    # (WindowsIdentity), so the recipe adds the own-SID read ACE too.
    function Grant-ConfRecipe {
        # A bare SID is only accepted with the leading '*' (otherwise
        # icacls treats it as an account name and fails, leaving the
        # previous DACL in place). icacls never removes ACEs for trustees
        # it does not name, so an earlier Everyone/Authenticated-Users/
        # Users ACE added by another case survives /inheritance:r -- strip
        # those three explicitly before re-granting.
        icacls $conf /remove "*S-1-1-0" "*S-1-5-11" "*S-1-5-32-545" > $null
        icacls $conf /inheritance:r /grant:r "*S-1-5-18:(F)" "*S-1-5-32-544:(F)" `
            "*S-1-5-19:(RX)" "*${ownSid}:(F)" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $conf (exit $LASTEXITCODE)" }
    }
    function New-Con([string[]]$Extra) {
        Set-Content -Path $conf -Encoding ascii -Value (@(
            "socket_path = $pipe",
            "hmac_key_file = $key") + $Extra)
    }
    # Launch the daemon against $conf, wait for either 'listening on' in
    # the stderr log or a process exit, stop any survivor, and return
    # both outcomes + the log text. A fresh log file each time mirrors
    # Start-Fsqd's "a fresh stderr log" rule.
    function Boot-Probe {
        Remove-Item -Force $log, "$log.out" -ErrorAction SilentlyContinue
        $p = Start-Process -FilePath $script:DaemonExe `
            -ArgumentList @("-c", "`"$conf`"") `
            -RedirectStandardError $log -RedirectStandardOutput "$log.out" `
            -PassThru -WindowStyle Hidden
        # The finally reaps the probe even if the poll throws or the
        # run is interrupted here: an orphaned daemon keeps
        # fractalsqld.exe locked and breaks the next build's link step
        # (seen as [FAIL] 01 build after an aborted run).
        try {
            $booted = $false
            for ($i = 0; $i -lt (40 * $TimeoutMult); $i++) {
                if ($p.HasExited) { break }
                if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'listening on' -Quiet)) { $booted = $true; break }
                Start-Sleep -Milliseconds 100
            }
            $logText = ""
            $logText = Read-LogShared $log
            return @{ Booted = $booted; Exited = $p.HasExited; Log = $logText }
        } finally {
            if (-not $p.HasExited) {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                $p.WaitForExit(3000) | Out-Null
            }
        }
    }

    $keyHex = -join ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32) | ForEach-Object { $_.ToString('x2') })
    Set-Content -Path $key -Value $keyHex -NoNewline -Encoding ascii

    # (a) Everyone gets RX on the conf -> refusal, key named in the log.
    New-Con @()
    icacls $conf /grant "*S-1-1-0:(RX)" | Out-Null
    $r = Boot-Probe
    if (-not $r.Booted -and $r.Log -match 'grants access to Everyone') {
        Pass "33 conf_gate: conf DACL granting Everyone -> daemon refuses to boot"
    } else {
        Fail "33 conf_gate: Everyone-granted conf was not refused: booted=$($r.Booted) log: $($r.Log)"
    }

    # (b) the provisioner recipe (no wide ACEs) boots and listens. The
    # conf is recreated so case (a)'s explicit Everyone ACE dies with the
    # file -- icacls never removes ACEs for trustees it does not name.
    Remove-Item -Force $conf -ErrorAction SilentlyContinue
    New-Con @()
    Grant-ConfRecipe
    $r = Boot-Probe
    if ($r.Booted) {
        Pass "33 conf_gate: provisioner-recipe DACL -> daemon boots and listens"
    } else {
        Fail "33 conf_gate: provisioner-recipe DACL did not boot; log: $($r.Log)"
    }

    foreach ($spec in @(
        @{ extra = @("t2s_max_attempts = 15");              pattern = "provider key t2s_max_attempts" },
        @{ extra = @("think_num_ctx = nonsense");           pattern = "provider key think_num_ctx" },
        @{ extra = @("reasoning_url = ");                   pattern = "provider key reasoning_url" },
        @{ extra = @("t2s_allowed_statements = delete");    pattern = "provider key t2s_allowed_statements" })) {
        New-Con $spec.extra
        Grant-ConfRecipe
        $r = Boot-Probe
        if (-not $r.Booted -and $r.Log -match ([regex]::Escape($spec.pattern))) {
            Pass "33 conf_gate: startup refuses '$($spec.extra -join '')' (key named in the log)"
        } else {
            Fail "33 conf_gate: '$($spec.extra -join '')' not refused: booted=$($r.Booted) log: $($r.Log)"
        }
    }

    # (d) unknown key: warns, boot proceeds.
    New-Con @("reasning_url = http://127.0.0.1:9/warnprobe")
    Grant-ConfRecipe
    $r = Boot-Probe
    if ($r.Booted -and $r.Log -match "unknown key 'reasning_url' ignored") {
        Pass "33 conf_gate: unknown key warns and is ignored (boot proceeds)"
    } else {
        Fail "33 conf_gate: unknown-key conf did not warn+boot: booted=$($r.Booted) log: $($r.Log)"
    }

    Remove-Item -Force $conf, $key, $log, "$log.out" -ErrorAction SilentlyContinue
}

# fractal_embed()'s own edge cases plus the vectorizer's injection/
# double-create rejections. NULL input and a nonexistent plugin path
# both collapse to a silent NULL (no SQL-visible error text) --
# assertions are "result IS NULL, mariadbd still up", matching gate 07's
# posture. tests/evil_embed_plugin.c returns
# MAX_EMBED_DIM+1 (16385) floats straight through the reasoning-VFS
# generate() callback -- proves fractal_embed's own dimension-limit
# check rejects cleanly rather than truncating.
function Gate-15-Embed {
    $rnull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), NULL), '<NULL>');" 2>&1
    if ($rnull -eq "<NULL>") { Pass "15 embed: NULL input rejected cleanly" } else { Fail "15 embed: NULL input expected NULL, got: $rnull" }

    $rc = Swap-ReasoningPlugin "$Here\.gate15_nonexistent.dll"
    if ($rc -ne 0) { Fail "15 embed: bad-path restart did not take effect"; Restore-ReasoningPlugin; return }
    $rbad = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), 'x'), '<NULL>');" 2>&1
    $upbad = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($upbad -ne "1") { Fail "15 embed: nonexistent plugin path -- mariadbd did not survive: $rbad" }
    elseif ($rbad -eq "<NULL>") { Pass "15 embed: nonexistent plugin path rejected cleanly" }
    else { Fail "15 embed: nonexistent plugin path expected NULL, got: $rbad" }

    $rc = Swap-ReasoningPlugin $script:EvilEmbedSo
    if ($rc -ne 0) { Fail "15 embed: evil_embed plugin swap did not take effect"; Restore-ReasoningPlugin; return }
    $revil = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), 'x'), '<NULL>');" 2>&1
    if ($revil -eq "<NULL>") { Pass "15 embed: over-limit embedding array (16385) rejected, not silently truncated" } else { Fail "15 embed: expected a clean NULL rejection, got: $revil" }
    Restore-ReasoningPlugin

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';
DROP TABLE IF EXISTS bt_embed_docs;
CREATE TABLE bt_embed_docs (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
INSERT INTO bt_embed_docs (body) VALUES ('a'), ('b');
'@ 2>&1 | Out-Null

    $rinj = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create('bt_embed_docs''; DROP TABLE bt_embed_docs; --', 'body', 'embedding', NULL, @vid);" 2>&1
    $ninj = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM bt_embed_docs;" 2>&1
    if ($ninj -eq "2") { Pass "15 embed: injection-shaped source_table did not execute (bt_embed_docs intact)" } else { Fail "15 embed: bt_embed_docs row count changed (n=$ninj) -- injection may have executed" }
    if ($rinj -match "(?i)not found") { Pass "15 embed: injection-shaped source_table cleanly rejected" } else { Fail "15 embed: unexpected result: $rinj" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "CALL fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding', NULL, @vzid);" 2>&1 | Out-Null
    $vzid = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_docs' AND text_col='body' AND embedding_col='embedding';" 2>&1

    $rdup = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding', NULL, @vid2);" 2>&1
    if ($rdup -match "already exists") { Pass "15 embed: double-create rejected with a clean, specific error" } else { Fail "15 embed: expected a clean double-create rejection, got: $rdup" }

    $n = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(10, 600);" 2>&1
    if ($n -eq "2") { Pass "15 embed: process_queue processed 2 backfilled rows" } else { Fail "15 embed: process_queue expected 2, got: $n" }

    $embedded = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM bt_embed_docs WHERE embedding LIKE '%0.1%';" 2>&1
    if ($embedded -eq "2") { Pass "15 embed: both rows got the real embedding written back" } else { Fail "15 embed: expected 2 rows with the embedding, got: $embedded" }

    $status = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT status FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid;" 2>&1
    if ($status -eq "done") { Pass "15 embed: vectorizer status shows done, no failures" } else { Fail "15 embed: expected status 'done', got: $status" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_docs'; DROP TABLE IF EXISTS bt_embed_docs;" 2>&1 | Out-Null
}

# Vectorizer authz, the same regression class as gate 08 applied to
# fractal_vectorizer_process_queue (SQL SECURITY INVOKER). GRANT
# statements and the account-host adaptation follow gate 08's own
# comment (127.0.0.1, not localhost -- see there for why).
function Gate-16-EmbedAuthz {
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DROP USER IF EXISTS 'bt_embed_owner'@'127.0.0.1';
CREATE USER 'bt_embed_owner'@'127.0.0.1';
GRANT ALL PRIVILEGES ON fractalsql_bt.* TO 'bt_embed_owner'@'127.0.0.1';
DROP USER IF EXISTS 'bt_embed_outsider'@'127.0.0.1';
CREATE USER 'bt_embed_outsider'@'127.0.0.1';
GRANT EXECUTE, CREATE TEMPORARY TABLES ON fractalsql_bt.* TO 'bt_embed_outsider'@'127.0.0.1';
GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizer_queue TO 'bt_embed_outsider'@'127.0.0.1';
GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizers TO 'bt_embed_outsider'@'127.0.0.1';
GRANT SELECT ON fractalsql_bt.fractal_vectorizer_status TO 'bt_embed_outsider'@'127.0.0.1';
GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizer_rate_window TO 'bt_embed_outsider'@'127.0.0.1';
FLUSH PRIVILEGES;
'@ 2>&1 | Out-Null

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -e @'
DROP TABLE IF EXISTS bt_embed_owned;
CREATE TABLE bt_embed_owned (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, embedding TEXT);
INSERT INTO bt_embed_owned (body) VALUES ('owner data');
CALL fractal_vectorizer_create('bt_embed_owned', 'body', 'embedding', NULL, @vid);
'@ 2>&1 | Out-Null
    $vzid = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_owned';" 2>&1
    if ($vzid -match "^\d+$") { Pass "16 embed_authz: owner created a vectorizer on its own table" } else { Fail "16 embed_authz: owner could not create its own vectorizer: $vzid" }

    $qn = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='pending';" 2>&1
    if ($qn -eq "1") { Pass "16 embed_authz: backfill enqueued the pre-existing row" } else { Fail "16 embed_authz: expected 1 pending row, got: $qn" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_outsider -D fractalsql_bt -e "CALL fractal_vectorizer_process_queue(10, 600);" 2>&1 | Out-Null
    $statuses = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT DISTINCT status FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1
    if ($statuses -eq "failed") { Pass "16 embed_authz: outsider's process_queue() call left the row 'failed', not processed" } else { Fail "16 embed_authz: expected 'failed' after the outsider's call, got: $statuses" }

    $errtext = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id=$vzid AND status='failed';" 2>&1
    if ($errtext -match "(?i)denied") { Pass "16 embed_authz: failure reason names a permission error, not a data value" } else { Fail "16 embed_authz: expected a permission-denied error, got: $errtext" }

    $leaked = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT embedding FROM bt_embed_owned WHERE embedding IS NOT NULL;" 2>&1
    if ([string]::IsNullOrEmpty($leaked)) { Pass "16 embed_authz: no embedding was written by the unauthorized outsider's call" } else { Fail "16 embed_authz: an embedding was written despite the outsider lacking SELECT: $leaked" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_owned';
DROP TABLE IF EXISTS bt_embed_owned;
DROP USER IF EXISTS 'bt_embed_owner'@'127.0.0.1';
DROP USER IF EXISTS 'bt_embed_outsider'@'127.0.0.1';
'@ 2>&1 | Out-Null
}

# Concurrent fractal_vectorizer_process_queue() calls against a SHARED
# queue -- proves the atomic claim-UPDATE gives each row to exactly one
# worker under real concurrent callers. Start-Job (not Start-
# ThreadJob/ForEach-Object -Parallel, to stay on PowerShell 5.1+
# baseline like the rest of this file) -- one background job per worker,
# each looping its own mariadb.exe calls.
$script:EmbedSoakRows = 60
$script:EmbedSoakWorkers = 6

function Gate-17-EmbedSoak {
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_soak';
DROP TABLE IF EXISTS bt_embed_soak;
CREATE TABLE bt_embed_soak (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
'@ 2>&1 | Out-Null
    $vals = (1..$script:EmbedSoakRows | ForEach-Object { "('row $_')" }) -join ","
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "INSERT INTO bt_embed_soak (body) VALUES $vals;" 2>&1 | Out-Null
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "CALL fractal_vectorizer_create('bt_embed_soak', 'body', 'embedding', NULL, @vid);" 2>&1 | Out-Null
    $vzid = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_soak';" 2>&1
    $queued = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='pending';" 2>&1
    if ($queued -ne "$($script:EmbedSoakRows)") { Fail "17 embed_soak: setup: expected $($script:EmbedSoakRows) queued rows, got $queued"; return }

    $iterationsPerWorker = [int]($script:EmbedSoakRows / $script:EmbedSoakWorkers) + 3
    $jobs = 1..$script:EmbedSoakWorkers | ForEach-Object {
        Start-Job -ScriptBlock {
            param($mariadbExe, $hostName, $port, $iterations)
            $total = 0; $rc = 0
            for ($i = 0; $i -lt $iterations; $i++) {
                $n = & $mariadbExe --host=$hostName --port=$port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(5, 600);" 2>&1
                if ($n -match "^\d+$") { $total += [int]$n } else { $rc = 1 }
            }
            [PSCustomObject]@{ Rc = $rc; Total = $total }
        } -ArgumentList $script:MariadbExe, "127.0.0.1", $script:Port, $iterationsPerWorker
    }
    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue

    $failedWorkers = ($results | Where-Object { $_.Rc -ne 0 }).Count
    $sumProcessed = ($results | Measure-Object -Property Total -Sum).Sum
    if ($failedWorkers -eq 0) { Pass "17 embed_soak: $($script:EmbedSoakWorkers) concurrent workers, no call errored" } else { Fail "17 embed_soak: $failedWorkers/$($script:EmbedSoakWorkers) workers had a failed call" }
    if ($sumProcessed -eq $script:EmbedSoakRows) { Pass "17 embed_soak: exactly $($script:EmbedSoakRows) rows processed total (no double-count, none lost)" } else { Fail "17 embed_soak: expected $($script:EmbedSoakRows) processed summed across workers, got $sumProcessed" }

    $doneN = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='done';" 2>&1
    if ($doneN -eq "$($script:EmbedSoakRows)") { Pass "17 embed_soak: all $($script:EmbedSoakRows) queue rows are 'done'" } else { Fail "17 embed_soak: expected $($script:EmbedSoakRows) 'done', got $doneN" }

    $embeddedN = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM bt_embed_soak WHERE embedding LIKE '%0.1%';" 2>&1
    if ($embeddedN -eq "$($script:EmbedSoakRows)") { Pass "17 embed_soak: all $($script:EmbedSoakRows) rows embedded exactly once" } else { Fail "17 embed_soak: expected $($script:EmbedSoakRows) embedded, got $embeddedN" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_soak'; DROP TABLE IF EXISTS bt_embed_soak;" 2>&1 | Out-Null
}

# Real crash mid-process_queue(), via tests/evil_crash_plugin.c (a
# reasoning-VFS-ABI plugin whose generate() writes through NULL --
# distinct from tests/evil_crash_udf.c/evil_crash.dll, the plain
# crashing UDF gate 06 already uses). Daemon-crash finding (see
# build_test.sh's own gate_18 comment, ported here): a daemon crash
# surfaces to process_queue as a failed embedding dispatch, not a
# stuck row -- it records that as a retry, putting the row back to
# 'pending' with one attempt counted, and the next process_queue call
# processes it. A MariaDB stored PROCEDURE has no implicit whole-body
# transaction, so without this the row would stay genuinely stuck
# 'processing' after a mid-batch crash.
function Gate-18-EmbedCrash {
    # Swap BEFORE creating the fixture table: Swap-ReasoningPlugin
    # restarts via a full Mdb-Teardown+Mdb-Setup (fresh datadir), same
    # as every other plugin-swap gate -- creating the table first would
    # lose it. The crash this gate tests comes later, from a REAL
    # process_queue() crash followed by an in-place (no-wipe) respawn.
    $rc = Swap-ReasoningPlugin $script:CrashReasoningSo
    if ($rc -ne 0) { Fail "18 embed_crash: plugin swap did not take effect"; Restore-ReasoningPlugin; return }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_crash';
DROP TABLE IF EXISTS bt_embed_crash;
CREATE TABLE bt_embed_crash (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
INSERT INTO bt_embed_crash (body) VALUES ('a');
CALL fractal_vectorizer_create('bt_embed_crash', 'body', 'embedding', NULL, @vid);
'@ 2>&1 | Out-Null
    $vzid = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_crash';" 2>&1

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(10, 600);" 2>&1 | Out-Null

    $up = $false
    $tries = 30 * $TimeoutMult
    $withinBudget = $false
    for ($i = 0; $i -lt ($tries * 2); $i++) {
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" >$null 2>&1
        if ($LASTEXITCODE -eq 0) { $up = $true; if ($i -le $tries) { $withinBudget = $true }; break }
        Start-Sleep -Milliseconds 500
    }
    if ($withinBudget) { Pass "18 embed_crash: mariadbd auto-restarted" } else { Fail "18 embed_crash: mariadbd did not come back within $($tries / 2)s" }
    if (-not $up) { Fail "18 embed_crash: mariadbd never came back -- remaining gates will run against the crash plugin"; return }

    # Restore the real plugin IN PLACE (same datadir) -- see Restart-
    # ReasoningPluginInPlace's own comment for why Restore-
    # ReasoningPlugin (which wipes the datadir) is wrong for this gate.
    $rc2 = Restart-ReasoningPluginInPlace "$script:PlugDir\fractalsql-reasoning-http.dll"
    if ($rc2 -ne 0) { Fail "18 embed_crash: could not restart mariadbd in place with the real plugin restored"; Restore-ReasoningPlugin; return }

    $stuck = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT CONCAT(status, ':', attempts) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1
    if ($stuck -eq "pending:1") { Pass "18 embed_crash: the failed dispatch is scheduled for retry (pending, attempts=1)" } else { Fail "18 embed_crash: expected 'pending:1' immediately post-crash/restore, got: $stuck" }

    $n = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(10, 0);" 2>&1
    if ($n -eq "1") { Pass "18 embed_crash: the retry processed the row after the daemon was restored" } else { Fail "18 embed_crash: expected 1 row retried+processed, got: $n" }

    $doneN = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT count(*) FROM bt_embed_crash WHERE embedding LIKE '%0.1%';" 2>&1
    if ($doneN -eq "1") { Pass "18 embed_crash: the row is correctly embedded after recovery" } else { Fail "18 embed_crash: expected 1 embedded row after recovery, got: $doneN" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_crash'; DROP TABLE IF EXISTS bt_embed_crash;" 2>&1 | Out-Null
}

function Gate-19-SfsBounds {
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_search('[[1,0]]', '[1,0]', 0, '{}');" 2>&1
    if ($r -match "k must be 1\.\.1000000|ERROR") { Pass "19 sfs_bounds: k=0 rejected" } else { Fail "19 sfs_bounds: expected k=0 rejection, got: $r" }

    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_search('[[1,0]]', '[1,0]', 2000000, '{}');" 2>&1
    if ($r2 -match "k must be 1\.\.1000000|ERROR") { Pass "19 sfs_bounds: k=2000000 rejected" } else { Fail "19 sfs_bounds: expected k=2000000 rejection, got: $r2" }

    # Oversized-query (>4MiB) rejection, same recipe as the Linux
    # harness: a big padded-but-valid-looking string is enough to trip
    # the raw args->lengths[1] check without a real 4M-element vector.
    # Piped via stdin file redirection, not -e: a >4MiB argv string
    # blows the OS command-line length limit before mariadb even
    # starts, and PowerShell's pipeline-to-native-stdin re-encodes
    # through the console codepage -- a temp file sidesteps both.
    $big = "[" + ("1," * 2100000) + "1]"            # > 4 MiB of text
    $bigSql = "$Here\.gate19_big.sql"
    [System.IO.File]::WriteAllText($bigSql, "SELECT fractal_search('[[1,0]]', '$big', 1, '{}');")
    try {
        $r3 = cmd /c "`"$script:MariadbExe`" --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N < `"$bigSql`" 2>&1"
        if (($r3 -join ' ') -match "ERROR|NULL") { Pass "19 sfs_bounds: oversized query (>4MiB) rejected" } else { Fail "19 sfs_bounds: expected oversized-query rejection, got: $(($r3 -join ' ').Substring(0, [Math]::Min(120, ($r3 -join ' ').Length)))" }
    } finally {
        Remove-Item $bigSql -ErrorAction SilentlyContinue
    }
}

function Gate-20-Analytics {
    $py = Get-PythonExe
    if (-not $py) { Skip "20 analytics: no python found to generate synthetic series"; return }

    $series = "[" + (& $py -c "import random; random.seed(1); print(','.join(str(round(random.gauss(0,1),4)) for _ in range(80)))") + "]"
    $dfa = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_dimension_dfa('$series');" 2>&1
    if ($dfa -match "^-?[0-9.]") { Pass "20 analytics: fractal_dimension_dfa returned a real value ($dfa)" } else { Fail "20 analytics: fractal_dimension_dfa='$dfa'" }

    $drift = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_dimension_drift('$series', 32);" 2>&1
    if ($drift -match '"drift"') { Pass "20 analytics: fractal_dimension_drift returned a real result" } else { Fail "20 analytics: fractal_dimension_drift='$drift'" }

    $pts = "[" + (& $py -c "import random; random.seed(2); print(','.join(str(round(random.uniform(0,1),4)) for _ in range(1000)))") + "]"
    $bc = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_dimension_boxcount('$pts', 2);" 2>&1
    if ($bc -match "^-?[0-9.]") { Pass "20 analytics: fractal_dimension_boxcount returned a real value ($bc)" } else { Fail "20 analytics: fractal_dimension_boxcount='$bc'" }

    $opt = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{}');" 2>&1
    if ($opt -match '"sharpe"') { Pass "20 analytics: fractal_optimize_portfolio returned a real result" } else { Fail "20 analytics: fractal_optimize_portfolio='$opt'" }

    # Named Feature Store: fractal_store_morphology (upsert) +
    # fractal_mine_topology_negatives (brute-force k-NN via the
    # existing fractal_vector_l2_squared UDF). No LLM.
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DELETE FROM fractalsql_feature_store WHERE doc_id IN (1,2,3);
CALL fractal_store_morphology(1, '[0,0,0]');
CALL fractal_store_morphology(2, '[1,1,1]');
CALL fractal_store_morphology(3, '[5,5,5]');
"@ 2>&1 | Out-Null

    $knn = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_mine_topology_negatives('[0.9,0.9,0.9]', 2, @r);
SELECT @r;
"@ 2>&1
    $knnJoined = ($knn -join "`n")
    if ($knnJoined -match '"doc_id":\s*2') {
        Pass "20 analytics: fractal_mine_topology_negatives ranks the nearest stored vector (doc_id=2) first"
    } else {
        Fail "20 analytics: fractal_mine_topology_negatives='$knnJoined'"
    }
    $docIdCount = ([regex]::Matches($knnJoined, '"doc_id"')).Count
    if ($docIdCount -eq 2) {
        Pass "20 analytics: fractal_mine_topology_negatives honors k=2 (returned exactly 2 rows)"
    } else {
        Fail "20 analytics: expected 2 result rows, got: $knnJoined"
    }

    # Upsert: re-store doc_id 3 with a vector identical to the surrogate
    # -- it must now rank first, proving ON DUPLICATE KEY UPDATE
    # actually overwrote the row rather than leaving [5,5,5] in place.
    $knn2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_store_morphology(3, '[0.9,0.9,0.9]');
CALL fractal_mine_topology_negatives('[0.9,0.9,0.9]', 1, @r2);
SELECT @r2;
"@ 2>&1
    $knn2Joined = ($knn2 -join "`n")
    if ($knn2Joined -match '"doc_id":\s*3') {
        Pass "20 analytics: fractal_store_morphology upsert overwrites an existing doc_id's features"
    } else {
        Fail "20 analytics: expected doc_id=3 after upsert, got: $knn2Joined"
    }

    $badDoc = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_store_morphology(-1, '[1,2,3]');" 2>&1
    if (($badDoc -join "`n") -match "doc_id must be") {
        Pass "20 analytics: fractal_store_morphology rejects a negative doc_id"
    } else {
        Fail "20 analytics: expected a doc_id rejection, got: $badDoc"
    }

    $badArr = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_store_morphology(4, 'not json');" 2>&1
    if (($badArr -join "`n") -match "must be a non-empty JSON array") {
        Pass "20 analytics: fractal_store_morphology rejects a malformed feature_array"
    } else {
        Fail "20 analytics: expected a feature_array rejection, got: $badArr"
    }

    $badK = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_mine_topology_negatives('[0,0,0]', 0, @r3);" 2>&1
    if (($badK -join "`n") -match "k must be") {
        Pass "20 analytics: fractal_mine_topology_negatives rejects k < 1"
    } else {
        Fail "20 analytics: expected a k rejection, got: $badK"
    }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DELETE FROM fractalsql_feature_store WHERE doc_id IN (1,2,3);" 2>&1 | Out-Null
}

function Gate-21-Diversify {
    $en = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_diversify_enable(CONNECTION_ID());" 2>&1
    if ($en -eq "0") { Pass "21 diversify: enable" } else { Fail "21 diversify: enable='$en'" }

    $sp = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_diversify_set_params(CONNECTION_ID(), '{\`"window_n\`":5}');" 2>&1
    if ($sp -eq "0") { Pass "21 diversify: set_params" } else { Fail "21 diversify: set_params='$sp'" }

    $ex = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_explain_result(CONNECTION_ID());" 2>&1
    if ($ex -match "diversify_enabled") { Pass "21 diversify: explain_result" } else { Fail "21 diversify: explain_result='$ex'" }

    $dis = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_diversify_disable(CONNECTION_ID());" 2>&1
    if ($dis -eq "0") { Pass "21 diversify: disable" } else { Fail "21 diversify: disable='$dis'" }
}

function Gate-22-VectorTier {
    $sim = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_cosine_similarity('[1,0,0]', '[1,0,0]');" 2>&1
    if ($sim -eq "1") { Pass "22 vector_tier: cosine_similarity(identical)=1" } else { Fail "22 vector_tier: cosine_similarity='$sim'" }

    $norm = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_norm('[3,4,0]');" 2>&1
    if ($norm -eq "5") { Pass "22 vector_tier: norm([3,4,0])=5" } else { Fail "22 vector_tier: norm='$norm'" }

    $add = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_add('[1,2,3]', '[1,1,1]');" 2>&1
    if ($add -match "^\[2,3,4\]$") { Pass "22 vector_tier: add" } else { Fail "22 vector_tier: add='$add'" }

    $dims = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_dims('[1,2,3,4]');" 2>&1
    if ($dims -eq "4") { Pass "22 vector_tier: dims" } else { Fail "22 vector_tier: dims='$dims'" }
}

function Gate-23-Cognition {
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1
    if ($r -match "(?i)sql") { Pass "23 cognition: fractal_reason returned the mock's reply" } else { Fail "23 cognition: fractal_reason='$r'" }

    $rnull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), NULL);" 2>&1
    if ($rnull -eq "NULL") { Pass "23 cognition: NULL query -> NULL result" } else { Fail "23 cognition: expected NULL, got: $rnull" }
}

function Gate-24-Agents {
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_memories, bt_caps;
CREATE TABLE bt_memories (id BIGINT PRIMARY KEY AUTO_INCREMENT, region VARCHAR(20), vec TEXT, content VARCHAR(100));
INSERT INTO bt_memories (region, vec, content) VALUES ('east','[1,0,0]','shipped'), ('west','[0,1,0]','refunded');
CREATE TABLE bt_caps (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb TEXT);
INSERT INTO bt_caps (emb) VALUES ('[1,0,0]'), ('[0,1,0]');
"@ 2>&1 | Out-Null

    $re = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_recall_hybrid('bt_memories','vec','[1,0,0]','region','east',5,'content', @r);
SELECT @r;
"@ 2>&1
    if (($re -join "`n") -match "shipped") { Pass "24 agents: recall_hybrid (E) found the real cohort content" } else { Fail "24 agents: recall_hybrid='$re'" }

    $rf = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_recommend_diverse('bt_memories','vec','[1,0,0]',2, @r2);
SELECT @r2;
"@ 2>&1
    if (($rf -join "`n") -match "item_id") { Pass "24 agents: recommend_diverse (F) returned real scored items" } else { Fail "24 agents: recommend_diverse='$rf'" }

    $rc = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_route_task('[0.9,0.1,0]','bt_caps','emb',1000,100, @r3);
SELECT @r3;
"@ 2>&1
    if (($rc -join "`n") -match "routed_to") { Pass "24 agents: route_task (C) composed telemetry + real LLM reasoning" } else { Fail "24 agents: route_task='$rc'" }

    # Single-quoted here-strings (@'...'@) below: no PS variable
    # interpolation needed, and it avoids backtick ambiguity between
    # PowerShell's escape character and MariaDB's `identifier` quoting
    # (`condition` is a reserved-word column name needing backtick
    # quoting in the SQL itself).
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @'
DROP TABLE IF EXISTS bt_patients;
CREATE TABLE bt_patients (id BIGINT PRIMARY KEY, age INT, `condition` VARCHAR(32), vitals TEXT);
INSERT INTO bt_patients VALUES
    (1, 72, 'sepsis', '[0.9,-0.8,0.7,0.6]'),
    (2, 81, 'sepsis', '[0.85,-0.75,0.65,0.55]'),
    (3, 64, 'sepsis', '[0.1,0.1,0.1,0.1]');
'@ 2>&1 | Out-Null

    $rg = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @'
CALL fractal_agent_patient_deterioration_triage(
    'bt_patients', 'vitals', '[0.9,-0.8,0.7,0.6]', '[0.1,0.1,0.1,0.1]', '[0.95,-0.85,0.75,0.65]',
    (SELECT CONCAT('[', GROUP_CONCAT(id), ']') FROM bt_patients WHERE age > 65 AND `condition`='sepsis'),
    5, @rg);
SELECT JSON_LENGTH(JSON_EXTRACT(@rg, '$.cohort_matches'));
'@ 2>&1
    $rgTrim = ($rg -join "").Trim()
    if ($rgTrim -eq "2") { Pass "24 agents: patient_deterioration_triage (H) cohort_matches now honors p_k (got 2 of 2 qualifying rows)" } else { Fail "24 agents: patient_deterioration_triage cohort_matches length='$rgTrim'" }

    # detect_loop (O), rewritten onto SimHash fingerprints + streaming
    # Brent cycle detection + a DFA-over-L2-norms check. The
    # near-identical "cognitive wobble" log must close a cycle and flag
    # loop_detected -- live-verified: its two states' SimHash
    # fingerprints COLLAPSE to one fingerprint (the vectors differ by
    # 0.005 on two of three dims, under random-hyperplane rounding), so
    # this is a period-1 cycle (cycle_len 1) rather than period-2; a
    # second log with genuinely distinct states below asserts the real
    # period-2 path.
    $py = Get-PythonExe
    if ($py) {
        $dlLog = & $py -c "import json; print(json.dumps([[0.5,0.5,0.5] if i % 2 == 0 else [0.505,0.495,0.5] for i in range(20)], separators=(',',':')))"
        $dl = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_detect_loop('bt_wobble', '$dlLog', 16, 42.0, 2, @dlr);
SELECT @dlr;
"@ 2>&1
        $dlJoined = ($dl -join "`n")
        if ($dlJoined -match '"loop_detected":\s*(true|1)') { Pass "24 agents: detect_loop flags the near-identical wobble log" } else { Fail "24 agents: detect_loop wobble='$dlJoined'" }
        if ($dlJoined -match '"cycle_detected":\s*"?(true|1)"?') { Pass "24 agents: detect_loop cycle check fired on the wobble log" } else { Fail "24 agents: detect_loop cycle='$dlJoined'" }

        # Genuinely distinct alternating states (directions far enough
        # apart that no fingerprint collapse happens): the 20-state log
        # must close a real period-2 cycle -- cycle_len 2, at_index 3
        # (Brent's checkpoint schedule closes it on the 4th state).
        $dlLog3 = & $py -c "import json; print(json.dumps([[0.5,0.5,0.5] if i % 2 == 0 else [0.9,0.1,0.5] for i in range(20)], separators=(',',':')))"
        $dl3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_detect_loop('bt_wobble2', '$dlLog3', 64, 42.0, 0, @dlr3);
SELECT @dlr3;
"@ 2>&1
        $dl3Joined = ($dl3 -join "`n")
        # ("cycle_len" comes back "2" quoted on 11.4 but 2 unquoted on
        # 10.6 -- MariaDB's JSON_OBJECT integer serialization differs
        # by major -- accept both spellings.)
        if (($dl3Joined -match '"cycle_len":\s*"?2"?') -and ($dl3Joined -match '"loop_detected":\s*(true|1)')) { Pass "24 agents: detect_loop closes a true period-2 cycle on distinct states (cycle_len 2)" } else { Fail "24 agents: detect_loop distinct-states='$dl3Joined' (expected cycle_len 2, loop_detected true)" }

        # A constant state log: the cycle check still fires, but every L2
        # norm is identical so the DFA-over-norms branch must be SKIPPED
        # (the core DFA errors on degenerate constant input) --
        # dfa_exponent stays null, and the call must not abort.
        $dlLog2 = & $py -c "import json; print(json.dumps([[0.5,0.5,0.5] for _ in range(8)], separators=(',',':')))"
        $dl2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_detect_loop('bt_constant', '$dlLog2', 16, 42.0, 0, @dlr2);
SELECT @dlr2;
"@ 2>&1
        $dl2Joined = ($dl2 -join "`n")
        # ("cycle_detected" comes back "1" quoted here but 1 unquoted on
        # the wobble CALL above -- MariaDB's JSON_OBJECT boolean
        # serialization is inconsistent by value -- accept both spellings.)
        if ($dl2Joined -match '"cycle_detected":\s*"?(true|1)"?') { Pass "24 agents: detect_loop constant-state log closes a cycle" } else { Fail "24 agents: detect_loop constant='$dl2Joined'" }
        if ($dl2Joined -match '"dfa_exponent":\s*null') { Pass "24 agents: detect_loop skips the DFA on degenerate constant norms (dfa_exponent null, no abort)" } else { Fail "24 agents: detect_loop constant dfa='$dl2Joined' (expected dfa_exponent null)" }
    } else {
        Skip "24 agents: detect_loop checks (no python found to generate the synthetic state log)"
    }

    # outlier_intercept (H-adjacent safety barrier), now with an explicit
    # metric argument. cosine (the default) intercepts a probe near a
    # known-bad state; l2 on a far probe does not; a nonsense metric
    # must SIGNAL, not silently fall back.
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_bad_states;
CREATE TABLE bt_bad_states (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb TEXT);
INSERT INTO bt_bad_states (emb) VALUES ('[1,0,0]'), ('[0.9,0.1,0]');
"@ 2>&1 | Out-Null

    $oi1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_outlier_intercept('[1.0,0.05,0]', 'bt_bad_states', 'emb', 0.5, 'cosine', @oi1);
SELECT @oi1;
"@ 2>&1
    $oi1Joined = ($oi1 -join "`n")
    # (outlier_intercept serializes "intercepted" as a quoted "1"/"0"
    # string, not a JSON boolean -- accept both spellings.)
    if ($oi1Joined -match '"intercepted":\s*"?(true|1)"?') { Pass "24 agents: outlier_intercept cosine intercepts a probe near a known-bad state" } else { Fail "24 agents: outlier_intercept cosine='$oi1Joined'" }

    $oi2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_outlier_intercept('[0.0,1.0,0.0]', 'bt_bad_states', 'emb', 0.5, 'l2', @oi2);
SELECT @oi2;
"@ 2>&1
    $oi2Joined = ($oi2 -join "`n")
    if (($oi2Joined -match '"intercepted":\s*"?(false|0)"?') -and $oi2Joined -match '"metric":\s*"l2"') { Pass "24 agents: outlier_intercept l2 does not intercept a far probe (metric echoed)" } else { Fail "24 agents: outlier_intercept l2='$oi2Joined'" }

    $oi3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_agent_outlier_intercept('[1,0,0]', 'bt_bad_states', 'emb', 0.5, 'manhattan', @oi3);" 2>&1
    if (($oi3 -join "`n") -match "metric must be") { Pass "24 agents: outlier_intercept SIGNALs on an unknown metric" } else { Fail "24 agents: expected a metric rejection, got: $oi3" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DROP TABLE IF EXISTS bt_bad_states;" 2>&1 | Out-Null
}

# The newest analytics/vector-math UDFs, known-answer asserted. No LLM.
# Every assertion here is convention-independent where the underlying
# convention lives in the vendored core (e.g. quantize_binary's sign-bit
# polarity): hamming(quantize(v), quantize(v))=0 and
# hamming(quantize(v), quantize(one sign flipped))=1 hold regardless of
# which bit value "positive" packs as.
function Gate-32-NewPrimitives {
    $py = Get-PythonExe
    if (-not $py) { Skip "32 new_primitives: no python found to generate synthetic series"; return }

    # fractal_change_point_detect: step up at t=50 in a 100-sample series
    # with a non-degenerate (sine) wobble, window=16, threshold=2. At
    # least one flagged boundary must land near the true split. A
    # constant-series wobble would risk the pooled-stddev denominator
    # being 0, so the wobble is real, not cosmetic.
    $step = & $py -c "import math; print(','.join('%.4f' % (0.2*math.sin(0.5*i) if i < 50 else 5.2+0.2*math.cos(0.5*i)) for i in range(100)))"
    $cp = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_change_point_detect('[$step]', 16, 2.0, 16);" 2>&1
    $cpJoined = ($cp -join "").Trim()
    $cpVals = $cpJoined.Trim("[]") -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    $cpOk = $false
    foreach ($v in $cpVals) { if (([double]$v -ge 30) -and ([double]$v -le 70)) { $cpOk = $true } }
    if ($cpOk) { Pass "32 new_primitives: change_point_detect flags a boundary near the t=50 step ($cpJoined)" } else { Fail "32 new_primitives: change_point_detect='$cpJoined' (no boundary in [30,70])" }

    $cpBad = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_change_point_detect('[1,2,3]', 0, 2.0, 16);" 2>&1
    # Empirical contract on this server family: a UDF whose main function
    # sets *error (no init message) surfaces as a NULL result, not a
    # statement error -- assert that, not an ERROR banner.
    if (($cpBad -join "").Trim() -eq "NULL") { Pass "32 new_primitives: change_point_detect rejects window < 1 (NULL)" } else { Fail "32 new_primitives: expected NULL for window < 1, got: $cpBad" }

    # fractal_periodogram: 64 samples of sin(2*pi*t/8) -> an exact
    # k=8/64 bin at 0.125 cycles/sample as the top-power peak.
    $sine = & $py -c "import math; print(','.join('%.6f' % (0.5*math.sin(2*math.pi*i/8)) for i in range(64)))"
    $pg = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_periodogram('$sine', 4);" 2>&1
    $pgJoined = ($pg -join "`n")
    if ($pgJoined -match '"freqs"') { Pass "32 new_primitives: periodogram returned peaks" } else { Fail "32 new_primitives: periodogram='$pgJoined'" }

    # Note: '$.freqs[0]' etc. are literal inside these double-quoted
    # strings -- PowerShell only interpolates $ followed by a name
    # character, and '.' is not one, so $.field paths pass through
    # verbatim to MariaDB.
    $pgTop = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT JSON_EXTRACT('$(($pg -join ''))', '$.freqs[0]');" 2>&1
    $pgTopVal = 0.0
    if ([double]::TryParse((($pgTop -join "").Trim()), [ref]$pgTopVal) -and ($pgTopVal -gt 0.124) -and ($pgTopVal -lt 0.126)) {
        Pass "32 new_primitives: periodogram top freq is the true 0.125 bin (got $pgTopVal)"
    } else {
        Fail "32 new_primitives: periodogram top freq='$pgTop' (expected 0.125)"
    }

    # fractal_state_fingerprint: 128 bits -> exactly 16 packed bytes, all
    # in [0,255], byte-for-byte deterministic across identical calls
    # (seeded random hyperplanes).
    $fp1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_state_fingerprint('1,2,3', 128, 42);" 2>&1
    $fp1Joined = ($fp1 -join "").Trim()
    $fp1Bytes = $fp1Joined.Trim("[]") -split "," | Where-Object { $_ -ne "" }
    if ($fp1Bytes.Count -eq 16) { Pass "32 new_primitives: state_fingerprint 128 bits -> 16 bytes" } else { Fail "32 new_primitives: state_fingerprint byte count=$($fp1Bytes.Count) ('$fp1Joined')" }
    $fpInRange = ($fp1Bytes | Where-Object { [double]$_ -lt 0 -or [double]$_ -gt 255 }).Count -eq 0
    if ($fpInRange) { Pass "32 new_primitives: state_fingerprint bytes all in [0,255]" } else { Fail "32 new_primitives: state_fingerprint out-of-range byte in '$fp1Joined'" }
    $fp2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_state_fingerprint('1,2,3', 128, 42);" 2>&1
    if (($fp2 -join "").Trim() -eq $fp1Joined) { Pass "32 new_primitives: state_fingerprint is deterministic (same seed, same bytes)" } else { Fail "32 new_primitives: state_fingerprint differs across identical calls: '$fp1Joined' vs '$(($fp2 -join '').Trim())'" }

    # fractal_cycle_detect: fingerprints of A,B,A,B,A,B (concatenated
    # 64-bit fingerprint bytes). Live-verified: Brent's checkpoint
    # schedule needs roughly twice the period in stream length to close,
    # so a bare A,B,A does NOT report a cycle -- the 6-element stream
    # does (cycle_len=2, at_index=3). Negative case uses A,B,D with
    # mutually non-collinear state vectors: SimHash fingerprints of
    # SCALAR-MULTIPLE states are byte-identical (live-verified: '9,9,9'
    # and '4,4,4' collide -- both on the (1,1,1) diagonal), so the
    # negative case needs a different direction, not a different magnitude.
    $fpA = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_state_fingerprint('1,2,3', 64, 7);" 2>&1) -join ""
    $fpB = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_state_fingerprint('9,9,9', 64, 7);" 2>&1) -join ""
    $fpD = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_state_fingerprint('4,5,6', 64, 7);" 2>&1) -join ""
    $sA = $fpA.Trim("[]"); $sB = $fpB.Trim("[]"); $sD = $fpD.Trim("[]")
    $cy = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_cycle_detect('$sA,$sB,$sA,$sB,$sA,$sB', 8, 0);" 2>&1
    $cyJoined = ($cy -join "`n")
    if ($cyJoined -match '"detected":\s*(true|1)') { Pass "32 new_primitives: cycle_detect closes the A,B,A,B,A,B period-2 stream" } else { Fail "32 new_primitives: cycle_detect(A,B,A,B,A,B)='$cyJoined'" }
    if ($cyJoined -match '"cycle_len":\s*2') { Pass "32 new_primitives: cycle_detect reports cycle_len=2" } else { Fail "32 new_primitives: cycle_detect cycle_len='$cyJoined'" }
    $cy2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_cycle_detect('$sA,$sB,$sD', 8, 0);" 2>&1
    if ((($cy2 -join "`n")) -match '"detected":\s*(false|0)') { Pass "32 new_primitives: cycle_detect reports no cycle for three distinct states" } else { Fail "32 new_primitives: cycle_detect(A,B,D)='$($cy2 -join '')' (expected detected:false)" }

    # fractal_tda_persistence_diagram: 12 points in two tight 6-point
    # clusters far apart. Each cluster forms a complete graph under
    # thresh=1.0, so the 1-skeleton cycle rank is 15 edges - 6 vertices
    # + 1 component = 10 per cluster = 20 total; h0 is 5 bars per
    # cluster = 10. max_dim=0 must leave betti1 null (scope note: the
    # 1-skeleton cycle rank, not full simplicial H1).
    $pts = & $py -c "a=[0.0,0.0, 0.1,0.0, 0.05,0.0866, 0.1,0.0866, 0.02,0.05, 0.08,0.03]; b=[10.0+x for x in a]; print(','.join('%.4f' % v for v in a+b))"
    $tda = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_tda_persistence_diagram('$pts', 2, 1, 1.0, 64);" 2>&1
    $tdaJoined = ($tda -join "`n")
    if ($tdaJoined -match '"betti1":\s*20') { Pass "32 new_primitives: tda_persistence_diagram two-cluster betti1=20 (2 x (15-6+1))" } else { Fail "32 new_primitives: tda_persistence_diagram='$tdaJoined' (expected betti1=20)" }
    if ($tdaJoined -match '"n_h0_bars":\s*10') { Pass "32 new_primitives: tda_persistence_diagram n_h0_bars=10 (2 x 5 merge bars)" } else { Fail "32 new_primitives: tda_persistence_diagram n_h0_bars='$tdaJoined' (expected 10)" }
    $tda0 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_tda_persistence_diagram('$pts', 2, 0, 1.0, 64);" 2>&1
    if ((($tda0 -join "`n")) -match '"betti1":\s*null') { Pass "32 new_primitives: tda_persistence_diagram max_dim=0 leaves betti1 null" } else { Fail "32 new_primitives: tda max_dim=0 betti1='$($tda0 -join '')' (expected null)" }

    # fractal_optimize_subset: value-weighted allocation with bounds 0.6
    # per item and at-most-2 nonzero. Live-verified: bounds must leave
    # the allocation FEASIBLE -- weights sum to 1.0, so with k=2 each cap
    # must allow the pair to reach 1.0 (0.6+0.4 works; the [0.4]*5 caps
    # would cap the pair at 0.8 < 1.0 and the infeasible instance comes
    # back NULL rather than an error). With feasible [0.6]*5 caps the
    # optimum puts 0.6 on the largest value (0.15) and 0.4 on the second
    # (0.12) -> score exactly 0.138.
    $os = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_optimize_subset('[0.12,0.09,0.15,0.06,0.11]', '[0.6,0.6,0.6,0.6,0.6]', 2, '{}');" 2>&1
    $osJoined = ($os -join "`n")
    if ($osJoined -match '"weights"') { Pass "32 new_primitives: optimize_subset returned a weights array" } else { Fail "32 new_primitives: optimize_subset='$osJoined'" }
    $osScoreStr = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT JSON_EXTRACT('$(($os -join ''))', '$.score');" 2>&1) -join ""
    $osScore = 0.0
    if ([double]::TryParse($osScoreStr.Trim(), [ref]$osScore) -and $osScore -gt 0.1378 -and $osScore -lt 0.1382) {
        Pass "32 new_primitives: optimize_subset hits the exact 0.138 optimum (got $osScore)"
    } else {
        Fail "32 new_primitives: optimize_subset score='$osScoreStr' (expected 0.138)"
    }
    $osInfeas = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_optimize_subset('[0.12,0.09,0.15,0.06,0.11]', '[0.4,0.4,0.4,0.4,0.4]', 2, '{}');" 2>&1) -join ""
    if ($osInfeas.Trim() -eq "NULL") { Pass "32 new_primitives: optimize_subset infeasible instance (caps 0.4x5 < 1.0 at k=2) returns NULL" } else { Fail "32 new_primitives: infeasible optimize_subset='$osInfeas' (expected NULL)" }
    $osW = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT JSON_EXTRACT('$(($os -join ''))', '$.weights');" 2>&1) -join ""
    # Numeric guard: a NULL/garbage token would throw under a bare
    # [double]$_ cast (this exact cast crashed a live gate run once).
    $osNonZero = (($osW.Trim("[]") -split ",") | Where-Object { $d = 0.0; [double]::TryParse($_.Trim(), [ref]$d) -and $d -gt 0.0000001 }).Count
    if ($osNonZero -le 2) { Pass "32 new_primitives: optimize_subset honors the at-most-2-nonzero cap ($osNonZero nonzero)" } else { Fail "32 new_primitives: optimize_subset nonzero weights=$osNonZero" }

    # fractal_vector_lp_distance: p=2 -> 5.0, p=1 -> 7.0.
    $lp = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_lp_distance('[3,4,0]', '[0,0,0]', 2.0);" 2>&1
    $lpVal = 0.0
    if ([double]::TryParse((($lp -join "").Trim()), [ref]$lpVal) -and $lpVal -gt 4.999 -and $lpVal -lt 5.001) {
        Pass "32 new_primitives: lp_distance p=2 ([3,4] from origin) = 5"
    } else {
        Fail "32 new_primitives: lp_distance p=2='$lp'"
    }
    $lp1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_lp_distance('[3,4,0]', '[0,0,0]', 1.0);" 2>&1
    $lp1Val = 0.0
    if ([double]::TryParse((($lp1 -join "").Trim()), [ref]$lp1Val) -and $lp1Val -gt 6.999 -and $lp1Val -lt 7.001) {
        Pass "32 new_primitives: lp_distance p=1 ([3,4] from origin) = 7"
    } else {
        Fail "32 new_primitives: lp_distance p=1='$lp1'"
    }

    # fractal_vector_quantize_int8: dequantization v[i] ~= values[i] *
    # scale must hold to within rounding error, and values stay int8.
    $q8 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_quantize_int8('[1,-2,3]');" 2>&1
    $q8Joined = ($q8 -join "`n")
    if ($q8Joined -match '"scale"') { Pass "32 new_primitives: quantize_int8 returned {scale,values}" } else { Fail "32 new_primitives: quantize_int8='$q8Joined'" }
    $q8Scale = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT JSON_EXTRACT('$(($q8 -join ''))', '$.scale');" 2>&1) -join ""
    $q8Vals = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT JSON_EXTRACT('$(($q8 -join ''))', '$.values');" 2>&1) -join ""
    $q8Nums = $q8Vals.Trim("[]") -split "," | Where-Object { $_ -ne "" } | ForEach-Object { [double]$_ }
    $q8ScaleNum = [double]($q8Scale.Trim())
    $q8Ok = ($q8Nums.Count -eq 3) -and ($q8ScaleNum -gt 0) `
        -and ([math]::Abs($q8Nums[0]*$q8ScaleNum - 1) -le $q8ScaleNum*0.6) `
        -and ([math]::Abs($q8Nums[1]*$q8ScaleNum + 2) -le $q8ScaleNum*0.6) `
        -and ([math]::Abs($q8Nums[2]*$q8ScaleNum - 3) -le $q8ScaleNum*0.6) `
        -and (($q8Nums | Where-Object { $_ -lt -127 -or $_ -gt 127 }).Count -eq 0)
    if ($q8Ok) { Pass "32 new_primitives: quantize_int8 dequantizes [1,-2,3] within rounding error" } else { Fail "32 new_primitives: quantize_int8 scale='$q8Scale' values='$q8Vals' (dequantization out of tolerance)" }

    # fractal_vector_quantize_binary + fractal_vector_hamming_distance:
    # 2 dims pack into 1 byte; identical vectors -> 0; one flipped sign
    # -> 1. (The sign-bit polarity itself is the vendored core's choice;
    # these assertions hold either way.)
    $qb = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_quantize_binary('[1,-1]');" 2>&1) -join ""
    $qbNums = $qb.Trim("[]") -split "," | Where-Object { $_ -ne "" }
    if ($qbNums.Count -eq 1) { Pass "32 new_primitives: quantize_binary 2 dims -> 1 packed byte" } else { Fail "32 new_primitives: quantize_binary byte count='$qb'" }
    $hm0 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_hamming_distance('$qb', '$qb');" 2>&1) -join ""
    if ($hm0.Trim() -eq "0") { Pass "32 new_primitives: hamming_distance(identical) = 0" } else { Fail "32 new_primitives: hamming_distance(identical)='$hm0'" }
    $qb2 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_quantize_binary('[1,1]');" 2>&1) -join ""
    $hm1 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_hamming_distance('$qb', '$qb2');" 2>&1) -join ""
    if ($hm1.Trim() -eq "1") { Pass "32 new_primitives: hamming_distance(one flipped sign) = 1" } else { Fail "32 new_primitives: hamming_distance(flipped sign)='$hm1'" }
    $hmBad = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_hamming_distance('[1]', '[1,2]');" 2>&1
    # Same *error -> NULL contract as the change_point rejection above.
    if (($hmBad -join "").Trim() -eq "NULL") { Pass "32 new_primitives: hamming_distance rejects unequal byte lengths (NULL)" } else { Fail "32 new_primitives: expected NULL for unequal byte lengths, got: $hmBad" }
}

# Regression test for fractal_sql_agent's SAVEPOINT/ROLLBACK TO
# SAVEPOINT safety net around its auto_execute INSERT/UPDATE branch
# (sql/install_udf.sql, CREATE PROCEDURE fractal_sql_agent): MariaDB's
# PREPARE/EXECUTE has no equivalent to Postgres's SPI-subtransaction
# wrap, so a failed auto_execute previously had no partial-write safety
# net beyond a CONTINUE HANDLER that only catches the error after the
# fact. This is the only gate in this suite that drives
# fractal_sql_agent -- one of the six C-level "Universal Agent"
# primitives -- through a real INSERT via the actual GENERATE ->
# ALLOWLIST -> auto_execute pipeline; Gate-24-Agents above exercises
# the PL/SQL-recipe agents built on top of them, not this layer itself.
#
# FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update is
# required for fractal_t2s_check_allowlist to accept an INSERT
# candidate at all (select-only by default) -- a restart-based env var
# (read once at mysqld/mariadbd startup), so this gate does its own
# Mdb-Teardown/Mdb-Setup restart. Deliberately NOT Swap-ReasoningPlugin:
# that helper also overrides FRACTALSQL_REASONING_PLUGIN, and this gate
# needs the REAL HTTP plugin against scripts/ci/mock_llm.py to stay
# active -- mock_llm.py has been taught a marker-routed canned INSERT
# reply for exactly this gate (see its own GATE31_MARKER), not a fake
# reasoning-VFS plugin.
function Gate-31-SqlAgentSavepoint {
    $env:FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS = 'select_insert_update'
    Mdb-Teardown
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Fail "31 sql_agent_savepoint: could not restart cluster with FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update set"
        Remove-Item Env:\FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS -ErrorAction SilentlyContinue
        Restore-ReasoningPlugin
        return
    }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_sql_agent_sp;
CREATE TABLE bt_sql_agent_sp (id INT PRIMARY KEY, val VARCHAR(20));
INSERT INTO bt_sql_agent_sp (id, val) VALUES (99, 'prior');
"@ 2>&1 | Out-Null

    # One connection, one open transaction: a real prior COMMITted write
    # (id=99, above), then three fractal_sql_agent calls whose GENERATE
    # step always comes back with the SAME candidate ("INSERT ... VALUES
    # (1, 'x')", via mock_llm.py's marker route) -- the first succeeds
    # (id=1 doesn't exist yet), the second and third both collide with
    # the PRIMARY KEY id=1 already wrote and must each roll back to the
    # SAVEPOINT cleanly, proving the fixed savepoint name can be reused
    # repeatedly within one transaction after a prior ROLLBACK, not just
    # after a RELEASE.
    $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
START TRANSACTION;
CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '["bt_sql_agent_sp"]', 1, TRUE, @sql1, @status1, @result1);
CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '["bt_sql_agent_sp"]', 1, TRUE, @sql2, @status2, @result2);
CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '["bt_sql_agent_sp"]', 1, TRUE, @sql3, @status3, @result3);
SELECT @status1, @result1, @status2, @result2, @status3, @result3;
COMMIT;
"@ 2>&1

    $joined = ($out -join "`n")
    if ($joined -match '(?m)^ERROR') {
        Fail "31 sql_agent_savepoint: a raw SQL error escaped the procedure instead of a reported status: $joined"
    }

    $fields = $joined.Trim() -split "`t"
    $status1 = if ($fields.Length -ge 1) { $fields[0] } else { "" }
    $result1 = if ($fields.Length -ge 2) { $fields[1] } else { "" }
    $status2 = if ($fields.Length -ge 3) { $fields[2] } else { "" }
    $result2 = if ($fields.Length -ge 4) { $fields[3] } else { "" }
    $status3 = if ($fields.Length -ge 5) { $fields[4] } else { "" }
    $result3 = if ($fields.Length -ge 6) { $fields[5] } else { "" }

    if ($status1 -eq "executed" -and $result1 -match '"rows":\s*1') {
        Pass "31 sql_agent_savepoint: first INSERT executed cleanly (rows:1)"
    } else {
        Fail "31 sql_agent_savepoint: first call expected status=executed/rows:1, got status='$status1' result='$result1'"
    }

    if ($status2 -eq "execution_failed") {
        Pass "31 sql_agent_savepoint: second (colliding) INSERT reported execution_failed via ROLLBACK TO SAVEPOINT, not a raw error"
    } else {
        Fail "31 sql_agent_savepoint: second call expected status=execution_failed, got status='$status2' result='$result2'"
    }

    if ($status3 -eq "execution_failed") {
        Pass "31 sql_agent_savepoint: third call reused the same fixed SAVEPOINT name after the second call's rollback, no 'savepoint does not exist'"
    } else {
        Fail "31 sql_agent_savepoint: third call expected status=execution_failed, got status='$status3' result='$result3'"
    }

    # The actual SAVEPOINT proof: id=99 (committed before any of the
    # three calls) AND id=1 (the first call's own successful write, same
    # transaction as the second/third calls' failures) BOTH survive --
    # ROLLBACK TO SAVEPOINT scoped each failed call's rollback to just
    # its own statement, never the whole transaction.
    $cnt = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT COUNT(*) FROM bt_sql_agent_sp;" 2>&1
    $cntTrim = ($cnt -join "").Trim()
    if ($cntTrim -eq "2") {
        Pass "31 sql_agent_savepoint: both the prior commit (id=99) and the first call's write (id=1) survive -- no phantom rows from the two rolled-back calls"
    } else {
        Fail "31 sql_agent_savepoint: expected exactly 2 surviving rows (id=1,99), COUNT(*)=$cntTrim"
    }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DROP TABLE IF EXISTS bt_sql_agent_sp;" 2>&1 | Out-Null
    Remove-Item Env:\FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS -ErrorAction SilentlyContinue
    Restore-ReasoningPlugin
}

function Gate-25-Enterprise {
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($r -eq "NULL") { Pass "25 enterprise: ledger functions correctly refuse when not loaded" } else { Fail "25 enterprise: expected NULL/refusal, got: $r" }

    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_audit_unpack('x');" 2>&1
    if ($r2 -eq "NULL") { Pass "25 enterprise: audit_unpack correctly refuses when not loaded" } else { Fail "25 enterprise: expected NULL/refusal, got: $r2" }

    # Dormant = NULL across the whole surface, including the audit
    # logger (agents and procedures call it best-effort on every
    # deployment, so it must never error while dormant) and the
    # multimodal _ex/_pareto variants.
    $r3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_audit_log('gate25_probe', JSON_OBJECT('probe', 1));" 2>&1
    if ($r3 -eq "NULL") { Pass "25 enterprise: audit_log is NULL-dormant (safe to call best-effort)" } else { Fail "25 enterprise: expected NULL from dormant audit_log, got: $r3" }

    $r4 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_optimize_portfolio_multimodal_ex('[0.05,0.1]','[1.0,0.0,0.0,1.0]',1,4,0.3,0.8,0,0,'gaussian');" 2>&1
    if ($r4 -eq "NULL") { Pass "25 enterprise: multimodal_ex correctly refuses when not loaded" } else { Fail "25 enterprise: expected NULL/refusal from dormant multimodal_ex, got: $r4" }

    $r5 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_optimize_portfolio_multimodal_pareto('[0.05,0.1]','[1.0,0.0,0.0,1.0]',1,4,8,0,0,'gaussian');" 2>&1
    if ($r5 -eq "NULL") { Pass "25 enterprise: multimodal_pareto correctly refuses when not loaded" } else { Fail "25 enterprise: expected NULL/refusal from dormant multimodal_pareto, got: $r5" }
}

# Enterprise gates 26-28 mirror build_test.sh's own restart-based-swap
# design 1:1 (env var -> Mdb-Teardown -> Mdb-Setup, since
# FRACTALSQL_ENTERPRISE_LIB is read once at mariadbd.exe startup, no
# live-reload). All three SKIP cleanly when their required artifact is
# absent -- this public repo never ships the licensed enterprise DLL
# (naming assumed as fractalsql-enterprise-sovereign-c.dll under
# include\windows-x86_64\, mirroring this repo's OWN Windows naming
# convention for the community DLLs already vendored there, e.g.
# fractalsql-community-sovereign-c.dll with no "lib" prefix, UNLIKE the
# Linux libfractalsql-*.so naming -- not independently confirmed against
# a real Windows enterprise release, since none has been staged here;
# flagged as the single most likely thing to need adjusting on a real
# run).
function Gate-26-EnterpriseActive {
    $entDll = "$Here\include\windows-x86_64\fractalsql-enterprise-sovereign-c.dll"
    if (-not (Test-Path $entDll)) { Skip "26 enterprise_active: no enterprise library found (include/)"; return }

    $ledgerPath = "$Here\.gate26_ledger.dat"
    Remove-Item $ledgerPath -ErrorAction SilentlyContinue

    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_LIB = $entDll
    $env:FRACTALSQL_ENTERPRISE_LEDGER_PATH = $ledgerPath
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB, Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
        Remove-Item $ledgerPath -ErrorAction SilentlyContinue
        Fail "26 enterprise_active: restart with FRACTALSQL_ENTERPRISE_LIB set failed (rc=$rc)"
        Mdb-Setup $MdbMajor | Out-Null
        return
    }

    $tc = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($tc -eq "0") { Pass "26 enterprise_active: truth_count succeeds once the library loads (activation gating works)" } else { Fail "26 enterprise_active: expected 0 from a freshly loaded library, got: $tc" }

    $rh = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_reset_hard(CONNECTION_ID());" 2>&1
    if ($rh -eq "0") { Pass "26 enterprise_active: reset_hard succeeds (no storage touched)" } else { Fail "26 enterprise_active: expected 0 from reset_hard, got: $rh" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive', 500);" 2>&1 | Out-Null
    $fl = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_flush(CONNECTION_ID());" 2>&1
    $fileOk = (Test-Path $ledgerPath) -and ((Get-Item $ledgerPath).Length -gt 0)
    if ($fl -eq "0" -and $fileOk) { Pass "26 enterprise_active: flush genuinely persists to a real ledger file" } else { Fail "26 enterprise_active: expected flush=0 and a non-empty $ledgerPath, got flush=$fl" }

    $v1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_verify(CONNECTION_ID());" 2>&1
    if ($v1 -eq '{"ok":true,"rows_verified":1}') { Pass "26 enterprise_active: fractal_ledger_verify confirms the 1-row chain" } else { Fail "26 enterprise_active: expected 1-row ok verify, got: $v1" }

    # Cross-PROCESS rehydration: restart mariadbd.exe (in-memory ledgers
    # reset to empty by construction), then load must pull the persisted
    # blob back from the file, not from any surviving process state.
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
    $ld = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_load(CONNECTION_ID());" 2>&1
    if ($ld -eq "0") { Pass "26 enterprise_active: load rehydrates the persisted ledger across a mariadbd restart" } else { Fail "26 enterprise_active: expected load=0 after restart, got: $ld" }

    # Tamper the latest record (last 5 bytes -- lands inside the fixed-
    # size trailer of any record with a non-empty blob, same offset
    # build_test.sh's python3 tamper step uses): both verify and load's
    # O(1) tip check must catch it (a shallow tamper, in scope for the
    # tip check). No python3 dependency here -- plain .NET file I/O.
    $bytes = [System.IO.File]::ReadAllBytes($ledgerPath)
    $idx = $bytes.Length - 5
    $bytes[$idx] = $bytes[$idx] -bxor 0xFF
    [System.IO.File]::WriteAllBytes($ledgerPath, $bytes)

    $v2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_verify(CONNECTION_ID());" 2>&1
    if ($v2 -like '{"ok":false,*') { Pass "26 enterprise_active: fractal_ledger_verify detects a byte-level tamper" } else { Fail "26 enterprise_active: expected a tamper-detected verify report, got: $v2" }

    $ld2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_load(CONNECTION_ID());" 2>&1
    if ($ld2 -eq "NULL") { Pass "26 enterprise_active: load refuses a tampered latest record (O(1) tip check)" } else { Fail "26 enterprise_active: expected NULL (refused) loading a tampered ledger, got: $ld2" }

    Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB, Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
    Remove-Item $ledgerPath -ErrorAction SilentlyContinue
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
}

# Needs the MariaDB CONNECT storage engine's Windows plugin
# (ha_connect.dll). NOT independently confirmed whether this ships in
# the standard archive.mariadb.org Windows binary zip the way
# mariadb-plugin-connect is a separate apt package on Linux -- the
# Test-Path check below is the actual runtime source of truth; if it's
# not found, this SKIPs rather than assuming either way.
function Gate-27-EnterpriseConnect {
    $entDll = "$Here\include\windows-x86_64\fractalsql-enterprise-sovereign-c.dll"
    if (-not (Test-Path $entDll)) { Skip "27 enterprise_connect: no enterprise library found (include/)"; return }

    $connectDll = $null
    foreach ($p in @("$script:Bin\..\lib\plugin\ha_connect.dll", (Join-Path (Get-MdbBin) "ha_connect.dll"))) {
        if ($p -and (Test-Path $p)) { $connectDll = $p; break }
    }
    if (-not $connectDll) { Skip "27 enterprise_connect: ha_connect.dll not found under the MariaDB binary tree"; return }

    $ledgerPath = "$Here\.gate27_ledger.dat"
    Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue

    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_LIB = $entDll
    $env:FRACTALSQL_ENTERPRISE_LEDGER_PATH = $ledgerPath
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB, Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
        Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue
        Fail "27 enterprise_connect: restart with FRACTALSQL_ENTERPRISE_LIB set failed (rc=$rc)"
        Mdb-Setup $MdbMajor | Out-Null
        return
    }

    Copy-Item $connectDll "$script:PlugDir\ha_connect.dll" -ErrorAction SilentlyContinue
    $ir = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "INSTALL SONAME 'ha_connect';" 2>&1
    if (-not $ir) { Pass "27 enterprise_connect: INSTALL SONAME 'ha_connect' succeeds" } else { Fail "27 enterprise_connect: INSTALL SONAME 'ha_connect' failed: $ir" }

    # Seed one QTL entry (kind=1) and one audit entry (kind=2) in a
    # SINGLE connection -- fractal_feedback_report's result_handle and
    # fractal_ledger_flush's in-memory ledger are per-CONNECTION_ID().
    $seedSql = @"
SELECT fractal_diversify_enable(CONNECTION_ID());
SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive', 500);
SELECT fractal_feedback_report(CONNECTION_ID(), 2, 'negative');
SELECT fractal_ledger_flush(CONNECTION_ID());
SELECT fractal_audit_log('gate27_test', JSON_OBJECT('probe', 1));
"@
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e $seedSql 2>&1 | Out-Null

    # Rewriting just the filename inside install_enterprise_connect.sql
    # would leave its CONCAT(@@GLOBAL.datadir, ...) prefix glued onto our
    # absolute path -- a path that can't exist, which CONNECT reads back
    # as zero rows with no error. Override the ledger file via the
    # script's own @fsql_ledger_csv session variable instead; forward
    # slashes dodge MySQL string-literal escape handling on Windows.
    $csvPath = "$ledgerPath.csv" -replace '\\', '/'
    $installSql = "SET @fsql_ledger_csv = '$csvPath';`n" + (Get-Content "$Here\sql\install_enterprise_connect.sql" -Raw)
    $cr = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e $installSql 2>&1
    if (-not $cr) { Pass "27 enterprise_connect: CREATE TABLE ... ENGINE=CONNECT succeeds" } else { Fail "27 enterprise_connect: CREATE TABLE failed: $cr" }

    $kc = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT COUNT(*) FROM fractalsql_ledger WHERE kind=1;" 2>&1
    if ($kc -eq "1") { Pass "27 enterprise_connect: SELECT ... WHERE kind=1 sees the flushed QTL row" } else { Fail "27 enterprise_connect: expected 1 kind=1 row, got: $kc" }

    $ac = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT COUNT(*) FROM fractalsql_ledger WHERE kind=2;" 2>&1
    if ($ac -eq "1") { Pass "27 enterprise_connect: SELECT ... WHERE kind=2 sees the fractal_audit_log row" } else { Fail "27 enterprise_connect: expected 1 kind=2 row, got: $ac" }

    $unpacked = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_audit_unpack(FROM_BASE64(blob_b64)) FROM fractalsql_ledger WHERE kind=1 ORDER BY id DESC LIMIT 1;" 2>&1
    if ($unpacked -match '"doc_id":1' -and $unpacked -match '"signal":"truth"') { Pass "27 enterprise_connect: fractal_audit_unpack(FROM_BASE64(...)) decodes the real flushed entry from SQL" } else { Fail "27 enterprise_connect: expected a decoded truth entry for doc_id=1, got: $unpacked" }

    $wr = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "INSERT INTO fractalsql_ledger (id,kind) VALUES (99,1);" 2>&1
    if ($wr -match "(?i)read only") { Pass "27 enterprise_connect: READONLY=1 blocks a stray INSERT (mirror can't be corrupted via SQL)" } else { Fail "27 enterprise_connect: expected a read-only rejection, got: $wr" }

    Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB, Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
    Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
}

function Gate-28-EnterpriseSignature {
    $entDll = "$Here\include\windows-x86_64\fractalsql-enterprise-sovereign-c.dll"
    $entSig = "$entDll.sig"
    if (-not (Test-Path $entDll)) { Skip "28 enterprise_signature: no enterprise library found (include/)"; return }
    if (-not (Test-Path $entSig)) { Skip "28 enterprise_signature: no signature file staged"; return }

    # Phase 1: the REAL signature.
    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_LIB = $entDll
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB -ErrorAction SilentlyContinue
        Fail "28 enterprise_signature: restart with a real signed DLL failed (rc=$rc)"
        Mdb-Setup $MdbMajor | Out-Null
        return
    }
    $r1 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($r1 -eq "0") { Pass "28 enterprise_signature: a real, validly-signed DLL loads (embedded pubkey matches FractalSQLabs's real key)" } else { Fail "28 enterprise_signature: expected 0 with the real .sig present, got: $r1" }

    # Phase 2: corrupt .sig (64 random bytes, right length, wrong
    # content) -- always fatal, regardless of REQUIRE_SIGNATURE.
    $badDir = "$Here\.gate28_badsig"
    Remove-Item -Recurse -Force $badDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $badDir | Out-Null
    Copy-Item $entDll "$badDir\lib.dll"
    $rand = New-Object byte[] 64
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($rand)
    [System.IO.File]::WriteAllBytes("$badDir\lib.dll.sig", $rand)

    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_LIB = "$badDir\lib.dll"
    Mdb-Setup $MdbMajor | Out-Null
    $r2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($r2 -eq "NULL") { Pass "28 enterprise_signature: a corrupt/wrong .sig refuses to load" } else { Fail "28 enterprise_signature: expected NULL (refused) with a corrupt .sig, got: $r2" }

    # Phase 3: missing .sig + REQUIRE_SIGNATURE=1 -- refuses.
    Remove-Item "$badDir\lib.dll.sig" -ErrorAction SilentlyContinue
    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE = "1"
    Mdb-Setup $MdbMajor | Out-Null
    $r3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($r3 -eq "NULL") { Pass "28 enterprise_signature: a missing .sig refuses when REQUIRE_SIGNATURE is set" } else { Fail "28 enterprise_signature: expected NULL (refused), got: $r3" }

    # Phase 4: missing .sig + REQUIRE_SIGNATURE unset -- loads
    # unverified (backward-compatible default).
    Mdb-Teardown
    Remove-Item Env:\FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE -ErrorAction SilentlyContinue
    Mdb-Setup $MdbMajor | Out-Null
    $r4 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1
    if ($r4 -eq "0") { Pass "28 enterprise_signature: a missing .sig loads unverified by default" } else { Fail "28 enterprise_signature: expected 0 (loaded unverified), got: $r4" }

    Remove-Item Env:\FRACTALSQL_ENTERPRISE_LIB, Env:\FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $badDir -ErrorAction SilentlyContinue
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
}

# Builds service\tests\reload_probe_w.c once via clang-cl (same build
# gate 29's own (d) sub-case already uses) and returns its path, or $null
# if no clang-cl is available. fsqlctl itself is a POSIX-only CLI, but
# the daemon's OP_RELOAD handling is cross-platform -- this probe speaks
# the same wire frame over the named pipe, giving gates 34/35 a real
# live-reload client the way build_test.sh's fsqlctl does for them on
# POSIX.
function Build-ReloadProbe {
    if (-not $script:ClangCl) {
        try { $script:ClangCl = Find-ClangCl } catch { $script:ClangCl = $null }
    }
    if (-not $script:ClangCl) { return $null }
    $probe = "$env:TEMP\fractalsql_bt_reload_probe_w.exe"
    & $script:ClangCl -O2 "/D_CRT_SECURE_NO_WARNINGS" (Join-Path $Here 'service\tests\reload_probe_w.c') "/Fe$probe" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $probe
}

# Gate 34: the reasoning tier's conf-live rotation -- reasoning_url
# pushed into the RUNNING daemon via reload_probe_w (no restart,
# mariadbd untouched), against the real reasoning plugin and
# mock_llm.py. Mirrors build_test.sh's gate_34_reasoning_conf_live
# line-for-line, with reload_probe_w (Build-ReloadProbe above) in place
# of fsqlctl -- mariadb-postgresql's own build_test.ps1 header note
# calling this gate "POSIX-only" turned out to be stale: gate 29's own
# (d) sub-case already proves a Windows-native reload client works
# against this exact daemon protocol, it was just never carried over to
# this gate until now.
function Gate-34-ReasoningConfLive {
    $mockUrl = $env:FRACTALSQL_HTTP_URL
    if (-not $mockUrl) {
        Fail "34 reasoning_conf: FRACTALSQL_HTTP_URL not set (Mdb-Setup missing?)"
        return
    }
    $probe = Build-ReloadProbe
    if (-not $probe) {
        Skip "34 reasoning_conf: no clang-cl.exe to build reload_probe_w"
        return
    }

    function Invoke-ReloadProbe34 {
        $r = & $probe $script:FsqdPipe $script:FsqdKey 2>&1
        return ($r -join "`n")
    }
    function Invoke-T2sProbe34 {
        $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_text_to_sql('q', NULL, @s, @e); SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1
        return (($out -join ' ') -replace "`t", ' ')
    }

    $confBackup = "$($script:FsqdConf).g34"
    Copy-Item $script:FsqdConf $confBackup -Force

    # (1) dead endpoint: the pushed reasoning_url moves live, and the
    # next call finds no provider there (127.0.0.1:1 refuses instantly,
    # so no timeout is involved).
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "reasoning_url = http://127.0.0.1:1/v1/chat/completions"
    $rd = Invoke-ReloadProbe34
    $out = Invoke-T2sProbe34
    if ($rd -match 'reloaded' -and $out -notmatch 'SELECT 1') {
        Pass "34 reasoning_conf: dead reasoning_url moved live (no mock reply on the next call)"
    } else {
        Fail "34 reasoning_conf: dead reasoning_url not enforced: reload='$rd' reply='$out'"
    }

    # (2) back to the mock endpoint: the canned reply returns through
    # the pushed value alone.
    Copy-Item $confBackup $script:FsqdConf -Force
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "reasoning_url = $mockUrl"
    $rd = Invoke-ReloadProbe34
    $out = Invoke-T2sProbe34
    if ($rd -match 'reloaded' -and $out -match 'SELECT 1') {
        Pass "34 reasoning_conf: good reasoning_url moved live (mock reply on the next call)"
    } else {
        Fail "34 reasoning_conf: good reasoning_url did not round-trip: reload='$rd' reply='$out'"
    }

    # (3) key removed: the daemon leaves its boot-environment fallback
    # (the same mock URL) in effect -- the reply keeps working.
    Copy-Item $confBackup $script:FsqdConf -Force
    Remove-Item -Force $confBackup -ErrorAction SilentlyContinue
    $rd = Invoke-ReloadProbe34
    $out = Invoke-T2sProbe34
    if ($rd -match 'reloaded' -and $out -match 'SELECT 1') {
        Pass "34 reasoning_conf: key removed, tier still served by its env fallback"
    } else {
        Fail "34 reasoning_conf: after key removal the tier lost its provider: reload='$rd' reply='$out'"
    }
    Remove-Item -Force $probe -ErrorAction SilentlyContinue
}

# Gate 35: enterprise activation/signature-verification wiring, via a
# throwaway, self-signed mock enterprise .dll compiled at test time
# (tests\mock_enterprise_core.c -- identical across fractalsql-mariadb
# and fractalsql-postgresql, built only from the public fractalsql.h).
# Mirrors build_test.sh's gate_35_enterprise_mock, with reload_probe_w
# (Build-ReloadProbe above) in place of fsqlctl -- same reasoning as
# gate 34. Compiled with /DFSQL_BUILDING_DLL rather than Compile-
# FsqlFixture's usual /DFSQL_STATIC + tests\windows\fractalsql-test-
# plugin.def pattern: this mock's ledger/portfolio symbol set has no
# entry in that shared .def at all, so fractalsql.h's own FSQL_API
# macro (-> __declspec(dllexport) under FSQL_BUILDING_DLL) exports
# every FSQL_API-annotated function in the file with no .def needed.
#
# The no-permission ledger-directory failure test uses icacls to deny
# the invoking user's own SID write access (same $ownSid pattern Gate-
# 33-ConfGate already uses for DACL tests) -- a best-effort Windows
# equivalent of build_test.sh's chmod 0555, unverified against a real
# access-denied failure path on real hardware yet (see this file's own
# top-of-file caveat on newly-added gates).
function Gate-35-EnterpriseMock {
    $tag = $MdbMajor -replace '\.', '_'
    $mockSo = "$env:TEMP\fractalsql_bt_mock_ent_$tag.dll"
    $badsigSo = "$mockSo.badsig.dll"
    $badsigSig = "$badsigSo.sig"
    # A separate copy at its OWN path, not a reuse of $mockSo: g_ent_
    # attempted (fractalsql_enterprise.c) is cached PROCESS-WIDE and
    # only re-arms when apply_provider() sees enterprise_lib's PATH
    # STRING actually change (line ~780-814, "Re-arm a failed load
    # attempt only when the library itself changed"). Path 2 and Path 3
    # both need a fresh dlopen attempt despite only require_signature
    # differing between them -- reusing $mockSo for both (as this port
    # first tried) left lib_changed=false on Path 3's reload, so it
    # silently inherited Path 2's cached failure and never actually
    # re-attempted the load. Confirmed live: build_test.sh's own
    # original uses three distinct files for exactly this reason.
    $nosigSo = "$mockSo.nosig.dll"
    $failSentinel = "$env:TEMP\fractalsql_bt_mock_ent_fail_$tag"
    $ledgerPath = Join-Path $Here '.gate35_ledger.dat'
    Remove-Item -Force $ledgerPath, $failSentinel, $mockSo, $badsigSo, $badsigSig, $nosigSo -ErrorAction SilentlyContinue

    $obj = [System.IO.Path]::ChangeExtension($mockSo, '.obj')
    $src = Join-Path $Here 'tests\mock_enterprise_core.c'
    $inc = Join-Path $Here 'include'
    $buildOut = & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL "/I$inc" $src "/Fo$obj" "/Fe$mockSo" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mockSo)) {
        Fail "35 enterprise_mock: mock .dll failed to build"
        Write-Host ($buildOut -join "`n")
        return
    }
    Copy-Item $mockSo $badsigSo -Force
    Copy-Item $mockSo $nosigSo -Force
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $randBytes = New-Object byte[] 64
    $rng.GetBytes($randBytes)
    [System.IO.File]::WriteAllBytes($badsigSig, $randBytes)

    $probe = Build-ReloadProbe
    if (-not $probe) {
        Skip "35 enterprise_mock: no clang-cl.exe to build reload_probe_w"
        Remove-Item -Force $mockSo, $badsigSo, $badsigSig, $nosigSo -ErrorAction SilentlyContinue
        return
    }
    function Invoke-ReloadProbe35 {
        $r = & $probe $script:FsqdPipe $script:FsqdKey 2>&1
        return ($r -join "`n")
    }
    function Invoke-Mdb35([string]$Sql) {
        return & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $Sql 2>&1
    }

    # FSQL_MOCK_ENT_FAIL must be in mariadbd's own environment (plain
    # getenv, read fresh per call, but the process's own environ never
    # changes after exec) -- a full restart is required to get it there
    # at all, the same constraint gates 26/27/28 already work around
    # for FRACTALSQL_ENTERPRISE_LIB.
    Mdb-Teardown
    $env:FSQL_MOCK_ENT_FAIL = $failSentinel
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Fail "35 enterprise_mock: restart with FSQL_MOCK_ENT_FAIL set failed (rc=$rc)"
        Remove-Item Env:\FSQL_MOCK_ENT_FAIL -ErrorAction SilentlyContinue
        Mdb-Setup $MdbMajor | Out-Null
        return
    }

    $pre = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    if ($pre -eq "NULL") { Pass "35 enterprise_mock: truth_count refuses cleanly before enterprise_lib is set" }
    else { Fail "35 enterprise_mock: expected NULL before enterprise_lib is set, got: $pre" }

    # Path 1: a corrupt/wrong .sig is ALWAYS fatal -- no real signing
    # key needed (ent_verify_signature rejects on a MISMATCH, which 64
    # random bytes reliably is).
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "enterprise_lib = $badsigSo"
    $rd = Invoke-ReloadProbe35
    # The daemon's wire reply on success is literally "reloaded"
    # (fractalsqld.c handle_reload: set_text(rep, FSQ_OK, "reloaded")) --
    # "reloaded: configuration swapped in" is fsqlctl's OWN client-side
    # phrasing of that same status, never actually sent over the wire,
    # so reload_probe_w (which prints the raw payload verbatim) was
    # never going to produce it. Confirmed live.
    if ($rd -notmatch 'reloaded') { Fail "35 enterprise_mock: reload (badsig path) rc/err: $rd" }
    $r1 = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    $logTail1 = Get-Content -Raw -Path $script:FsqdLog -ErrorAction SilentlyContinue
    if ($r1 -eq "NULL" -and $logTail1 -match 'failed signature verification') {
        Pass "35 enterprise_mock: a corrupt/wrong .sig refuses to load"
    } else {
        Fail "35 enterprise_mock: expected NULL + a logged refusal, got: $r1"
    }

    # Path 2: no .sig at all ($nosigSo has none either) + enterprise_
    # require_signature=1 -- fatal. A path DISTINCT from Path 1's
    # $badsigSo (see this gate's own header comment on $nosigSo) so the
    # daemon's lib_changed check re-arms a fresh dlopen attempt.
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value @("enterprise_lib = $nosigSo", "enterprise_require_signature = 1")
    $rd = Invoke-ReloadProbe35
    if ($rd -notmatch 'reloaded') { Fail "35 enterprise_mock: reload (nosig+require path) rc/err: $rd" }
    $r2 = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    if ($r2 -eq "NULL") { Pass "35 enterprise_mock: a missing .sig refuses to load when enterprise_require_signature is set" }
    else { Fail "35 enterprise_mock: expected NULL, got: $r2" }

    # Path 3: no .sig, enterprise_require_signature back off -- loads
    # unverified (the backward-compatible default). This is the mock
    # that stays loaded for the rest of this gate (its own distinct
    # path, $mockSo, different from Path 2's $nosigSo, again so
    # lib_changed re-arms the attempt). enterprise_ledger_key here too:
    # every ledger write/verify for the rest of this gate runs
    # HMAC-keyed, not just the structural hash-chain-only path gates
    # 26/27/28 already cover.
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value @(
        "enterprise_lib = $mockSo",
        "enterprise_ledger_path = $ledgerPath",
        "enterprise_ledger_key = gate35-hmac-test-key",
        "enterprise_require_signature = 0")
    $rd = Invoke-ReloadProbe35
    if ($rd -notmatch 'reloaded') { Fail "35 enterprise_mock: reload (mock path) rc/err: $rd" }
    $r3 = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    if ($r3 -eq "0") { Pass "35 enterprise_mock: a missing .sig loads unverified by default once require_signature is off" }
    else { Fail "35 enterprise_mock: expected 0, got: $r3" }

    # Every ledger void/count wrapper's success branch.
    foreach ($fn in @('fractal_ledger_flush','fractal_ledger_compact','fractal_ledger_reset_soft','fractal_ledger_reset_hard','fractal_ledger_load')) {
        $r = Invoke-Mdb35 "SELECT $fn(CONNECTION_ID());"
        if ($r -eq "0") { Pass "35 enterprise_mock: $fn succeeds while the mock is loaded" }
        else { Fail "35 enterprise_mock: expected 0 from $fn, got: $r" }
    }
    $sc = Invoke-Mdb35 "SELECT fractal_ledger_shadow_count(CONNECTION_ID());"
    if ($sc -eq "0") { Pass "35 enterprise_mock: shadow_count succeeds while the mock is loaded" }
    else { Fail "35 enterprise_mock: expected 0 from shadow_count, got: $sc" }

    # Failure branch: the sentinel flips the SAME mock's return codes
    # without touching the daemon's process environment again (see
    # tests\mock_enterprise_core.c's own header for why a file, not a
    # value, is the toggle).
    New-Item -ItemType File -Force -Path $failSentinel | Out-Null
    $rf = Invoke-Mdb35 "SELECT fractal_ledger_flush(CONNECTION_ID());"
    if ($rf -eq "NULL") { Pass "35 enterprise_mock: flush refuses cleanly (NULL, the UDF *error convention) when the mock reports failure" }
    else { Fail "35 enterprise_mock: expected NULL with the fail sentinel set, got: $rf" }
    Remove-Item -Force $failSentinel -ErrorAction SilentlyContinue

    # Deep storage layer -- entirely this repo's own code (ledger_write_
    # entry/read/scan, HMAC, chain hashing), reachable once ANYTHING is
    # loaded: audit_log/audit_unpack/ledger_verify never call back into
    # the dlopen'd library at all.
    Invoke-Mdb35 "SELECT fractal_audit_log('test.small', JSON_OBJECT('n', 1));" | Out-Null
    $v1 = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
    if ($v1 -eq '{"ok":true,"rows_verified":1}') { Pass "35 enterprise_mock: audit_log + ledger_verify round-trip a real chain entry" }
    else { Fail "35 enterprise_mock: expected 1-row ok verify, got: $v1" }

    # Torn-tail repair (ledger_repair_torn_tail): write a 2nd record,
    # then truncate a few bytes off its tail to simulate a crash mid-
    # append -- the next write (ledger_write_entry's own scan) must
    # detect the torn record, truncate the file back to the last
    # complete one, and append cleanly, rather than bricking the file
    # for every future write. Plain .NET file I/O, no python3 needed.
    Invoke-Mdb35 "SELECT fractal_audit_log('test.torn', JSON_OBJECT('will', 'be torn'));" | Out-Null
    if (-not (Test-Path $ledgerPath)) {
        Fail "35 enterprise_mock: torn-tail repair: $ledgerPath does not exist (an earlier assertion in this gate must have failed to actually load/flush the mock)"
    } else {
        $tornBytes = [System.IO.File]::ReadAllBytes($ledgerPath)
        [System.IO.File]::WriteAllBytes($ledgerPath, $tornBytes[0..($tornBytes.Length - 6)])
        Invoke-Mdb35 "SELECT fractal_audit_log('test.after_repair', JSON_OBJECT('n', 3));" | Out-Null
        $vRepair = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
        if ($vRepair -eq '{"ok":true,"rows_verified":2}') { Pass "35 enterprise_mock: a torn tail is repaired on the next write (torn record discarded, new one appended)" }
        else { Fail "35 enterprise_mock: expected a 2-row ok verify after repair, got: $vRepair" }
    }

    # A payload past the 8192-byte default cap forces fractal_audit_
    # unpack's FSQL_ETRUNCATED retry loop.
    $big = "A" * 9000
    $au = Invoke-Mdb35 "SELECT LENGTH(fractal_audit_unpack('$big'));"
    if ($au -eq "9000") { Pass "35 enterprise_mock: audit_unpack grows its buffer past the 8192-byte default cap" }
    else { Fail "35 enterprise_mock: expected length 9000, got: $au" }

    # Byte-level tamper detection -- the same storage path gates 26/27
    # prove with a real .so, here with no real .so at all. Same .NET
    # byte-flip pattern already established at gate 26 (-bxor 0xFF on
    # the last 5 bytes).
    if (-not (Test-Path $ledgerPath)) {
        Fail "35 enterprise_mock: byte-level tamper: $ledgerPath does not exist (an earlier assertion in this gate must have failed to actually load/flush the mock)"
    } else {
        $tamperBytes = [System.IO.File]::ReadAllBytes($ledgerPath)
        $idx = $tamperBytes.Length - 5
        $tamperBytes[$idx] = $tamperBytes[$idx] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($ledgerPath, $tamperBytes)
        $v2 = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
        if ($v2 -like '{"ok":false,*') { Pass "35 enterprise_mock: ledger_verify detects a byte-level tamper (no real .so needed)" }
        else { Fail "35 enterprise_mock: expected a tamper-detected report, got: $v2" }
    }

    # Portfolio multimodal family (all 3 optional symbols present here).
    $pm = Invoke-Mdb35 "SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42);"
    if ($pm -like '{"n_found":1,*') { Pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal returns a well-formed result" }
    else { Fail "35 enterprise_mock: expected a well-formed result, got: $pm" }
    $pmx = Invoke-Mdb35 "SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 0, 'gaussian');"
    if ($pmx -like '{"n_found":1,*') { Pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal_ex returns a well-formed result" }
    else { Fail "35 enterprise_mock: expected a well-formed result, got: $pmx" }
    $pmp = Invoke-Mdb35 "SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 2, 1, 42, 0, 'gaussian');"
    if ($pmp -like '{"n_found":1,*') { Pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal_pareto returns a well-formed result" }
    else { Fail "35 enterprise_mock: expected a well-formed result, got: $pmp" }

    # ledger_log_exit: the ledger write path's own diagnostic logger,
    # hit at every FSQL_ESTORAGE exit in ledger_write_entry -- no test
    # before this ever made that path actually fail I/O. Deny the
    # invoking user's own SID write access to a fresh directory (same
    # $ownSid pattern Gate-33-ConfGate already uses) so BOTH the "r+b"
    # open (file doesn't exist yet) and the "w+b" create fail with
    # access-denied, landing on the "open new ledger" exit -- best-
    # effort Windows equivalent of build_test.sh's chmod 0555 noperm_dir.
    $ownSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $noPermDir = "$env:TEMP\fractalsql_bt_gate35_noperm_$tag"
    New-Item -ItemType Directory -Force -Path $noPermDir | Out-Null
    icacls $noPermDir /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)(F)" "*S-1-5-32-544:(OI)(CI)(F)" | Out-Null
    icacls $noPermDir /deny "*${ownSid}:(OI)(CI)(W)" | Out-Null
    $noPermLedger = Join-Path $noPermDir 'ledger.dat'
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "enterprise_ledger_path = $noPermLedger"
    $rd = Invoke-ReloadProbe35
    if ($rd -notmatch 'reloaded') { Fail "35 enterprise_mock: reload (noperm ledger_path) rc/err: $rd" }
    $logMarkNoperm = (Get-Content -Raw -Path $script:FsqdLog -ErrorAction SilentlyContinue).Length
    $alNoperm = Invoke-Mdb35 "SELECT IFNULL(fractal_audit_log('test.noperm', JSON_OBJECT('n', 1)), '<NULL>');"
    $logTailNoperm = Get-Content -Raw -Path $script:FsqdLog -ErrorAction SilentlyContinue
    if ($logMarkNoperm -and $logTailNoperm.Length -gt $logMarkNoperm) { $logTailNoperm = $logTailNoperm.Substring($logMarkNoperm) }
    if ($alNoperm -eq "<NULL>" -and $logTailNoperm -match 'write path failed at open new ledger') {
        Pass "35 enterprise_mock: ledger_log_exit fires and audit_log refuses cleanly when the ledger dir is unwritable"
    } else {
        Fail "35 enterprise_mock: expected <NULL> + a logged ledger_log_exit, got: $alNoperm"
    }
    icacls $noPermDir /reset | Out-Null
    Remove-Item -Recurse -Force $noPermDir -ErrorAction SilentlyContinue

    # Restore the real ledger_path for the rest of this gate.
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "enterprise_ledger_path = $ledgerPath"
    $rd = Invoke-ReloadProbe35
    if ($rd -notmatch 'reloaded') { Fail "35 enterprise_mock: reload (restore ledger_path) rc/err: $rd" }

    # The reload-race guard: enterprise_lib cannot change live while a
    # library is already loaded (unlike fractalsql-postgresql's own port
    # of this gate, this assertion DOES apply here -- mariadbd is one
    # persistent process, not one-backend-per-connection, so the
    # daemon's own "already loaded" state is genuinely long-lived).
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "enterprise_lib = $badsigSo"
    $rd = Invoke-ReloadProbe35
    if ($rd -match 'reload failed') { Pass "35 enterprise_mock: reload refuses to change enterprise_lib while it is loaded" }
    else { Fail "35 enterprise_mock: expected a refusal, got: $rd" }
    $r4 = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    if ($r4 -eq "0") { Pass "35 enterprise_mock: the refused reload left the mock loaded and working" }
    else { Fail "35 enterprise_mock: expected 0 (still loaded), got: $r4" }

    Remove-Item Env:\FSQL_MOCK_ENT_FAIL -ErrorAction SilentlyContinue
    Remove-Item -Force $ledgerPath, $failSentinel, $mockSo, $badsigSo, $badsigSig, $nosigSo, $probe -ErrorAction SilentlyContinue
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
}

# Gate 36: the four Analytics-tier mesh/graph morphology UDFs (src\
# fractalsql.c): fractal_vascular_network, fractal_cortical_folding,
# fractal_nerve_plexus_metric, fractal_morphological_complexity. Known-
# answer/edge-case asserted, mirrors build_test.sh's gate_36_morphology_
# metrics exactly (same point-cloud sizes -- see that gate's own
# comment for why fsqli_boxcount_dimension's internal eps-sweep needs
# 3000/2000/2000 points to clear its "3 valid octave levels" floor).
# PowerShell has no python3 dependency for the fixtures here (unlike
# build_test.sh): .NET's [Random] with an explicit seed reproduces the
# same deterministic-fixture intent, just not byte-identical point
# clouds to the bash run's own python3 random module -- irrelevant,
# since every assertion here checks shape/presence of result fields or
# a clean NULL rejection, never an exact numeric fractal_dimension
# value. The 3000-point vascular_network CSV is piped via stdin
# (Get-Content/here-string | & mariadb.exe), the same ARG_MAX workaround
# this file already uses elsewhere (Mdb-Setup's own install_udf.sql/
# install_agents.sql piping) -- a 3000-node CSV as a literal -e argument
# would blow well past the Windows command-line length limit.
function Gate-36-MorphologyMetrics {
    # fractal_vascular_network(node_coords_csv, edges_csv, edge_arc_length_csv):
    # a 3000-node random recursive tree spread over a real 3D volume.
    # Parallel per-axis lists, not an array-of-3-arrays-per-point: the
    # jagged "$pts += , @(x,y,z)" + "$pts[$i][0]" idiom this block first
    # tried hit "[System.Object[]] does not contain a method named
    # 'op_Multiply'" on real hardware -- PowerShell's array arithmetic
    # doesn't coerce a nested-array element back to a scalar double the
    # way this tried to assume. Flat, strongly-typed List[double] per
    # axis sidesteps that entirely: every index is a real scalar.
    $rndVn = [Random]::new(1)
    $vnXs = New-Object System.Collections.Generic.List[double]
    $vnYs = New-Object System.Collections.Generic.List[double]
    $vnZs = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt 3000; $i++) {
        $vnXs.Add($rndVn.NextDouble() * 10)
        $vnYs.Add($rndVn.NextDouble() * 10)
        $vnZs.Add($rndVn.NextDouble() * 10)
    }
    $vnEdges = New-Object System.Collections.Generic.List[int]
    $vnArcs = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt 3000; $i++) {
        $j = $rndVn.Next(0, $i)
        $vnEdges.Add($j); $vnEdges.Add($i)
        $dx = $vnXs[$i] - $vnXs[$j]; $dy = $vnYs[$i] - $vnYs[$j]; $dz = $vnZs[$i] - $vnZs[$j]
        $vnArcs.Add([Math]::Sqrt($dx * $dx + $dy * $dy + $dz * $dz) * 1.05)
    }
    $vnCoordParts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 3000; $i++) {
        $vnCoordParts.Add("{0:F6}" -f $vnXs[$i])
        $vnCoordParts.Add("{0:F6}" -f $vnYs[$i])
        $vnCoordParts.Add("{0:F6}" -f $vnZs[$i])
    }
    $vnCoords = $vnCoordParts -join ','
    $vnEdgesCsv = $vnEdges -join ','
    $vnArcsCsv = ($vnArcs | ForEach-Object { "{0:F6}" -f $_ }) -join ','

    $vn = "SELECT fractal_vascular_network('$vnCoords', '$vnEdgesCsv', '$vnArcsCsv');" |
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N 2>&1
    if ($vn -match '"mean_tortuosity"' -and $vn -match '"fractal_dimension"') {
        Pass "36 morphology: fractal_vascular_network returns mean_tortuosity/fractal_dimension"
    } else {
        Fail "36 morphology: expected a well-formed result, got: $vn"
    }

    $vnNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vascular_network(NULL, '0,1,1,2', '1,1');" 2>&1
    if ($vnNull -eq "NULL") { Pass "36 morphology: fractal_vascular_network(NULL, ...) -> NULL" }
    else { Fail "36 morphology: expected NULL, got: $vnNull" }

    $vnOob = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vascular_network('0,0,0,1,0,0,2,0,0', '0,1,1,3', '1,1');" 2>&1
    if ($vnOob -eq "NULL") { Pass "36 morphology: fractal_vascular_network rejects an out-of-range node index" }
    else { Fail "36 morphology: expected NULL for an OOB edge index, got: $vnOob" }

    $vnShape = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vascular_network('0,0,0,1,0,0', '0,1,1,2', '1,1');" 2>&1
    if ($vnShape -eq "NULL") { Pass "36 morphology: fractal_vascular_network rejects node_coords not divisible by 3" }
    else { Fail "36 morphology: expected NULL for a malshaped node_coords, got: $vnShape" }

    # fractal_cortical_folding(vertices_csv, faces_csv): a regular
    # tetrahedron (4 non-coplanar vertices) and its 4 triangular faces.
    $cf = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_cortical_folding('0,0,0,1,0,0,0,1,0,0,0,1', '0,1,2,0,1,3,0,2,3,1,2,3');" 2>&1
    if ($cf -match '"gyrification_index"') { Pass "36 morphology: fractal_cortical_folding returns a gyrification_index" }
    else { Fail "36 morphology: expected a well-formed result, got: $cf" }

    $cfNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_cortical_folding(NULL, '0,1,2,0,1,3,0,2,3,1,2,3');" 2>&1
    if ($cfNull -eq "NULL") { Pass "36 morphology: fractal_cortical_folding(NULL, ...) -> NULL" }
    else { Fail "36 morphology: expected NULL, got: $cfNull" }

    $cfOob = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_cortical_folding('0,0,0,1,0,0,0,1,0,0,0,1', '0,1,2,0,1,3,0,2,3,1,2,4');" 2>&1
    if ($cfOob -eq "NULL") { Pass "36 morphology: fractal_cortical_folding rejects an out-of-range face index" }
    else { Fail "36 morphology: expected NULL for an OOB face index, got: $cfOob" }

    # fractal_nerve_plexus_metric(node_coords_csv, dim, edges_csv): same
    # random-recursive-tree shape, 2D, 2000 points (box-counting's eps-
    # sweep clears its floor at a smaller N in 2D than 3D).
    $rndNp = [Random]::new(2)
    $npXs = New-Object System.Collections.Generic.List[double]
    $npYs = New-Object System.Collections.Generic.List[double]
    for ($i = 0; $i -lt 2000; $i++) { $npXs.Add($rndNp.NextDouble() * 10); $npYs.Add($rndNp.NextDouble() * 10) }
    $npEdges = New-Object System.Collections.Generic.List[int]
    for ($i = 1; $i -lt 2000; $i++) { $j = $rndNp.Next(0, $i); $npEdges.Add($j); $npEdges.Add($i) }
    $npCoordParts = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt 2000; $i++) { $npCoordParts.Add("{0:F6}" -f $npXs[$i]); $npCoordParts.Add("{0:F6}" -f $npYs[$i]) }
    $npCoords = $npCoordParts -join ','
    $npEdgesCsv = $npEdges -join ','

    $np = "SELECT fractal_nerve_plexus_metric('$npCoords', 2, '$npEdgesCsv');" |
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N 2>&1
    if ($np -match '"fiber_length_density"') { Pass "36 morphology: fractal_nerve_plexus_metric returns fiber_length_density" }
    else { Fail "36 morphology: expected a well-formed result, got: $np" }

    $npDim0 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_nerve_plexus_metric('0,0,1,0,2,0', 0, '0,1,1,2');" 2>&1
    if ($npDim0 -eq "NULL") { Pass "36 morphology: fractal_nerve_plexus_metric rejects dim <= 0" }
    else { Fail "36 morphology: expected NULL for dim=0, got: $npDim0" }

    $npOob = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_nerve_plexus_metric('0,0,1,0,2,0', 2, '0,1,1,3');" 2>&1
    if ($npOob -eq "NULL") { Pass "36 morphology: fractal_nerve_plexus_metric rejects an out-of-range node index" }
    else { Fail "36 morphology: expected NULL for an OOB edge index, got: $npOob" }

    # fractal_morphological_complexity(points_csv, dim): 2000 random
    # points in 2D -- same box-counting floor as nerve_plexus_metric.
    $rndMc = [Random]::new(3)
    $mcVals = @()
    for ($i = 0; $i -lt (2000 * 2); $i++) { $mcVals += "{0:F6}" -f ($rndMc.NextDouble() * 10) }
    $mcCsv = $mcVals -join ','

    $mc = "SELECT fractal_morphological_complexity('$mcCsv', 2);" |
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N 2>&1
    if ($mc -match '"dimension"' -and $mc -match '"lacunarity"') { Pass "36 morphology: fractal_morphological_complexity returns dimension/lacunarity" }
    else { Fail "36 morphology: expected a well-formed result, got: $mc" }

    $mcDim0 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_morphological_complexity('0,0,0,1,0,0,0,1,0,0,0,1', 0);" 2>&1
    if ($mcDim0 -eq "NULL") { Pass "36 morphology: fractal_morphological_complexity rejects dim <= 0" }
    else { Fail "36 morphology: expected NULL for dim=0, got: $mcDim0" }

    $mcFew = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_morphological_complexity('0,0,0,1,0,0,0,1,0,0,0,1', 3);" 2>&1
    if ($mcFew -eq "NULL") { Pass "36 morphology: fractal_morphological_complexity rejects too few points for a box count" }
    else { Fail "36 morphology: expected NULL for a too-small point cloud, got: $mcFew" }

    $mcNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_morphological_complexity(NULL, 3);" 2>&1
    if ($mcNull -eq "NULL") { Pass "36 morphology: fractal_morphological_complexity(NULL, ...) -> NULL" }
    else { Fail "36 morphology: expected NULL, got: $mcNull" }
}

# --- dispatch --------------------------------------------------------

function Run-Gates([string[]]$Gates) {
    Write-Host "== MariaDB $MdbMajor (Windows) =="
    if ($Gates -contains "01") {
        if (-not (Gate-01-Build)) { return }
    }
    # Gate 30 (fuzz smoke) is standalone like gate 01 -- links only
    # src\fractalsql_parse.c directly, no extension DLL, no mariadbd.exe,
    # no cluster at all.
    if ($Gates -contains "30") { Gate-30-FuzzSmoke }
    $needDb = $Gates | Where-Object { $_ -in @("02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","31","32","34","35","36") }
    if ($needDb) {
        $rc = Mdb-Setup $MdbMajor
        if ($rc -eq 1) { Skip "MariaDB $MdbMajor runtime gates (mariadbd.exe not found, pass -MdbDir)"; return }
        if ($rc -ne 0) { Fail "MariaDB $MdbMajor cluster setup"; return }
        foreach ($g in $Gates) {
            switch ($g) {
                "02" { Gate-02-Smoke }
                "03" { Gate-03-SchemaContext }
                "04" { Gate-04-TextToSql }
                "05" { Gate-05-EvilOverread }
                "06" { Gate-06-CrashRecovery }
                "07" { Gate-07-EvilLyingLength }
                "08" { Gate-08-Authz }
                "10" { Gate-10-DosAndInjection }
                "11" { Gate-11-Scout }
                "12" { Gate-12-Soak }
                "13" { Gate-13-VectorizerEmbed }
                "14" { Gate-14-Retry }
                "15" { Gate-15-Embed }
                "16" { Gate-16-EmbedAuthz }
                "17" { Gate-17-EmbedSoak }
                "18" { Gate-18-EmbedCrash }
                "19" { Gate-19-SfsBounds }
                "20" { Gate-20-Analytics }
                "21" { Gate-21-Diversify }
                "22" { Gate-22-VectorTier }
                "23" { Gate-23-Cognition }
                "24" { Gate-24-Agents }
                "25" { Gate-25-Enterprise }
                "26" { Gate-26-EnterpriseActive }
                "27" { Gate-27-EnterpriseConnect }
                "28" { Gate-28-EnterpriseSignature }
                "29" { Gate-29-Think }
                "31" { Gate-31-SqlAgentSavepoint }
                "32" { Gate-32-NewPrimitives }
                "33" { Gate-33-ConfGate }
                "34" { Gate-34-ReasoningConfLive }
                "35" { Gate-35-EnterpriseMock }
                "36" { Gate-36-MorphologyMetrics }
            }
        }
        Mdb-Teardown
    }
}

try {
    if ($Gate -ne "") { Run-Gates @($Gate) }
    elseif ($Quick) { Run-Gates $QuickGates }
    elseif ($Fuzz) { Run-Gates $FuzzGates }
    else { Run-Gates $DefaultGates }
} finally {
    Mdb-Teardown
}

if ($script:Failed) { Write-Host "`nbuild_test: FAIL" -ForegroundColor Red; exit 1 }
else { Write-Host "`nbuild_test: PASS" -ForegroundColor Green; exit 0 }
