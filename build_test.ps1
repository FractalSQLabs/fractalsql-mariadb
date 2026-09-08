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
    29 think (FRACTALSQL_HTTP_THINK* -> FSQL_REASONING_HTTP_THINK* bridge)
    -- full parity with build_test.sh's DEFAULT_GATES (01-25 and 29, all
    of 05/07/08/14-18 included and unconditional there too) plus its
    three opt-in enterprise gates (26-28). Gate 09 (a non-
    superuser SQL-SET privilege-escalation check against a server
    system variable) is intentionally NOT
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
    (in that order) when omitted. Only read by the plain (non -Asan/
    -Ubsan) build path here (passed through to build.bat via
    $env:VCPKG_ROOT) and by Build-AsanExtension/Build-UbsanExtension's
    own direct cl.exe/clang-cl invocations below.

.PARAMETER Asan
    Rebuilds fractalsql.dll with MSVC /fsanitize=address into a separate
    dist\windows-asan\ tree (never touches the normal dist\windows\
    release output), then runs the same gates against the instrumented
    DLL loaded into mariadbd.exe. Only this repo's own SRCS get
    instrumented; the vendored core .lib (include\windows-x86_64\
    fractalsql-*.lib) is linked as-is, not rebuilt -- catches bugs in
    the extension's own glue code but not inside core's own SFS
    algorithm internals. /GL (whole-program optimization, on in the
    normal build) is dropped -- documented MSVC incompatibility with
    /fsanitize=address -- and /LTCG drops with it at link time.
    Mutually exclusive with -Ubsan (each rebuilds its own separate
    dist\ tree, run one at a time).

.PARAMETER Ubsan
    Same structure as -Asan (separate dist\windows-ubsan\ tree, same
    gates run against the instrumented DLL), but via clang-cl (LLVM's
    MSVC-ABI-compatible driver -- native cl.exe has no UBSan support at
    all) and -fsanitize=undefined instead of native cl.exe's
    /fsanitize=address.

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
$DefaultGates = @("01","02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29")
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

$script:Failed = $false
function Pass([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Failed = $true }
function Skip([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

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
    $script:RespawnJob = Start-Job -ScriptBlock {
        param($mariadbdExe, $dataDir, $port, $plugDir)
        while ($true) {
            & $mariadbdExe --datadir=$dataDir --port=$port --plugin-dir=$plugDir `
                --bind-address=127.0.0.1 2>&1 | Out-Null
            Start-Sleep -Milliseconds 500
        }
    } -ArgumentList $script:MariadbdExe, $script:DataDir, $script:Port, $script:PlugDir
}

function Mdb-Teardown {
    if ($script:RespawnJob) { Stop-Job $script:RespawnJob -ErrorAction SilentlyContinue; Remove-Job $script:RespawnJob -Force -ErrorAction SilentlyContinue }
    Get-Process mariadbd -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "*$script:Bin*" } | Stop-Process -Force -ErrorAction SilentlyContinue
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

# This repo's own SRCS list (Makefile / scripts\windows\build.bat) --
# kept as one array so Build-AsanExtension/Build-UbsanExtension compile
# exactly the same set build.bat does, not a hand-maintained subset that
# can silently drift from it.
$script:FsqlSrcs = @('fractalsql','fractalsql_parse','fractalsql_session','fractalsql_vector','fractalsql_cognition','fractalsql_textsql','fractalsql_enterprise')

# --- gate 01: build --------------------------------------------------
# Plain path replicates scripts\windows\build.bat's own compile+link
# (calls it directly, doesn't reimplement it -- MARIADB_DIR/MARIADB_
# MAJOR/OUT_DIR/VCPKG_ROOT are all env-var-driven per that script's own
# header). -Asan/-Ubsan bypass build.bat entirely (no sanitizer option
# there) via their own direct cl.exe/clang-cl invocations below.
function Gate-01-Build {
    Write-Host "  building..."
    Push-Location $Here
    try {
        if ($Asan) {
            try { Build-AsanExtension } catch { Fail "01 build: $_"; return $false }
        } elseif ($Ubsan) {
            try { Build-UbsanExtension } catch { Fail "01 build: $_"; return $false }
        } else {
            $env:MARIADB_DIR   = $MdbDir
            $env:MARIADB_MAJOR = $MdbMajor
            $env:OUT_DIR       = Split-Path -Parent $Dll
            if ($VcpkgRoot -ne "") { $env:VCPKG_ROOT = $VcpkgRoot }
            & "$Here\scripts\windows\build.bat"
            if ($LASTEXITCODE -ne 0) { Fail "01 build"; return $false }
        }
    } finally { Pop-Location }
    if (-not (Test-Path $Dll)) { Fail "01 build: $Dll not produced"; return $false }
    Pass "01 build$(if ($Asan) { ' [ASan]' } elseif ($Ubsan) { ' [UBSan]' })"
    return $true
}

# Rebuilds fractalsql.dll with MSVC /fsanitize=address into $Dll (its
# own dist\windows-asan\ tree, see the -Asan PARAMETER block above for
# the full rationale). Only this repo's own SRCS get instrumented; the
# vendored core .lib and OpenSSL's libcrypto.lib are linked as-is.
# Adapted for a UDF DLL (mysql.h headers only, no
# server-import lib to link against -- a MariaDB UDF DLL never
# links against mariadbd.exe's own symbols, see build.bat's own header
# comment) and for this repo's own SRCS list.
function Build-AsanExtension {
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "cl.exe not on PATH. Activate MSVC first (Native Tools Command Prompt / ilammy/msvc-dev-cmd)."
    }
    $outDir = Split-Path -Parent $Dll
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $mdbInc = Join-Path $MdbDir "include\mysql"
    if (-not (Test-Path (Join-Path $mdbInc "mysql.h"))) { throw "mysql.h not found under $mdbInc -- check -MdbDir layout" }

    $coreLib = Join-Path $Here "include\windows-x86_64\fractalsql-community-sovereign-c.lib"
    if (-not (Test-Path $coreLib)) { throw "vendored core library not found: $coreLib" }

    # libcrypto.lib: ent_verify_signature() in fractalsql_enterprise.c
    # (Ed25519 check on the optional enterprise .so) calls OpenSSL's EVP
    # API -- see build.bat's own Prerequisites comment for the full
    # wolfSSL-vs-OpenSSL rationale (MariaDB's own Windows binaries have
    # no libcrypto.lib to reuse).
    $opensslDir = Resolve-OpenSslDir
    $cryptoLib = Join-Path $opensslDir "lib\libcrypto.lib"
    if (-not (Test-Path $cryptoLib)) { throw "libcrypto.lib not found at $cryptoLib" }

    $objs = @()
    # /GL/(+/LTCG at link) dropped -- documented MSVC incompatibility
    # with /fsanitize=address. /U_WINDLL: same fix as build.bat's own cl.exe
    # invocation (MSVC's /LD implicitly predefines _WINDLL, which flips
    # openssl/e_os2.h's OPENSSL_EXPORT/OPENSSL_EXTERN macros to the
    # wrong dllimport branch for a static libcrypto.lib) -- see that
    # file's own comment for the full account, unchanged here.
    $commonCompileArgs = @(
        '/nologo', '/MT', '/O2', '/fsanitize=address', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/D_CRT_SECURE_NO_WARNINGS',
        # /DFSQL_STATIC: static-linking the vendored .lib -- without it
        # the FSQL_API macro's default dllimport branch emits __imp_fsql_*
        # references the static .lib (plain fsql_* symbols) can't satisfy.
        # See include/fractalsql.h:82-91.
        '/DFSQL_STATIC',
        '/U_WINDLL',
        "/I$mdbInc",
        "/I$(Join-Path $Here 'include')",
        "/I$(Join-Path $opensslDir 'include')"
    )
    foreach ($s in $script:FsqlSrcs) {
        $src = Join-Path $Here "src\$s.c"
        $obj = Join-Path $outDir "$s.obj"
        & cl.exe @commonCompileArgs "/Fo$obj" $src
        if ($LASTEXITCODE -ne 0) { throw "ASan compile failed for $s.c (exit $LASTEXITCODE)" }
        $objs += $obj
    }

    $linkArgs = @('/nologo', '/LD') + $objs + @(
        "/Fe$Dll",
        '/link', '/DEBUG',
        $coreLib, $cryptoLib,
        'ws2_32.lib', 'crypt32.lib', 'advapi32.lib', 'user32.lib', 'gdi32.lib', 'bcrypt.lib'
    )
    & cl.exe @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "ASan link failed for $Dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path $Dll)) { throw "ASan build did not produce $Dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $Dll, (Get-Item $Dll).Length) -ForegroundColor Green
}

# Same structure as Build-AsanExtension above -- clang-cl instead of
# cl.exe, -fsanitize=undefined instead of /fsanitize=address.
function Build-UbsanExtension {
    $outDir = Split-Path -Parent $Dll
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $mdbInc = Join-Path $MdbDir "include\mysql"
    if (-not (Test-Path (Join-Path $mdbInc "mysql.h"))) { throw "mysql.h not found under $mdbInc -- check -MdbDir layout" }

    $coreLib = Join-Path $Here "include\windows-x86_64\fractalsql-community-sovereign-c.lib"
    if (-not (Test-Path $coreLib)) { throw "vendored core library not found: $coreLib" }

    $opensslDir = Resolve-OpenSslDir
    $cryptoLib = Join-Path $opensslDir "lib\libcrypto.lib"
    if (-not (Test-Path $cryptoLib)) { throw "libcrypto.lib not found at $cryptoLib" }

    $objs = @()
    # /MD, not /MT -- LLVM's prebuilt UBSan runtime expects dynamic-CRT
    # import-thunk symbols; UNVERIFIED here whether the vendored core .lib (a /MT
    # release artifact, linked unchanged below) is CRT-compatible with
    # these now-/MD-compiled objects in the same final DLL -- watch the
    # first real run for a CRT mismatch (LNK4098-class warning/error).
    $commonCompileArgs = @(
        '/nologo', '/MD', '/O2', '-fsanitize=undefined', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/D_CRT_SECURE_NO_WARNINGS',
        # /DFSQL_STATIC: see Build-AsanExtension's matching comment above.
        '/DFSQL_STATIC',
        '/U_WINDLL',
        "/I$mdbInc",
        "/I$(Join-Path $Here 'include')",
        "/I$(Join-Path $opensslDir 'include')"
    )
    foreach ($s in $script:FsqlSrcs) {
        $src = Join-Path $Here "src\$s.c"
        $obj = Join-Path $outDir "$s.obj"
        & $script:ClangCl @commonCompileArgs "/Fo$obj" $src
        if ($LASTEXITCODE -ne 0) { throw "UBSan compile failed for $s.c (exit $LASTEXITCODE)" }
        $objs += $obj
    }

    $linkArgs = @('/nologo', '/LD') + $objs + @(
        "/Fe$Dll",
        '/link', '/DEBUG',
        $coreLib, $cryptoLib,
        'ws2_32.lib', 'crypt32.lib', 'advapi32.lib', 'user32.lib', 'gdi32.lib', 'bcrypt.lib'
    )
    & $script:ClangCl @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "UBSan link failed for $Dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path $Dll)) { throw "UBSan build did not produce $Dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $Dll, (Get-Item $Dll).Length) -ForegroundColor Green
}

# Windows port of build_test.sh's Gate 30 (--fuzz). No live cluster
# needed -- same as gate 01, this builds and briefly runs standalone
# .exe's linking only src\fractalsql_parse.c (mysql.h-free by design,
# see that file's header comment) + one libFuzzer driver each, nothing
# else. Uses $script:ClangCl (resolved by -Fuzz/-Ubsan's shared
# Find-ClangCl call above), retargeted at this repo's own 3 parse
# functions (parse_vector_csv/parse_corpus/parse_index_csv).
function Gate-30-FuzzSmoke {
    $fuzzDir = Join-Path $Here 'dist\windows-fuzz'
    if (Test-Path $fuzzDir) { Remove-Item -Recurse -Force $fuzzDir }
    New-Item -ItemType Directory -Force -Path $fuzzDir | Out-Null

    $srcParse = Join-Path $Here 'src\fractalsql_parse.c'
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
            $srcParse, $driver,
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
    $ver = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractalsql_version();" 2>&1
    if ($ver -eq $wantVer) { Pass "02 smoke: version=$ver" } else { Fail "02 smoke: version='$ver' (want $wantVer)" }

    $ed = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractalsql_edition();" 2>&1
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
        "SELECT fractal_explore('$corpus', '[1,0,0]', '{\`"population_size\`":24,\`"iterations\`":12}');" 2>&1
    if ($r -match '"population"') { Pass "11 scout: fractal_explore returns a population array" } else { Fail "11 scout: fractal_explore='$r'" }
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
# crashing UDF gate 06 already uses). MariaDB-specific finding (see
# build_test.sh's own gate_18 comment): a MariaDB stored PROCEDURE has
# no implicit whole-body transaction, so a mid-batch crash leaves the
# CURRENT row stuck 'processing' (not reverted) -- the correct recovery
# is a later process_queue call with a short stale_after reclaiming it,
# which is what this gate proves.
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

    $stuck = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT status FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1
    if ($stuck -eq "processing") { Pass "18 embed_crash: the in-flight row is stuck 'processing' after the crash (no wrapping transaction to revert it)" } else { Fail "18 embed_crash: expected 'processing' immediately post-crash/restore, got: $stuck" }

    $n = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(10, 0);" 2>&1
    if ($n -eq "1") { Pass "18 embed_crash: stale reclaim (stale_after_secs=0) recovered the stuck row" } else { Fail "18 embed_crash: expected 1 row reclaimed+processed, got: $n" }

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
    if (-not (Test-Path $entDll)) { Skip "26 enterprise_active: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"; return }

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
    if (-not (Test-Path $entDll)) { Skip "27 enterprise_connect: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"; return }

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
    if (-not (Test-Path $entDll)) { Skip "28 enterprise_signature: skipped (community edition; no fractalsql-enterprise-sovereign-c.* shared lib in include/)"; return }
    if (-not (Test-Path $entSig)) { Skip "28 enterprise_signature: no $entSig staged (opt-in gate, ships in fractalsql-core's release tarball)"; return }

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
    $needDb = $Gates | Where-Object { $_ -in @("02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29") }
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
