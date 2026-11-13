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
    mock enterprise .dll compiled at test time, from this repo's own
    tests\mock_enterprise_core.c), 36
    morphology_metrics (the four Analytics-tier mesh/graph UDFs,
    known-answer/edge-case asserted), 39 mcp_smoke (the full MCP server
    session against the scratch cluster: initialize, the 93-tool
    catalog, per-tier tools/call round trips, $/cancel with KILL QUERY,
    resources+prompts, and the S-FT-004 partial-reasoning case through
    the admin tools -- driver: mcp\tests\mcp_smoke_client.py; self-skips
    without a toolchain -- build_test.sh's own gate_39_mcp_smoke is the
    POSIX twin), 47 ledger_chain (the ledger verifier's FULL-chain walk:
    a three-record chain built by tests\ledger_chain_tool.py verifies
    clean, and tampering the MIDDLE record is reported at that record
    (first_failure_id=2) rather than at the tip -- the case a tip-only
    check would miss; build_test.sh's own gate_47_ledger_chain is the
    POSIX twin), 48 t2s_review_isolation (the four reasoning tiers are
    four SEPARATE plugin instances, so the review tier's baked-in
    response mode cannot be the operator's -- build_test.sh's own
    gate_48_t2s_review_isolation is the POSIX twin), 49
    config_overlay (the per-session configuration overlay's five SQL
    functions -- set/get/list/reset/keys -- the canonical vector form
    (fractal_vector/from_text/to_json) and fractal_search_debug; the
    MCP's own half of the overlay contract is proven by gate 39)
    51 udf_sweeps, 52 validators, 55 ledger_forged, 58 enterprise_loading
    and 60 scripted_replies (the robustness gates that need only the SQL
    layer and the daemon's pipe; they share build_test.sh's tables in
    tests\robustness\. Gates 53, 54, 56, 57, 59, 61 and 62 there depend
    on AF_UNIX sockets, POSIX file modes or LD_PRELOAD and are not ported),
    68 mcp_conformance (the shared conformance driver: both protocol eras,
    the authentication, the framing, the operator switches and the tool
    catalog, checked against the published rules -- driver:
    mcp\tests\mcp_conformance.py, the same file in every engine's
    repository; build_test.sh's own gate_68_mcp_conformance is the POSIX
    twin)
    -- full parity with build_test.sh's DEFAULT_GATES (01-25, 29, 31,
    32, 33, 34, 35, 36, 39, 47, 48, 49, all of 05/07/08/14-18 included
    and unconditional there too) plus its three opt-in enterprise gates
    (26-28).
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

.PARAMETER ClientDir
    Path to the MariaDB Connector/C DEVELOPMENT files -- the tree holding
    include\mysql\mysql.h, the client import library (lib\libmariadb.lib)
    and the client DLL (lib\libmariadb.dll) that the MCP-server build
    (gates 39, 40, 66, 68) and the C++ probe builds (gates 42, 43, 44)
    link against. Defaults to -MdbDir, which is where the server .zip
    distributions this repo's CI unpacks keep them.

    Override it when the SERVER tree has no Connector/C development files:
    an MSI install without the "Development components" feature ships no
    import library at all, and the gates that need one fail at the link
    step with LNK1181 ("cannot open input file 'libmariadb.lib'"). Any
    MariaDB tree's client library works -- Connector/C is a client, not a
    server component -- so pointing this at a sibling install is enough.

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

.PARAMETER Coverage
    Builds fractalsqld.exe with clang-cl -fprofile-instr-generate
    -fcoverage-mapping -fprofile-update=atomic into a separate
    dist\windows-cov\ tree, runs the gates against it, and reports what
    the run covered: a per-file table, a POSIX-shaped lines/functions/
    branches summary, and an HTML report under coverage_html\.

    The Windows counterpart of build_test.sh's --coverage. It is NOT the
    same pipeline, because Windows has no lcov/genhtml/gcov: the raw
    data is LLVM's .profraw, merged with llvm-profdata and rendered
    with llvm-cov. The summary's counting rules are the POSIX ones
    though (see run_coverage_report() in build_test.sh), so the two
    harnesses' numbers are comparable.

    The daemon writes its own profile while it runs, because the LLVM
    runtime only writes at a normal process exit and this harness stops
    the daemon with a hard kill (see the FRACTALSQL_PROFILE_FLUSH_MS
    path in service\daemon\fractalsqld.c).

.PARAMETER Gate
    Run specific gates by number instead of the default set. Accepts a
    single number ("43") or a comma-separated list ("42,43,44") --
    the list form is this harness's own convenience, because the
    Windows harness is the one a developer drives by hand, and
    re-running a single gate at a time means paying the whole
    cluster setup and teardown for each one.

.PARAMETER Quick
    Gates 01, 02 only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MdbDir,
    [Parameter(Mandatory = $true)][ValidateSet('10.6', '10.11', '11.4', '12.3')][string]$MdbMajor,
    [int]$TimeoutMult = 1,
    [string]$VcpkgRoot = "",
    [string]$ClientDir = "",
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
if ($Coverage -and ($Asan -or $Ubsan)) {
    throw "-Coverage and -Asan/-Ubsan are mutually exclusive -- each rebuilds its own separate dist\ tree. Run one at a time."
}

# -MdbDir is resolved to an ABSOLUTE path here, once, for every
# consumer. The gates that compile C or C++ do not all run from the
# same working directory: the MCP probe builds (gates 42/43/44) run
# from the mcp\ subtree, while the rest of the harness runs from the
# repo root. A RELATIVE -MdbDir (e.g. "deps\mariadb\root", the layout
# this repo's own release workflow uses) therefore resolved against
# the wrong directory for exactly those gates -- the MariaDB include
# and lib paths pointed at a directory that does not exist from
# there, and the probe builds failed with C1083 (mysql.h not found)
# and LNK1181 (libmariadb.lib not found) while every other gate,
# compiling from the repo root, passed. Absolutizing once, here,
# makes every consumer independent of the working directory.
#
# -ErrorAction Stop: a path that does not exist is a caller error and
# should say so now, not three gates later as a confusing compile
# failure.
$MdbDir = (Resolve-Path -LiteralPath $MdbDir -ErrorAction Stop).Path

# The MCP server and the C++ probe builds (gates 39, 40, 42, 43, 44, 66, 68) link MariaDB's client import library, which is NOT part of
# every MariaDB tree: the server .zip distribution (what the CI and release workflows unpack into deps\mariadb\root) has it, and an MSI
# install has it only when its "Development components" feature was installed. The client tree is resolved once, further down
# (Resolve-MariaDbClient), and reported there -- so nothing is checked here.

$ErrorActionPreference = "Stop"
# Test fixtures load unsigned mock plugins and an unsigned mock enterprise core; the product defaults are exercised explicitly where tested.
if (-not $env:FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE) { $env:FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE = "0" }
if (-not $env:FSQL_REASONING_REQUIRE_SIGNATURE) { $env:FSQL_REASONING_REQUIRE_SIGNATURE = "0" }
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
$DefaultGates = @("01","02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","31","32","33","34","35","36","39","40","41","42","43","44","45","47","48","49","50","51","52","55","58","60","66","68","37","38","46","53","54","56","57","59","61","62","63","64","65","67")
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
    throw "-Ubsan/-Fuzz/-Coverage requested but clang-cl.exe not found (checked PATH, VS's 'C++ Clang tools for Windows' component, standalone LLVM)."
}
$script:ClangCl = $null
if ($Ubsan -or $Fuzz -or $Coverage) {
    $script:ClangCl = Find-ClangCl
    Write-Host "Using clang-cl: $script:ClangCl"
}

# Same VCPKG_ROOT/VCPKG_INSTALLATION_ROOT/C:\vcpkg fallback chain as
# scripts\windows\build.bat's own resolution, but -VcpkgRoot (this
# script's own parameter, matching fractalsql-reasoning-http's
# scripts\build-windows.ps1 -VcpkgRoot) wins when passed explicitly.
#
# The environment candidates are SKIPPED when the tree they name has no
# OpenSSL installed, rather than being accepted blindly. This matters
# because vcvars64.bat OVERWRITES VCPKG_ROOT with the VS-bundled vcpkg
# tree (VC\vcpkg), and that tree has no openssl:x64-windows-static
# package installed -- so trusting the environment variable here
# resolves to a tree whose include\openssl and lib\ are both empty,
# and the build then dies with "cannot open input file 'libssl.lib'".
# The first tree that actually HAS the OpenSSL package wins.
function Resolve-VcpkgRoot {
    if ($VcpkgRoot -ne "") { return $VcpkgRoot }
    $candidates = @()
    if ($env:VCPKG_ROOT) { $candidates += $env:VCPKG_ROOT }
    if ($env:VCPKG_INSTALLATION_ROOT) { $candidates += $env:VCPKG_INSTALLATION_ROOT }
    # The PERSISTED (User/Machine) scope matters as much as the process
    # scope: a dev box that has a real vcpkg installed for the account
    # ("setx VCPKG_ROOT ...") has it in the User scope, while the
    # PROCESS scope of a shell that has run vcvars64 carries the
    # VS-bundled tree instead -- the one with no OpenSSL in it. Reading
    # only the process scope therefore misses the tree the user
    # actually installed into.
    foreach ($scope in @('User', 'Machine')) {
        foreach ($name in @('VCPKG_ROOT', 'VCPKG_INSTALLATION_ROOT')) {
            $v = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($v) { $candidates += $v }
        }
    }
    $candidates += "C:\vcpkg"
    # A candidate that actually HAS the OpenSSL package wins, whatever
    # order it appears in. The environment candidates come first in the
    # list, so a VS-bundled VCPKG_ROOT (no OpenSSL installed) is passed
    # over in favour of a real vcpkg tree further down.
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "installed\x64-windows-static\include\openssl\evp.h")) {
            return $c
        }
    }
    # Nothing has OpenSSL: fall back to the first candidate so the
    # caller's error message names a concrete tree to install into.
    if ($candidates.Count -gt 0) { return $candidates[0] }
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

# The MariaDB Connector/C DEVELOPMENT files: the client headers, the client
# import library and the client DLL. The MCP-server build (gates 39, 40,
# 66, 68) and the C++ probe builds (gates 42, 43, 44) link against them.
#
# They normally live in the SAME tree as the server binaries: the server
# .zip distributions this repo's CI unpacks (deps\mariadb\root) ship
# include\mysql, lib\libmariadb.lib and lib\libmariadb.dll together, and
# so does the "Development components" of an MSI install.
#
# An MSI install WITHOUT that feature has no import library at all. The
# 10.6 MSI on a dev box carries only lib\mariadbclient.lib, which is a
# DIFFERENT thing: it is the STATIC client library (an archive of object
# code -- no .idata section, no import table), and there is no client DLL
# next to it either. Linking "libmariadb.lib" against such a tree fails at
# the link step with LNK1181, long after every other gate has passed.
#
# So the client tree is resolved ONCE, here, from an ordered list of
# candidates, and the tree that is used is printed -- a build that links
# a DIFFERENT MariaDB client's DLL than the server it talks to has to be
# visible, not inferred.
function Test-MariaDbImportLib([string]$path) {
    # An import library carries an .idata section. The static client
    # library does not, and linking it is a different exercise entirely
    # (it drags in its own zlib/OpenSSL expectations), so it is NOT
    # accepted as a stand-in for the import library.
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        return [Text.Encoding]::ASCII.GetString($bytes).Contains('.idata')
    }
    catch { return $false }
}

function Resolve-MariaDbClient {
    $candidates = @()
    if ($ClientDir -ne "") {
        $candidates += ,@{ Dir = (Resolve-Path -LiteralPath $ClientDir -ErrorAction Stop).Path; Why = 'the -ClientDir tree' }
    }
    $candidates += ,@{ Dir = $MdbDir; Why = 'the -MdbDir tree' }
    # The repo's own vendored server tree -- the same layout CI unpacks
    # into deps\mariadb\root, and the one mcp\scripts\windows\build.bat
    # defaults to when MARIADB_DIR is unset.
    $vendored = Join-Path $Here 'deps\mariadb\root'
    if (Test-Path -LiteralPath $vendored) {
        $candidates += ,@{ Dir = (Resolve-Path -LiteralPath $vendored).Path; Why = 'the repo''s vendored deps\mariadb\root tree' }
    }
    # Sibling MSI installs on this box. Connector/C is a CLIENT library:
    # it links against any MariaDB server of a compatible vintage, so a
    # client tree from a different install is a legitimate source.
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'MariaDB*' -ErrorAction SilentlyContinue)) {
            $candidates += ,@{ Dir = $d.FullName; Why = "the sibling install $($d.FullName)" }
        }
    }

    foreach ($c in $candidates) {
        $inc = Join-Path $c.Dir 'include\mysql'
        if (-not (Test-Path -LiteralPath (Join-Path $inc 'mysql.h'))) { continue }
        $libName = $null
        foreach ($n in @('libmariadb.lib', 'mariadbclient.lib')) {
            $p = Join-Path $c.Dir "lib\$n"
            if (-not (Test-Path -LiteralPath $p)) { continue }
            # libmariadb.lib is always the import library; mariadbclient.lib
            # is only accepted when it IS one (see Test-MariaDbImportLib).
            if ($n -eq 'libmariadb.lib' -or (Test-MariaDbImportLib $p)) { $libName = $n; break }
        }
        if (-not $libName) { continue }
        $dll = $null
        foreach ($n in @('libmariadb.dll', 'mariadbclient.dll')) {
            foreach ($sub in @('lib', 'bin')) {
                $p = Join-Path $c.Dir "$sub\$n"
                if (Test-Path -LiteralPath $p) { $dll = $p; break }
            }
            if ($dll) { break }
        }
        return [pscustomobject]@{
            Dir     = $c.Dir
            Why     = $c.Why
            Inc     = $inc
            LibName = $libName
            LibPath = (Join-Path $c.Dir "lib\$libName")
            Dll     = $dll
        }
    }
    return $null
}

$script:MariaDbClient = Resolve-MariaDbClient
if ($script:MariaDbClient) {
    Write-Host "  MariaDB client (Connector/C): $($script:MariaDbClient.Dir)  [$($script:MariaDbClient.LibName)]"
    if ($script:MariaDbClient.Dir -ne $MdbDir) {
        Write-Host "    (taken from $($script:MariaDbClient.Why); the server tree under test is $MdbDir)"
    }
    if (-not $script:MariaDbClient.Dll) {
        Write-Host "    WARNING: no client DLL (libmariadb.dll) in that tree. The probe gates stage it next to the probe binary and will not start without it."
    }
}
else {
    Write-Host "  WARNING: no MariaDB Connector/C import library (libmariadb.lib) found in any candidate tree."
    Write-Host "           Gates 39, 40, 42, 43, 44, 66 and 68 link it and will fail at the link step (LNK1181)."
    Write-Host "           Point -MdbDir at a server .zip distribution (deps\mariadb\root), pass -ClientDir <tree>,"
    Write-Host "           or install the MSI's 'Development components' feature."
}

# dist\ subdir convention: -Asan/-Ubsan/-Coverage each get their own
# tree, never touching the normal release build's output.
$DistSubdir = if ($Asan) { "dist\windows-asan\mdb$MdbMajor" }
              elseif ($Ubsan) { "dist\windows-ubsan\mdb$MdbMajor" }
              elseif ($Coverage) { "dist\windows-cov\mdb$MdbMajor" }
              else { "dist\windows\mdb$MdbMajor" }
$Dll = Join-Path $Here "$DistSubdir\fractalsql.dll"
$DaemonExe = Join-Path $Here "$DistSubdir\fractalsqld.exe"

# --- coverage (Windows) ----------------------------------------------
#
# -Coverage builds an INSTRUMENTED fractalsqld.exe and reports what the
# gate run actually covered. The Windows counterpart of build_test.sh's
# run_coverage_report().
#
# WHY LLVM'S TOOLING AND NOT lcov/gcov:
#   Windows has neither, and the POSIX pipeline (gcov .gcda ->
#   lcov --capture/--extract -> genhtml) has no Windows equivalent. So
#   this uses LLVM's own: clang-cl -fprofile-instr-generate
#   -fcoverage-mapping -> .profraw -> llvm-profdata merge -sparse ->
#   llvm-cov report/show/export.
#
#   One of the POSIX side's measurement fixes has NO counterpart here:
#   lcov 2.0's --rc no_exception_branch=1 (and the raw BRDA: summing
#   that goes with it) works around a geninfo bug that zeroes the
#   branch counts for compiler-synthesised exception-unwind landing
#   pads. llvm-cov derives branch coverage from the coverage mapping
#   itself and reports Branches natively, so there is nothing to
#   exclude and nothing to work around.
#
# WHY THE DAEMON FLUSHES ITS OWN PROFILE:
#   The LLVM runtime writes the .profraw at a NORMAL process exit, and
#   this harness stops the daemon with a hard kill (Stop-Process
#   -Force), which skips the CRT's exit handlers -- so an instrumented
#   daemon would leave no profile at all. The daemon therefore writes
#   the profile itself on a timer when FRACTALSQL_PROFILE_FLUSH_MS is
#   set (service/daemon/fractalsqld.c). The value below is the flush
#   period: the smaller it is, the less of the run's tail is lost when
#   the daemon is killed, at the cost of more (small) file writes.
if ($Coverage) {
    $script:CovDir = Join-Path $env:TEMP "fsql_bt_coverage"
    Remove-Item -Recurse -Force $script:CovDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $script:CovDir | Out-Null
    # %p keeps each daemon process's profile in its own file: the
    # harness restarts the daemon (gates 26/33/47 do), and the LLVM
    # runtime MERGES each write into the file it already wrote, so two
    # processes sharing one file would add their counts together.
    $env:LLVM_PROFILE_FILE = Join-Path $script:CovDir "fractalsqld-%p.profraw"
    $env:FRACTALSQL_PROFILE_FLUSH_MS = "500"
}

$script:Failed = $false
function Pass([string]$msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Fail([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Failed = $true }
function Skip([string]$msg) { Write-Host "  [SKIP] $msg" -ForegroundColor Yellow }

# --- coverage report (Windows) ----------------------------------------
#
# The Windows counterpart of build_test.sh's run_coverage_report(): turn
# the daemon's .profraw files into a merged profile, a per-file table,
# a POSIX-shaped summary, and an HTML report.
#
# The LLVM tool trio lives next to clang-cl (the VS-bundled LLVM, or
# whatever standalone LLVM clang-cl came from) so the tools and the
# compiler are always the same version -- a profile written by one
# LLVM version and merged by another is rejected.
function Write-CoverageReport {
    if (-not $script:ClangCl) { Fail "coverage: no clang-cl (the -Coverage build never ran?)"; return }
    $llvmBin = Split-Path -Parent $script:ClangCl
    $profdataTool = Join-Path $llvmBin "llvm-profdata.exe"
    $covTool      = Join-Path $llvmBin "llvm-cov.exe"
    if (-not (Test-Path $profdataTool)) { Fail "coverage: llvm-profdata.exe not found next to $script:ClangCl"; return }
    if (-not (Test-Path $covTool))      { Fail "coverage: llvm-cov.exe not found next to $script:ClangCl"; return }

    $raw = @(Get-ChildItem -Path $script:CovDir -Filter "*.profraw" -ErrorAction SilentlyContinue)
    if ($raw.Count -eq 0) {
        Fail "coverage: no .profraw under $script:CovDir -- was the -Coverage build instrumented, and did the daemon run?"
        return
    }
    $profdata = Join-Path $script:CovDir "coverage.profdata"
    if (Test-Path $profdata) { Remove-Item -Force $profdata }
    $mergeOut = & $profdataTool merge -sparse @($raw.FullName) -o $profdata 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $profdata)) {
        Fail "coverage: llvm-profdata merge failed ($($mergeOut -join ' '))"
        return
    }
    Write-Host "  coverage: merged $($raw.Count) profile file(s) -> $(Split-Path -Leaf $profdata)"

    # The per-file table is restricted to THIS project's own sources
    # (src/*.c + service/daemon/fractalsqld.c) by passing them as
    # positional arguments -- the same set the POSIX side extracts with
    # `lcov --extract '*/src/*.c' '*/daemon/fractalsqld.c'`. Without
    # that, the table also lists the vendored MariaDB and OpenSSL
    # headers, which are not this project's code.
    $srcFiles = @(Get-ChildItem -Path (Join-Path $Here "src") -Filter "*.c" -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName })
    $srcFiles += (Join-Path $Here "service\daemon\fractalsqld.c")
    $report = & $covTool report $DaemonExe "-instr-profile=$profdata" @srcFiles 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "coverage: llvm-cov report failed ($($report -join ' '))"
        return
    }
    Write-Host ""
    Write-Host "  === per-file coverage ==="
    foreach ($line in $report) { Write-Host "  $line" }

    # The POSIX summary is computed from lcov's .info file, summing
    # LF:/LH:/FNF:/FNH: and the raw BRDA: lines. llvm-cov can emit the
    # SAME tracefile format (-format=lcov), so the Windows summary is
    # computed the same way and the two harnesses' numbers are directly
    # comparable. (llvm-cov's JSON export is not used: this LLVM
    # version's `export` only accepts -format=lcov.)
    #
    # The file set is the POSIX side's --extract set: src/*.c and
    # service/daemon/fractalsqld.c. The vendored MariaDB and OpenSSL
    # headers that the report also lists are not this project's code.
    $lcov = & $covTool export $DaemonExe "-instr-profile=$profdata" -format=lcov 2>$null
    if ($LASTEXITCODE -ne 0) { Fail "coverage: llvm-cov export (-format=lcov) failed"; return }
    $records = @()
    $cur = @()
    foreach ($l in $lcov) {
        if ($l -eq "end_of_record") { $records += ,$cur; $cur = @(); continue }
        $cur += $l
    }
    if ($cur.Count -gt 0) { $records += ,$cur }

    $lf = 0; $lh = 0; $fnf = 0; $fnh = 0; $brf = 0; $brh = 0
    foreach ($rec in $records) {
        $sf = $rec | Where-Object { $_ -like "SF:*" } | Select-Object -First 1
        if (-not $sf) { continue }
        $path = $sf.Substring(3)
        if (($path -notmatch 'src\\[^\\]+\.c$') -and ($path -notmatch 'service\\daemon\\fractalsqld\.c$')) { continue }
        foreach ($l in $rec) {
            if ($l -match '^LF:(\d+)')      { $lf  += [int]$Matches[1] }
            elseif ($l -match '^LH:(\d+)')  { $lh  += [int]$Matches[1] }
            elseif ($l -match '^FNF:(\d+)') { $fnf += [int]$Matches[1] }
            elseif ($l -match '^FNH:(\d+)') { $fnh += [int]$Matches[1] }
            elseif ($l -match '^BRDA:\d+,\d+,\d+,(\S+)$') {
                # Same rule as the POSIX awk: every branch counts, and a
                # branch counts as hit when it was actually taken. The
                # POSIX side also skips 'e'-tagged (exception) branches
                # -- a gcov-only concept, and llvm-cov never emits it,
                # so there is nothing to skip here.
                $brf++
                if ($Matches[1] -ne "-" -and ([int]$Matches[1]) -gt 0) { $brh++ }
            }
        }
    }
    Write-Host ""
    Write-Host "  === coverage (src\*.c, daemon\fractalsqld.c) ==="
    Write-Host ("  lines:     {0}/{1}{2}" -f $lh, $lf, $(if ($lf -gt 0) { " ({0:N1}%)" -f (100.0 * $lh / $lf) } else { "" }))
    Write-Host ("  functions: {0}/{1}{2}" -f $fnh, $fnf, $(if ($fnf -gt 0) { " ({0:N1}%)" -f (100.0 * $fnh / $fnf) } else { "" }))
    Write-Host ("  branches:  {0}/{1}{2}" -f $brh, $brf, $(if ($brf -gt 0) { " ({0:N1}%)" -f (100.0 * $brh / $brf) } else { "" }))

    $htmlDir = Join-Path $Here "coverage_html"
    Remove-Item -Recurse -Force $htmlDir -ErrorAction SilentlyContinue
    & $covTool show $DaemonExe "-instr-profile=$profdata" -format=html "-output-dir=$htmlDir" @srcFiles 2>&1 | Out-Null
    if ((Test-Path (Join-Path $htmlDir "coverage.html")) -or (Test-Path (Join-Path $htmlDir "index.html"))) {
        Pass "coverage: report at coverage_html\"
    } else {
        Fail "coverage: llvm-cov show produced no HTML report in $htmlDir"
    }
}

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
# The reasoning-VFS-ABI test fixtures, built by Mdb-Setup. SlowSo is the
# one the MCP gate's shutdown-drain phase consumes (it needs a
# deterministically-slow reasoning plugin to hold a request in flight
# across the shutdown); the others are swapped in by their own gates.
$script:EvilReasoningSo = $null
$script:LyingSo = $null
$script:CrashReasoningSo = $null
$script:EvilEmbedSo = $null
$script:RetrySo = $null
$script:ThinkSo = $null
$script:SlowSo = $null
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
# Every daemon THIS harness started, by PID. The teardown kills these and
# only these (see Mdb-Teardown): the installed fractalsqld Windows
# service runs from this very same dist\windows\mdb11.4\fractalsqld.exe,
# so a "every fractalsqld under this exe" sweep would reach the user's
# own service -- and kill it for real when the harness runs elevated.
# PID-only is also what this repo's own convention asks for.
$script:OwnedFsqdPids = @()

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
    # The reasoning_plugin key rides in the conf, not only in the daemon's
    # boot environment, so the MCP gate's shutdown-drain phase can SWAP it
    # live (the admin tier's fractal_daemon_config_set -> daemon RELOAD) to
    # point the daemon at a deterministically-slow reasoning fixture, and
    # put it back afterwards. The boot-environment fallback still applies
    # for a key the conf does not carry, so writing it here changes
    # nothing about which plugin the daemon uses -- it only makes the
    # value readable and writable through the admin tier.
    #
    # The value must be BACKSLASH-separated: the reasoning core resolves
    # the configured path with _fullpath() and refuses anything whose
    # resolved form differs from the input ("reasoning plugin path is not
    # canonical"). _fullpath() turns forward slashes into backslashes, so
    # a forward-slash value fails that comparison -- measured live.
    if ($env:FRACTALSQL_REASONING_PLUGIN) {
        $rp = (Resolve-Path -LiteralPath $env:FRACTALSQL_REASONING_PLUGIN -ErrorAction SilentlyContinue).Path
        if (-not $rp) { $rp = $env:FRACTALSQL_REASONING_PLUGIN }
        Add-Content -Path $script:FsqdConf -Encoding ascii -Value "reasoning_plugin = $rp"
    }

    $env:FRACTALSQL_CONFIG = $script:FsqdConf
    $script:FsqdProc = Start-Process -FilePath $script:DaemonExe `
        -ArgumentList @("-c", "`"$($script:FsqdConf)`"") `
        -RedirectStandardError $script:FsqdLog -RedirectStandardOutput "$($script:FsqdLog).out" `
        -PassThru -WindowStyle Hidden
    $script:OwnedFsqdPids += $script:FsqdProc.Id
    for ($i = 0; $i -lt (100 * $TimeoutMult); $i++) {
        if ($script:FsqdProc.HasExited) { Write-FsqdStartFailure $true; return $false }
        if ((Test-Path $script:FsqdLog) -and (Select-String -Path $script:FsqdLog -Pattern 'listening on' -Quiet)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    Write-FsqdStartFailure $false
    return $false
}

# Says why fractalsqld did not come up, so a sanitizer build that dies in the loader (which writes nothing to
# its log) is not an empty failure: whether it exited and with what status (0xC0000135 is a missing DLL,
# 0xC0000409 a stack-buffer check, 0xC0000005 an access violation), whether the ASan runtime sits beside the
# exe, and whatever it wrote to either stream.
function Write-FsqdStartFailure([bool]$Exited) {
    $p = $script:FsqdProc
    if ($Exited -and $p) {
        # ExitCode is a signed Int32, so an NT status such as 0xC0000139 arrives negative: widen before formatting.
        $code = [int64]$p.ExitCode
        $hex  = if ($code -lt 0) { $code + 4294967296 } else { $code }
        Write-Host ("    fractalsqld exited before it was listening, status 0x{0:X8} ({1})" -f $hex, $code)
    } else {
        Write-Host "    fractalsqld was still running but never logged 'listening on' (timed out)"
    }
    $exeDir = Split-Path -Parent $script:DaemonExe
    $rt = Join-Path $exeDir 'clang_rt.asan_dynamic-x86_64.dll'
    if ($Asan) { Write-Host "    ASan runtime beside the exe: $(Test-Path $rt) ($rt)" }
    foreach ($f in @($script:FsqdLog, "$($script:FsqdLog).out")) {
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) {
            Write-Host "    --- tail of $f ---"
            Get-Content -Path $f -Tail 25 | ForEach-Object { Write-Host "    $_" }
        } else {
            Write-Host "    ($f is empty or missing)"
        }
    }
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
    # The text-to-SQL tier's REVIEW-ISOLATION fixture (gate 48): reports
    # the RESPONSE_MODE its own plugin instance was born with, captured
    # at fsql_reasoning_init time (see that file's own header for why
    # init-time capture is the only meaningful measurement, and why the
    # per-instance state has to hang off vfs->user_ctx rather than a
    # module global -- one DLL handle is shared by every tier).
    $script:ReviewModeSo     = Compile-FsqlFixture "tests\review_mode_reasoning_plugin.c" "review_mode_reasoning.dll" $fsqlIncDirs
    # A deterministically-SLOW reasoning plugin: generate() sleeps
    # FSQL_MOCK_SLOW_MS (default 3000) before answering. Used by the MCP
    # gate's shutdown-drain phase (gate 39) to hold a request genuinely
    # in flight at the moment the server is asked to shut down, so the
    # transport's drain-wait loop is actually exercised instead of losing
    # a sub-millisecond race every time. Portable as-is: its POSIX/
    # Windows split is a nanosleep/Sleep() choice, nothing else.
    $script:SlowSo           = Compile-FsqlFixture "tests\slow_reasoning_plugin.c"     "slow_reasoning.dll"      $fsqlIncDirs
    if (-not ($script:EvilReasoningSo -and $script:LyingSo -and $script:CrashReasoningSo -and $script:EvilEmbedSo -and $script:RetrySo -and $script:ThinkSo -and $script:ReviewModeSo -and $script:SlowSo)) { return 2 }

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
    #
    # BY PID, and only the ones this harness started. The previous
    # "every fractalsqld under this exe" sweep also matched the
    # INSTALLED fractalsqld Windows service -- which runs from this very
    # same dist\windows\mdb11.4\fractalsqld.exe -- and would have killed
    # the user's own service for real whenever the harness ran elevated.
    foreach ($owned in $script:OwnedFsqdPids) {
        Stop-Process -Id $owned -Force -ErrorAction SilentlyContinue
    }
    $script:OwnedFsqdPids = @()
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
    $name = 'clang_rt.asan_dynamic-x86_64.dll'
    $found = $null
    # The runtime must come from the SAME toolset as the compiler that instrumented the exe: an
    # instrumented binary and a runtime of another version disagree about the entry points between
    # them, and the exe then dies in the loader (STATUS_ENTRYPOINT_NOT_FOUND, 0xC0000139) before it can
    # write a word to its log. A machine can have several toolsets installed, so a blind recursive search
    # for "the first" copy may pick an older one. The developer environment names the compiler's toolset.
    if ($env:VCToolsInstallDir) {
        $cand = Join-Path $env:VCToolsInstallDir "bin\Hostx64\x64\$name"
        if (Test-Path $cand) { $found = Get-Item $cand }
    }
    if (-not $found) {
        $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $roots = @()
        if (Test-Path $VsWhere) {
            $vsPath = & $VsWhere -latest -products * -property installationPath 2>$null
            if ($vsPath) { $roots += (Join-Path $vsPath 'VC\Tools\MSVC') }
        }
        foreach ($r in $roots) {
            # Newest toolset first (directory names are version numbers).
            $found = Get-ChildItem -Path $r -Recurse -Filter $name -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'Hostx64\\x64' } |
                Sort-Object { [version]($_.FullName -replace '^.*\\MSVC\\([0-9.]+)\\.*$', '$1') } -Descending |
                Select-Object -First 1
            if ($found) { break }
        }
    }
    if (-not $found) {
        throw "$name not found under the MSVC toolset (install the 'MSVC ... ASan' component)"
    }
    Copy-Item $found.FullName $OutDir -Force
    Write-Host "  ASan runtime: $($found.FullName) (file version $($found.VersionInfo.FileVersion))"
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
        Remove-Item Env:\CC_DAEMON, Env:\CRT_FLAG, Env:\SAN_FLAGS, Env:\LINK_EXPORTS -ErrorAction SilentlyContinue
        if ($Asan) {
            $env:SAN_FLAGS = '/fsanitize=address /Zi'
        } elseif ($Ubsan) {
            $env:CC_DAEMON = $script:ClangCl
            $env:CRT_FLAG  = '/MD'
            $env:SAN_FLAGS = '-fsanitize=undefined'
        } elseif ($Coverage) {
            # Coverage instruments fractalsqld.exe only, for the same
            # reason the sanitizers do: the shim is a thin forwarder
            # with no logic of its own (build.bat hardcodes cl.exe for
            # it), while the adapter code that matters all runs in
            # the daemon.
            $env:CC_DAEMON = $script:ClangCl
            $env:CRT_FLAG  = '/MD'
            # -fprofile-update=atomic: the daemon serves every client
            # connection on its own thread, so the profile counters are
            # updated concurrently -- the same reason mcp/Makefile needs
            # it for the MCP binary.
            $env:SAN_FLAGS = '-fprofile-instr-generate -fcoverage-mapping -fprofile-update=atomic'
            # The daemon flushes its own profile on a timer and finds
            # the runtime entry points with GetProcAddress, which can
            # only see EXPORTED symbols. The coverage runtime is linked
            # statically, so the two entry points have to be exported
            # explicitly -- otherwise the lookup fails, the daemon logs
            # "no coverage runtime" and never writes a profile.
            $env:LINK_EXPORTS = '/EXPORT:__llvm_profile_write_file /EXPORT:__llvm_profile_reset_counters'
        }
        $env:MARIADB_DIR   = $MdbDir
        $env:MARIADB_MAJOR = $MdbMajor
        $env:OUT_DIR       = Split-Path -Parent $Dll
        # The build script reads VCPKG_ROOT from ITS OWN environment, and
        # it resolves it AFTER any vcvars call -- which is exactly when
        # vcvars has overwritten it with the VS-bundled tree that has no
        # OpenSSL in it. Export the RESOLVED root (the one that actually
        # has openssl:x64-windows-static installed) so the build script's
        # own "VCPKG_ROOT is read after vcvars" ordering is fed a good
        # value rather than a bad one.
        $env:VCPKG_ROOT = Resolve-VcpkgRoot
        try {
            & "$Here\scripts\windows\build.bat"
            if ($LASTEXITCODE -ne 0) { Fail "01 build"; return $false }
        } finally {
            Remove-Item Env:\CC_DAEMON, Env:\CRT_FLAG, Env:\SAN_FLAGS, Env:\LINK_EXPORTS -ErrorAction SilentlyContinue
        }
        if ($Asan) { Copy-AsanRuntime (Split-Path -Parent $Dll) }
    } finally { Pop-Location }
    if (-not (Test-Path $Dll)) { Fail "01 build: $Dll not produced"; return $false }
    if (-not (Test-Path $DaemonExe)) { Fail "01 build: $DaemonExe not produced"; return $false }
    Pass "01 build (shim + fractalsqld.exe$(if ($Asan) { ', ASan' } elseif ($Ubsan) { ', UBSan' } elseif ($Coverage) { ', coverage-instrumented' }))"
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

    # Composite FK with non-default ON UPDATE / ON DELETE actions. The
    # bt_customers/bt_orders fixture's single-column FK with implicit NO
    # ACTION never exercises a multi-column join or the action clauses at
    # all, and MariaDB's information_schema.REFERENTIAL_CONSTRAINTS is
    # where UPDATE_RULE/DELETE_RULE come from -- a plain JOIN on
    # key_column_usage never sees them. So the schema context has to read
    # referential_constraints explicitly to report the actions.
    #
    # The child columns are NULLABLE, and that is not a detail: ON
    # UPDATE SET NULL requires the referencing columns to accept NULL
    # (a NOT NULL child column would make the constraint impossible to
    # satisfy, and MariaDB refuses the CREATE outright -- errno 150,
    # "Foreign key constraint is incorrectly formed"). The fixture has
    # to be creatable for the assertion to mean anything.
    #
    # Dropped again right after so the auto-discovery assertion above (and
    # gate 10's own schema expectations) are unaffected by later gates.
    $fkSetup = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;
CREATE TABLE bt_fk_parent (a BIGINT NOT NULL, b BIGINT NOT NULL, PRIMARY KEY (a, b));
CREATE TABLE bt_fk_child (
  pa BIGINT NULL, pb BIGINT NULL,
  FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a, b)
    ON DELETE CASCADE ON UPDATE SET NULL
);
"@ 2>&1
    $fkSetupStr = ($fkSetup -join "`n")
    if ($fkSetupStr -match "(?i)ERROR") {
        Fail "03 schema_context: composite-FK fixture setup failed: $fkSetupStr"
    }
    else {
        $ctxfk = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e `
            "CALL fractal_schema_context(NULL, @ctxfk); SELECT @ctxfk;" 2>&1
        $ctxfkStr = ($ctxfk -join "`n")
        if ($ctxfkStr -match [regex]::Escape("FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a, b)") `
            -and $ctxfkStr -match "ON UPDATE SET NULL" `
            -and $ctxfkStr -match "ON DELETE CASCADE") {
            Pass "03 schema_context: composite FK with ON UPDATE/ON DELETE actions"
        }
        else {
            Fail "03 schema_context: composite FK with actions, got: $ctxfkStr"
        }
    }
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e `
        "DROP TABLE IF EXISTS bt_fk_child; DROP TABLE IF EXISTS bt_fk_parent;" 2>&1 | Out-Null
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

    # A plain (non-versioned, non-hint) block comment is inert text, not
    # an exec comment (t2s_has_exec_comment only rejects /*! and /*+) --
    # this is the one allowlist input that drives t2s_skip_ws_comments'
    # own /* */ loop, t2s_count_statements' and t2s_has_into_outfile's
    # comment-skip branches, and t2s_has_exec_comment's plain-comment
    # skip loop all in one call; nothing else in this suite's allowlist
    # inputs contains a comment at all.
    $a3 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT /* a plain comment */ 1'), '<PASS>');" 2>&1
    if ($a3 -eq "<PASS>") { Pass "04 text_to_sql: a plain block comment is inert, not rejected" } else { Fail "04 text_to_sql: expected the commented SELECT to pass, got: $a3" }

    # A candidate that starts with something that is not a statement
    # keyword at all. The allowlist's leading-statement classifier
    # (t2s_classify_leading_stmt) reports such input as "OTHER", and
    # "OTHER" is never a permitted statement type -- so the rejection
    # reason here is the statement-type one, not a parse failure. (This
    # repo's allowlist has no separate "does not start with a keyword"
    # message: the classifier's OTHER bucket IS that case.)
    $a4 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('123 not a keyword'), '<PASS>');" 2>&1
    if ($a4 -ne "<PASS>") { Pass "04 text_to_sql: a non-keyword start is rejected" } else { Fail "04 text_to_sql: expected '123 not a keyword' to be rejected" }

    # INSERT in select-only mode. The default allowed_statements is
    # "select", so an INSERT candidate must be refused by the statement
    # type check -- the mode-specific branch of the classifier, not the
    # DDL branch the DROP TABLE case above covers.
    $a5 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('INSERT INTO bt_customers (name) VALUES (''x'')'), '<PASS>');" 2>&1
    if ($a5 -ne "<PASS>") { Pass "04 text_to_sql: INSERT rejected in select-only mode" } else { Fail "04 text_to_sql: expected INSERT to be rejected in select-only mode" }
    if ($a5 -match "(?i)not permitted") { Pass "04 text_to_sql: the INSERT rejection names the statement type" } else { Fail "04 text_to_sql: expected a 'not permitted' reason for INSERT, got: $a5" }

    # Empty candidate: the model's response carried no SQL at all. The
    # mock's chat reply is a fixed fenced ```sql block, so the
    # "no SQL in the response" path is not reachable through it -- the
    # allowlist's own "SQL is empty" branch is the closest equivalent
    # and is what this asserts. (A truly empty model response reaches
    # fractal_t2s_generate's own NULL-summary error, which the UDF ABI
    # surfaces as a plain NULL to the caller -- see the comment in
    # src/fractalsql_textsql.c's fractal_t2s_generate.)
    $a6 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_check_allowlist(''), '<PASS>');" 2>&1
    if ($a6 -ne "<PASS>") { Pass "04 text_to_sql: an empty candidate is rejected, not passed through" } else { Fail "04 text_to_sql: expected an empty candidate to be rejected" }
    if ($a6 -match "(?i)empty") { Pass "04 text_to_sql: the empty-candidate rejection says so" } else { Fail "04 text_to_sql: expected an 'empty' reason, got: $a6" }

    # The model replies with PROSE and no SQL at all (the mock's
    # NO_SQL_MARKER route). The GENERATE step has no candidate to
    # allowlist, so this must fail with a specific reason -- "the model
    # response contained no SQL" -- rather than handing back a NULL
    # out_sql with no explanation, or a garbage statement.
    $a7 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_text_to_sql('FRACTALSQL_BT_NO_SQL_MARKER', NULL, @s, @e); SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1
    if ($a7 -match "contained no SQL") { Pass "04 text_to_sql: a prose-only model reply is reported as 'contained no SQL'" } else { Fail "04 text_to_sql: expected a 'contained no SQL' reason, got: $a7" }
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

    # The "no visible tables" branch of fractal_schema_context: the
    # procedure must SIGNAL rather than return an empty context that a
    # later stage would treat as a perfectly good (but useless) schema.
    #
    # MARIADB SHAPE. A single-file engine has one database, so "a
    # table-less database" there is a separate DATABASE file. MariaDB
    # cannot reproduce that shape at all: a stored routine's
    # DATABASE() is bound to the ROUTINE'S OWN schema, not the caller's
    # session schema (confirmed live: a procedure defined in fractalsql_bt
    # and called with -D bt_empty_db still sees DATABASE() = fractalsql_bt
    # and still enumerates fractalsql_bt's tables). So pointing the client
    # at a second, empty database cannot reach this branch -- the procedure
    # would keep auto-discovering the ORIGINAL database's tables and
    # happily return them.
    #
    # The MariaDB-equivalent condition for "the caller can see no tables"
    # is a caller with no table privileges in the schema, because
    # information_schema hides tables the caller cannot see and
    # fractal_schema_context is SQL SECURITY INVOKER. An EMPTY table-name
    # array ('[]') reaches the same n_tables = 0 branch through the same
    # SIGNAL, with no second user and no second database, so that is what
    # is asserted here: the request-for-nothing case and the
    # see-nothing case must be indistinguishable to the caller.
    $rEmpty = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e `
        "CALL fractal_schema_context('[]', @e);" 2>&1
    $rEmptyStr = ($rEmpty -join "`n")
    if ($rEmptyStr -match "(?i)no visible tables found") {
        Pass "10 dos_and_injection: schema_context with no visible tables reports no visible tables"
    }
    else {
        Fail "10 dos_and_injection: expected 'no visible tables found', got: $rEmptyStr"
    }
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

    # ---- vectorizer argument-validation cases -------------------------
    # Every one of these is a guard in the fractal_vectorizer_* procedures
    # themselves (sql/install_udf.sql). They are asserted here, against
    # the live procedures, rather than assumed from reading the SIGNALs.

    # A schema-qualified source_table. The procedure resolves it with an
    # exact-match lookup against information_schema.tables in the CURRENT
    # database, so "db.tbl" (or any other qualified form) can never
    # match a base table -- and it is rejected outright with a specific
    # message rather than being silently quoted as one identifier
    # (which is the shape of the bug this case exists to pin down:
    # a multi-segment identifier must not be quoted as a single segment).
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e `
        "DROP TABLE IF EXISTS bt_vsq; CREATE TABLE bt_vsq (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);" 2>&1 | Out-Null
    $rsq = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create('fractalsql_bt.bt_vsq', 'body', 'emb', NULL, @vid);" 2>&1) -join "`n"
    if ($rsq -match "(?i)schema-qualified source_table is not supported") { Pass "13 vectorizer_embed: a schema-qualified source_table is rejected with a specific reason" } else { Fail "13 vectorizer_embed: expected a schema-qualified rejection, got: $rsq" }

    # A digit-leading identifier. It cannot be a bare table name, and the
    # procedure's own lookup would simply not find it -- but the
    # rejection must be a clean SIGNAL, never a SQL-syntax error from
    # the trigger DDL the procedure builds.
    $rdig = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create('1_leading_digit', 'body', 'emb', NULL, @vid);" 2>&1) -join "`n"
    if ($rdig -match "(?i)not found") { Pass "13 vectorizer_embed: a digit-leading source_table is rejected cleanly" } else { Fail "13 vectorizer_embed: expected a clean rejection, got: $rdig" }

    # A NULL source_table: rejected, not treated as an empty table name.
    $rnullt = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create(NULL, 'body', 'emb', NULL, @vid);" 2>&1) -join "`n"
    if ($rnullt.Trim() -ne "") { Pass "13 vectorizer_embed: a NULL source_table is rejected" } else { Fail "13 vectorizer_embed: expected a NULL source_table to be rejected, got: $rnullt" }

    # pause / resume / drop: a NULL id and a nonexistent id each. The
    # pause and resume procedures both use an UPDATE ... WHERE id = ?
    # + ROW_COUNT() guard, so a NULL id matches no row and must SIGNAL
    # rather than silently succeed; drop reads the row first and
    # SIGNALs on a NULL read.
    $rp = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_pause(NULL);" 2>&1) -join "`n"
    if ($rp -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: pause(NULL) rejected" } else { Fail "13 vectorizer_embed: expected pause(NULL) to be rejected, got: $rp" }
    $rr = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_resume(NULL);" 2>&1) -join "`n"
    if ($rr -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: resume(NULL) rejected" } else { Fail "13 vectorizer_embed: expected resume(NULL) to be rejected, got: $rr" }
    $rd = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_drop(NULL);" 2>&1) -join "`n"
    if ($rd -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: drop(NULL) rejected" } else { Fail "13 vectorizer_embed: expected drop(NULL) to be rejected, got: $rd" }

    $rp9 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_pause(9999);" 2>&1) -join "`n"
    if ($rp9 -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: pause rejects a nonexistent id" } else { Fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rp9" }
    $rr9 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_resume(9999);" 2>&1) -join "`n"
    if ($rr9 -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: resume rejects a nonexistent id" } else { Fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rr9" }
    $rd9 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_drop(9999);" 2>&1) -join "`n"
    if ($rd9 -match "(?i)no vectorizer with that id") { Pass "13 vectorizer_embed: drop rejects a nonexistent id" } else { Fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rd9" }

    # A duplicate vectorizer: the same (source_table, text_col,
    # embedding_col) triple created twice. fractal_vectorizers carries
    # a UNIQUE constraint on that triple AND the procedure checks for an
    # existing row first -- both must produce a clean, specific error.
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e `
        "DROP TABLE IF EXISTS bt_vdup; CREATE TABLE bt_vdup (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);" 2>&1 | Out-Null
    $rdup2 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_create('bt_vdup', 'body', 'emb', NULL, @v1); CALL fractal_vectorizer_create('bt_vdup', 'body', 'emb', NULL, @v2);" 2>&1) -join "`n"
    if ($rdup2 -match "(?i)already exists") { Pass "13 vectorizer_embed: a duplicate source/text/embedding triple is rejected" } else { Fail "13 vectorizer_embed: expected a duplicate-create rejection, got: $rdup2" }

    # An embed endpoint that is not configured: every queued row must
    # end up 'failed' with a clean error, never silently skipped and
    # never left in 'pending' forever.
    #
    # The reasoning plugin is swapped to a nonexistent path IN PLACE
    # (Restart-ReasoningPluginInPlace, not Swap-ReasoningPlugin): the
    # vectorizer's rows are already queued in the live database, and a
    # full swap would wipe the datadir out from under them. The
    # in-place restart keeps the datadir, the routines and the queue
    # rows -- only the plugin the daemon loads changes.
    #
    # Note the retry semantics: fractal_embed returning NULL is a
    # RETRYABLE failure, so the row goes back to 'pending' with the
    # attempt counted until options.max_attempts (default 3) is
    # exhausted, and only then to 'failed'. So the queue is run the
    # number of times the retry policy needs before the rows are
    # terminally failed.
    $rcBad = Restart-ReasoningPluginInPlace "$Here\.gate13_nonexistent.dll"
    if ($rcBad -ne 0) {
        Fail "13 vectorizer_embed: bad-path restart did not take effect"
        Restart-ReasoningPluginInPlace "$script:PlugDir\fractalsql-reasoning-http.dll" | Out-Null
        return
    }
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e @"
DROP TABLE IF EXISTS bt_vnoembed;
CREATE TABLE bt_vnoembed (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);
INSERT INTO bt_vnoembed (body) VALUES ('a'), ('b');
CALL fractal_vectorizer_create('bt_vnoembed', 'body', 'emb', NULL, @vid);
"@ 2>&1 | Out-Null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(10, 600);" 2>&1 | Out-Null
    }
    # The vectorizer id is read back in its OWN client session, not via
    # the @vid user variable set by the CREATE above. A MariaDB user
    # variable lives in the SESSION that set it, and the CREATE ran in a
    # different invocation than this query -- so "@vid" here is an
    # undefined variable, i.e. NULL, and "vectorizer_id = NULL" matches
    # NO rows. The assertion would then read FAILED=0 / PENDING=0 /
    # <NO ERROR> and pass for entirely the wrong reason (an empty
    # result set is indistinguishable from a correctly-failing queue).
    # Resolving the id by its source_table is session-independent and
    # names exactly the vectorizer this block created.
    $rfail = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
SELECT CONCAT('FAILED=', COUNT(*)) FROM fractal_vectorizer_queue
 WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed') AND status = 'failed';
SELECT CONCAT('PENDING=', COUNT(*)) FROM fractal_vectorizer_queue
 WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed') AND status = 'pending';
SELECT IFNULL(MAX(error), '<NO ERROR>') FROM fractal_vectorizer_queue
 WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed');
"@ 2>&1) -join "`n"
    Restart-ReasoningPluginInPlace "$script:PlugDir\fractalsql-reasoning-http.dll" | Out-Null
    if ($rfail -match "FAILED=2") { Pass "13 vectorizer_embed: an unconfigured embed endpoint fails every row cleanly" } else { Fail "13 vectorizer_embed: expected 2 failed rows, got: $rfail" }
    if ($rfail -match "PENDING=0") { Pass "13 vectorizer_embed: an unconfigured embed endpoint leaves no row stuck in pending" } else { Fail "13 vectorizer_embed: expected no pending rows, got: $rfail" }
    if ($rfail -match "dispatch failed") { Pass "13 vectorizer_embed: the failed row carries a clean, specific error" } else { Fail "13 vectorizer_embed: expected a 'dispatch failed' error, got: $rfail" }

    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e `
        "DELETE FROM fractal_vectorizers WHERE source_table IN ('bt_vsq','bt_vdup','bt_vnoembed'); DROP TABLE IF EXISTS bt_vsq; DROP TABLE IF EXISTS bt_vdup; DROP TABLE IF EXISTS bt_vnoembed;" 2>&1 | Out-Null
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
    # The scratch file lives in the TEMP dir, not in the repo root:
    # the harness rewrites it on every run, so keeping it in the
    # working tree left a permanently-modified file in `git status`
    # (build_test.sh's twin already writes it to /tmp).
    $retryPrompt = Join-Path $env:TEMP "fractalsql_bt_retry_prompt.txt"
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
#       the three PATH-shaped keys (reasoning_plugin, enterprise_lib,
#       enterprise_ledger_path) additionally refuse a relative path and
#       a ".." traversal, while a canonical absolute path is accepted;
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
        # Tracked so an interrupted probe is still reaped by the
        # teardown's PID-only sweep (see $script:OwnedFsqdPids).
        $script:OwnedFsqdPids += $p.Id
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
        @{ extra = @("t2s_allowed_statements = delete");    pattern = "provider key t2s_allowed_statements" },
        # The three PATH-shaped provider keys: a relative path and a
        # ".." traversal are refused at CONFIGURATION time (the
        # daemon checks the path's SHAPE, not whether the file loads),
        # so the refusal arrives with the key's name in the log rather
        # than as a dlopen error on the first call.
        @{ extra = @("reasoning_plugin = relative\plugin.dll");       pattern = "provider key reasoning_plugin" },
        @{ extra = @("reasoning_plugin = C:\opt\fsql\..\evil.dll");   pattern = "provider key reasoning_plugin" },
        @{ extra = @("enterprise_lib = relative\enterprise.dll");     pattern = "provider key enterprise_lib" },
        @{ extra = @("enterprise_ledger_path = ..\ledger.csv");        pattern = "provider key enterprise_ledger_path" })) {
        New-Con $spec.extra
        Grant-ConfRecipe
        $r = Boot-Probe
        if (-not $r.Booted -and $r.Log -match ([regex]::Escape($spec.pattern))) {
            Pass "33 conf_gate: startup refuses '$($spec.extra -join '')' (key named in the log)"
        } else {
            Fail "33 conf_gate: '$($spec.extra -join '')' not refused: booted=$($r.Booted) log: $($r.Log)"
        }
    }

    # Control: the SAME key with a canonical absolute path is ACCEPTED
    # (a drive-letter path with no ".." segment), so the refusals above
    # are about the path's shape and not about the key being present at
    # all.
    New-Con @("reasoning_plugin = C:\fractalsql_bt\plugin.dll")
    Grant-ConfRecipe
    $r = Boot-Probe
    if ($r.Booted) {
        Pass "33 conf_gate: the same key with a canonical absolute path is accepted (the refusal above is about the path's shape)"
    } else {
        Fail "33 conf_gate: a canonical absolute reasoning_plugin was refused: booted=$($r.Booted) log: $($r.Log)"
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

    # An input over the 4 MiB cap (FRACTAL_COGNITION_MAX_INPUT_BYTES in
    # src/fractalsql_cognition.c). A caller-controlled string that drives
    # an allocation and an outbound request body, uncapped, would let a
    # multi-GiB argument OOM-kill the server or build an abusive request
    # -- so the cap has to be enforced, not merely documented. The value
    # is built with REPEAT() rather than a literal so the test itself
    # does not carry 4 MiB of text.
    $rbig = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), REPEAT('x', 4194305)), '<NULL>');" 2>&1
    if ($rbig -eq "<NULL>") { Pass "15 embed: input over the 4 MiB cap rejected" } else { Fail "15 embed: expected an over-cap input to be rejected, got: $rbig" }
    $upbig = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -N -e "SELECT 1;" 2>&1
    if ($upbig -eq "1") { Pass "15 embed: the server survived the over-cap input" } else { Fail "15 embed: mariadbd did not survive the over-cap input" }

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
    # process_queue() only claims vectorizers registered by the calling account, so an
    # outsider's call is a no-op: the owner's row stays pending and is NOT marked failed by someone else.
    if ($statuses -eq "pending") { Pass "16 embed_authz: outsider's process_queue() call left the owner's row untouched ('pending')" } else { Fail "16 embed_authz: expected 'pending' after the outsider's call, got: $statuses" }

    $errtext = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -u bt_embed_owner -D fractalsql_bt -N -e "SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id=$vzid AND status='failed';" 2>&1
    if ([string]::IsNullOrEmpty($errtext)) { Pass "16 embed_authz: the outsider's call recorded no failure against the owner's vectorizer" } else { Fail "16 embed_authz: expected no failed row for the owner's vectorizer, got: $errtext" }

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

    # Integer arguments past int range. A value that wraps back into range
    # (2^32 plus a valid value) must be refused, not run as the smaller value;
    # a refused call answers NULL. Each row is label, call with {N}, valid value.
    function Invoke-Bt19([string]$sql) {
        (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $sql 2>&1 | Out-String).Trim()
    }
    $wrapRows = @(
        @('search_debug iterations', "SELECT fractal_search_debug('[1,2,3]', {N}, 10, 2, 42);", 20),
        @('search_debug population', "SELECT fractal_search_debug('[1,2,3]', 20, {N}, 2, 42);", 10),
        @('search_debug diffusion', "SELECT fractal_search_debug('[1,2,3]', 20, 10, {N}, 42);", 2),
        @('state_fingerprint n_bits', "SELECT fractal_state_fingerprint('1,2,3', {N}, 42);", 64)
    )
    $wrapBad = @()
    foreach ($row in $wrapRows) {
        $wrapLabel = $row[0]; $wrapSql = $row[1]; $wrapBase = [int64]$row[2]
        $out = Invoke-Bt19 ($wrapSql.Replace('{N}', "$wrapBase"))
        if ($out -eq 'NULL' -or $out -match '^ERROR') { $wrapBad += "${wrapLabel}: the valid value $wrapBase was refused"; continue }
        $wrapVal = $wrapBase + 4294967296
        $out = Invoke-Bt19 ($wrapSql.Replace('{N}', "$wrapVal"))
        if ($out -ne 'NULL') { $wrapBad += "${wrapLabel}: $wrapVal answered '$($out.Substring(0, [Math]::Min(40, $out.Length)))'" }
    }
    if ($wrapBad.Count -eq 0) { Pass "19 sfs_bounds: $($wrapRows.Count) integer arguments reject a value that wraps back into range" }
    else { Fail "19 sfs_bounds: integer arguments past int range: $($wrapBad -join '; ')" }
    $rk = Invoke-Bt19 "SELECT fractal_search('[[1,0]]', '[1,0]', 4294967297, '{}');"
    if ($rk -match "k must be 1\.\.1000000|ERROR") { Pass "19 sfs_bounds: k=4294967297 (wraps to 1) rejected" } else { Fail "19 sfs_bounds: k that wraps to 1 was accepted: $rk" }
    $rb = Invoke-Bt19 "SELECT fractal_state_fingerprint('1,2,3', 33554425, 42);"
    if ($rb -eq 'NULL') { Pass '19 sfs_bounds: state_fingerprint refuses an n_bits past the 4 MiB ceiling' } else { Fail "19 sfs_bounds: state_fingerprint accepted n_bits past the ceiling: $rb" }
    # The cost is n_bits x vector length, so that product is bounded as well.
    $rw = Invoke-Bt19 "SELECT fractal_state_fingerprint('1,2,3,4,5,6,7,8,9', 33554424, 42);"
    if ($rw -eq 'NULL') { Pass '19 sfs_bounds: state_fingerprint refuses n_bits x length past the work bound' } else { Fail "19 sfs_bounds: state_fingerprint accepted n_bits x length past the work bound: $rw" }
    # The other bounded costs. Values are built in SQL so no argument is large;
    # a refused call answers NULL.
    $rbig = Invoke-Bt19 "SELECT fractal_search_debug(CONCAT('[', REPEAT('0.5,', 999), '0.5]'), 1000, 1000, 8, 42);"
    if ($rbig -eq 'NULL') { Pass '19 sfs_bounds: search_debug refuses iterations x population x diffusion x dim past the work bound' } else { Fail "19 sfs_bounds: search_debug accepted a search past the work bound: $rbig" }
    $rbig = Invoke-Bt19 "SELECT fractal_periodogram(CONCAT(REPEAT('0.1,', 1048576), '0.1'), 3);"
    if ($rbig -eq 'NULL') { Pass '19 sfs_bounds: periodogram refuses a series past 1048576 samples' } else { Fail "19 sfs_bounds: periodogram accepted a series past 1048576 samples: $rbig" }
    $rbig = Invoke-Bt19 "SELECT fractal_dimension_boxcount(CONCAT(REPEAT('1,2,', 2097153), '3,4'), 2);"
    if ($rbig -eq 'NULL') { Pass '19 sfs_bounds: boxcount refuses points x dim past the work bound' } else { Fail "19 sfs_bounds: boxcount accepted points x dim past the work bound: $rbig" }
    $rbig = Invoke-Bt19 "SELECT fractal_dimension_boxcount('0,0,1,0,0,1,1,1,2,2,3,1,1,3,4,4,nan,5', 2);"
    if ($rbig -eq 'NULL') { Pass '19 sfs_bounds: boxcount refuses a non-finite coordinate' } else { Fail "19 sfs_bounds: boxcount accepted a non-finite coordinate: $rbig" }
    $rbig = Invoke-Bt19 "SELECT fractal_optimize_subset(CONCAT(REPEAT('5,', 5999), '5'), NULL, 3000, '{}');"
    if ($rbig -eq 'NULL') { Pass '19 sfs_bounds: optimize_subset refuses items x k past the work bound' } else { Fail "19 sfs_bounds: optimize_subset accepted items x k past the work bound: $rbig" }
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

    # The "diversify_enabled" field has to report the SESSION's own
    # state, and the session IS the connection -- so the enable and the
    # read have to happen in ONE connection. Every `mariadb -e` above is
    # its own connection with its own CONNECTION_ID(), which is exactly
    # why the two statements below are issued as a single -e.
    #
    # The flag used to be derived from the core's own params query,
    # which answers with the tunables whether or not the monitor is
    # actually running: the field therefore said "true" for EVERY
    # session, including one that had never enabled anything. The
    # state is now recorded where the only calls that change it live
    # (fractal_diversify_enable / _disable).
    $fresh = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_explain_result(CONNECTION_ID());" 2>&1
    if (($fresh -join "") -match '"diversify_enabled"\s*:\s*false') { Pass "21 diversify: a session that never enabled the monitor reports diversify_enabled=false" }
    else { Fail "21 diversify: a fresh session reported '$(($fresh -join ''))' (expected diversify_enabled:false)" }
    $enOn = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_diversify_enable(CONNECTION_ID()); SELECT fractal_explain_result(CONNECTION_ID());" 2>&1
    if (($enOn -join "") -match '"diversify_enabled"\s*:\s*true') { Pass "21 diversify: the same session reports diversify_enabled=true once it enables the monitor" }
    else { Fail "21 diversify: after enable the session reported '$(($enOn -join ''))' (expected diversify_enabled:true)" }
    $enOff = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_diversify_enable(CONNECTION_ID()); SELECT fractal_diversify_disable(CONNECTION_ID()); SELECT fractal_explain_result(CONNECTION_ID());" 2>&1
    if (($enOff -join "") -match '"diversify_enabled"\s*:\s*false') { Pass "21 diversify: disabling the monitor puts the flag back to false" }
    else { Fail "21 diversify: after disable the session reported '$(($enOff -join ''))' (expected diversify_enabled:false)" }

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

    # The NULL guard on a vector argument. The guard it exercises is the
    # shared FRACTAL_VECTOR_BINOP macro (src\fractalsql_vector.c) -- so
    # this asserts the macro all thirteen vector UDFs are built from,
    # not one hand-written body. A NULL argument must come back as a
    # NULL result: never a crash, and never a zero-length vector
    # masquerading as an answer.
    $addNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_add(NULL, '[1,1,1]');" 2>&1
    if ($addNull -eq "NULL") { Pass "22 vector_tier: add(NULL, ...) -> NULL" } else { Fail "22 vector_tier: expected NULL, got: $addNull" }

    # The 3 of the 13 vector-tier functions no gate called at all
    # before this: normalize, scale, negative_inner_product. float32
    # storage, not exact decimal: 0.6/0.8 round-trip through
    # fractal_vector's actual (every binding's) float32 precision as
    # 0.600000024/0.800000012 -- confirmed live.
    $norm2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_normalize('[3,4,0]');" 2>&1
    if ($norm2 -match '^\[0\.600000024,0\.800000012,0\]$') { Pass "22 vector_tier: normalize([3,4,0]) -> unit vector [0.6,0.8,0]" } else { Fail "22 vector_tier: normalize='$norm2'" }
    $norm2Null = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_normalize(NULL);" 2>&1
    if ($norm2Null -eq "NULL") { Pass "22 vector_tier: normalize(NULL) -> NULL" } else { Fail "22 vector_tier: expected NULL, got: $norm2Null" }

    $scale = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_scale('[1,2,3]', 2);" 2>&1
    if ($scale -match '^\[2,4,6\]$') { Pass "22 vector_tier: scale([1,2,3], 2) -> [2,4,6]" } else { Fail "22 vector_tier: scale='$scale'" }
    $scaleNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_scale(NULL, 2);" 2>&1
    if ($scaleNull -eq "NULL") { Pass "22 vector_tier: scale(NULL, ...) -> NULL" } else { Fail "22 vector_tier: expected NULL, got: $scaleNull" }

    $nip = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_negative_inner_product('[1,0,0]', '[1,0,0]');" 2>&1
    if ($nip -eq "-1") { Pass "22 vector_tier: negative_inner_product(identical unit vectors) = -1" } else { Fail "22 vector_tier: negative_inner_product='$nip'" }
    $nipNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_negative_inner_product(NULL, '[1,0,0]');" 2>&1
    if ($nipNull -eq "NULL") { Pass "22 vector_tier: negative_inner_product(NULL, ...) -> NULL" } else { Fail "22 vector_tier: expected NULL, got: $nipNull" }

    $l2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_l2_distance('[0,0,0]', '[3,4,0]');" 2>&1
    if ($l2 -eq "5") { Pass "22 vector_tier: l2_distance([0,0,0],[3,4,0])=5" } else { Fail "22 vector_tier: l2_distance='$l2'" }

    # cosine_distance had no caller at all before this: every other
    # gate only ever exercises its sibling cosine_similarity.
    $cd = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_cosine_distance('[1,0,0]', '[1,0,0]');" 2>&1
    if ($cd -eq "0") { Pass "22 vector_tier: cosine_distance(identical)=0" } else { Fail "22 vector_tier: cosine_distance='$cd'" }
    $cdNull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_cosine_distance(NULL, '[1,0,0]');" 2>&1
    if ($cdNull -eq "NULL") { Pass "22 vector_tier: cosine_distance(NULL, ...) -> NULL" } else { Fail "22 vector_tier: expected NULL, got: $cdNull" }

    $f8f = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_from_float8_array('[1,2,3]');" 2>&1
    if ($f8f -match '^\[1,2,3\]$') { Pass "22 vector_tier: from_float8_array canonicalizes [1,2,3]" } else { Fail "22 vector_tier: from_float8_array='$f8f'" }
    $f8t = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_to_float8_array('[1,2,3]');" 2>&1
    if ($f8t -match '^\[1,2,3\]$') { Pass "22 vector_tier: to_float8_array canonicalizes [1,2,3]" } else { Fail "22 vector_tier: to_float8_array='$f8t'" }

    # A UDF error message is never EMPTY. The shim's three err buffers
    # are initialised and fsq_set_msg() falls back to a generic message
    # when the buffer has nothing in it, so a failing UDF must always
    # say SOMETHING to the client -- an empty error is the failure mode
    # this assertion exists to catch. The wrong-argument-count call is
    # the one that fails in _init, which is the path that carries a
    # message.
    $badInit = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_vector_add('[1,2,3]');" 2>&1) -join ' '
    if ($badInit -match "(?i)argument") { Pass "22 vector_tier: a UDF error message is never empty (it names the argument problem)" } else { Fail "22 vector_tier: expected a non-empty UDF error message naming the argument problem, got: '$badInit'" }
}

function Gate-23-Cognition {
    $r = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1
    if ($r -match "(?i)sql") { Pass "23 cognition: fractal_reason returned the mock's reply" } else { Fail "23 cognition: fractal_reason='$r'" }

    $rnull = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), NULL);" 2>&1
    if ($rnull -eq "NULL") { Pass "23 cognition: NULL query -> NULL result" } else { Fail "23 cognition: expected NULL, got: $rnull" }

    # fractal_t2s_review's PASS/FAIL branches had no coverage in this
    # harness (the POSIX twin covers them in build_test.sh's gate 23).
    # The mock LLM routes on a marker embedded in the question, which
    # lands verbatim in the review prompt: the marker routes the reply
    # to a "PASS, ..." text, and a review that sees a PASS returns NULL
    # (the NULL-means-pass convention).
    $revFail = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1'), '<NULL>');" 2>&1
    if ("$revFail" -ne "<NULL>") { Pass "23 cognition: t2s_review returns the critique text on a non-PASS reply" }
    else { Fail "23 cognition: expected the critique text on a non-PASS reply, got: $revFail" }

    $revPass = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'FRACTALSQL_BT_REVIEW_PASS_MARKER', 'SELECT 1'), '<NULL>');" 2>&1
    if ("$revPass" -eq "<NULL>") { Pass "23 cognition: t2s_review returns NULL (PASS) on a passing reply" }
    else { Fail "23 cognition: expected NULL (PASS), got: $revPass" }

    # The review PROMPT must not be truncated. It used to be assembled
    # in a fixed 8 KiB stack buffer, and a longer question was cut
    # mid-statement with the truncation never detected and never
    # reported: the model then graded a question the caller never sent
    # -- and that PASS/FAIL verdict IS this function's return value,
    # which feeds straight back into the next GENERATE attempt as
    # retry feedback. The marker sits at the END of a 9 KiB question:
    # cut at 8 KiB it never reaches the mock, the mock answers with
    # its default (not a PASS), and the review returns the critique
    # text instead of NULL.
    $longQ = ("A" * 9000) + "FRACTALSQL_BT_REVIEW_PASS_MARKER"
    $revLong = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), '$longQ', 'SELECT 1'), '<NULL>');" 2>&1
    if ("$revLong" -eq "<NULL>") { Pass "23 cognition: a 9 KiB question reaches the model in full (the review prompt is not truncated)" }
    else { Fail "23 cognition: a 9 KiB question was truncated before the model saw it (expected NULL, got: $revLong)" }
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

    # --- S-FT-004 partial-result honesty (opt-in agent_partial mode) ----
    # Same pair build_test.sh's gate_24 gained: with the flag OFF (the
    # documented default) a dead reasoning endpoint keeps the data half
    # (dfa_exponent) with a NULL rationale and NO reasoning_step_failed
    # detail; with the flag ON the same call adds the detail. The
    # endpoint is repointed via the daemon conf's reasoning_url key +
    # reload_probe_w's OP_RELOAD frame (Gate-34-ReasoningConfLive's own
    # client, Build-ReloadProbe), so no restart is involved; the conf is
    # restored and reloaded before this gate returns.
    $mockUrl = $env:FRACTALSQL_HTTP_URL
    if (-not $mockUrl) {
        Fail "24 agents: FRACTALSQL_HTTP_URL not set (Mdb-Setup missing?)"
        return
    }
    $probe = Build-ReloadProbe
    if (-not $probe) {
        Skip "24 agents: partial pair (no clang-cl.exe to build reload_probe_w)"
        return
    }
    $py = Get-PythonExe
    if (-not $py) {
        Skip "24 agents: partial pair (no python found to generate the synthetic series)"
        Remove-Item -Force $probe -ErrorAction SilentlyContinue
        return
    }
    $series = & $py -c "import json; print(json.dumps([round(0.1*i + (0.02 if i == 37 else 0.0), 6) for i in range(100)], separators=(',',':')))"

    function Invoke-ReloadProbe24 {
        $r = & $probe $script:FsqdPipe $script:FsqdKey 2>&1
        return ($r -join "`n")
    }

    $confBackup = "$($script:FsqdConf).g24"
    Copy-Item $script:FsqdConf $confBackup -Force
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "reasoning_url = http://127.0.0.1:1/v1/chat/completions"
    $rd = Invoke-ReloadProbe24
    if ($rd -match 'reloaded') {
        # (a) flag OFF = default: data half, NULL rationale, no partial
        # detail. ONE client invocation per case: the flag/sentinel are
        # session-scoped (fractal_session keyed by CONNECTION_ID()) and
        # every Invoke-Mariadb run is a fresh TCP connection.
        $ra = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
CALL fractal_agent_regime_triage('$series', NULL, NULL, NULL, @ra);
SELECT @ra;
"@ 2>&1
        $raJoined = ($ra -join "`n")
        if (($raJoined -match '"dfa_exponent":\s*"?-?[0-9]') -and
            ($raJoined -match '"rationale":\s*null') -and
            ($raJoined -match '"reasoning_step_failed":\s*null')) {
            Pass "24 agents: partial mode off (default) keeps the data half with no reasoning_step_failed detail"
        } else {
            Fail "24 agents: flag-off default case broken: $raJoined"
        }

        # (b) flag ON: same dead endpoint, opt in on the SAME connection
        # (one invocation), then the doc gains reasoning_step_failed with
        # the plugin's detail while the data half stays intact.
        $rb = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e @"
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'on');
CALL fractal_agent_regime_triage('$series', NULL, NULL, NULL, @rb);
SELECT @rb;
"@ 2>&1
        $rbJoined = ($rb -join "`n")
        if (($rbJoined -match '(?m)^on\s*$') -and
            ($rbJoined -match '"dfa_exponent":\s*"?-?[0-9]') -and
            ($rbJoined -match '"reasoning_step_failed":\s*"') -and
            ($rbJoined -match 'fractal_reason: (dispatch failed|failed to load reasoning plugin)') -and
            ($rbJoined -match '"rationale":\s*null')) {
            Pass "24 agents: partial mode on returns the data half plus reasoning_step_failed (sentinel split)"
        } else {
            Fail "24 agents: expected the partial document, got: $rbJoined"
        }

        # The client-visible detail is BOUNDED. The reasoning plugin's
        # own diagnostic is embedded in the agent document verbatim, so
        # the sentinel caps it (and says so when it has to cut). An
        # uncapped detail would let one plugin error fill the whole
        # document. The value is picked out as a JSON string literal
        # (escapes included) and then DECODED, so the length checked is
        # what the client actually reads -- not the raw wire form, and
        # not a greedy run to the last quote on the line (which would
        # also swallow whatever keys follow it in the document).
        $dm = [regex]::Match($rbJoined, '"reasoning_step_failed"\s*:\s*("(?:[^"\\]|\\.)*")')
        $dlen = -1
        if ($dm.Success) {
            try { $dlen = ($dm.Groups[1].Value | ConvertFrom-Json).Length } catch { $dlen = -1 }
        }
        if ($dlen -ge 0 -and $dlen -le 512) {
            Pass "24 agents: the client-visible failure detail is bounded ($dlen chars)"
        } else {
            Fail "24 agents: the client-visible failure detail is unbounded: $rbJoined"
        }

        # The sentinel leaks nowhere else: a fresh session without the
        # opt-in still gets the plain failure NULL (not the sentinel).
        $rr = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_reason(CONNECTION_ID(), 'ping'), '<NULL>');" 2>&1
        if (($rr -join "").Trim() -eq "<NULL>") {
            Pass "24 agents: fresh session without the opt-in still gets the plain failure NULL"
        } else {
            Fail "24 agents: expected a bare NULL from fractal_reason off-session, got: $rr"
        }
    } else {
        Fail "24 agents: dead reasoning_url reload failed: '$rd'"
    }

    # Restore the live mock provider for any later reasoning case.
    Copy-Item $confBackup $script:FsqdConf -Force
    Remove-Item -Force $confBackup -ErrorAction SilentlyContinue
    $rd = Invoke-ReloadProbe24
    $rr2 = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1
    if ($rd -match 'reloaded' -and (($rr2 -join "").Trim() -ne "NULL") -and (($rr2 -join "").Trim() -ne "")) {
        Pass "24 agents: mock reasoning provider restored after the partial pair"
    } else {
        Fail "24 agents: mock reasoning provider NOT restored: reload='$rd' reply='$($rr2 -join ' ')'"
    }
    Remove-Item -Force $probe -ErrorAction SilentlyContinue
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

    # A power value large enough to need 300+ characters in "%.10f".
    # The emitters used to size their per-number buffer at 40 bytes, so
    # the snprintf truncated and the whole UDF refused (a truncated
    # snprintf is a hard error here, not a rounded value) -- the
    # spectrum of a legitimately huge series was a bare NULL. The
    # buffers are now sized for the worst case a finite double can
    # print at, so the answer comes back.
    $pgBig = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_periodogram('1e150,1e150,1e150,1e150', 2);" 2>&1
    $pgBigJoined = ($pgBig -join "`n")
    if ($pgBigJoined -match '"freqs"\s*:\s*\[' -and $pgBigJoined -match '"power"\s*:\s*\[') {
        Pass "32 new_primitives: periodogram of a 1e150-magnitude series returns a full result (the power values need 300+ characters)"
    } else {
        Fail "32 new_primitives: periodogram of a 1e150-magnitude series='$pgBigJoined' (expected a freqs/power result)"
    }

    # fractal_spectrogram_entropy: a pure tone (ordered, low entropy) vs
    # LCG noise (disordered, high entropy). The series are generated here
    # so no fixture file is needed; the JSON array is parsed with python
    # (no JSON_TABLE, which older server versions in the matrix lack).
    # Output is a BARE array of per-frame entropy in [0,1].
    $seNoise = (& $py -c "x = 12345; out = []
for _ in range(128):
    x = (x * 1103515245 + 12345) % 2147483648
    out.append(str((x // 65536) % 1000))
print(','.join(out))") -join ''
    $seTone = (& $py -c "print(','.join(str([1,0,-1,0][i % 4]) for i in range(128)))") -join ''
    $seMix = (& $py -c "x = 12345; out = []
for i in range(128):
    x = (x * 1103515245 + 12345) % 2147483648
    out.append(str([1,0,-1,0][i % 4]) if i < 64 else str((x // 65536) % 1000))
print(','.join(out))") -join ''
    $seQuery = { param($sql) (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $sql 2>&1) -join '' }
    $seT = (& $seQuery "SELECT fractal_spectrogram_entropy('$seTone', 32, 16);").Trim()
    $seTOk = & $py -c "import json,sys; v = json.loads(sys.argv[1]); sys.exit(0 if len(v) == 7 and all(0.0 <= e <= 1.0 for e in v) and max(v) < 0.5 else 1)" $seT 2>$null
    if ($LASTEXITCODE -eq 0) { Pass "32 new_primitives: spectrogram_entropy reads a pure tone as ordered (7 frames, all < 0.5)" } else { Fail "32 new_primitives: spectrogram_entropy tone='$seT' (expected 7 frames in [0,0.5))" }
    $seN = (& $seQuery "SELECT fractal_spectrogram_entropy('$seNoise', 32, 32);").Trim()
    $seNOk = & $py -c "import json,sys; v = json.loads(sys.argv[1]); sys.exit(0 if len(v) == 4 and max(v) <= 1.0 and sum(v) / len(v) > 0.7 else 1)" $seN 2>$null
    if ($LASTEXITCODE -eq 0) { Pass "32 new_primitives: spectrogram_entropy reads noise as disordered (mean > 0.7, <= 1)" } else { Fail "32 new_primitives: spectrogram_entropy noise='$seN' (expected 4 frames, mean > 0.7)" }
    $seC = (& $seQuery "SELECT fractal_spectrogram_entropy('2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2', 8, 8);").Trim()
    if ($seC -eq '[0.0000000000,0.0000000000]') { Pass "32 new_primitives: spectrogram_entropy reports a constant frame as 0.0, not NaN" } else { Fail "32 new_primitives: spectrogram_entropy constant frame='$seC'" }
    $seM = (& $seQuery "SELECT JSON_LENGTH(fractal_spectrogram_entropy('$seTone', 32, 16, 2));").Trim()
    if ($seM -eq '2') { Pass "32 new_primitives: spectrogram_entropy honours max_frames" } else { Fail "32 new_primitives: spectrogram_entropy max_frames length='$seM' (expected 2)" }
    $seNull = (& $seQuery "SELECT fractal_spectrogram_entropy(NULL, 8);").Trim()
    if ($seNull -eq 'NULL') { Pass "32 new_primitives: spectrogram_entropy(NULL) is NULL" } else { Fail "32 new_primitives: spectrogram_entropy(NULL)='$seNull'" }
    # Same empirical contract as change_point_detect above: a UDF whose
    # main function sets *error surfaces as a NULL result. Every
    # out-of-range argument must be refused that way, never crash or
    # return a short array.
    foreach ($seCase in @(
            @('window < 8', "'$seTone', 4"),
            @('window > 512', "'$seTone', 600"),
            @('hop < 1', "'$seTone', 16, 0"),
            @('max_frames < 1', "'$seTone', 16, 8, 0"),
            @('max_frames > 4096', "'$seTone', 16, 8, 5000"),
            @('a series shorter than the window', "'1,2,3', 8"),
            @('a malformed series', "'bad!vec', 8"))) {
        $seBad = (& $seQuery "SELECT fractal_spectrogram_entropy($($seCase[1]));").Trim()
        if ($seBad -eq 'NULL') { Pass "32 new_primitives: spectrogram_entropy rejects $($seCase[0]) (NULL)" } else { Fail "32 new_primitives: spectrogram_entropy $($seCase[0]) expected NULL, got: $seBad" }
    }
    # Composition: 64 tone samples then 64 noise samples -> the entropy
    # series steps up and change_point_detect localizes it from the bare
    # array (the function's output feeds the next function directly).
    $seCp = (& $seQuery "SELECT fractal_change_point_detect(fractal_spectrogram_entropy('$seMix', 16, 8), 3, 1.0, 16);").Trim()
    if ($seCp -match '[0-9]' -and $seCp -notmatch 'NULL') { Pass "32 new_primitives: spectrogram_entropy -> change_point_detect localizes a regime change ($seCp)" } else { Fail "32 new_primitives: spectrogram_entropy regime change='$seCp'" }

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

    # A filtration scale large enough that the death value needs 150+
    # characters in "%.10f". The bar emitter used to size its buffer at
    # 128 bytes for TWO numbers plus their keys, so this truncated and
    # the whole UDF refused (a truncated snprintf is a hard error here)
    # -- the barcode of a legitimately huge-scale filtration was a bare
    # NULL. The buffer is now sized for the worst case a finite double
    # can print at.
    $tdaBig = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_tda_persistence_diagram('0,0,0,0,1e150,0,1e150,0', 2, 1, 1e151, 64);" 2>&1
    $tdaBigJoined = ($tdaBig -join "`n")
    if ($tdaBigJoined -match '"h0_bars"\s*:\s*\[' -and $tdaBigJoined -match '"death"') {
        Pass "32 new_primitives: tda_persistence_diagram of a 1e150-scale filtration returns a full barcode (the death values need 150+ characters)"
    } else {
        Fail "32 new_primitives: tda_persistence_diagram of a 1e150-scale filtration='$tdaBigJoined' (expected an h0_bars barcode)"
    }

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

    # --- argument-count and size caps on the reasoning-tier surface.
    # MariaDB's UDF ABI reports a bad argument count at INIT time
    # (fractal_reason_init's own arg_count check), which the server
    # surfaces as an ERROR on the CALL, not as a NULL result -- so these
    # assert on the error text, not on a NULL.
    $rArity0 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason();" 2>&1) -join "`n"
    if ($rArity0 -match "(?i)expected 2 or 3") { Pass "32 new_primitives: fractal_reason() with zero arguments is rejected" } else { Fail "32 new_primitives: expected fractal_reason() to reject zero arguments, got: $rArity0" }
    $rArity3 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q', 'ctx', 'extra');" 2>&1) -join "`n"
    if ($rArity3 -match "(?i)expected 2 or 3") { Pass "32 new_primitives: fractal_reason with four arguments is rejected" } else { Fail "32 new_primitives: expected fractal_reason to reject four arguments, got: $rArity3" }

    # fractal_t2s_generate's input cap (FRACTAL_T2S_MAX_INPUT_BYTES in
    # src/fractalsql_textsql.c, 4 MiB). A caller-controlled prompt
    # string that drives an allocation and an outbound request body
    # needs a cap; REPEAT() builds the over-cap value without the test
    # carrying 4 MiB of literal text.
    #
    # The cap is enforced in the UDF BODY (fractalsql_textsql.c's
    # `args->lengths[1] > FRACTAL_T2S_MAX_INPUT_BYTES` check, which
    # sets *error and returns NULL) -- NOT in the init function, which
    # takes no message. So it does NOT surface as an ERROR on the CALL
    # the way the arity check above does: it surfaces as a silent NULL
    # result, exactly like the change_point_detect and
    # hamming_distance rejections above. That is the same *error -> NULL
    # contract, and the assertion has to match it. (The daemon's own
    # log confirms the rejection happened: "fractal_t2s_generate:
    # adapter reported an error for this call".)
    $rT2sBig = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_generate(CONNECTION_ID(), REPEAT('x', 4194305), '{}', 'mariadb114'), '<NULL>');" 2>&1) -join "`n"
    if ($rT2sBig.Trim() -eq "<NULL>") { Pass "32 new_primitives: text_to_sql's generate step rejects a prompt over the 4 MiB cap" } else { Fail "32 new_primitives: expected an over-cap prompt to be rejected, got: $rT2sBig" }

    # fractal_vectorizer_process_queue's batch size. MariaDB's procedure
    # takes the batch size as a plain INT and applies it as a LIMIT in
    # the claim UPDATE, so an absurd value is not a crash but it IS an
    # unbounded single-transaction claim -- the queue's whole backlog in
    # one statement. This asserts the call is bounded rather than
    # rejected: MariaDB has no FSQLV_MAX_BATCH cap of its own, so the
    # honest assertion is that the call completes and processes a
    # bounded number of rows, and that the negative case (batch size 0)
    # processes nothing at all.
    $rBq0 = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "CALL fractal_vectorizer_process_queue(0, 600); SELECT COUNT(*) FROM fractal_vectorizer_queue WHERE status = 'processing';" 2>&1) -join "`n"
    if ($rBq0.Trim() -match "(?m)^0$") { Pass "32 new_primitives: process_queue with batch size 0 claims no rows" } else { Fail "32 new_primitives: expected process_queue(0) to claim nothing, got: $rBq0" }
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

# The ledger's FULL-CHAIN verification -- build_test.sh's gate 47.
#
# WHAT THIS PROVES:
#   fractal_ledger_verify(session_id, kind) walks the WHOLE chain, not
#   just the tip. Gate 26's tamper test flips a byte in the LAST record,
#   which a tip-only check would also catch -- so it cannot tell the two
#   apart. This gate builds a THREE-record chain, tampers the MIDDLE
#   record (leaving the tip intact), and requires the verifier to name
#   the middle record (first_failure_id = 2).
#
#   A tip-only implementation would report ok:true here, because the tip
#   itself is untouched and self-consistent.
#
# WHY THE FIXTURE IS BUILT HERE AND NOT BY THE PRODUCT:
#   The only SQL-reachable writer for the kind=2 decision-audit chain is
#   fractal_audit_log, and that UDF is gated behind the licensed
#   enterprise library, which this public repo does not ship -- a gate
#   that used it would SKIP everywhere. The on-disk format is documented
#   in src\fractalsql_enterprise.c, and the WRITE side is already covered
#   by gate 26 (flush -> verify round trip against the product's own
#   writer). What is under test here is the verifier's chain walk.
#
#   tests\ledger_chain_tool.py builds and tampers the fixture, so this
#   harness and build_test.sh share ONE definition of the format.
function Gate-47-LedgerChain {
    $py = Get-PythonExe
    if (-not $py) { Skip "47 ledger_chain: no python found to build the fixture chain"; return }

    $ledgerPath = "$Here\.gate47_ledger.dat"
    $tool = "$Here\tests\ledger_chain_tool.py"
    Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue

    # The ledger path is read by the DAEMON -- every UDF body runs there
    # -- and the enterprise code snapshots its environment ONCE per
    # process, so the variable has to be in place BEFORE the daemon
    # starts. Same restart-based env swap gate 26 uses.
    Mdb-Teardown
    $env:FRACTALSQL_ENTERPRISE_LEDGER_PATH = $ledgerPath
    $rc = Mdb-Setup $MdbMajor
    if ($rc -ne 0) {
        Remove-Item Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
        Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue
        Fail "47 ledger_chain: restart with FRACTALSQL_ENTERPRISE_LEDGER_PATH set failed (rc=$rc)"
        Mdb-Setup $MdbMajor | Out-Null
        return
    }

    # The chain is written AFTER the daemon started on purpose: the
    # verifier reads the file per call, so the content does not need a
    # second restart.
    & $py $tool build $ledgerPath 3 | Out-Null
    if (-not (Test-Path $ledgerPath) -or (Get-Item $ledgerPath).Length -eq 0) {
        Fail "47 ledger_chain: the fixture chain was not written"
        Remove-Item Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
        Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue
        Mdb-Teardown
        Mdb-Setup $MdbMajor | Out-Null
        return
    }

    $v = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1 | Out-String).Trim()
    if ($v -eq '{"ok":true,"rows_verified":3}') {
        Pass "47 ledger_chain: a three-record chain verifies clean (the walk reaches back to the genesis record)"
    } else {
        Fail "47 ledger_chain: expected a clean 3-row verify report, got: $v"
    }

    # Tamper the MIDDLE record; the tip stays intact.
    & $py $tool tamper $ledgerPath 1 | Out-Null
    $v = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1 | Out-String).Trim()
    if ($v -like '{"ok":false,"first_failure_id":2,*') {
        Pass "47 ledger_chain: a tampered MIDDLE record is detected (first_failure_id=2 -- not the tip)"
    } else {
        Fail "47 ledger_chain: expected the mid-chain tamper to be reported at row 2, got: $v"
    }

    Remove-Item Env:\FRACTALSQL_ENTERPRISE_LEDGER_PATH -ErrorAction SilentlyContinue
    Remove-Item $ledgerPath, "$ledgerPath.csv" -ErrorAction SilentlyContinue
    Mdb-Teardown
    Mdb-Setup $MdbMajor | Out-Null
}

# Gate 48: the text-to-SQL tier's REVIEW isolation.
#
# The engine's four reasoning tiers -- reason, embed, text-to-SQL
# generate and text-to-SQL review -- are four SEPARATE ctx slots
# (src\fractalsql_session.c's g_tier_ctx[]), and the reasoning VFS ABI
# has NO per-dispatch override for the response mode: a plugin reads
# FSQL_REASONING_HTTP_RESPONSE_MODE once, in fsql_reasoning_init, and
# bakes it into that instance for its whole lifetime. The review tier
# therefore has to be born with NO response mode at all: if it shared
# the reason ctx, the operator's own fractal_reason() setting would
# silently apply to review as well, and a code-mode extractor would
# pull a quoted SQL fragment out of review's PASS/FAIL verdict
# instead of the verdict text (apply_review_env_locked's own comment
# records that rationale).
#
# tests\review_mode_reasoning_plugin.c captures the mode at INIT time
# -- the instant it is baked into that ctx's instance -- into a
# per-instance struct hung off vfs->user_ctx, and echoes it back from
# generate(). The core's loader calls fsql_reasoning_init once per ctx
# load (it hands the plugin a stack-local vfs), so each tier reports
# the mode that was in the environment at ITS OWN load. On Windows the
# fixture reads the environment with GetEnvironmentVariableA, not
# getenv: a /MT DLL's private environ is frozen at ITS load time, so
# a getenv() read would never see the tier-scoped setenv/unsetenv
# calls the daemon makes later in the same process.
#
# The three calls are made SEPARATELY, in this order, because the
# order is part of what is being proven: the reason tier is loaded
# first, so a review tier that had wrongly shared the reason ctx would
# report the reason tier's baked value instead of its own.
function Gate-48-T2SReviewIsolation {
    # The operator's own response mode. The reason tier must report
    # it; the review tier must NOT -- that is the whole point.
    $env:FSQL_REASONING_HTTP_RESPONSE_MODE = "operator"

    $rc = Swap-ReasoningPlugin $script:ReviewModeSo
    if ($rc -ne 0) {
        Fail "48 t2s_review_isolation: plugin swap did not take effect"
        Remove-Item Env:\FSQL_REASONING_HTTP_RESPONSE_MODE -ErrorAction SilentlyContinue
        Restore-ReasoningPlugin
        return
    }

    # (1) the reason tier: the operator's own mode, baked into the
    # reason ctx's plugin instance.
    $r = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1 | Out-String)
    if ($r -like "*FSQL_MODE=operator*") {
        Pass "48 t2s_review_isolation: the reason tier keeps the operator's RESPONSE_MODE"
    } else {
        Fail "48 t2s_review_isolation: the reason tier did not report the operator's RESPONSE_MODE: $r"
    }

    # (2) the generate tier: its own ctx, RESPONSE_MODE=code
    # (apply_generate_env_locked forces it, whatever the operator set).
    $g = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT fractal_t2s_generate(CONNECTION_ID(), 'q', '{}', 'gate48');" 2>&1 | Out-String)
    if ($g -like "*FSQL_MODE=code*") {
        Pass "48 t2s_review_isolation: the generate tier's own ctx carries RESPONSE_MODE=code"
    } else {
        Fail "48 t2s_review_isolation: the generate tier did not report RESPONSE_MODE=code: $g"
    }

    # (3) the review tier: its own ctx, RESPONSE_MODE unset -- NOT the
    # operator's value and NOT code. The verdict text is the fixture's
    # own "FSQL_MODE=..." line (a review response starting with "pass"
    # would be swallowed as a PASS verdict), so it is read back
    # through IFNULL.
    $v = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1'), '<NULL>');" 2>&1 | Out-String)
    if ($v -like "*FSQL_MODE=(unset)*") {
        Pass "48 t2s_review_isolation: the review tier's own ctx has RESPONSE_MODE unset (not the operator's, not code)"
    } else {
        Fail "48 t2s_review_isolation: the review tier inherited a RESPONSE_MODE it must not have: $v"
    }

    # (4) the three tiers really are three DIFFERENT plugin instances:
    # each ctx load calls fsql_reasoning_init once, so the ordinals
    # must differ. Identical ordinals would mean one instance is
    # shared -- the very failure mode this gate exists to catch.
    $ri = if ($r -match 'FSQL_INSTANCE=(-?\d+)') { $Matches[1] } else { "" }
    $gi = if ($g -match 'FSQL_INSTANCE=(-?\d+)') { $Matches[1] } else { "" }
    $vi = if ($v -match 'FSQL_INSTANCE=(-?\d+)') { $Matches[1] } else { "" }
    if ($ri -ne "" -and $gi -ne "" -and $vi -ne "" -and $ri -ne $gi -and $ri -ne $vi -and $gi -ne $vi) {
        Pass "48 t2s_review_isolation: the three tiers run on three DISTINCT plugin instances (reason=$ri generate=$gi review=$vi)"
    } else {
        Fail "48 t2s_review_isolation: the tiers are not on distinct plugin instances (reason=$ri generate=$gi review=$vi)"
    }

    # Restore-ReasoningPlugin already clears FSQL_REASONING_HTTP_RESPONSE_MODE
    # (a leftover "operator" would ride every later daemon boot's env).
    Restore-ReasoningPlugin
}

# Gate 49: the per-session configuration overlay, the canonical vector
# form, and the search's convergence view.
#
# These three groups are the SQL half of the surface the MCP's admin
# tools sit on: the overlay is what fractalsql_session_config_* reads
# and writes, the canonical vector form is what the vector tools carry
# between calls, and fractal_search_debug is the convergence view the
# search tool exposes. The MCP's own half of that contract is proven
# by gate 39; this gate proves the ENGINE's half, so a failure here
# names the engine rather than the plugin.
#
# The overlay is keyed by a session id the CALLER passes, and every
# statement in one mariadb client run shares one connection id, so the
# set/get/list round trip below runs as ONE multi-statement call: a
# second client run would be a second connection, and a second
# connection id, and would see none of the first one's overrides.
# Gate 50: the twenty-nine newer industry kits (demo/demo-vertical-*.sql).
# Each kit is run end to end through the scratch cluster's client (agents
# installed, the mock LLM answering the reasoned steps) and must (a) exist,
# (b) raise no SQL error beyond the documented exception (the scenario-
# planning kit's plan_explore call needs an embedding endpoint the cluster
# may not have: at most one error), (c) print no NaN, and (d) reproduce its
# headline result -- the fixtures are deterministic (no RAND()), so the
# claim is checked against fixed numbers.
function KitNum { param([string]$S)
    $d = 0.0
    if ([double]::TryParse($S, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return [double]::NaN
}

# KitShape: the 13 original kits print no HEADLINE line and seed random numbers, so only the SHAPE of
# their output is pinned: the count of lines that are neither errors nor blank. A step that silently
# returns no rows drops them. Callers require three quarters of what a clean run prints.
function KitShape($lines) {
    return @($lines | Where-Object { $_ -notmatch '^(ERROR |\s*$)' }).Count
}

function Gate-50-Kits {
    $demoDir = Join-Path $Here 'demo'
    if (-not (Test-Path -LiteralPath $demoDir)) {
        Skip '50 kits (demo/ not present)'
        return
    }
    $kits = @('ev-battery-lifecycle', 'adas-safety-validation', 'v2x-warranty-triage',
              'critical-inventory-routing', 'heavy-industry-predictive-maintenance',
              'climatech-grid-balancing', 'hazmat-occupational-triage',
              'scenario-planning-simulation', 'avionics-fault-prediction',
              'satellite-constellation-coverage', 'telecom-account-anomaly-screening',
              'telecom-traffic-routing', 'climatech-emissions-monitoring',
              'climatech-risk-exposure', 'rf-spectrum-sensing',
              'event-stream-anomaly-triage', 'outlier-interception-footprint',
              'agentic-budget-reallocation', 'stalled-process-triage',
              'intent-matching-discovery', 'agentic-next-action-ranking',
              'document-risk-drift', 'coordinated-record-detection',
              'sensor-telemetry-allocation', 'simulated-economy-drift',
              'multi-series-replenishment', 'periodicity-portfolio-selection',
              'agentic-recall-recommendation', 'spatial-footprint-portfolio-risk',
              'agentic-customer-support', 'agentic-edge-swarm',
              'agentic-fintech-mcts', 'agentic-ops-devops',
              'biotech-genomics', 'cybersecurity-threat-detection',
              'fleet-logistics', 'maritime-defense', 'medtech-clinical',
              'quant-finance', 'recommendation-search', 'smart-cities-iot',
              'sovereign-edge-ai')
    foreach ($k in $kits) {
        $kit = Join-Path $demoDir "demo-vertical-$k.sql"
        if (-not (Test-Path -LiteralPath $kit)) { Fail "50 kits: demo-vertical-$k.sql is missing"; continue }
        $kitSrc = $kit -replace '\\', '/'
        $raw = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N --force -e "source $kitSrc" 2>&1
        $out = ($raw | ForEach-Object { "$_" }) -join "`n"
        $lines = @($out -split "`r?`n" | ForEach-Object { $_ -replace "`t", '|' })
        $nerr = @($lines | Where-Object { $_ -match '^ERROR ' }).Count
        $maxerr = 0
        if ($k -eq 'scenario-planning-simulation') { $maxerr = 1 }
        if ($k -eq 'periodicity-portfolio-selection') { $maxerr = 1 }
        if ($k -eq 'agentic-fintech-mcts') { $maxerr = 1 }
        if ($k -eq 'agentic-ops-devops') { $maxerr = 2 }
        if ($nerr -gt $maxerr) {
            $first = (@($lines | Where-Object { $_ -match '^ERROR ' }) | Select-Object -First 2) -join ' '
            Fail "50 kits: $k raised $nerr SQL error(s), at most ${maxerr} expected: $first"
            continue
        }
        if (@($lines | Where-Object { $_ -match '(^|\|)-?(nan|NaN|inf)(\||$)' }).Count -gt 0) { Fail "50 kits: $k printed a NaN/inf cell"; continue }
        $text = $lines -join "`n"
        $rows = @($lines | ForEach-Object { ,($_ -split '\|') })
        $ok = $false
        switch ($k) {
            { $_ -in @('event-stream-anomaly-triage', 'outlier-interception-footprint', 'agentic-budget-reallocation', 'stalled-process-triage', 'intent-matching-discovery', 'agentic-next-action-ranking', 'document-risk-drift', 'coordinated-record-detection', 'sensor-telemetry-allocation', 'simulated-economy-drift', 'multi-series-replenishment', 'periodicity-portfolio-selection', 'agentic-recall-recommendation', 'spatial-footprint-portfolio-risk') } {
                $ok = [bool]($text -match ("HEADLINE kit=" + $k + " ok")) }
            'agentic-customer-support' { $ok = (KitShape $lines) -ge 13 }
            'agentic-edge-swarm' { $ok = (KitShape $lines) -ge 12 }
            'agentic-fintech-mcts' { $ok = (KitShape $lines) -ge 5 }
            'agentic-ops-devops' { $ok = (KitShape $lines) -ge 6 }
            'biotech-genomics' { $ok = (KitShape $lines) -ge 6 }
            'cybersecurity-threat-detection' { $ok = (KitShape $lines) -ge 15 }
            'fleet-logistics' { $ok = (KitShape $lines) -ge 10 }
            'maritime-defense' { $ok = (KitShape $lines) -ge 11 }
            'medtech-clinical' { $ok = (KitShape $lines) -ge 3 }
            'quant-finance' { $ok = (KitShape $lines) -ge 3 }
            'recommendation-search' { $ok = (KitShape $lines) -ge 15 }
            'smart-cities-iot' { $ok = (KitShape $lines) -ge 8 }
            'sovereign-edge-ai' { $ok = (KitShape $lines) -ge 8 }
            'ev-battery-lifecycle' {
                $a = @($rows | Where-Object { $_[0] -eq 'EV-203' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'EV-101' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 -and (KitNum $_[2]) -lt 1 }).Count -gt 0
                $ok = $a -and $b }
            'adas-safety-validation' {
                $a = @($rows | Where-Object { $_[0] -like 'P1 firm*' -and $_.Count -eq 4 -and $_[3] -eq '1' }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -like 'P2 steady*' -and $_.Count -eq 4 -and $_[3] -eq '0' }).Count -gt 0
                $c = @($rows | Where-Object { $_[0] -like 'P3 gentle*' -and $_.Count -eq 4 -and $_[3] -eq '1' }).Count -gt 0
                $ok = $a -and $b -and $c }
            'v2x-warranty-triage' { $ok = $text -match '(?m)^battery-thermal-service\|0\.99' }
            'critical-inventory-routing' {
                $ok = @($rows | Where-Object { $_[0] -eq '4' -and $_.Count -ge 5 -and $_[1] -eq 'west' -and (KitNum $_[4]) -gt 1.2 }).Count -gt 0 }
            'heavy-industry-predictive-maintenance' {
                $a = @($rows | Where-Object { $_[0] -eq 'PUMP-07' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'PUMP-03' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'climatech-grid-balancing' {
                $a = @($rows | Where-Object { $_[0] -eq 'AREA-C' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.2 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'AREA-A' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'hazmat-occupational-triage' {
                $n = @($rows | Where-Object { @('7', '15', '31') -contains $_[0] -and $_.Count -eq 4 -and $_[1] -eq 'reactor-bay' -and $_[2] -eq 'night' -and (KitNum $_[3]) -lt 0.001 }).Count
                $ok = $n -ge 3 }
            'scenario-planning-simulation' {
                $ok = @($lines | Where-Object { $_ -match 'variant' }).Count -ge 6 }
            'avionics-fault-prediction' { $ok = $text -match '(?m)^AC-09\|0\.2' }
            'satellite-constellation-coverage' {
                $h = @($rows | Where-Object { $_[0] -eq 'healthy' -and $_.Count -eq 3 } | Select-Object -First 1)
                $d = @($rows | Where-Object { $_[0] -eq 'degraded' -and $_.Count -eq 3 } | Select-Object -First 1)
                $ok = ($h.Count -eq 1) -and ($d.Count -eq 1) -and ((KitNum $h[0][2]) -gt 0) -and ((KitNum $d[0][2]) -gt (KitNum $h[0][2])) }
            'telecom-account-anomaly-screening' {
                $a = @($rows | Where-Object { $_[0] -like 'E1 swap*' -and $_.Count -eq 4 -and $_[3] -eq '1' }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -like 'E2 routine*' -and $_.Count -eq 4 -and $_[3] -eq '0' }).Count -gt 0
                $c = @($rows | Where-Object { $_[0] -like 'E4 faint*' -and $_.Count -eq 4 -and $_[3] -eq '1' }).Count -gt 0
                $ok = $a -and $b -and $c }
            'telecom-traffic-routing' {
                $ok = ($text -match '(?m)^R3 mobile handover burst\|edge-mobile-hub\|') -and ($text -match '(?m)^R3 mobile handover burst\|edge-backup-west\s*$') }
            'climatech-emissions-monitoring' {
                $a = @($rows | Where-Object { $_[0] -eq 'CH4-02' -and $_.Count -eq 4 -and (KitNum $_[1]) -gt 0.5 -and (KitNum $_[2]) -gt 1.5 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'CH4-01' -and $_.Count -eq 4 -and (KitNum $_[1]) -lt 0 }).Count -gt 0
                $ok = $a -and $b }
            'climatech-risk-exposure' {
                $a = @($rows | Where-Object { $_[0] -eq 'dry season' -and $_.Count -eq 3 }).Count -gt 0
                $b = @($rows | Where-Object { $_[0] -eq 'wet season' -and $_.Count -eq 3 }).Count -gt 0
                $ok = $a -and $b }
            'rf-spectrum-sensing' {
                $ok = ($text -match '(?m)^CH-A\|\[9\]\s*$') -and ($text -match '(?m)^CH-B\|\[\]\s*$') -and ($text -match '(?m)^CH-C\|\[\]\s*$') }
        }
        if ($ok) { Pass "50 kits: demo-vertical-$k.sql runs clean and reproduces its headline result" }
        else {
            $probeSql = Join-Path $env:TEMP 'fsql_bt_scout_probe.sql'
            Set-Content -Path $probeSql -Encoding ascii -Value @(
                "SELECT JSON_LENGTH(JSON_EXTRACT(fractal_search_explore('0,0;1,1;2,2;3,3;4,4;5,5;6,6;7,7', '0,0', '{""population_size"": 3, ""iterations"": 2}'), '`$.population'));",
                "SELECT JSON_LENGTH(JSON_EXTRACT(fractal_search_explore('0,0;1,1;2,2;3,3;4,4;5,5;6,6;7,7', '0,0', '{""population_size"": 3, ""iterations"": 2, ""seed"": 5}'), '`$.population'));")
            $probe = (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N --force -e ("source " + ($probeSql -replace '\\', '/')) 2>&1) -join ' ' 
            Fail ("50 kits: demo-vertical-$k.sql did not reproduce its headline result (non-error lines: " + (KitShape $lines) + ", errors: $nerr; first lines: " + ((@($lines | Select-Object -First 16) | ForEach-Object { $_.Substring(0, [Math]::Min(48, $_.Length)) }) -join '/') + "; headline: " + (@($lines | Where-Object { $_ -match 'HEADLINE' } | Select-Object -First 1) -join '') + "; last: " + ((@($lines | Select-Object -Last 2) | ForEach-Object { $_.Substring(0, [Math]::Min(100, $_.Length)) }) -join '/') + "; probe(population_size=3 returns n points): $probe" + ")") }
    }
    # The kits leave their tables behind for inspection; this gate does not.
    $null = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e "DROP TABLE IF EXISTS ebl_telemetry, asv_known_bad, asv_proposed, asv_routes, v2x_capabilities, v2x_claims, cir_depots, cir_consumption, cir_profile, hpm_readings, cgb_freq, cgb_resources, hot_workers, sps_scenarios, afp_flights, scc_footprints, scc_slots, taa_known_anomalous, taa_proposed, ttr_nodes, ttr_requests, ttr_available, cem_readings, cre_grid, rfs_capture, rfs_entropy, esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj, oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim, abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed, spt_items, spt_traj, spt_triage, imd_entities, imd_picks, imd_content, imd_rec, anr_candidates, anr_recall, anr_actions, anr_rec, drd_risk, drd_prof, drd_clauses, drd_picks, drd_approved, drd_rec, crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim, sta_demand, sta_prof, sta_result, sed_price, sed_prof, sed_result, sed_loop, msr_units, msr_prof, msr_result, pps_sales, pps_prof, pps_result, pps_catalog, pps_rec, arr_offers, arr_picks, arr_sessions, arr_recall, sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks;" 2>&1
}

function Gate-49-ConfigOverlay {
    function Invoke-Sql([string]$sql) {
        (& $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $sql 2>&1 | Out-String).Trim()
    }

    # --- fractal_config_keys(): the whole surface, discoverable, with
    # each key's type and whether a session may override it.
    $keys = Invoke-Sql "SELECT fractal_config_keys();"
    $nkeys = ([regex]::Matches($keys, '"name":')).Count
    if ($nkeys -eq 18) {
        Pass "49 config_overlay: keys() lists all 18 configuration keys"
    } else {
        Fail "49 config_overlay: keys() listed $nkeys keys (expected 18): $keys"
    }
    if ($keys -like '*"name":"think","type":"string","session_overridable":true*') {
        Pass "49 config_overlay: keys() marks the tuning keys session-overridable"
    } else {
        Fail "49 config_overlay: keys() does not mark 'think' session-overridable: $keys"
    }
    if ($keys -like '*"name":"reasoning_plugin","type":"path","session_overridable":false*') {
        Pass "49 config_overlay: keys() marks the daemon-wide keys operator-only"
    } else {
        Fail "49 config_overlay: keys() does not mark 'reasoning_plugin' operator-only: $keys"
    }

    # --- The round trip: set, get, list, in ONE session. The reset
    # first clears any override a recycled connection id might carry.
    $out = Invoke-Sql "SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_set('think','high',CONNECTION_ID()); SELECT fractal_config_get('think',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID()); SELECT fractal_config_get('t2s_use_review',CONNECTION_ID());"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne "" })
    $l1 = if ($lines.Count -gt 0) { $lines[0] } else { "" }
    $l2 = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    $l3 = if ($lines.Count -gt 2) { $lines[2] } else { "" }
    $l4 = if ($lines.Count -gt 3) { $lines[3] } else { "" }
    $l5 = if ($lines.Count -gt 4) { $lines[4] } else { "" }
    if ($l2 -eq "ok") {
        Pass "49 config_overlay: set() accepts a tuning key and answers 'ok'"
    } else {
        Fail "49 config_overlay: set('think','high') answered '$l2' (expected 'ok')"
    }
    if ($l3 -eq "high") {
        Pass "49 config_overlay: get() returns the session's own override"
    } else {
        Fail "49 config_overlay: get('think') answered '$l3' (expected 'high')"
    }
    if ($l4 -eq '{"think":"high"}') {
        Pass "49 config_overlay: list() renders the session's overrides as a JSON object"
    } else {
        Fail "49 config_overlay: list() answered '$l4' (expected {`"think`":`"high`"})"
    }
    # A key the session never touched comes back as the daemon-wide
    # value (or NULL when there is none) -- the overlay is a layer, not
    # a replacement.
    if ($l5 -ne "" -and $l5 -ne "high" -and $l5 -ne '{"think":"high"}') {
        Pass "49 config_overlay: an untouched key falls through to the daemon-wide value ($l5)"
    } else {
        Fail "49 config_overlay: an untouched key answered '$l5' (expected the daemon-wide value, not the overlay)"
    }

    # --- TWO keys in ONE session. A session may hold more than one
    # override at a time, and every one of them must be readable: the
    # overlay's entry table is indexed by session id, so a second
    # override used to land in a second entry for the same session, where
    # every read (and the reset) only ever saw the first one. The symptom
    # was a value that set() reported as accepted and then refused to read
    # back -- and a reset that reported "dropped 1" and left the session
    # still holding an override.
    $out = Invoke-Sql "SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_set('think','high',CONNECTION_ID()); SELECT fractal_config_set('think_num_ctx','8192',CONNECTION_ID()); SELECT fractal_config_get('think',CONNECTION_ID()); SELECT fractal_config_get('think_num_ctx',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID()); SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID());"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne "" })
    $l1 = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    $l2 = if ($lines.Count -gt 2) { $lines[2] } else { "" }
    $l3 = if ($lines.Count -gt 3) { $lines[3] } else { "" }
    $l4 = if ($lines.Count -gt 4) { $lines[4] } else { "" }
    $l5 = if ($lines.Count -gt 5) { $lines[5] } else { "" }
    $l6 = if ($lines.Count -gt 6) { $lines[6] } else { "" }
    $l7 = if ($lines.Count -gt 7) { $lines[7] } else { "" }
    if ($l1 -eq "ok" -and $l2 -eq "ok") {
        Pass "49 config_overlay: a session may hold TWO overrides at once"
    } else {
        Fail "49 config_overlay: the two sets answered '$l1' / '$l2' (expected 'ok' / 'ok')"
    }
    if ($l3 -eq "high" -and $l4 -eq "8192") {
        Pass "49 config_overlay: BOTH overrides read back, not just the first one"
    } else {
        Fail "49 config_overlay: the two gets answered '$l3' / '$l4' (expected 'high' / '8192')"
    }
    if (($l5 -like '*"think":"high"*') -and ($l5 -like '*"think_num_ctx":"8192"*')) {
        Pass "49 config_overlay: list() shows every override the session holds"
    } else {
        Fail "49 config_overlay: list() answered '$l5' (expected both overrides)"
    }
    if ($l6 -eq "2") {
        Pass "49 config_overlay: reset() drops every override the session holds"
    } else {
        Fail "49 config_overlay: reset() answered '$l6' (expected 2 dropped overrides)"
    }
    if ($l7 -eq "{}") {
        Pass "49 config_overlay: after the reset the session holds no overrides"
    } else {
        Fail "49 config_overlay: after the reset the session still holds '$l7' (expected {})"
    }

    # --- The refusal: a daemon-wide key is refused BY NAME, with the
    # reason, and it is a RETURNED string (the UDF ABI cannot carry a
    # reason on the error path). The set, the refusal and the list run
    # in ONE session, so the list shows exactly what this session holds.
    $out = Invoke-Sql "SELECT fractal_config_set('reasoning_model','m',CONNECTION_ID()); SELECT fractal_config_set('reasoning_plugin','/opt/evil.so',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID());"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne "" })
    $l1 = if ($lines.Count -gt 0) { $lines[0] } else { "" }
    $l2 = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    $l3 = if ($lines.Count -gt 2) { $lines[2] } else { "" }
    if ($l2 -like "*'reasoning_plugin' is a daemon-wide setting and cannot be changed by a session*") {
        Pass "49 config_overlay: a daemon-wide key is refused by name, with the reason"
    } else {
        Fail "49 config_overlay: set('reasoning_plugin') answered '$l2' (expected the by-name refusal)"
    }
    if ($l3 -like "*reasoning_plugin*") {
        Fail "49 config_overlay: the refused key was stored anyway: $l3"
    } elseif ($l3 -eq '{"reasoning_model":"m"}') {
        Pass "49 config_overlay: the refused key is not in the session's overrides"
    } else {
        Fail "49 config_overlay: list() answered '$l3' (expected {`"reasoning_model`":`"m`"})"
    }

    # --- A secret's value is never returned: the caller learns whether
    # a credential is configured, and nothing more.
    $out = Invoke-Sql "SELECT fractal_config_get('reasoning_token',CONNECTION_ID());"
    if ($out -eq "<redacted>" -or $out -eq "<unset>") {
        Pass "49 config_overlay: a secret's value is never returned ($out)"
    } else {
        Fail "49 config_overlay: get('reasoning_token') answered '$out' (expected <redacted> or <unset>)"
    }

    # --- The renderer sizes the document ITSELF. A stored value with
    # control bytes escapes to six bytes each (\u00XX), so a value of
    # 8000 newlines is a 48 KB document: a buffer sized from a guess
    # about the escape factor truncates it (or returns NULL), and the
    # session's configuration silently stops being readable. The
    # document must be valid JSON and must round-trip the value.
    $out = Invoke-Sql "SELECT fractal_config_set('reasoning_model', REPEAT(CHAR(10), 8000), CONNECTION_ID()); SELECT JSON_VALID(fractal_config_list(CONNECTION_ID())); SELECT CHAR_LENGTH(JSON_UNQUOTE(JSON_EXTRACT(fractal_config_list(CONNECTION_ID()), '`$.reasoning_model')));"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne "" })
    $l1 = if ($lines.Count -gt 0) { $lines[0] } else { "" }
    $l2 = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    $l3 = if ($lines.Count -gt 2) { $lines[2] } else { "" }
    if ($l1 -eq "ok" -and $l2 -eq "1") {
        Pass "49 config_overlay: a heavily escaped value still renders as valid JSON"
    } else {
        Fail "49 config_overlay: the escaped-value render answered '$l1' / JSON_VALID='$l2' (expected 'ok' / '1')"
    }
    if ($l3 -eq "8000") {
        Pass "49 config_overlay: the escaped value round-trips through the JSON document"
    } else {
        Fail "49 config_overlay: the escaped value came back '$l3' bytes long (expected 8000)"
    }
    # Clear the override again: the model name is published into the
    # daemon's environment on the next cognition dispatch, and a
    # 48 KB model name is not something to leave behind.
    Invoke-Sql "SELECT fractal_config_reset(CONNECTION_ID());" | Out-Null

    # --- The value-length boundary. A value of exactly 8192 bytes was
    # ACCEPTED by set() and then came back TRUNCATED at 8191: the limit
    # was compared against the buffer's size rather than against the
    # space the value needs in it, terminator included. The value that
    # fits has to round-trip whole, the one that does not has to be
    # refused with a reason, and the refusal must not disturb the value
    # already stored.
    $out = Invoke-Sql "SELECT fractal_config_set('think', REPEAT('a', 8191), CONNECTION_ID()); SELECT CHAR_LENGTH(fractal_config_get('think', CONNECTION_ID())); SELECT fractal_config_set('think', REPEAT('a', 8192), CONNECTION_ID()); SELECT CHAR_LENGTH(fractal_config_get('think', CONNECTION_ID())); SELECT fractal_config_reset(CONNECTION_ID());"
    $lines = @($out -split "`r?`n" | Where-Object { $_ -ne "" })
    $l1 = if ($lines.Count -gt 0) { $lines[0] } else { "" }
    $l2 = if ($lines.Count -gt 1) { $lines[1] } else { "" }
    $l3 = if ($lines.Count -gt 2) { $lines[2] } else { "" }
    $l4 = if ($lines.Count -gt 3) { $lines[3] } else { "" }
    if ($l1 -eq "ok" -and $l2 -eq "8191") {
        Pass "49 config_overlay: a value that fits the buffer round-trips whole (8191 bytes)"
    } else {
        Fail "49 config_overlay: the 8191-byte value answered '$l1' / '$l2' (expected 'ok' / '8191')"
    }
    if ($l3 -like "*too long*") {
        Pass "49 config_overlay: a value one byte over the limit is refused, with the reason"
    } else {
        Fail "49 config_overlay: the 8192-byte value answered '$l3' (expected a 'too long' refusal)"
    }
    if ($l4 -eq "8191") {
        Pass "49 config_overlay: the refused value did not disturb the stored one"
    } else {
        Fail "49 config_overlay: after the refusal the stored value is '$l4' bytes long (expected 8191)"
    }

    # --- The canonical vector form: a u16 dimension (LE), a u16
    # reserved field (zero), then the float32 values (LE), carried as
    # lowercase hex. fractal_vector(3) is the zero vector of dimension
    # 3: "0300" + "0000" + 24 zero digits.
    $z3 = Invoke-Sql "SELECT fractal_vector(3);"
    if ($z3 -eq "03000000000000000000000000000000") {
        Pass "49 config_overlay: fractal_vector(3) is the canonical zero vector"
    } else {
        Fail "49 config_overlay: fractal_vector(3) answered '$z3' (expected 03000000000000000000000000000000)"
    }
    $c123 = Invoke-Sql "SELECT fractal_vector_from_text('[1,2,3]');"
    if ($c123 -eq "030000000000803f0000004000004040") {
        Pass "49 config_overlay: from_text() encodes [1,2,3] into the canonical form"
    } else {
        Fail "49 config_overlay: from_text('[1,2,3]') answered '$c123' (expected 030000000000803f0000004000004040)"
    }
    # The canonical form is a FIXED POINT: converting it again yields
    # the same bytes.
    $c2 = Invoke-Sql "SELECT fractal_vector_from_text(fractal_vector_from_text('[1,2,3]'));"
    if ($c2 -eq $c123) {
        Pass "49 config_overlay: the canonical form is a fixed point"
    } else {
        Fail "49 config_overlay: re-encoding the canonical form changed it ('$c123' -> '$c2')"
    }
    $tj = Invoke-Sql "SELECT fractal_vector_to_json(fractal_vector_from_text('[1,2,3]'));"
    if ($tj -eq "[1,2,3]") {
        Pass "49 config_overlay: to_json() renders the canonical form back as a JSON array"
    } else {
        Fail "49 config_overlay: to_json() answered '$tj' (expected [1,2,3])"
    }
    $nd = Invoke-Sql "SELECT fractal_vector_dims(fractal_vector_from_text('[1,2,3]'));"
    if ($nd -eq "3") {
        Pass "49 config_overlay: dims() reads the dimension back out of the canonical form"
    } else {
        Fail "49 config_overlay: dims() answered '$nd' (expected 3)"
    }
    # Out-of-range dimensions are refused: the cap is the format's own
    # (1..32767), and a dimension of 0 has no canonical encoding.
    $bad = Invoke-Sql "SELECT fractal_vector(0);"
    if ($bad -eq "NULL") {
        Pass "49 config_overlay: fractal_vector(0) is refused"
    } else {
        Fail "49 config_overlay: fractal_vector(0) answered '$bad' (expected NULL)"
    }
    $bad = Invoke-Sql "SELECT fractal_vector(32768);"
    if ($bad -eq "NULL") {
        Pass "49 config_overlay: fractal_vector(32768) is refused (the format's dimension cap)"
    } else {
        Fail "49 config_overlay: fractal_vector(32768) answered '$bad' (expected NULL)"
    }
    $bad = Invoke-Sql "SELECT fractal_vector_to_json('not a vector');"
    if ($bad -eq "NULL") {
        Pass "49 config_overlay: to_json() refuses text that is not a vector"
    } else {
        Fail "49 config_overlay: to_json('not a vector') answered '$bad' (expected NULL)"
    }

    # --- fractal_search_debug: the convergence view. A pinned seed makes
    # the trace byte-stable, which is the point of the seed argument.
    $sd = Invoke-Sql "SELECT fractal_search_debug('[1,2,3]', 20, 10, 2, 42);"
    if ($sd -like '*"best_point"*' -and $sd -like '*"best_fit"*' -and $sd -like '*"trace"*') {
        Pass "49 config_overlay: search_debug() returns the convergence view (best_point/best_fit/trace)"
    } else {
        Fail "49 config_overlay: search_debug() did not return the convergence view: $sd"
    }
    $sd2 = Invoke-Sql "SELECT fractal_search_debug('[1,2,3]', 20, 10, 2, 42);"
    if ($sd -eq $sd2) {
        Pass "49 config_overlay: search_debug() with a pinned seed is byte-stable"
    } else {
        Fail "49 config_overlay: search_debug() with a pinned seed differed between calls"
    }
    # The adapter refuses the same parameter range the CORE refuses, so
    # an out-of-range argument is turned away here rather than travelling
    # to the core to fail with a generic message.
    $bad = Invoke-Sql "SELECT fractal_search_debug('[1,2,3]', 0);"
    if ($bad -eq "NULL") {
        Pass "49 config_overlay: search_debug() refuses iterations=0"
    } else {
        Fail "49 config_overlay: search_debug(iterations=0) answered '$bad' (expected NULL)"
    }
    $bad = Invoke-Sql "SELECT fractal_search_debug('[1,2,3]', 10, 20000);"
    if ($bad -eq "NULL") {
        Pass "49 config_overlay: search_debug() refuses a population above the core's own cap"
    } else {
        Fail "49 config_overlay: search_debug(population=20000) answered '$bad' (expected NULL)"
    }

    # --- A caller-supplied output count that does not fit. The count is
    # multiplied by the element size to size the buffer the core writes
    # into: a count whose multiplication wrapped to 0 gave the core a
    # zero-length buffer to write real output into (a heap overflow
    # inside mariadbd). The count is now clamped to what the data can
    # actually produce, so the answer is the same as asking for that
    # many -- and the server stays up.
    $big = Invoke-Sql "SELECT fractal_periodogram('1,2,3,4,5,6,7,8', 2305843009213693952);"
    $alive = Invoke-Sql "SELECT 42;"
    if ($alive -eq "42") {
        Pass "49 config_overlay: a periodogram count of 2^61 does not take the server down"
    } else {
        Fail "49 config_overlay: the server did not answer after fractal_periodogram(2^61) (answered '$alive')"
    }
    if ($big -eq "NULL" -or ($big -like '*"freqs"*' -and $big -like '*"power"*')) {
        Pass "49 config_overlay: a periodogram count of 2^61 is refused or clamped, never a short buffer"
    } else {
        Fail "49 config_overlay: fractal_periodogram(2^61) answered '$big'"
    }
    $big = Invoke-Sql "SELECT fractal_change_point_detect('1,2,3,4,5,6,7,8', 2, 0.5, 2305843009213693952);"
    $alive = Invoke-Sql "SELECT 42;"
    # The result is a bare JSON array ([2,5]), so the check is for a
    # literal '[' -- matched as a REGEX ('\['), not as a -like wildcard:
    # PowerShell's -like treats '[' as the start of a character class
    # even inside a single-quoted string, so a pattern like '*"["*' is
    # an INVALID wildcard and throws ("The specified wildcard character
    # pattern is not valid") the moment it is evaluated -- which
    # aborted the whole run at this line, silently skipping the last
    # two assertions of the last gate.
    if ($alive -eq "42" -and ($big -eq "NULL" -or ($big -match '\['))) {
        Pass "49 config_overlay: a change-point count of 2^61 is refused or clamped, and the server stays up"
    } else {
        Fail "49 config_overlay: fractal_change_point_detect(2^61) answered '$big' (server answered '$alive')"
    }
    $big = Invoke-Sql "SELECT fractal_tda_persistence_diagram('1,2,3,4,5,6', 2, 0, 10.0, 2305843009213693952);"
    $alive = Invoke-Sql "SELECT 42;"
    if ($alive -eq "42" -and ($big -eq "NULL" -or $big -like '*"h0_bars"*')) {
        Pass "49 config_overlay: a persistence-diagram bar count of 2^61 is refused or clamped, and the server stays up"
    } else {
        Fail "49 config_overlay: fractal_tda_persistence_diagram(2^61) answered '$big' (server answered '$alive')"
    }
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
# (tests\mock_enterprise_core.c -- built only from the public
# fractalsql.h).
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
    Remove-Item -Force $ledgerPath, "$ledgerPath.head", "$ledgerPath.csv", $failSentinel, $mockSo, $badsigSo, $badsigSig, $nosigSo -ErrorAction SilentlyContinue

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

    # Engine-side latch behind the MCP server's FSQL_MCP_READ_ONLY switch.
    # fractal_lock_destructive(session_id) is one-way: afterwards the
    # destructive ledger UDFs refuse for that session id (NULL, the UDF *error
    # convention) even though the mock core is loaded and they just succeeded
    # above; fractal_ledger_load overwrites the live ledger state, so it is
    # latched too. One client invocation is one connection, so CONNECTION_ID()
    # is the same id throughout. The latch is keyed by the session id the
    # caller passes (see docs\enterprise.md): a fresh connection has a new id
    # and is not latched.
    $lk = Invoke-Mdb35 "SELECT fractal_lock_destructive(CONNECTION_ID()); SELECT fractal_ledger_flush(CONNECTION_ID()); SELECT fractal_ledger_compact(CONNECTION_ID()); SELECT fractal_ledger_reset_soft(CONNECTION_ID()); SELECT fractal_ledger_reset_hard(CONNECTION_ID()); SELECT fractal_ledger_load(CONNECTION_ID());"
    $lkNorm = (("$lk") -replace '\s+', ' ').Trim()
    if ($lkNorm -eq '1 NULL NULL NULL NULL NULL') { Pass "35 enterprise_mock: fractal_lock_destructive() latches flush/compact/reset_soft/reset_hard/load for the session id" }
    else { Fail "35 enterprise_mock: expected '1 NULL NULL NULL NULL NULL' after the latch, got: $lkNorm" }
    $lk2 = Invoke-Mdb35 "SELECT fractal_ledger_reset_hard(CONNECTION_ID());"
    if ($lk2 -eq "0") { Pass "35 enterprise_mock: the latch is per session id (a fresh connection is not latched)" }
    else { Fail "35 enterprise_mock: expected a fresh connection to be unlatched (0), got: $lk2" }

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

    # The portfolio decision's audit record must actually LAND. The
    # record's head embeds the Sharpe ratio as "%.10f", and a Sharpe
    # ratio large enough to need 150+ characters overflowed the old
    # fixed budget: the snprintf truncated, the write was SKIPPED, and
    # the decision's provenance silently vanished -- no error, no
    # record, just a missing row in the chain. An expected return that
    # large is legal input.
    #
    # This sits BEFORE the byte-level tamper below on purpose: the
    # tamper deliberately breaks the chain, and a broken chain's verify
    # report carries no rows_verified count to compare against.
    $chainBefore = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
    # The Sharpe ratio here is ret/risk with the risk floored at 1e-6
    # (the core's own variance floor), so a 1e250 expected return over
    # a 1e-300 variance gives a 257-digit Sharpe ratio -- a number no
    # fixed "a few hundred bytes" budget can hold.
    $pf = Invoke-Mdb35 "SELECT fractal_optimize_portfolio('1e250,9e249', '1e-300,0,0,1e-300', 1, '{}');"
    $chainAfter = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
    $nBefore = -1; $nAfter = -1
    if ("$chainBefore" -match '"rows_verified":(\d+)') { $nBefore = [int]$Matches[1] }
    if ("$chainAfter"  -match '"rows_verified":(\d+)') { $nAfter  = [int]$Matches[1] }
    $sharpeDigits = 0
    if ("$pf" -match '"sharpe":(-?[0-9]+)\.') { $sharpeDigits = $Matches[1].TrimStart('-').Length }
    if ($nAfter -eq ($nBefore + 1) -and $sharpeDigits -ge 138) {
        Pass "35 enterprise_mock: a portfolio decision with a $sharpeDigits-digit Sharpe ratio still lands its audit record"
    } else {
        Fail "35 enterprise_mock: the portfolio audit record did not land (chain $nBefore -> $nAfter, sharpe digits $sharpeDigits; the call answered '$pf')"
    }

    # A negative seed is not a seed the core can use -- the core's seed
    # is a uint64_t, so a SIGNED read of {"seed":-1} widened to
    # 18446744073709551615: a value the caller never asked for, and one
    # that silently differed from the documented default (0). The
    # portfolio decision's own audit record carries the seed, so the
    # chain is the readout: the seed in the record must be 0, not the
    # widened value.
    Invoke-Mdb35 "SELECT fractal_optimize_portfolio('0.1,0.15', '0.04,0.01,0.01,0.03', 1, '{`"seed`":-1}');" | Out-Null
    $seedSeen = "<no record>"
    if (Test-Path "$ledgerPath.csv") {
        $seedRows = @(Get-Content "$ledgerPath.csv" -ErrorAction SilentlyContinue)
        if ($seedRows.Count -gt 0) {
            $seedCols = $seedRows[$seedRows.Count - 1].Split(',')
            if ($seedCols.Count -gt 2 -and $seedCols[1] -eq "2") {
                try {
                    $seedDoc = [System.Text.Encoding]::UTF8.GetString(
                        [System.Convert]::FromBase64String($seedCols[2]))
                    if ($seedDoc -match '"seed":(-?\d+)') { $seedSeen = $Matches[1] }
                } catch { $seedSeen = "<undecodable record>" }
            } else { $seedSeen = "<last mirror row is not a kind=2 record>" }
        }
    }
    if ($seedSeen -eq "0") {
        Pass "35 enterprise_mock: a negative seed falls back to the default instead of widening to a huge unsigned value"
    } else {
        Fail "35 enterprise_mock: expected the audit record's seed to be 0 for a negative seed, got '$seedSeen'"
    }

    # The CSV mirror's `id` is the record's position in the CHAIN, not a
    # line count of the mirror file. Delete the mirror and the next
    # record must still be numbered by where it lands in the chain --
    # a mirror that re-derives the id from its own line count would
    # hand out id 1 again and the mirror's "ORDER BY id" would no
    # longer name the same row the chain's tip does.
    if (Test-Path "$ledgerPath.csv") {
        Remove-Item "$ledgerPath.csv" -Force -ErrorAction SilentlyContinue
        Invoke-Mdb35 "SELECT fractal_audit_log('test.mirror_id', JSON_OBJECT('n', 4));" | Out-Null
        $mirrorRows = @(Get-Content "$ledgerPath.csv" -ErrorAction SilentlyContinue)
        $mirrorId = -1
        if ($mirrorRows.Count -gt 0 -and $mirrorRows[0] -match '^(\d+),') { $mirrorId = [int]$Matches[1] }
        if ($mirrorId -gt 1) {
            Pass "35 enterprise_mock: the mirror's id is the chain's record position ($mirrorId), not a restart at 1"
        } else {
            Fail "35 enterprise_mock: the mirror's id restarted at $mirrorId instead of continuing the chain's numbering"
        }
    } else {
        Fail "35 enterprise_mock: mirror-id check: $ledgerPath.csv does not exist (an earlier assertion in this gate must have failed to actually write the mirror)"
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
    # library is already loaded. This assertion DOES apply here --
    # mariadbd is one persistent process, not one-backend-per-connection,
    # so the daemon's own "already loaded" state is genuinely long-lived.
    Add-Content -Path $script:FsqdConf -Encoding ascii -Value "enterprise_lib = $badsigSo"
    $rd = Invoke-ReloadProbe35
    if ($rd -match 'reload failed') { Pass "35 enterprise_mock: reload refuses to change enterprise_lib while it is loaded" }
    else { Fail "35 enterprise_mock: expected a refusal, got: $rd" }
    $r4 = Invoke-Mdb35 "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    if ($r4 -eq "0") { Pass "35 enterprise_mock: the refused reload left the mock loaded and working" }
    else { Fail "35 enterprise_mock: expected 0 (still loaded), got: $r4" }

    # An EMPTY JSON object is well-formed JSON. The audit log's own
    # structural gate used to reject it -- a closing bracket demanded a
    # completed value, and an empty container has none -- so
    # fractal_audit_log(type, JSON_OBJECT()) wrote nothing to the chain
    # and returned a bare NULL, while the file's own comment claimed
    # JSON_OBJECT() output "clears this easily".
    $emptyObj = Invoke-Mdb35 "SELECT IFNULL(fractal_audit_log('test.empty', JSON_OBJECT()), '<NULL>');"
    if ($emptyObj -eq "0") { Pass "35 enterprise_mock: audit_log accepts an empty JSON object (JSON_OBJECT())" }
    else { Fail "35 enterprise_mock: audit_log with JSON_OBJECT() answered '$emptyObj' (expected 0)" }
    $emptyArr = Invoke-Mdb35 "SELECT IFNULL(fractal_audit_log('test.empty_arr', JSON_ARRAY()), '<NULL>');"
    if ($emptyArr -eq "0") { Pass "35 enterprise_mock: audit_log accepts an empty JSON array (JSON_ARRAY())" }
    else { Fail "35 enterprise_mock: audit_log with JSON_ARRAY() answered '$emptyArr' (expected 0)" }
    # A trailing separator is still NOT well-formed: the fix must not
    # have loosened the gate into accepting broken JSON.
    # A single-quoted PowerShell string, with the SQL's own single
    # quotes doubled: a backslash is NOT an escape character in
    # PowerShell, so a "{\"a\":1,}" inside a double-quoted string ends
    # the string at the first quote and hands MariaDB a truncated
    # statement.
    $trailing = Invoke-Mdb35 'SELECT IFNULL(fractal_audit_log(''test.trailing'', ''{"a":1,}''), ''<NULL>'');'
    if ($trailing -eq "<NULL>") { Pass "35 enterprise_mock: audit_log still refuses a JSON payload with a trailing separator" }
    else { Fail "35 enterprise_mock: audit_log with a trailing separator answered '$trailing' (expected <NULL>)" }

    # A ZERO-LENGTH ledger file is not a corrupt ledger: it is a ledger
    # that was created but never got its header (a crash between the
    # create and the first append, an operator's `touch`, a copy that
    # lost its tail). There is no chain in it to lose. The write path
    # used to treat it as CORRUPT and refuse -- and because every
    # later write went through the same check, that one zero-byte file
    # BRICKED THE LEDGER PERMANENTLY: no record could ever be written
    # again, and the only way out was deleting the file by hand. It
    # must instead be re-headed and used normally.
    if (Test-Path $ledgerPath) {
        [System.IO.File]::WriteAllBytes($ledgerPath, @())
        Remove-Item -Force "$ledgerPath.head" -ErrorAction SilentlyContinue   # this simulates a never-written file, not a wiped chain (the head record would flag the latter)
        $zLog = Invoke-Mdb35 "SELECT IFNULL(fractal_audit_log('test.zero_byte', JSON_OBJECT('n', 1)), '<NULL>');"
        $zVer = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
        if ($zLog -eq "0" -and $zVer -eq '{"ok":true,"rows_verified":1}') {
            Pass "35 enterprise_mock: a zero-length ledger file is re-headed and used, not bricked"
        } else {
            Fail "35 enterprise_mock: a zero-length ledger answered '$zLog' / verify '$zVer' (expected 0 / a 1-row ok verify)"
        }
    } else {
        Fail "35 enterprise_mock: zero-length ledger: $ledgerPath does not exist (an earlier assertion in this gate must have failed to actually load the mock)"
    }

    # A record header that CLAIMS a 4 GiB blob must not be believed.
    # The ledger's on-disk length field is a uint32_t, and the read path
    # sized two things from it: the blob allocation, and the hash-
    # recomputation buffer (LEDGER_HASH_LEN + blob_len + ...). That
    # second expression is computed in 32-bit UNSIGNED arithmetic, so a
    # claimed length near 2^32 WRAPS it round to a small number -- the
    # allocation came out 32 bytes while the memcpy right below it
    # copied the claimed length into it: a heap overflow in the
    # daemon's own address space, on both the O(1) tip check and the
    # full chain walk. The read path now bounds the claimed length
    # (LEDGER_MAX_BLOB_BYTES) and reports the record as corrupt.
    if (Test-Path $ledgerPath) {
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes("FSQLLDGR"))  # magic
        $bw.Write([byte]1)                                           # version
        $bw.Write([uint32]2)                                         # kind = 2 (decision audit)
        $bw.Write([uint32]4294967295)                                # blob_len: 4 GiB - 1
        $bw.Write([byte]0)                                           # has_mac
        $bw.Write([byte]0)                                           # sealed
        $bw.Write([byte]0); $bw.Write([byte]0)                       # reserved
        $bw.Write([byte[]]::new(32))                                 # mac
        $bw.Write([byte[]]::new(32))                                 # prev_hash
        $bw.Write([byte[]]::new(32))                                 # entry_hash
        $bw.Write([int64]0)                                          # updated
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($ledgerPath, $ms.ToArray())
        $bw.Dispose(); $ms.Dispose()
        Remove-Item -Force "$ledgerPath.head" -ErrorAction SilentlyContinue   # a hand-built file stands in for a fresh ledger; no earlier rows are expected
        $vLen = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
        if ($vLen -eq '{"ok":false,"first_failure_id":1,"reason":"record blob length out of range"}') {
            Pass "35 enterprise_mock: a record header claiming a 4 GiB blob is refused as corrupt, not sized from"
        } else {
            Fail "35 enterprise_mock: a bogus 4 GiB blob length answered '$vLen' (expected the out-of-range refusal)"
        }
        # The WRITE path must self-heal the same file: a record that
        # cannot be parsed ends the chain, so the repair step truncates
        # there and the next append starts a fresh, valid chain -- the
        # alternative (refusing the file) would leave the ledger
        # permanently unwritable.
        $wLen = Invoke-Mdb35 "SELECT IFNULL(fractal_audit_log('test.corrupt_len', JSON_OBJECT('n', 1)), '<NULL>');"
        $vLen2 = Invoke-Mdb35 "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
        if ($wLen -eq "0" -and $vLen2 -eq '{"ok":true,"rows_verified":1}') {
            Pass "35 enterprise_mock: a corrupt-length record is repaired as a torn tail on the next write"
        } else {
            Fail "35 enterprise_mock: a corrupt-length record was not repaired (write '$wLen' / verify '$vLen2')"
        }
    } else {
        Fail "35 enterprise_mock: bogus blob length: $ledgerPath does not exist (an earlier assertion in this gate must have failed to actually load the mock)"
    }

    Remove-Item Env:\FSQL_MOCK_ENT_FAIL -ErrorAction SilentlyContinue
    Remove-Item -Force $ledgerPath, "$ledgerPath.head", "$ledgerPath.csv", $failSentinel, $mockSo, $badsigSo, $badsigSig, $nosigSo, $probe -ErrorAction SilentlyContinue
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

# The MCP server binary for the active mode: the plain build, or the ASan or
# UBSan build under -Asan / -Ubsan. Rebuilt when missing or older than the
# sources or its build script. Returns the exe path, or $null after
# reporting a skip or failure for $label.
function Get-McpServerExe([string]$label) {
    $dist   = if ($Asan) { 'windows-mcp-asan' } elseif ($Ubsan) { 'windows-mcp-ubsan' } else { 'windows-mcp' }
    $buildBat = if ($Asan) { 'build-asan.bat' } elseif ($Ubsan) { 'build-ubsan.bat' } else { 'build.bat' }
    $exe = Join-Path $script:Here "mcp\dist\$dist\fractalsql-mariadb-mcp.exe"
    $needsBuild = -not (Test-Path -LiteralPath $exe)
    if (-not $needsBuild) {
        $exeTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
        $watch = @(Get-ChildItem -LiteralPath (Join-Path $script:Here 'mcp\src') -Recurse -File)
        $watch += Get-Item -LiteralPath (Join-Path $script:Here "mcp\scripts\windows\$buildBat")
        $needsBuild = [bool]($watch | Where-Object { $_.LastWriteTimeUtc -gt $exeTime })
    }
    if (-not $needsBuild) { return $exe }

    $boot = Join-Path $env:TEMP 'fractalsql_bt_mcp_build_cmd.bat'
    [IO.File]::WriteAllLines($boot, @(
        '@echo off',
        "call `"$script:Here\mcp\scripts\windows\$buildBat`"",
        'exit /b %ERRORLEVEL%'
    ))
    Remove-Item -LiteralPath $exe -ErrorAction SilentlyContinue
    # The MCP server build links the MariaDB client too. MARIADB_DIR is
    # pointed at the RESOLVED client tree (not at $MdbDir) and the import
    # library's name is passed in explicitly, because a tree that carries
    # the client under the legacy mariadbclient.lib name would otherwise
    # fail the link step with LNK1181.
    $client = $script:MariaDbClient
    if (-not $client) {
        Skip "$label (no MariaDB Connector/C import library -- libmariadb.lib was not found in any candidate tree)"
        return $null
    }
    $prevMdbDir  = $env:MARIADB_DIR
    $prevLib     = $env:MARIADB_CLIENT_LIB
    $prevDll     = $env:MARIADB_CLIENT_DLL
    $env:MARIADB_DIR       = $client.Dir
    $env:MARIADB_CLIENT_LIB = $client.LibName
    if ($client.Dll) { $env:MARIADB_CLIENT_DLL = $client.Dll } else { Remove-Item Env:\MARIADB_CLIENT_DLL -ErrorAction SilentlyContinue }
    try {
        $out = & cmd /c "call $boot" 2>&1
    }
    finally {
        foreach ($kv in @(@('MARIADB_DIR', $prevMdbDir), @('MARIADB_CLIENT_LIB', $prevLib), @('MARIADB_CLIENT_DLL', $prevDll))) {
            if ($null -eq $kv[1] -or $kv[1] -eq '') { Remove-Item "Env:\$($kv[0])" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "Env:\$($kv[0])" -Value $kv[1] }
        }
    }
    if (Test-Path -LiteralPath $exe) { return $exe }
    if (($out -join "`n") -match 'not found|openssl tree|VCPKG_ROOT|no Visual Studio') {
        Skip "$label (no toolchain for the MCP server binary build -- install VS C++ + vcpkg openssl:x64-windows-static)"
    }
    else {
        $out | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
        Fail "${label}: MCP server build failed"
    }
    return $null
}

function Gate-39-McpSmoke {
    # Windows port of build_test.sh's gate_39_mcp_smoke (8.3's MCP
    # gate): built on the harness's RUNNING scratch cluster, it starts
    # the stdio fractalsql-mariadb-mcp C++ server subprocess against it
    # and drives a real client session through initialize / tools-list /
    # per-tier tools/call round trips (happy paths and clean error
    # paths side by side), plus the S-FT-004 partial-reasoning case
    # through the admin tools. The client driver lives at
    # mcp\tests\mcp_smoke_client.py so build_test.sh's POSIX gate
    # drives the same file. The driver's phase-0 lock checks
    # (10.5/15.3/15.5) mechanically enforce the regenerate-and-commit
    # workflow: a changed tool table without freshly generated
    # committed locks fails here before any DB call runs.
    if (-not (Test-Path -LiteralPath (Join-Path $script:Here 'mcp\tests\mcp_smoke_client.py')) -or
            -not (Test-Path -LiteralPath (Join-Path $script:Here 'mcp\src\main.cpp'))) {
        Skip '39 mcp_smoke (mcp/ server code not present -- spec 8.3 self-skip)'
        return
    }
    $py = Get-PythonExe
    if (-not $py) {
        Skip '39 mcp_smoke (no python on PATH -- the smoke client driver needs it)'
        return
    }

    $script:McpExe = Get-McpServerExe '39 mcp_smoke'
    if (-not $script:McpExe) { return }

    # A per-run scratch CWD: the server's stderr JSON log (its own
    # per-call audit trail) lands there as mcp_server.log.
    $smokeCwd = Join-Path $env:TEMP "fractalsql_bt_mcp_smoke_$MdbMajor"
    if (Test-Path $smokeCwd) { Remove-Item -Recurse -Force $smokeCwd -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $smokeCwd | Out-Null

    # The client driver gets everything through the environment, per the
    # MCP server's own spec 1.2 configuration convention: the MariaDB
    # connection (this harness's own scratch cluster), the daemon-admin
    # realm (the conf file the live fractalsqld is running -- the
    # S-FT-004 case's conf edit + reload targets exactly it), and the
    # direct-SQL fixture path. The mock reasoning provider needs no MCP
    # env at all: the daemon was started with it (Mdb-Setup), and every
    # reasoning-tier call crosses the shim to the daemon.
    $env:MCP_HERE          = Join-Path $script:Here 'mcp'
    $env:MCP_SERVER_EXE    = $script:McpExe
    $env:MCP_SERVER_CWD    = $smokeCwd
    $env:MCP_TEST_DAEMON_EXE = $script:DaemonExe
    $env:MCP_MARIADB_BIN   = $script:MariadbExe
    # The slow reasoning plugin (tests\slow_reasoning_plugin.c), built by
    # Mdb-Setup alongside the other reasoning-VFS-ABI fixtures. The MCP
    # client's shutdown-drain phase needs its path across the process
    # boundary, so it travels as an env var like every other one.
    $env:MCP_SLOW_REASONING_PLUGIN = $script:SlowSo
    $env:MARIADB_HOST      = '127.0.0.1'
    $env:MARIADB_PORT      = "$($script:Port)"
    $env:MARIADB_DATABASE  = 'fractalsql_bt'
    $env:MARIADB_USER      = 'root'
    $env:MARIADB_PASSWORD  = ''
    $env:FSQLCTL_SOCKET    = $script:FsqdPipe
    $env:FSQLCTL_KEY       = $script:FsqdKey
    $env:FSQLCTL_CONF      = $script:FsqdConf

    # The MCP server is fail-closed about a missing lock file (a hard
    # startup exit), and its default lock-path resolution walks up from
    # the scratch CWD this gate uses -- which is not a checkout root, so
    # the walk resolves Absent and the server refuses to start. Point it
    # at the repo's committed locks explicitly: that is what the gate
    # wants to exercise anyway, the real drift check against the
    # committed schema/annotation locks.
    $env:FSQL_MCP_SCHEMA_LOCK = Join-Path $script:Here 'mcp\.mcp-schema-lock'
    $env:FSQL_MCP_SAFETY_LOCK = Join-Path $script:Here 'mcp\.mcp-safety-annotations-lock'

    try {
        & $py -u (Join-Path $script:Here 'mcp\tests\mcp_smoke_client.py') 2>&1 |
            ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -eq 0) {
            Pass '39 mcp_smoke: full MCP session (initialize, 93-tool catalog, discovery/cognition/agency round trips, enterprise clean-error path, $/cancel, resources+prompts, partial-reasoning S-FT-004 via the admin tools, shutdown drain)'
        }
        else {
            Fail "39 mcp_smoke: client driver exited $LASTEXITCODE (server log: $smokeCwd\mcp_server.log)"
        }
    }
    finally {
        foreach ($v in @('MCP_HERE','MCP_SERVER_EXE','MCP_SERVER_CWD','MCP_MARIADB_BIN','MCP_TEST_DAEMON_EXE',
                         'MCP_SLOW_REASONING_PLUGIN',
                         'MARIADB_HOST','MARIADB_PORT','MARIADB_DATABASE','MARIADB_USER',
                         'MARIADB_PASSWORD','FSQLCTL_SOCKET','FSQLCTL_KEY','FSQLCTL_CONF',
                         'FSQL_MCP_SCHEMA_LOCK','FSQL_MCP_SAFETY_LOCK')) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
}

# --- C++ toolchain discovery (gates 42/43/44) ------------------------
#
# The MCP probe gates need a C++ compiler.
#
# On Windows the compiler is MSVC's cl.exe, invoked through vcvars64 --
# the same toolchain and the same OpenSSL tree (vcpkg's STATIC one) that
# mcp\scripts\windows\build.bat uses. The static OpenSSL is the reason
# this is not a plain g++ invocation: libcrypto.lib was built with
# MSVC's CRT and references __security_cookie / __chkstk / __GSHandlerCheck,
# which MinGW's g++ cannot resolve ("undefined reference to
# __security_cookie" at link time). A g++-built probe therefore cannot
# link logging.cpp at all on this box.
#
# On POSIX the compiler is a plain g++/clang++ (the bash harness's own
# mcp_probe_gate shape), and the OpenSSL tree is whatever the system has.
$script:VcVars = $null

# Find-VcVars: locate a vcvars64.bat and remember it. Returns $null when
# no VS install is found.
function Find-VcVars {
    if ($script:VcVars) { return $script:VcVars }
    $candidates = @(
        'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat',
        'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
    )
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -products * -property installationPath 2>$null
        if ($vsPath) {
            $candidates = @((Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat')) + $candidates
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $script:VcVars = $c; return $script:VcVars }
    }
    return $null
}

# Invoke-McpProbe <gate> <label> <src> <extraSources> <extraLibs>
#
# Builds one of the MCP's standalone C++ probes and runs it. All three
# link the MCP's own sources directly rather than driving them through
# the JSON-RPC surface -- which is the only way to reach several of
# their internal branches at all (a malformed vector element would be
# rejected by the MCP's own inputSchema check before it ever reached
# the coercion code; a per-client concurrency limit is a mutex-guarded
# counter that only a direct call can saturate deterministically).
#
# Built from mcp/ so the recorded source path for mcp/src/*.cpp matches
# the main build's own, merging into its coverage rather than
# duplicating it.
#
# $extraLibs is accepted for signature parity with the bash harness's
# mcp_probe_gate, but the Windows link line is fixed: MSVC names its
# libraries without the "-l" prefix and the set is the MCP server's own
# (mcp\scripts\windows\build.bat), because every probe links the same
# MariaDB client + OpenSSL pair. Passing a different set here would
# silently change nothing, so it is ignored rather than half-honored.
function Invoke-McpProbe([string]$gate, [string]$label, [string]$src, [string[]]$extraSources, [string[]]$extraLibs) {
    $probe = Join-Path $script:Here "mcp\tests\$src"
    if (-not (Test-Path -LiteralPath $probe)) {
        Skip "$gate $label ($src not present)"
        return
    }

    $mcpDir = Join-Path $script:Here 'mcp'
    $outDir = $script:PlugDir
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $bin = Join-Path $outDir ($src -replace '\.cpp$', '.exe')
    $buildLog = Join-Path $outDir ($src -replace '\.cpp$', '_build.log')

    # The MariaDB connector headers (db_probe needs them) and the
    # OpenSSL headers (logging.cpp needs them, and db_probe links
    # logging.cpp). The vendored tree's own include dir is the one the
    # harness's Mdb-Setup already uses.
    #
    # The OpenSSL tree is the STATIC one (installed\x64-windows-static) --
    # the same tree mcp\scripts\windows\build.bat uses. The dynamic
    # tree (installed\x64-windows) is empty on this box, and linking
    # against it would produce a binary that wants libssl-3-x64.dll at
    # runtime, which is not staged anywhere.
    $incPaths = @()
    $client = $script:MariaDbClient
    if (-not $client) {
        Fail "${gate} ${label}: no MariaDB Connector/C import library (libmariadb.lib) was found in any candidate tree, so the probe cannot be built. See the warning at the top of the run."
        return
    }
    # The CLIENT tree's headers, not the server tree's: they are the ones
    # that match the import library this probe links against.
    $mdbInc = $client.Inc
    if (Test-Path $mdbInc) { $incPaths += $mdbInc }
    # The OpenSSL tree is resolved through the harness's own
    # Resolve-OpenSslDir, NOT through $env:VCPKG_ROOT directly. The
    # environment variable is the one vcvars64 OVERWRITES with the
    # VS-bundled vcpkg tree -- and that tree has no OpenSSL installed,
    # so reading $env:VCPKG_ROOT here finds headers that are not there
    # and a lib path with no libs in it ("cannot open input file
    # 'libssl.lib'"). Resolve-OpenSslDir is the same resolution the
    # main build uses, and it fails LOUDLY with the vcpkg install
    # command to run, rather than producing a link error.
    try {
        $opensslDir = Resolve-OpenSslDir
    }
    catch {
        Skip "$gate ${label} ($($_.Exception.Message))"
        return
    }
    $incPaths += (Join-Path $opensslDir 'include')

    $libPaths = @()
    $mdbLib = Split-Path -Parent $client.LibPath
    if (Test-Path $mdbLib) { $libPaths += $mdbLib }
    $libPaths += (Join-Path $opensslDir 'lib')

    # The compile is driven through a generated .bat so cl.exe runs
    # INSIDE a vcvars64'd environment: cl.exe needs the CRT/SDK include
    # and lib paths, which only vcvars64 sets up. A .bat (not a bare
    # cl.exe invocation from PowerShell) is what the MCP's own
    # build.bat does for the same reason.
    #
    # The cl.exe command is emitted as ONE line, not a multi-line
    # caret-continued one: a generated .bat whose continuation char is
    # a lone "^" at end-of-line is fragile (a trailing space after the
    # caret, or a stray CR, silently turns the rest of the command
    # into a separate batch line, and cmd then reports "/I is not
    # recognized" for every fragment). One line, no continuation, is
    # the shape that cannot break.
    $bat = Join-Path $env:TEMP "fractalsql_bt_${src -replace '\.cpp$',''}_build.bat"
    $cmd = @(
        'cl.exe', '/nologo', '/std:c++17', '/EHsc', '/O1', '/W3', '/utf-8', '/Zm500',
        '/MT', '/D_CRT_SECURE_NO_WARNINGS', '/DNOMINMAX',
        '/I', '"vendor"'
    )
    foreach ($i in $incPaths) { $cmd += '/I'; $cmd += "`"$i`"" }
    $cmd += "`"tests\$src`""
    foreach ($s in $extraSources) { $cmd += "`"$s`"" }
    $cmd += "/Fe`"$bin`""
    # The DOUBLED trailing backslash is not a typo: cl.exe's /Fo with
    # several source files needs a directory, and a single "\" before
    # the closing quote escapes the quote itself -- cmd then hands cl.exe
    # the rest of the command line as part of the /Fo argument ("/FoC:
    # \...\probes" /link /LIBPATH:C:\Users\Daniel' not allowed with
    # multiple source files). mcp\scripts\windows\build.bat uses the
    # same doubled form for the same reason.
    $cmd += "/Fo`"$outDir\\`""
    $cmd += '/link'
    foreach ($l in $libPaths) { $cmd += "/LIBPATH:`"$l`"" }
    $cmd += $client.LibName, 'libssl.lib', 'libcrypto.lib'
    $cmd += 'ws2_32.lib', 'advapi32.lib', 'crypt32.lib', 'user32.lib'

    $lines = @('@echo off')
    $vc = Find-VcVars
    if ($vc) { $lines += "call `"$vc`" >nul 2>&1" }
    $lines += ($cmd -join ' ')
    $lines += 'exit /b %ERRORLEVEL%'
    [IO.File]::WriteAllLines($bat, $lines)

    Push-Location $mcpDir
    try {
        $bout = & cmd /c "call `"$bat`"" 2>&1
        $bout | Out-File -FilePath $buildLog -Encoding utf8
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
            # The build log lives in $script:PlugDir, which Mdb-Teardown
            # deletes at the end of the run -- so the log's own content
            # is echoed here, while it still exists. A failure message
            # that points at a file the teardown is about to remove is
            # a failure message nobody can act on.
            Write-Host "    --- compiler output ---"
            $bout | ForEach-Object { Write-Host "    $_" }
            Write-Host "    --- end compiler output ---"
            Fail "${gate} ${label}: the probe failed to build"
            return
        }
    }
    finally {
        Pop-Location
    }

    # The probe links the MariaDB client library dynamically, and the
    # DLL is not on the system PATH -- stage it next to the probe exe,
    # the same thing mcp\scripts\windows\build.bat does for the MCP
    # server binary itself. Without this the probe fails to start with
    # "libmariadb.dll: cannot open shared object file" and the gate
    # reports a build failure for what is really a missing runtime
    # dependency. (OpenSSL is the STATIC tree here, so it needs no
    # staging -- only the MariaDB client is a runtime DLL.)
    $mdbDll = $client.Dll
    if ($mdbDll -and (Test-Path -LiteralPath $mdbDll)) {
        Copy-Item -LiteralPath $mdbDll -Destination (Split-Path -Parent $bin) -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "    WARNING: no MariaDB client DLL to stage next to $bin -- the probe will fail to start with a missing-libmariadb.dll error."
    }

    # The db probe reads the connection details from the same MARIADB_*
    # environment variables the MCP server itself reads
    # (EngineConfig::fromEnv). Without them the probe prints its own
    # SKIP line and exits 0 -- which would look like a pass for a probe
    # that never ran against the cluster.
    $env:MARIADB_HOST     = '127.0.0.1'
    $env:MARIADB_PORT     = "$($script:Port)"
    $env:MARIADB_DATABASE = 'fractalsql_bt'
    $env:MARIADB_USER     = 'root'
    $env:MARIADB_PASSWORD = ''
    try {
        $out = & $bin 2>&1
        $rc = $LASTEXITCODE
    }
    finally {
        foreach ($v in @('MARIADB_HOST','MARIADB_PORT','MARIADB_DATABASE','MARIADB_USER','MARIADB_PASSWORD')) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
    $out | ForEach-Object { Write-Host "    $_" }
    if ($rc -eq 0) { Pass "${gate} ${label}: the standalone probe's own checks all passed" }
    else {
        $nOut = @($out).Count
        Fail ("${gate} ${label}: the standalone probe reported a failure (exit code 0x{0:X8}, {1} output lines; see the OK/FAIL lines above)" -f $rc, $nOut)
        if ($nOut -eq 0) { Write-Host "    (no output at all: the probe likely crashed or could not start, e.g. a missing libmariadb.dll)" }
    }
}

function Gate-42-VectorsProbe {
    # vectors.cpp is pure (JSON in, JSON/string/bytes out): no DB, no
    # transport, no cluster needed.
    Invoke-McpProbe '42' 'vectors_probe' 'vectors_probe.cpp' @('src/vectors.cpp', 'src/errors.cpp') @()
}

function Gate-43-DbProbe {
    # db.cpp talks to a LIVE MariaDB server through the C connector, so
    # this gate needs the harness's scratch cluster. The probe skips
    # cleanly (exit 0) when no server is reachable -- a missing cluster
    # is not a defect in db.h.
    Invoke-McpProbe '43' 'db_probe' 'db_probe.cpp' @('src/db.cpp', 'src/errors.cpp', 'src/logging.cpp') @('-lmariadb', '-lssl', '-lcrypto')
}

function Gate-44-ConcurrencyProbe {
    # concurrency.h is header-only and DB-agnostic: no cluster needed.
    Invoke-McpProbe '44' 'concurrency_probe' 'concurrency_probe.cpp' @() @()
}

# Gate 40: the MCP server's direct-TLS mode.
#
# Deliberately narrow (see mcp/tests/mcp_https_smoke_client.py's own
# docstring). What it proves is only what is specific to the TLS mode:
#   1. fail-fast misconfiguration -- TLS with no cert/key, with an
#      unloadable cert, with a key that doesn't parse, and with a valid
#      cert paired with a valid but NON-MATCHING key all exit nonzero
#      immediately, never falling back to plaintext and never hanging.
#   2. the listening port actually speaks TLS (a bare HTTP request
#      against it gets no valid HTTP response).
#   3. a full authenticated JSON-RPC round trip over TLS, with the
#      Bearer-token check still applying underneath it.
function Gate-40-McpHttps {
    $client = Join-Path $script:Here 'mcp\tests\mcp_https_smoke_client.py'
    $mainCpp = Join-Path $script:Here 'mcp\src\main.cpp'
    if (-not (Test-Path -LiteralPath $client) -or -not (Test-Path -LiteralPath $mainCpp)) {
        Skip '40 mcp_https (mcp/ server code not present)'
        return
    }
    $py = Get-PythonExe
    if (-not $py) {
        Skip '40 mcp_https (no python on PATH -- the TLS smoke client driver needs it)'
        return
    }
    $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if (-not $openssl) {
        Skip '40 mcp_https (no openssl CLI on PATH to generate the throwaway TLS cert/key)'
        return
    }

    $mcpExe = Get-McpServerExe '40 mcp_https'
    if (-not $mcpExe) { return }

    # Throwaway self-signed cert/key, 1-day validity, CN=127.0.0.1
    # (the only host this gate ever connects to). Regenerated every
    # run; never reused across invocations and never committed
    # anywhere.
    $tlsCert = Join-Path $env:TEMP 'fractalsql_bt_mcp_https_cert.pem'
    $tlsKey  = Join-Path $env:TEMP 'fractalsql_bt_mcp_https_key.pem'
    $tlsCnf  = Join-Path $env:TEMP 'fractalsql_bt_mcp_https_openssl.cnf'
    Remove-Item -Force $tlsCert, $tlsKey, $tlsCnf -ErrorAction SilentlyContinue
    # A minimal synthesized [req]/distinguished_name section, rather
    # than OPENSSL_CONF=/dev/null (empty config): whichever openssl
    # resolves on PATH may carry a baked-in default config path from
    # an unrelated install (seen in practice on Windows: PostgreSQL's
    # psqlODBC ships its own openssl.exe pointing at its own
    # etc/openssl.cnf, which `openssl req` hard-fails loading if it
    # doesn't exist) -- but macOS's /usr/bin/openssl is Apple's
    # LibreSSL, not OpenSSL, and LibreSSL's `req`, unlike OpenSSL >=
    # 1.1.1, has no built-in fallback when the config has no
    # distinguished_name section. An explicit minimal config satisfies
    # both implementations.
    [IO.File]::WriteAllText($tlsCnf, "[req]`ndistinguished_name = dn`nprompt = no`n[dn]`n")
    $certLog = Join-Path $env:TEMP 'fractalsql_bt_mcp_https_certgen.log'
    & $openssl.Source req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=127.0.0.1' `
        -config $tlsCnf -keyout $tlsKey -out $tlsCert 1>$certLog 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tlsCert)) {
        Fail "40 mcp_https: openssl req failed to generate the throwaway cert/key (see $certLog)"
        return
    }

    # A per-run scratch CWD: the server's stderr JSON log lands there.
    $httpsCwd = Join-Path $env:TEMP "fractalsql_bt_mcp_https_$($MdbMajor -replace '\D','')"
    if (Test-Path $httpsCwd) { Remove-Item -Recurse -Force $httpsCwd -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $httpsCwd | Out-Null

    # The TLS port must be a free port of its own, distinct from every
    # other gate's -- the harness's own 133xx range is already spoken
    # for by the cluster's own port, and a squatted port silently
    # breaks the user's next run.
    $tlsPort = 13400 + ([int]($MdbMajor -replace '\D', '') % 90)

    $env:MCP_SERVER_EXE = $mcpExe
    $env:MCP_SERVER_CWD = $httpsCwd
    $env:MCP_HTTPS_PORT = "$tlsPort"
    $env:MCP_HTTPS_CERT = $tlsCert
    $env:MCP_HTTPS_KEY  = $tlsKey
    $env:MARIADB_HOST     = '127.0.0.1'
    $env:MARIADB_PORT     = "$($script:Port)"
    $env:MARIADB_DATABASE = 'fractalsql_bt'
    $env:MARIADB_USER     = 'root'
    $env:MARIADB_PASSWORD = ''

    # Same reason as gate 39: the server is fail-closed about a missing
    # lock and its default lookup walks up from the scratch CWD, which is
    # not a checkout root. Point it at the repo's committed locks.
    $env:FSQL_MCP_SCHEMA_LOCK = Join-Path $script:Here 'mcp\.mcp-schema-lock'
    $env:FSQL_MCP_SAFETY_LOCK = Join-Path $script:Here 'mcp\.mcp-safety-annotations-lock'

    try {
        & $py -u $client 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -eq 0) {
            Pass '40 mcp_https: TLS fail-fast misconfig, TLS-only listening, a full authenticated JSON-RPC round trip, one reply per connection, and a terminal 404'
        }
        else {
            Fail "40 mcp_https: client driver exited $LASTEXITCODE (server log: $httpsCwd\mcp_https_server.log)"
        }
    }
    finally {
        foreach ($v in @('MCP_SERVER_EXE','MCP_SERVER_CWD','MCP_HTTPS_PORT','MCP_HTTPS_CERT',
                         'MCP_HTTPS_KEY','MARIADB_HOST','MARIADB_PORT','MARIADB_DATABASE',
                         'MARIADB_USER','MARIADB_PASSWORD',
                         'FSQL_MCP_SCHEMA_LOCK','FSQL_MCP_SAFETY_LOCK')) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
}

# Gate 41: the standalone parser probe.
#
# src/fractalsql_parse.c is a standalone TU with no <mysql.h> dependency
# (that is deliberate -- it is what lets the libFuzzer drivers link it
# without a MariaDB dev package), so this gate needs only a C compiler:
# no extension .so, no mariadbd, no cluster at all. It exercises the
# three parsers' malformed-input branches, which no end-to-end gate
# reaches: parse_vector_csv runs on the embeddings endpoint's raw,
# unvalidated HTTP response body, and parse_corpus / parse_index_csv see
# SQL-caller-supplied text -- every realistic caller feeds them
# well-formed text, so their error paths are otherwise dead.
function Gate-41-ParseProbe {
    $probe = Join-Path $script:Here 'tests\parse_csv_probe.c'
    if (-not (Test-Path -LiteralPath $probe)) {
        Skip '41 parse_probe (tests\parse_csv_probe.c not present)'
        return
    }
    $cc = Get-Command cc.exe -ErrorAction SilentlyContinue
    if (-not $cc) { $cc = Get-Command gcc.exe -ErrorAction SilentlyContinue }
    if (-not $cc) { $cc = Get-Command clang.exe -ErrorAction SilentlyContinue }
    if (-not $cc) {
        Skip '41 parse_probe (no C compiler on PATH)'
        return
    }
    $outDir = Join-Path $env:TEMP 'fractalsql_bt_parse_probe'
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $buildLog = Join-Path $outDir 'parse_csv_probe_build.log'
    $bin = Join-Path $outDir 'parse_csv_probe.exe'
    # The parse TU is C (not C++) and lives in the repo's own src/ --
    # the include path is the repo root's src/, so the probe's
    # "../src/fractalsql_parse.h" resolves.
    & $cc.Source -std=c99 -O1 -g -I (Join-Path $script:Here 'src') `
        (Join-Path $script:Here 'tests\parse_csv_probe.c') `
        (Join-Path $script:Here 'src\fractalsql_parse.c') `
        (Join-Path $script:Here 'src\fractalsql_interrupt.c') `
        -o $bin 1>$buildLog 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bin)) {
        Fail "41 parse_probe: the probe failed to build (see $buildLog)"
        return
    }
    $out = & $bin 2>&1
    $rc = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "    $_" }
    if ($rc -eq 0) {
        Pass '41 parse_probe: parse_vector_csv / parse_corpus / parse_index_csv happy paths and every malformed-input rejection'
    }
    else {
        Fail '41 parse_probe: the parser probe reported a failure (see the OK/FAIL lines above)'
    }
}

function Gate-45-DomainAgents {
    # Windows port of build_test.sh's gate_45_domain_agents: the
    # Agency-tier (Domain Agent) engine sweep -- one live CALL per
    # engine, this server's own result-JSON key names, this server's
    # own SIGNAL messages, and the reasoning canary that proves the
    # LLM tier really ran.
    #
    # Three differences from the POSIX original, all forced by the
    # server's own shape rather than by the platform:
    #   1. CALL, not SELECT. Every engine here is a stored PROCEDURE
    #      with a trailing OUT p_result JSON, so the calling shape is
    #      "CALL fractal_agent_x(args..., @r); SELECT @r;" -- one
    #      connection, two statements. A scalar SELECT would raise
    #      ERROR 1305 (PROCEDURE ... does not exist).
    #   2. The engines' own SIGNAL messages, not upstream's.
    #   3. MariaDB's own result-JSON key names, which differ from
    #      upstream's (threat_score, not anomaly_score; rationale, not
    #      explanation; morph_dimension, not dimension; ...).
    #
    # The reasoning canary: the mock LLM's canned reply is
    # "```sql\nSELECT 1\n```" and fractal_reason returns it verbatim,
    # so "SELECT 1" appearing inside an engine's rationale /
    # triage_summary / analysis field is the observable proof that the
    # engine's reasoning step really ran against the live endpoint.

    $g45err = "$env:TEMP\fractalsql_bt_gate45.err"

    # Invoke-G45Sql <sql>: run one statement batch, return its STDOUT.
    # stderr goes to its own file rather than being folded into the
    # result: a SIGNAL lands on stderr, but so does the client's own
    # noise (the Windows client's "insecure passwordless login"
    # notice, for one), and folding the two together makes a data
    # assertion match a warning line instead of the value it is
    # looking for.
    #
    # The client's exit code is published in $script:G45Exit rather than
    # read back from $LASTEXITCODE by the caller: $LASTEXITCODE is set
    # in the scope where the native command ran, so a caller outside
    # this nested function's scope can see a stale value from whatever
    # ran before it.
    function Invoke-G45Sql([string]$sql) {
        $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N -e $sql 2>$g45err
        $script:G45Exit = $LASTEXITCODE
        return @($out)
    }

    # Test-G45Error <label> <expected-substring> <sql>: assert the
    # statement FAILS with the expected clean error. The client exits
    # nonzero on a SIGNAL and the message lands on stderr.
    function Test-G45Error([string]$label, [string]$want, [string]$sql) {
        $out = Invoke-G45Sql $sql
        $rc = $script:G45Exit
        $err = ""
        if (Test-Path -LiteralPath $g45err) { $err = [string](Get-Content -LiteralPath $g45err -Raw) }
        if ($rc -eq 0) {
            Fail "45 domain_agents: $label -- expected an error, but the call succeeded: $out"
            return
        }
        if (($err + ($out -join "`n")).Contains($want)) { Pass "45 domain_agents: $label" }
        else { Fail "45 domain_agents: $label -- expected '$want', got: $err$out" }
    }

    # The reasoning-tier assertions need the mock LLM endpoint the
    # harness's own Mdb-Setup wires up -- FRACTALSQL_HTTP_URL is set
    # only when the mock actually came up. Without it the data half of
    # every engine still runs, but every rationale comes back NULL, so
    # the canary assertions SKIP rather than FAIL.
    $haveReasoning = [bool]$env:FRACTALSQL_HTTP_URL

    # Test-G45Canary <label> <json>: the reasoning canary. The mock
    # LLM's canned reply is "```sql\nSELECT 1\n```" and fractal_reason
    # returns it verbatim, so "SELECT 1" inside the engine's own
    # rationale/triage_summary/analysis field is the proof that the
    # reasoning step really ran.
    function Test-G45Canary([string]$label, [string]$json) {
        if (-not $haveReasoning) { Skip "45 domain_agents: $label (no mock LLM endpoint configured)"; return }
        if ($json.Contains('SELECT 1')) { Pass "45 domain_agents: $label" }
        else { Fail "45 domain_agents: $label -- expected the reasoning canary, got: $json" }
    }

    # --- fixtures ------------------------------------------------------
    # Every fixture is deterministic: no RAND() anywhere, so a rerun
    # of the gate produces byte-identical results and a numeric
    # assertion can be an exact comparison rather than a range.
    $fixtureSql = @'
DROP TABLE IF EXISTS g45_logs, g45_alloc, g45_nodes, g45_data,
                         g45_vehicles, g45_tracks, g45_empty,
                         g45_fcatalog, g45_fwarmup, g45_traj, g45_univ;

-- Engine A: a drifting metric series with a real regime change
-- after row 48, so fractal_dimension_drift's 32-point recent
-- window has something to detect.
CREATE TABLE g45_logs (id BIGINT PRIMARY KEY AUTO_INCREMENT,
                        metric DOUBLE, ts BIGINT, host VARCHAR(32));
INSERT INTO g45_logs (metric, ts, host)
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 96)
SELECT 50.0 + MOD(gs, 8) * 1.3 + CASE WHEN gs > 48 THEN 30.0 ELSE 0.0 END,
       gs, 'host-1' FROM seq;

-- Engine K: three stored allocations to search against.
CREATE TABLE g45_alloc (id BIGINT PRIMARY KEY, alloc JSON);
INSERT INTO g45_alloc VALUES
    (1, '[0.25, 0.25, 0.25, 0.25]'),
    (2, '[0.40, 0.30, 0.20, 0.10]'),
    (3, '[0.10, 0.20, 0.30, 0.40]');

-- Engine J: three nodes with distinct 5-D capability vectors.
CREATE TABLE g45_nodes (id INT PRIMARY KEY, capability JSON);
INSERT INTO g45_nodes VALUES
    (1, '[0.9, 0.1, 0.0, 0.0, 0.0]'),
    (2, '[0.0, 0.0, 0.9, 0.1, 0.0]'),
    (3, '[0.1, 0.0, 0.0, 0.0, 0.9]');

-- Engine G: a small fact table for the text-to-SQL agent.
CREATE TABLE g45_data (id INT PRIMARY KEY, category VARCHAR(32), amount DOUBLE);
INSERT INTO g45_data VALUES
    (1, 'hardware', 1200.00), (2, 'software', 800.50), (3, 'hardware', 450.25);

-- Engines L and M: fleet and track tables, plus an EMPTY one
-- (the clean-error fixtures for both engines).
CREATE TABLE g45_vehicles (id INT PRIMARY KEY, emb JSON);
INSERT INTO g45_vehicles VALUES
    (1, '[0.9, 0.1, 0.0, 0.0]'), (2, '[0.0, 0.9, 0.0, 0.0]'), (3, '[0.0, 0.0, 0.9, 0.0]');
CREATE TABLE g45_tracks (id INT PRIMARY KEY, emb JSON);
INSERT INTO g45_tracks VALUES
    (1, '[0.9, 0.1, 0.0, 0.0]'), (2, '[0.0, 0.9, 0.0, 0.0]'), (3, '[0.0, 0.0, 0.9, 0.0]');
CREATE TABLE g45_empty (id INT PRIMARY KEY, emb JSON);

-- Engine I: a catalog to diversify over and a warmup table whose
-- rows are the varied queries that fill the D_q rolling window.
CREATE TABLE g45_fcatalog (id BIGINT PRIMARY KEY, emb JSON);
INSERT INTO g45_fcatalog
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 20)
SELECT gs, JSON_ARRAY(ROUND(MOD(gs,7)/7.0,4), ROUND(MOD(gs*3,11)/11.0,4), ROUND(MOD(gs*5,13)/13.0,4)) FROM seq;
CREATE TABLE g45_fwarmup (ord INT PRIMARY KEY, vc JSON);
INSERT INTO g45_fwarmup
WITH RECURSIVE seq(gs) AS (SELECT 1 UNION ALL SELECT gs+1 FROM seq WHERE gs < 8)
SELECT gs, JSON_ARRAY(ROUND(MOD(gs,5)/5.0,4), ROUND(MOD(gs*2,7)/7.0,4), ROUND(MOD(gs*3,9)/9.0,4)) FROM seq;

-- fractal_agent_trajectory_predict: a three-row trajectory.
CREATE TABLE g45_traj (id BIGINT PRIMARY KEY, emb JSON);
INSERT INTO g45_traj VALUES
    (1, '[0.1, 0.2, 0.3]'), (2, '[0.2, 0.3, 0.4]'), (3, '[0.3, 0.4, 0.5]');

-- The Universal Agent procedures' shared corpus.
CREATE TABLE g45_univ (id BIGINT PRIMARY KEY, emb JSON, txt TEXT);
INSERT INTO g45_univ VALUES
    (1, '[0.1, 0.2, 0.3]', 'alpha doc'),
    (2, '[0.9, 0.8, 0.7]', 'beta doc');
'@
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e $fixtureSql 2>$g45err | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "45 domain_agents: fixture setup failed (see $g45err)"
        Get-Content -LiteralPath $g45err
        return
    }

    # --- Engine A: fractal_agent_anomaly_triage -----------------------
    # drift + reason. The threat_score is a real computed float (not a
    # constant), and the triage_summary carries the reasoning canary.
    $a1 = (Invoke-G45Sql @'
CALL fractal_agent_anomaly_triage('g45_logs','metric','ts','host','host-1',32,@r);
SELECT @r;
'@) -join "`n"
    if ($a1 -match '"threat_score" *: *"-?[0-9]+\.[0-9]+"') { Pass "45 domain_agents: anomaly_triage (A) threat_score is a real computed drift float" } else { Fail "45 domain_agents: anomaly_triage threat_score not a float: $a1" }
    Test-G45Canary "anomaly_triage (A) composes drift -> reason (the reasoning step really ran)" $a1
    if ($a1 -match '"anomaly_type" *: *"vector_drift"') { Pass "45 domain_agents: anomaly_triage (A) names the anomaly type" } else { Fail "45 domain_agents: anomaly_triage anomaly_type missing: $a1" }
    Test-G45Error "anomaly_triage (A) raises a clean error when the filter matches no rows" `
        "no rows matching the filter" `
        "CALL fractal_agent_anomaly_triage('g45_logs','metric','ts','host','no-such-host',32,@r);"
    Test-G45Error "anomaly_triage (A) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_anomaly_triage(NULL,'metric','ts','host','host-1',32,@r);"

    # --- Engine B: fractal_agent_allocate -----------------------------
    # Community-tier cardinality-constrained optimizer + reason. The
    # 'allocation' key is a NESTED object ({"sharpe":..,"weights":[..]}),
    # so JSON_EXTRACT is the right tool, not JSON_VALUE.
    $b1 = (Invoke-G45Sql @'
CALL fractal_agent_allocate('[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1,
                            '{"portfolio": "gate45"}', @r);
SELECT @r;
'@) -join "`n"
    if ($b1 -match '"weights" *: *\[[^\]]*\]') { Pass "45 domain_agents: allocate (B) returns a real nested allocation with weights" } else { Fail "45 domain_agents: allocate allocation.weights missing: $b1" }
    if ($b1 -match '"sharpe" *: *"?0\.1"?') { Pass "45 domain_agents: allocate (B) sharpe matches the hand-computed value (0.1)" } else { Fail "45 domain_agents: allocate sharpe was not 0.1: $b1" }
    Test-G45Canary "allocate (B) narrates the allocation through the reasoning tier" $b1

    # --- Engine G: fractal_agent_data_analyst -------------------------
    # The horizontal NL -> SQL -> execute -> reason engine. The mock
    # LLM's canned reply IS a valid SELECT, so the whole pipeline runs
    # for real: the generated_sql is the mock's own fenced block
    # ("SELECT 1") and result_json reports the execution.
    # p_auto_execute is the caller's EXPLICIT opt-in (the procedure has
    # no default -- MariaDB routines cannot carry DEFAULT values), so
    # the executing path passes TRUE explicitly.
    $g1 = (Invoke-G45Sql @'
CALL fractal_agent_data_analyst('total amount spent per category in g45_data',
                                '["g45_data"]', 2, NULL, TRUE, @r);
SELECT @r;
'@) -join "`n"
    if ($g1 -match '"generated_sql" *: *"SELECT 1"') { Pass "45 domain_agents: data_analyst (G) generated real SQL from the LLM tier" } else { Fail "45 domain_agents: data_analyst generated_sql missing: $g1" }
    if ($g1 -match '"status" *: *"executed"') { Pass "45 domain_agents: data_analyst (G) actually EXECUTED the generated SQL" } else { Fail "45 domain_agents: data_analyst result_json not executed: $g1" }
    Test-G45Canary "data_analyst (G) narrates the result through the reasoning tier" $g1
    # p_auto_execute => FALSE: the statement is generated and validated
    # but NOT run, so result_json carries no "executed" status and the
    # reasoning step never runs (analysis stays null).
    $g1b = (Invoke-G45Sql @'
CALL fractal_agent_data_analyst('total amount spent per category in g45_data',
                                '["g45_data"]', 2, NULL, FALSE, @r);
SELECT @r;
'@) -join "`n"
    if ($g1b -match '"generated_sql" *: *"SELECT 1"') { Pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE still returns the generated SQL" } else { Fail "45 domain_agents: data_analyst generated_sql missing with auto_execute=FALSE: $g1b" }
    if ($g1b -match '"status" *: *"executed"') { Fail "45 domain_agents: data_analyst (G) EXECUTED the generated SQL with auto_execute=FALSE" } else { Pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE does NOT execute the generated SQL" }
    if ($g1b -match '"analysis" *: *null') { Pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE skips the reasoning step (analysis null)" } else { Fail "45 domain_agents: data_analyst analysis is not null with auto_execute=FALSE: $g1b" }

    # --- Engine I: fractal_agent_feedback_audit -----------------------
    # Pure analytics, no LLM: it warms the D_q window with varied
    # searches and reports the diversity quotient. The explanation is a
    # NESTED object ({"dq":..,"diversify_enabled":..}).
    $i1 = (Invoke-G45Sql @'
CALL fractal_agent_feedback_audit('g45_fcatalog','emb','[0.5,0.5,0.5]',
                                  'g45_fwarmup','vc',8,3,@r);
SELECT @r;
'@) -join "`n"
    if ($i1 -match '"diversity_quotient" *: *"?-?[0-9]') { Pass "45 domain_agents: feedback_audit (I) reports a real diversity quotient" } else { Fail "45 domain_agents: feedback_audit diversity_quotient missing: $i1" }
    if ($i1 -match '"diversify_enabled" *: *true') { Pass "45 domain_agents: feedback_audit (I) reports the diversify state it ran under" } else { Fail "45 domain_agents: feedback_audit explanation lacks diversify_enabled: $i1" }
    Test-G45Error "feedback_audit (I) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_feedback_audit(NULL,'emb','[0.5]','g45_fwarmup','vc',8,3,@r);"

    # --- Engine J: fractal_agent_schedule_workload --------------------
    # fractal_search refinement + telemetry + reason. The assignment is
    # the node table's own PRIMARY KEY (id 1, nearest to the refined
    # task vector), and the confidence is 1/(1+distance) -- a real
    # number in (0,1].
    $j1 = (Invoke-G45Sql @'
CALL fractal_agent_schedule_workload('[0.8, 0.1, 0.0, 0.0, 0.1]',
                                     'g45_nodes', 'capability', 30, 50, 5, NULL, @r);
SELECT @r;
'@) -join "`n"
    if ($j1 -match '"assigned_node" *: *"1"') { Pass "45 domain_agents: schedule_workload (J) assigns the nearest node (1)" } else { Fail "45 domain_agents: schedule_workload assigned_node wrong: $j1" }
    if ($j1 -match '"confidence" *: *"?0\.[0-9]') { Pass "45 domain_agents: schedule_workload (J) derives a real confidence from the distance" } else { Fail "45 domain_agents: schedule_workload confidence missing: $j1" }
    Test-G45Canary "schedule_workload (J) justifies the placement through the reasoning tier" $j1
    Test-G45Error "schedule_workload (J) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_schedule_workload('[0.1]', NULL, 'capability', 30, 50, 5, NULL, @r);"
    # The engine's own "no node rows found" is likewise unreachable
    # behind the shared scanner's error, for the same reason as L and M
    # below.
    Test-G45Error "schedule_workload (J) raises a clean error when the node table has no rows" `
        "no non-NULL vector rows found" `
        "CALL fractal_agent_schedule_workload('[0.9,0.1,0.0,0.0,0.1]', 'g45_empty', 'emb', 30, 50, 5, NULL, @r);"

    # --- Engine K: fractal_agent_rebalance_sibling --------------------
    # Community optimizer + trajectory search + reason. The nearest
    # allocation is resolved by searching the DELTA (current minus
    # baseline) against the stored allocation vectors, so the winner is
    # a real distance computation, not a fixed id.
    $k1 = (Invoke-G45Sql @'
CALL fractal_agent_rebalance_sibling(
    '[0.05, 0.10, 0.15, 0.20]',
    '[0.04, 0.0, 0.0, 0.0, 0.0, 0.09, 0.0, 0.0, 0.0, 0.0, 0.16, 0.0, 0.0, 0.0, 0.0, 0.25]',
    4, 'g45_alloc', 'alloc', '[0.25, 0.25, 0.25, 0.25]', 42, NULL, @r);
SELECT @r;
'@) -join "`n"
    if ($k1 -match '"nearest_alloc_id" *: *"[123]"') { Pass "45 domain_agents: rebalance_sibling (K) resolves a real nearest allocation" } else { Fail "45 domain_agents: rebalance_sibling nearest_alloc_id missing: $k1" }
    if ($k1 -match '"weights" *: *\[[^\]]*\]') { Pass "45 domain_agents: rebalance_sibling (K) returns the optimizer's weights" } else { Fail "45 domain_agents: rebalance_sibling weights missing: $k1" }
    Test-G45Canary "rebalance_sibling (K) narrates the rebalance through the reasoning tier" $k1
    Test-G45Error "rebalance_sibling (K) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_rebalance_sibling('[0.1]','[1,0,0,1]',1,NULL,'alloc','[1]',42,NULL,@r);"

    # --- Engine L: fractal_agent_detour_classify ----------------------
    # Trajectory search + box-counting dimension of the GPS trace + reason.
    # The trace needs a few hundred points for the box count to be
    # meaningful; a deterministic sine walk supplies them.
    $l1 = (Invoke-G45Sql @'
CALL fractal_agent_detour_classify(
    'g45_vehicles', 'emb', '[0.9, 0.1, 0.0, 0.0]', '[0.0, 0.9, 0.0, 0.0]',
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 200)
        SELECT t, ROUND(SIN(t/9.0) + t/200.0, 6) AS v FROM seq) q),
    5, 2, @r);
SELECT @r;
'@) -join "`n"
    if ($l1 -match '"nearest_fleet_id" *: *"[123]"') { Pass "45 domain_agents: detour_classify (L) resolves the nearest fleet peer" } else { Fail "45 domain_agents: detour_classify nearest_fleet_id missing: $l1" }
    if ($l1 -match '"trace_complexity" *: *"?-?[0-9]') { Pass "45 domain_agents: detour_classify (L) computes a real box-counting dimension for the GPS trace" } else { Fail "45 domain_agents: detour_classify trace_complexity missing: $l1" }
    Test-G45Canary "detour_classify (L) classifies the detour through the reasoning tier" $l1
    Test-G45Error "detour_classify (L) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_detour_classify(NULL,'emb','[1,0]','[0,1]','[1,2]',5,2,@r);"
    # NOTE the message asserted here is the SHARED scanner's
    # ("_fractalsql_scan_corpus: no non-NULL vector rows found"), not
    # detour_classify's own "no vehicle rows found". The engine's own
    # message is unreachable for an empty table: fractal_search_
    # trajectory -> _fractalsql_scan_corpus raises FIRST, before the
    # engine's own JSON_LENGTH(v_traj) = 0 check ever runs. Asserting
    # the message that actually reaches the client (rather than the one
    # the procedure's source reads like it should raise) is the point
    # of this assertion -- a clean, specific error either way.
    Test-G45Error "detour_classify (L) raises a clean error when the fleet table has no rows" `
        "no non-NULL vector rows found" `
        "CALL fractal_agent_detour_classify('g45_empty','emb','[1,0]','[0,1]','[1,2]',5,2,@r);"

    # --- Engine M: fractal_agent_track_anomaly -----------------------
    # Trajectory search + DFA over the heading series + reason.
    $m1 = (Invoke-G45Sql @'
CALL fractal_agent_track_anomaly(
    'g45_tracks', 'emb', '[0.9, 0.1, 0.0, 0.0]', '[0.0, 0.9, 0.0, 0.0]',
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 120)
        SELECT t, ROUND(0.1 + 0.02*SIN(t/7.0), 6) AS v FROM seq) q),
    5, @r);
SELECT @r;
'@) -join "`n"
    if ($m1 -match '"nearest_fleet_id" *: *"[123]"') { Pass "45 domain_agents: track_anomaly (M) resolves the nearest tracked peer" } else { Fail "45 domain_agents: track_anomaly nearest_fleet_id missing: $m1" }
    if ($m1 -match '"dfa_exponent" *: *"?-?[0-9]') { Pass "45 domain_agents: track_anomaly (M) computes a real DFA exponent over the heading series" } else { Fail "45 domain_agents: track_anomaly dfa_exponent missing: $m1" }
    Test-G45Canary "track_anomaly (M) triages the track through the reasoning tier" $m1
    Test-G45Error "track_anomaly (M) rejects NULL identifier arguments" `
        "identifier arguments must not be NULL" `
        "CALL fractal_agent_track_anomaly(NULL,'emb','[1,0]','[0,1]','[1,2,3]',5,@r);"
    # Same shared-scanner-first ordering as detour_classify above: the
    # engine's own "no track rows found" is unreachable behind
    # _fractalsql_scan_corpus's error.
    Test-G45Error "track_anomaly (M) raises a clean error when the track table has no rows" `
        "no non-NULL vector rows found" `
        "CALL fractal_agent_track_anomaly('g45_empty','emb','[1,0]','[0,1]','[1,2,3]',5,@r);"

    # --- Engine N: fractal_agent_network_coverage_alert --------------
    # No table arguments: the point cloud and the drift series are
    # passed directly. The cloud is a flattened 20x20 grid (800 values,
    # 2 per point), which is what the box count needs to be meaningful.
    $n1 = (Invoke-G45Sql @'
CALL fractal_agent_network_coverage_alert(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY id, ord SEPARATOR ','), ']') FROM (
        SELECT r0*20 + c0 AS id, 1 AS ord, r0 + MOD(c0,3)*0.01 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
        UNION ALL
        SELECT r0*20 + c0 AS id, 2 AS ord, c0 + MOD(r0,3)*0.01 AS v
          FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (r0 INT PATH '$')) AS rr
         CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '$[*]' COLUMNS (c0 INT PATH '$')) AS cc
    ) g),
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
        SELECT t, ROUND(CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31)
                             ELSE 4.0 + 3.0*SIN(t*1.4) END, 6) AS v FROM seq) q),
    2, 48, 0.5, NULL, @r);
SELECT @r;
'@) -join "`n"
    if ($n1 -match '"morph_dimension" *: *"?-?[0-9]') { Pass "45 domain_agents: network_coverage_alert (N) computes a real morphological dimension" } else { Fail "45 domain_agents: network_coverage_alert morph_dimension missing: $n1" }
    if ($n1 -match '"lacunarity" *: *"?-?[0-9]') { Pass "45 domain_agents: network_coverage_alert (N) computes a real lacunarity" } else { Fail "45 domain_agents: network_coverage_alert lacunarity missing: $n1" }
    if ($n1 -match '"drift_detected" *: *"?1"?') { Pass "45 domain_agents: network_coverage_alert (N) detects the drift in the series" } else { Fail "45 domain_agents: network_coverage_alert drift_detected not set: $n1" }
    Test-G45Canary "network_coverage_alert (N) issues the alert through the reasoning tier" $n1
    Test-G45Error "network_coverage_alert (N) requires both the point cloud and the drift series" `
        "point_cloud and drift_series are required" `
        "CALL fractal_agent_network_coverage_alert(NULL, '[1,2,3]', 2, 48, 0.5, NULL, @r);"

    # --- Engine O: fractal_agent_regime_triage -----------------------
    # The general-purpose engine: DFA + drift + reason, no table
    # arguments at all.
    $o1 = (Invoke-G45Sql @'
CALL fractal_agent_regime_triage(
    (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
        WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
        SELECT t, ROUND(CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31)
                             ELSE 4.0 + 3.0*SIN(t*1.4) END, 6) AS v FROM seq) q),
    64, 0.5, NULL, @r);
SELECT @r;
'@) -join "`n"
    if ($o1 -match '"dfa_exponent" *: *"?-?[0-9]') { Pass "45 domain_agents: regime_triage (O) computes a real DFA exponent" } else { Fail "45 domain_agents: regime_triage dfa_exponent missing: $o1" }
    if (($o1 -match '"recent_alpha" *: *"?-?[0-9]') -and ($o1 -match '"baseline_alpha" *: *"?-?[0-9]')) { Pass "45 domain_agents: regime_triage (O) reports both the recent and the baseline alpha" } else { Fail "45 domain_agents: regime_triage alpha pair missing: $o1" }
    if ($o1 -match '"drift_detected" *: *"?1"?') { Pass "45 domain_agents: regime_triage (O) detects the regime change" } else { Fail "45 domain_agents: regime_triage drift_detected not set: $o1" }
    Test-G45Error "regime_triage (O) requires a series" `
        "series is required" `
        "CALL fractal_agent_regime_triage(NULL, 64, 0.5, NULL, @r);"

    # --- Engine P: fractal_agent_diverse_portfolios ------------------
    # Enterprise-tier: the backing fractal_optimize_portfolio_multimodal
    # returns NULL on a Community deployment, and the procedure SIGNALs
    # a clean error rather than passing that NULL through as if it were
    # real data. The objective_mode guard is checked FIRST, so it fires
    # even with no enterprise tier loaded.
    Test-G45Error "diverse_portfolios (P) rejects an unknown objective_mode" `
        "objective_mode must be 'sharpe' or 'pareto'" `
        "CALL fractal_agent_diverse_portfolios('[0.05,0.1]','[1,0,0,1]',1,4,0.3,0.8,NULL,'nonsense',NULL,@r);"
    Test-G45Error "diverse_portfolios (P) raises a clean error when the enterprise tier is not loaded" `
        "enterprise tier not loaded" `
        "CALL fractal_agent_diverse_portfolios('[0.05,0.1]','[1,0,0,1]',1,4,0.3,0.8,NULL,'sharpe',NULL,@r);"

    # --- the Universal Agent procedures ------------------------------
    # fractal_search_agent: embed -> scan -> Scout search -> refetch
    # the rows -> reason. The mock's canned embedding is a real
    # 3-element vector, so the whole pipeline runs.
    $u1 = (Invoke-G45Sql @'
CALL fractal_search_agent('alpha', 'g45_univ', 'emb', 20, 30, @r);
SELECT @r;
'@) -join "`n"
    if ($u1 -match '"source_doc_ids" *: *\[[^\]]*\]') { Pass "45 domain_agents: search_agent resolves real source doc_ids from the corpus" } else { Fail "45 domain_agents: search_agent source_doc_ids missing: $u1" }
    Test-G45Canary "search_agent answers through the reasoning tier" $u1
    Test-G45Error "search_agent rejects NULL arguments" `
        "query, table_name and vector_col must not be NULL" `
        "CALL fractal_search_agent(NULL,'g45_univ','emb',20,30,@r);"

    # fractal_rag_agent: the same pipeline behind a thinner surface --
    # the OUT is the bare answer scalar, not a document.
    $u2 = (Invoke-G45Sql @'
CALL fractal_rag_agent('alpha', 'g45_univ', 'emb', JSON_OBJECT('x',1), @r);
SELECT @r;
'@) -join "`n"
    Test-G45Canary "rag_agent returns the reasoned answer as a bare scalar" $u2

    # fractal_agent_plan_explore: each branch is a DISTINCT corpus row
    # with its OWN vector (the branch's plan_trajectory), not the query
    # vector repeated.
    $u3 = (Invoke-G45Sql @'
CALL fractal_agent_plan_explore('start', 'g45_univ', 'emb', 2, @r);
SELECT @r;
'@) -join "`n"
    if ($u3 -match '"plan_trajectory"') { Pass "45 domain_agents: plan_explore returns a plan trajectory per branch" } else { Fail "45 domain_agents: plan_explore plan_trajectory missing: $u3" }
    Test-G45Error "plan_explore rejects NULL arguments" `
        "initial_state, strategy_table and vector_col must not be NULL" `
        "CALL fractal_agent_plan_explore(NULL,'g45_univ','emb',2,@r);"

    # fractal_agent_trajectory_predict: reads the baseline row by PK,
    # computes the delta, and searches the whole table for the nearest
    # point to that delta.
    $u4 = (Invoke-G45Sql @'
CALL fractal_agent_trajectory_predict('g45_traj','emb',1,3,0.5,@r);
SELECT @r;
'@) -join "`n"
    if ($u4 -match '"predicted_state_vector" *: *\[[^\]]*\]') { Pass "45 domain_agents: trajectory_predict returns a predicted state vector" } else { Fail "45 domain_agents: trajectory_predict predicted_state_vector missing: $u4" }
    if ($u4 -match '"projected_drift_delta" *: *"?-?[0-9]') { Pass "45 domain_agents: trajectory_predict computes a real projected drift delta" } else { Fail "45 domain_agents: trajectory_predict projected_drift_delta missing: $u4" }
    Test-G45Error "trajectory_predict rejects NULL arguments" `
        "table, vector_col and baseline_id must not be NULL" `
        "CALL fractal_agent_trajectory_predict(NULL,'emb',1,3,0.5,@r);"
    Test-G45Error "trajectory_predict raises a clean error for a baseline_id that does not exist" `
        "no row with the given baseline_id" `
        "CALL fractal_agent_trajectory_predict('g45_traj','emb',999,3,0.5,@r);"

    # --- the whole tier, in one sweep --------------------------------
    # A single call that exercises every engine in turn, so a
    # regression that breaks one engine's registration (a dropped
    # procedure, a renamed OUT parameter) is caught as one clean
    # failure rather than as N independent ones that each fail for
    # their own reason.
    $all1 = ((Invoke-G45Sql @'
SELECT COUNT(*) FROM information_schema.routines
 WHERE routine_schema = 'fractalsql_bt' AND routine_type = 'PROCEDURE'
   AND routine_name IN (
     'fractal_agent_anomaly_triage','fractal_agent_allocate',
     'fractal_agent_route_task','fractal_agent_outlier_intercept',
     'fractal_agent_recall_hybrid','fractal_agent_recommend_diverse',
     'fractal_agent_data_analyst','fractal_agent_patient_deterioration_triage',
     'fractal_agent_feedback_audit','fractal_agent_schedule_workload',
     'fractal_agent_rebalance_sibling','fractal_agent_detour_classify',
     'fractal_agent_track_anomaly','fractal_agent_network_coverage_alert',
     'fractal_agent_regime_triage','fractal_agent_diverse_portfolios',
     'fractal_agent_trajectory_predict','fractal_search_agent',
     'fractal_rag_agent','fractal_agent_plan_explore',
     'fractal_agent_detect_loop');
'@) -join "`n").Trim()
    if ($all1 -eq "21") { Pass "45 domain_agents: all 16 lettered engines plus the 5 Universal Agent procedures are registered" } else { Fail "45 domain_agents: expected 21 registered agent procedures, got: $all1" }

    # --- cleanup ------------------------------------------------------
    & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -e "DROP TABLE IF EXISTS g45_logs, g45_alloc, g45_nodes, g45_data, g45_vehicles, g45_tracks, g45_empty, g45_fcatalog, g45_fwarmup, g45_traj, g45_univ;" 2>$g45err | Out-Null
}

# --- dispatch --------------------------------------------------------

# ======================================================================
# Robustness gates 51, 52, 55, 58 and 60
#
# The gates above prove what each function does with GOOD input. These
# prove what the engine does with BAD input, and that its input
# validators and integrity checks give the right verdict. They are the
# Windows twins of build_test.sh's gates of the same numbers and share
# its tables (tests\robustness\*.tsv):
#
#   51 udf_sweeps          every UDF with malformed, extreme and oversize
#                          arguments, odd JSON parameter spellings, and
#                          the session configuration functions
#   52 validators          the text-to-SQL allowlist and the audit-log
#                          JSON check against tables with a known verdict
#   55 ledger_forged       hand-built ledgers, valid and corrupted, under
#                          a matching key, no key and the wrong key
#   58 enterprise_loading  enterprise_lib and signature combinations
#   60 scripted_replies    reasoning-plugin replies of every shape
#
# Gates 53, 54, 56, 57, 59, 61 and 62 of build_test.sh are not ported:
# 53, 54 and 61 drive the daemon's AF_UNIX socket and its POSIX
# permission rules, 56 relies on POSIX file modes, 57 relies on
# LD_PRELOAD, and 59 and 62 would need the reload client to change keys
# one at a time (they are covered in part by gates 33 and 34 above).
#
# A sweep passes when the daemon is still running and still answers
# afterwards and logged no FATAL. These gates restart the daemon in place
# on the same pipe and key, so the server's shim keeps working across
# restarts; the daemon's configuration file is restored at the end of
# each gate.
# ======================================================================
$script:RbBaseConf = $null
$script:RbFatal    = $null

function Rb-Begin {
    $script:RbBaseConf = Get-Content -Path $script:FsqdConf
    $script:RbFatal = $null
}

# Runs the mariadb client against the scratch server; returns the output lines.
function Rb-Mdb([string[]]$ClientArgs) {
    $out = & $script:MariadbExe --host=127.0.0.1 --port=$script:Port --skip-ssl-verify-server-cert -uroot -D fractalsql_bt -N --default-character-set=utf8mb4 @ClientArgs 2>$null
    return @($out)
}

function Rb-LogMark { return (Read-LogShared $script:FsqdLog).Length }
function Rb-LogSince([int]$Mark) {
    $t = Read-LogShared $script:FsqdLog
    if ($Mark -ge $t.Length) { return "" }
    return $t.Substring($Mark)
}
function Rb-LogFatal([string]$Text) {
    return ($Text -split "`n" | Where-Object { $_ -match 'FATAL' } | Select-Object -First 1)
}

# $true when the daemon process is alive and a UDF round trip works.
function Rb-DaemonOk {
    if (-not $script:FsqdProc -or $script:FsqdProc.HasExited) { return $false }
    $v = (Rb-Mdb @("-e", "SELECT fractal_version();")) -join ""
    return ($v -match '^\d+\.\d+')
}

function Rb-WaitOk {
    for ($i = 0; $i -lt (50 * $TimeoutMult); $i++) {
        if (Rb-DaemonOk) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

# Replaces (or, with an empty value, removes) one key of the daemon's
# configuration file.
function Rb-ConfSet([string]$Key, [string]$Val) {
    $lines = @(Get-Content -Path $script:FsqdConf | Where-Object { $_ -notmatch "^$Key\s*=" })
    if ($Val -ne "") { $lines += "$Key = $Val" }
    Set-Content -Path $script:FsqdConf -Value $lines -Encoding ascii
}

# Restarts the daemon on the configuration file and key as they stand, on
# the same pipe. Environment variables in $EnvVars reach the new process.
function Rb-Restart([hashtable]$EnvVars = @{}) {
    if ($script:FsqdProc -and -not $script:FsqdProc.HasExited) {
        Stop-Process -Id $script:FsqdProc.Id -Force -ErrorAction SilentlyContinue
        $null = $script:FsqdProc.WaitForExit(5000)
    }
    $old = Rb-LogFatal (Read-LogShared $script:FsqdLog)
    if ($old -and -not $script:RbFatal) { $script:RbFatal = $old }
    foreach ($k in $EnvVars.Keys) { Set-Item -Path "Env:\$k" -Value $EnvVars[$k] }
    try {
        $script:FsqdProc = Start-Process -FilePath $script:DaemonExe `
            -ArgumentList @("-c", "`"$($script:FsqdConf)`"") `
            -RedirectStandardError $script:FsqdLog -RedirectStandardOutput "$($script:FsqdLog).out" `
            -PassThru -WindowStyle Hidden
    } finally {
        foreach ($k in $EnvVars.Keys) { Remove-Item -Path "Env:\$k" -ErrorAction SilentlyContinue }
    }
    $script:OwnedFsqdPids += $script:FsqdProc.Id
    for ($i = 0; $i -lt (100 * $TimeoutMult); $i++) {
        if ($script:FsqdProc.HasExited) { return $false }
        if ((Test-Path $script:FsqdLog) -and (Select-String -Path $script:FsqdLog -Pattern 'listening on' -Quiet)) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Back to the configuration the gate started with, on a fresh daemon.
function Rb-End {
    if ($script:RbBaseConf) {
        Set-Content -Path $script:FsqdConf -Value $script:RbBaseConf -Encoding ascii
        $null = Rb-Restart
        $null = Rb-WaitOk
    }
}

# The mock enterprise core (the fixture gate 35 uses), built once per run.
function Rb-MockLib {
    $tag = $MdbMajor -replace '\.', '_'
    $dll = "$env:TEMP\fractalsql_bt_robust_mock_$tag.dll"
    if (-not (Test-Path $dll)) {
        if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { return $null }
        $obj = [System.IO.Path]::ChangeExtension($dll, '.obj')
        $null = & cl.exe /nologo /MT /LD /DFSQL_BUILDING_DLL "/I$Here\include" (Join-Path $Here 'tests\mock_enterprise_core.c') "/Fo$obj" "/Fe$dll" 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dll)) { return $null }
    }
    return $dll
}

# Points the daemon at the mock enterprise core and a ledger file, with an
# optional ledger key, and restarts it.
function Rb-EnterpriseUp([string]$Lib, [string]$Ledger, [string]$Key) {
    Rb-ConfSet enterprise_lib $Lib
    Rb-ConfSet enterprise_ledger_path $Ledger
    Rb-ConfSet enterprise_ledger_key $Key
    Rb-ConfSet enterprise_require_signature "0"
    if (-not (Rb-Restart)) { return $false }
    return (Rb-WaitOk)
}

function Rb-Reload([string]$Probe) {
    return ((& $Probe $script:FsqdPipe $script:FsqdKey 2>&1) -join "`n")
}

function Rb-WriteUtf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Runs one generated sweep through the client and judges the daemon.
function Rb-Sweep([string]$Label, [string]$Mode, [string[]]$Extra = @()) {
    $py = Get-PythonExe
    $stride = if ($env:FSQL_ROBUST_STRIDE) { $env:FSQL_ROBUST_STRIDE } else { "1" }
    $sqlFile = "$env:TEMP\fractalsql_bt_sweep_$PID.sql"
    Remove-Item -Force $sqlFile -ErrorAction SilentlyContinue
    $mark = Rb-LogMark
    $args1 = @("`"$Here\tests\robustness\udf_sweep.py`"", $Mode,
               "--install", "`"$Here\sql\install_udf.sql`"",
               "--seed", "`"$Here\tests\robustness\seed_calls.sql`"",
               "--stride", $stride) + $Extra
    $p = Start-Process -FilePath $py -ArgumentList $args1 -RedirectStandardOutput $sqlFile `
        -RedirectStandardError "$sqlFile.err" -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -ne 0 -or -not (Test-Path $sqlFile)) {
        Fail "51 udf_sweeps: $Label -- the generator failed (exit $($p.ExitCode))"
        return
    }
    $null = Rb-Mdb @("--force", "-e", "source $($sqlFile -replace '\\', '/')")
    $fatal = Rb-LogFatal (Rb-LogSince $mark)
    if (-not (Rb-WaitOk)) {
        $why = if ($script:FsqdProc -and $script:FsqdProc.HasExited) { "fractalsqld exited with code $($script:FsqdProc.ExitCode)" } else { "fractalsqld is alive but a UDF call gets no answer" }
        # The restart below rewrites the log, so quote the daemon's last words and
        # the statement the sweep client stopped at before they are gone.
        # An ASan report ends in a legend of shadow-byte codes; the lines that name the
        # bug are the ERROR line, the first frames and the SUMMARY.
        $since = (Rb-LogSince $mark) -split "`n" | Where-Object { $_.Trim() }
        $asan  = @($since | Where-Object { $_ -match 'ERROR: |SUMMARY: |^\s*#\d+ ' } | Select-Object -First 9)
        $last  = (@(if ($asan.Count) { $asan } else { $since | Select-Object -Last 4 }) | ForEach-Object { $_.Trim() }) -join ' | '
        $keep = "$($script:FsqdLog).sweep-failed-$(Get-Random)"
        Copy-Item -Path $script:FsqdLog -Destination $keep -ErrorAction SilentlyContinue
        Fail "51 udf_sweeps: $Label -- the daemon stopped answering ($why; last log lines: $last; full log kept at $keep)"
        # Bring a fresh daemon up so one bad sweep does not fail every sweep after it.
        $null = Rb-Restart
        $null = Rb-WaitOk
    } elseif ($fatal) {
        Fail "51 udf_sweeps: $Label -- the daemon logged a FATAL: $fatal"
    } else {
        Pass "51 udf_sweeps: $Label -- the daemon stayed up and answering"
    }
    Remove-Item -Force $sqlFile, "$sqlFile.err" -ErrorAction SilentlyContinue
}

function Gate-51-UdfSweeps {
    if (-not (Get-PythonExe)) { Skip "51 udf_sweeps (no python on PATH)"; return }
    Rb-Begin
    # Start from a fresh daemon on the stock configuration (build_test.sh's
    # rb_reset_daemon): earlier gates leave the daemon with their own state.
    $null = Rb-Restart
    $null = Rb-WaitOk
    Rb-Sweep "every UDF called with 0-8 arguments of mixed types and NULL" "arity"
    Rb-Sweep "each seed call with one argument at a time set to an edge value" "mutate"
    Rb-Sweep "numeric series arguments of many lengths and shapes" "shapes"
    Rb-Sweep "JSON parameter objects in many spellings, and session ids" "params"
    Rb-Sweep "inputs just past the 4 MiB limit" "oversize"
    Rb-Sweep "the session configuration functions across every key and edge value" "config"

    # The enterprise functions refuse before doing anything while no core is
    # loaded, so repeat the argument sweeps with the mock core and a ledger.
    $lib = Rb-MockLib
    if (-not $lib) {
        Skip "51 udf_sweeps: no cl.exe to build the mock enterprise core; enterprise-loaded sweeps skipped"
    } else {
        $ledger = "$env:TEMP\fractalsql_bt_robust_ledger.bin"
        Remove-Item -Force $ledger, "$ledger.csv" -ErrorAction SilentlyContinue
        if (Rb-EnterpriseUp $lib $ledger "sweep-key") {
            Rb-Sweep "the ledger, audit and multimodal functions with the enterprise core loaded (arity)" "arity" @("--only", "ledger|audit|multimodal")
            Rb-Sweep "the ledger, audit and multimodal functions with the enterprise core loaded (edge values)" "mutate" @("--only", "ledger|audit|multimodal")
        } else {
            Fail "51 udf_sweeps: the daemon did not restart with the mock enterprise core"
        }
        Rb-End
        Remove-Item -Force $ledger, "$ledger.csv" -ErrorAction SilentlyContinue
    }
    Rb-End
}

# Compares the verdicts a table expects with what the engine answered.
# $Expected: "N<TAB>expected<TAB>text" lines; $Got: "N<TAB>answer" lines.
# An expected "PASS" means the allowlist let it through, "REJECT" that it
# refused; anything else is the exact value. Returns up to five mismatches.
function Rb-TableDiff([string[]]$Expected, [string[]]$Got) {
    $have = @{}
    foreach ($l in $Got) {
        $p = $l -split "`t", 2
        if ($p.Count -eq 2) { $have[$p[0]] = $p[1].TrimEnd("`r") }
    }
    $bad = @()
    foreach ($l in $Expected) {
        $p = $l -split "`t", 3
        $n = $p[0]; $want = $p[1]; $text = $p[2]
        if (-not $have.ContainsKey($n)) { $bad += "case $n ($text): no answer"; continue }
        $h = $have[$n]
        if ($want -eq "PASS") { if ($h -ne "<PASS>") { $bad += "case $n ($text): expected a pass, got a refusal" } }
        elseif ($want -eq "REJECT") { if ($h -eq "<PASS>") { $bad += "case $n ($text): expected a refusal, got a pass" } }
        elseif ($h -ne $want) { $bad += "case $n ($text): expected $want, got $h" }
    }
    return @($bad | Select-Object -First 5)
}

# Gate 52: the two input validators that guard what reaches the model's
# output and the ledger, against tables of inputs with a known verdict.
function Gate-52-Validators {
    $probe = Build-ReloadProbe
    if (-not $probe) { Skip "52 validators: no clang-cl.exe to build reload_probe_w"; return }
    Rb-Begin
    $W = "$env:TEMP\fractalsql_bt_validators"
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $W | Out-Null
    $tsv = Join-Path $Here 'tests\robustness'

    foreach ($mode in @("select", "select_insert_update")) {
        Rb-ConfSet t2s_allowed_statements $mode
        $null = Rb-Reload $probe
        $exp = New-Object System.Collections.Generic.List[string]
        $sql = New-Object System.Text.StringBuilder
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines("$tsv\allowlist_cases.tsv", [System.Text.Encoding]::UTF8)) {
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            $c = $line -split "`t"
            $n++
            $want = if ($mode -eq "select") { $c[1] } else { $c[2] }
            $exp.Add("$n`t$want`t$($c[0])")
            [void]$sql.Append("SELECT $n, IFNULL(fractal_t2s_check_allowlist($($c[0])), '<PASS>');`n")
        }
        Rb-WriteUtf8 "$W\sql.sql" $sql.ToString()
        $got = Rb-Mdb @("--force", "-e", "source $(("$W\sql.sql") -replace '\\', '/')")
        $diff = @(Rb-TableDiff $exp.ToArray() $got)
        if ($diff.Count -eq 0) {
            Pass "52 validators: the allowlist gives the right verdict for all $n statements (t2s_allowed_statements = $mode)"
        } else {
            Fail "52 validators: allowlist ($mode): $($diff[0..([Math]::Min(2, $diff.Count - 1))] -join '; ')"
        }
    }
    Rb-ConfSet t2s_allowed_statements ""
    $null = Rb-Reload $probe

    # The audit-log payload check needs the enterprise core and a ledger.
    $lib = Rb-MockLib
    if (-not $lib) {
        Skip "52 validators: no cl.exe to build the mock enterprise core; the audit-log check was skipped"
    } elseif (-not (Rb-EnterpriseUp $lib "$W\ledger.bin" "validator-key")) {
        Fail "52 validators: the daemon did not restart with the mock enterprise core"
    } else {
        $exp = New-Object System.Collections.Generic.List[string]
        $sql = New-Object System.Text.StringBuilder
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines("$tsv\audit_json_cases.tsv", [System.Text.Encoding]::UTF8)) {
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            $c = $line -split "`t", 2
            $n++
            $want = if ($c[0] -eq "OK") { "0" } else { "<NULL>" }
            $exp.Add("$n`t$want`t$($c[1])")
            [void]$sql.Append("SELECT $n, IFNULL(fractal_audit_log('probe', $($c[1])), '<NULL>');`n")
        }
        Rb-WriteUtf8 "$W\sql.sql" $sql.ToString()
        $got = Rb-Mdb @("--force", "-e", "source $(("$W\sql.sql") -replace '\\', '/')")
        $diff = @(Rb-TableDiff $exp.ToArray() $got)
        if ($diff.Count -eq 0) {
            Pass "52 validators: fractal_audit_log accepts exactly the well-formed JSON payloads and refuses the malformed ones ($n cases)"
        } else {
            Fail "52 validators: audit-log payload check: $($diff[0..([Math]::Min(2, $diff.Count - 1))] -join '; ')"
        }
        # What was accepted must still verify as an intact chain.
        $v = (Rb-Mdb @("-e", "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);")) -join ""
        if ($v -like '{"ok":true,"rows_verified":*') { Pass "52 validators: the chain built from the accepted payloads verifies clean" }
        else { Fail "52 validators: the chain built from the accepted payloads did not verify: $v" }
    }
    Rb-End
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    Remove-Item -Force $probe -ErrorAction SilentlyContinue
}

# Turns a verify() JSON report into "ok:ROWS" or "bad:FIRST_FAILURE:REASON".
function Rb-Verdict([string]$Text) {
    $s = $Text -replace "[\r\n]", ""
    if ($s -match '^\{"ok":true,"rows_verified":(\d+)\}$') { return "ok:$($Matches[1])" }
    if ($s -match '^\{"ok":false,"first_failure_id":(\d+),"reason":"(.*)"\}$') { return "bad:$($Matches[1]):$($Matches[2])" }
    return $s
}

# Gate 55: ledgers built by hand, valid and corrupted in every way the
# integrity check is meant to notice, under a matching key, no key and the
# wrong key.
function Gate-55-LedgerForged {
    $py = Get-PythonExe
    if (-not $py) { Skip "55 ledger_forged (no python on PATH)"; return }
    $lib = Rb-MockLib
    if (-not $lib) { Skip "55 ledger_forged: no cl.exe to build the mock enterprise core"; return }
    Rb-Begin
    $ledger = "$env:TEMP\fractalsql_bt_forged.bin"
    $cases = @([System.IO.File]::ReadAllLines((Join-Path $Here 'tests\robustness\ledger_cases.tsv'), [System.Text.Encoding]::UTF8) |
               Where-Object { $_ -ne "" -and -not $_.StartsWith("#") })
    foreach ($mode in @("keyed", "unkeyed", "wrongkey")) {
        switch ($mode) {
            "keyed"    { $daemonKey = "forge-key"; $recordKey = "forge-key" }
            "unkeyed"  { $daemonKey = "";          $recordKey = "" }
            "wrongkey" { $daemonKey = "forge-key"; $recordKey = "other-key" }
        }
        Remove-Item -Force $ledger, "$ledger.csv" -ErrorAction SilentlyContinue
        if (-not (Rb-EnterpriseUp $lib $ledger $daemonKey)) {
            Fail "55 ledger_forged: the daemon did not restart for the $mode cases"
            continue
        }
        $ok = 0; $bad = 0; $firstBad = ""
        foreach ($row in $cases) {
            $c = $row -split "`t"
            if ($c[0] -ne $mode) { continue }
            $scn = $c[1]; $wantLoad = $c[2]; $wantV1 = $c[3]; $wantV2 = $c[4]
            $forgeArgs = @("`"$Here\tests\robustness\ledger_forge.py`"", "`"$ledger`"", $scn)
            if ($recordKey -ne "") { $forgeArgs += $recordKey }
            $p = Start-Process -FilePath $py -ArgumentList $forgeArgs -NoNewWindow -PassThru -Wait `
                -RedirectStandardOutput "$env:TEMP\fractalsql_bt_forge.out" -RedirectStandardError "$env:TEMP\fractalsql_bt_forge.err"
            if ($p.ExitCode -ne 0) {
                $bad++; if (-not $firstBad) { $firstBad = "$scn`: the ledger could not be written (exit $($p.ExitCode))" }
                continue
            }
            $gotLoad = (Rb-Mdb @("-e", "SELECT IFNULL(fractal_ledger_load(CONNECTION_ID()), 'refused');")) -join ""
            if ($gotLoad -eq "0") { $gotLoad = "ok" }
            $gotV1 = Rb-Verdict ((Rb-Mdb @("-e", "SELECT fractal_ledger_verify(CONNECTION_ID(), 1);")) -join "")
            $gotV2 = Rb-Verdict ((Rb-Mdb @("-e", "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);")) -join "")
            if ($gotLoad -eq $wantLoad -and $gotV1 -eq $wantV1 -and $gotV2 -eq $wantV2) { $ok++ }
            else {
                $bad++
                if (-not $firstBad) { $firstBad = "$scn`: load $gotLoad/$wantLoad, kind 1 '$gotV1'/'$wantV1', kind 2 '$gotV2'/'$wantV2'" }
            }
        }
        if ($bad -eq 0 -and $ok -gt 0) { Pass "55 ledger_forged: $ok forged ledgers gave the right load and verify verdicts ($mode)" }
        else { Fail "55 ledger_forged ($mode): $bad of $($ok + $bad) forged ledgers were judged wrongly, first: $firstBad" }
    }
    Rb-End
    Remove-Item -Force $ledger, "$ledger.csv", "$env:TEMP\fractalsql_bt_forge.out", "$env:TEMP\fractalsql_bt_forge.err" -ErrorAction SilentlyContinue
}

# Gate 58: enterprise_lib and signature combinations the loader must
# either load or refuse cleanly, leaving the engine running either way.
function Gate-58-EnterpriseLoading {
    $lib = Rb-MockLib
    if (-not $lib) { Skip "58 enterprise_loading: no cl.exe to build the mock enterprise core"; return }
    Rb-Begin
    $W = "$env:TEMP\fractalsql_bt_entload"
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $W | Out-Null
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function New-RandFile([string]$Path, [int]$Len) {
        $b = New-Object byte[] $Len
        if ($Len -gt 0) { $rng.GetBytes($b) }
        [System.IO.File]::WriteAllBytes($Path, $b)
    }
    Set-Content -Path "$W\not_a_dll.dll" -Value "not a shared library" -Encoding ascii
    New-Item -ItemType File -Path "$W\empty.dll" | Out-Null
    foreach ($s in @(@("sig_16_bytes", 16), @("sig_64_random", 64), @("sig_65_bytes", 65), @("sig_empty", 0))) {
        Copy-Item $lib "$W\$($s[0]).dll"
        New-RandFile "$W\$($s[0]).dll.sig" $s[1]
    }
    Copy-Item $lib "$W\sig_is_dir.dll"
    New-Item -ItemType Directory -Path "$W\sig_is_dir.dll.sig" | Out-Null
    Copy-Item $lib "$W\unsigned.dll"

    # name | path | require_signature | expected truth_count answer ("0" loaded, "NULL" refused)
    $table = @(
        @("not_a_dll", "$W\not_a_dll.dll", "0", "NULL"),
        @("empty_file", "$W\empty.dll", "0", "NULL"),
        @("sig_16_bytes", "$W\sig_16_bytes.dll", "0", "NULL"),
        @("sig_64_random", "$W\sig_64_random.dll", "0", "NULL"),
        @("sig_65_bytes", "$W\sig_65_bytes.dll", "0", "NULL"),
        @("sig_empty", "$W\sig_empty.dll", "0", "NULL"),
        # fopen() cannot open a directory on Windows, so the loader sees no .sig at all
        # and, with signatures not required, loads the library unverified.
        @("sig_is_a_directory", "$W\sig_is_dir.dll", "0", "0"),
        @("sig_is_a_directory_required", "$W\sig_is_dir.dll", "1", "NULL"),
        @("sig_64_random_required", "$W\sig_64_random.dll", "1", "NULL"),
        @("nonexistent", "$W\nonexistent.dll", "0", "NULL"),
        @("directory", "$W", "0", "NULL"),
        @("no_required_symbols", "$env:SystemRoot\System32\kernel32.dll", "0", "NULL"),
        @("unsigned_not_required", "$W\unsigned.dll", "0", "0"),
        @("unsigned_but_required", "$W\unsigned.dll", "1", "NULL")
    )
    $bad = 0; $firstBad = ""
    foreach ($t in $table) {
        Rb-ConfSet enterprise_lib $t[1]
        Rb-ConfSet enterprise_ledger_path "$W\ledger.bin"
        Rb-ConfSet enterprise_ledger_key "load-key"
        Rb-ConfSet enterprise_require_signature $t[2]
        if (-not (Rb-Restart) -or -not (Rb-WaitOk)) {
            $bad++; if (-not $firstBad) { $firstBad = "$($t[0]): the daemon did not start" }
            continue
        }
        $got = (Rb-Mdb @("-e", "SELECT fractal_ledger_truth_count(CONNECTION_ID());")) -join ""
        if ($got -ne $t[3]) { $bad++; if (-not $firstBad) { $firstBad = "$($t[0]): truth_count answered '$got', expected '$($t[3])'" } }
        if (-not (Rb-DaemonOk)) { $bad++; if (-not $firstBad) { $firstBad = "$($t[0]): the daemon stopped answering" } }
    }
    # The log is replaced on each restart; Rb-Restart kept the first FATAL it saw.
    $fatal = $script:RbFatal
    if (-not $fatal) { $fatal = Rb-LogFatal (Read-LogShared $script:FsqdLog) }
    if ($fatal) { $bad++; if (-not $firstBad) { $firstBad = "the daemon logged a FATAL: $fatal" } }
    if ($bad -eq 0) { Pass "58 enterprise_loading: $($table.Count) enterprise_lib/signature combinations loaded or were refused as expected" }
    else { Fail "58 enterprise_loading: $bad problem(s) across $($table.Count) combinations, first: $firstBad" }
    Rb-End
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
}

# Gate 60: what the engine does with every shape of reply a reasoning
# plugin can hand back. A scripted plugin returns whatever a file says.
function Gate-60-ScriptedReplies {
    $W = "$env:TEMP\fractalsql_bt_scripted"
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $W | Out-Null
    $dll = Compile-FsqlFixture "tests\scripted_reasoning_plugin.c" "scripted_reasoning.dll" @("$Here\include\windows-x86_64", "$Here\include")
    if (-not $dll) { Fail "60 scripted_replies: the scripted plugin failed to build"; return }
    Rb-Begin
    $rp = (Resolve-Path -LiteralPath $dll).Path
    Rb-ConfSet reasoning_plugin $rp
    $replyFile = "$W\reply"
    if (-not (Rb-Restart @{ FSQL_SCRIPTED_REPLY = $replyFile }) -or -not (Rb-WaitOk)) {
        Fail "60 scripted_replies: the daemon did not restart with the scripted plugin"
        Rb-End; return
    }
    $mark = Rb-LogMark
    $reasonQ = "SELECT IFNULL(fractal_reason('q','c'),'<NULL>')"
    $reviewQ = "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(),'q','SELECT 1'),'<NULL>')"
    $genQ    = "SELECT IFNULL(fractal_t2s_generate(CONNECTION_ID(),'mariadb1011','schema','q'),'<NULL>')"
    # reply, expected reason, expected review, expected generate ("*" = any)
    $table = @(
        @("hello", "hello", "hello", "hello"),
        @("SELECT 1", "SELECT 1", "SELECT 1", "SELECT 1"),
        @("", "", "", ""),
        @("PASS", "PASS", "<NULL>", "PASS"),
        @("pass", "pass", "<NULL>", "pass"),
        @("Pass: fine", "Pass: fine", "<NULL>", "Pass: fine"),
        @(" `t Pass", "*", "<NULL>", "*"),
        @("FAIL: bad", "FAIL: bad", "FAIL: bad", "FAIL: bad"),
        @("pas", "pas", "pas", "pas"),
        @("@null", "<NULL>", "<NULL>", "<NULL>"),
        @("@rc=-5", "<NULL>", "<NULL>", "<NULL>"),
        @("@rc=-1", "<NULL>", "<NULL>", "<NULL>"),
        @("@size=16777217", "<NULL>", "<NULL>", "<NULL>")
    )
    $bad = 0; $firstBad = ""
    foreach ($t in $table) {
        [System.IO.File]::WriteAllBytes($replyFile, [System.Text.Encoding]::ASCII.GetBytes($t[0]))
        $qs = @(@("fractal_reason", $reasonQ, $t[1]), @("fractal_t2s_review", $reviewQ, $t[2]), @("fractal_t2s_generate", $genQ, $t[3]))
        foreach ($q in $qs) {
            $got = ((Rb-Mdb @("-e", $q[1])) -join "`n").TrimEnd("`r", "`n")
            if ($q[2] -ne "*" -and $got -ne $q[2]) {
                $bad++
                if (-not $firstBad) { $firstBad = "reply '$($t[0])': $($q[0]) answered '$got', expected '$($q[2])'" }
            }
        }
    }
    # A large but legal reply comes back whole.
    [System.IO.File]::WriteAllBytes($replyFile, [System.Text.Encoding]::ASCII.GetBytes("@size=5242880"))
    $got = (Rb-Mdb @("-e", "SELECT LENGTH(fractal_reason('q','c'));")) -join ""
    if ($got -ne "5242880") { $bad++; if (-not $firstBad) { $firstBad = "a 5 MiB reply came back as '$got' bytes" } }
    if (-not (Rb-DaemonOk)) { $bad++; if (-not $firstBad) { $firstBad = "the daemon stopped answering" } }
    $fatal = Rb-LogFatal (Rb-LogSince $mark)
    if ($fatal) { $bad++; if (-not $firstBad) { $firstBad = "the daemon logged a FATAL: $fatal" } }
    if ($bad -eq 0) { Pass "60 scripted_replies: $($table.Count + 1) scripted plugin replies were passed through, refused or judged as expected" }
    else { Fail "60 scripted_replies: $bad problem(s) across $($table.Count + 1) replies, first: $firstBad" }
    Rb-End
    Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
    Remove-Item -Force $dll -ErrorAction SilentlyContinue
}

# Gates that only exist on POSIX hosts. Each one prints an explicit [SKIP]
# with the reason, so a Windows transcript shows the gate was considered
# and not silently left out.
function Skip-PosixOnlyGate([string]$gate, [string]$name, [string]$why) {
    Skip "$gate $name ($why)"
}
function Gate-37-OomInjection  { Skip-PosixOnlyGate '37' 'oom_injection' 'needs LD_PRELOAD (tests/oom_preload.c) to fail allocations in the running server; Linux only' }
function Gate-38-FatalSignal   { Skip-PosixOnlyGate '38' 'fatal_signal' 'sends SIGABRT to the daemon and reads its fatal-signal log; Windows has no equivalent signal delivery' }
function Gate-46-LedgerTsan    { Skip-PosixOnlyGate '46' 'ledger_tsan_concurrent' 'ThreadSanitizer is not available for MSVC/clang-cl on Windows' }
function Gate-53-DaemonFrames  { Skip-PosixOnlyGate '53' 'daemon_frames' 'tests/robustness/frame_fuzz.py speaks AF_UNIX; the Windows daemon listens on a named pipe and the driver is not ported' }
function Gate-54-DaemonConfBoot{ Skip-PosixOnlyGate '54' 'daemon_conf_boot' 'cases assert POSIX file modes and uid allowlists (conf_boot_cases.txt); not applicable to Windows ACLs' }
function Gate-56-LedgerFiles   { Skip-PosixOnlyGate '56' 'ledger_files' 'cases use /dev/full, /dev/null and chmod 400; Linux/macOS only' }
function Gate-57-FaultSweeps   { Skip-PosixOnlyGate '57' 'fault_sweeps' 'needs LD_PRELOAD and signals; Linux only' }
function Gate-59-ProviderReload{ Skip-PosixOnlyGate '59' 'provider_reload' 'drives the daemon through fsqlctl over AF_UNIX; the Windows named-pipe path is not ported' }
function Gate-61-DaemonLimits  { Skip-PosixOnlyGate '61' 'daemon_limits' 'tests/robustness/conn_limits.py speaks AF_UNIX; not ported to the Windows named pipe' }
function Gate-62-ProviderEnv   { Skip-PosixOnlyGate '62' 'provider_env' 'restarts the daemon under POSIX environment and socket handling; not ported' }
function Gate-63-DirectCalls   { Skip-PosixOnlyGate '63' 'direct_calls' 'udf_direct harness loads the plugin with dlopen; Linux/macOS only' }
function Gate-64-DirectFaults  { Skip-PosixOnlyGate '64' 'direct_faults' 'needs LD_PRELOAD; Linux only' }
function Gate-65-McpFaults     { Skip-PosixOnlyGate '65' 'mcp_faults' 'needs LD_PRELOAD (oom_preload.so) and signals; Linux only' }

# Gate 66: the MCP server's command line and environment, every flag and
# variable including bad values (mcp\tests\mcp_cli.py).
function Gate-66-McpCli {
    $client = Join-Path $script:Here 'mcp\tests\mcp_cli.py'
    if (-not (Test-Path -LiteralPath $client)) { Skip '66 mcp_cli (mcp/tests/mcp_cli.py not present)'; return }
    $py = Get-PythonExe
    if (-not $py) { Skip '66 mcp_cli (no python on PATH)'; return }
    $mcpExe = Get-McpServerExe '66 mcp_cli'
    if (-not $mcpExe) { return }
    $cwd = Join-Path $env:TEMP "fractalsql_bt_mcp_cli_$($MdbMajor -replace '\D','')"
    if (Test-Path $cwd) { Remove-Item -Recurse -Force $cwd -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $cwd | Out-Null
    $env:MCP_SERVER_EXE = $mcpExe
    $env:MCP_SERVER_CWD = $cwd
    $env:MCP_MARIADB_BIN = $script:MariadbExe
    $env:MARIADB_HOST = '127.0.0.1'
    $env:MARIADB_PORT = "$($script:Port)"
    $env:MARIADB_DATABASE = 'fractalsql_bt'
    $env:MARIADB_USER = 'root'
    $env:MARIADB_PASSWORD = ''
    try {
        & $py -u $client 2>&1 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -eq 0) { Pass '66 mcp_cli: every command line and environment ended as expected' }
        else { Fail "66 mcp_cli: driver exited $LASTEXITCODE" }
    }
    finally {
        foreach ($v in @('MCP_SERVER_EXE','MCP_SERVER_CWD','MCP_MARIADB_BIN','MARIADB_HOST','MARIADB_PORT',
                         'MARIADB_DATABASE','MARIADB_USER','MARIADB_PASSWORD')) {
            Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
        }
    }
}

# Gate 67: libFuzzer on the MCP server's vector and JSON-RPC parsers.
# Standalone like gate 30: no cluster. db.cpp is replaced by
# tests\fuzz\mcp_db_stub.cpp, so only the Connector/C headers are needed.
function Gate-67-McpFuzz {
    $drv1 = Join-Path $script:Here 'tests\fuzz\fuzz_mcp_jsonrpc.cpp'
    $drv2 = Join-Path $script:Here 'tests\fuzz\fuzz_mcp_vectors.cpp'
    if (-not (Test-Path -LiteralPath $drv1) -or -not (Test-Path -LiteralPath $drv2) -or
        -not (Test-Path -LiteralPath (Join-Path $script:Here 'mcp\src\main.cpp'))) {
        Skip '67 mcp_fuzz (mcp/ server code or fuzz targets not present)'; return
    }
    if (-not $script:ClangCl) { Skip '67 mcp_fuzz (clang-cl not found)'; return }
    try { $openssl = Resolve-OpenSslDir } catch { Skip "67 mcp_fuzz ($($_.Exception.Message))"; return }
    $outDir = Join-Path $script:Here 'dist\windows-fuzz-mcp'
    if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $fuzzTime = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { '30' }
    $rt = $null
    try { $rt = (& $script:ClangCl -print-resource-dir 2>$null | Select-Object -First 1) } catch { }
    if ($rt) { $d = Join-Path $rt 'lib\windows'; if (Test-Path $d) { $env:PATH = "$d;$env:PATH" } }
    $mdbInc = Join-Path $MdbDir 'include\mysql'
    $common = @('/std:c++17', '-O1', '-Zi', '/EHsc', '-D_CRT_SECURE_NO_WARNINGS', '-DNOMINMAX',
                # The MSVC STL turns on container annotations under ASan and libFuzzer's
                # prebuilt library has them off, which fails to link, so they are disabled.
                '-D_DISABLE_STRING_ANNOTATION', '-D_DISABLE_VECTOR_ANNOTATION',
                '-Imcp\src', '-Imcp\vendor', '-Itests\fuzz', "-I$(Join-Path $openssl 'include')")
    if (Test-Path $mdbInc) { $common += "-I$mdbInc" }
    $libs = @("/link", "/LIBPATH:$(Join-Path $openssl 'lib')", 'libssl.lib', 'libcrypto.lib', 'ws2_32.lib', 'crypt32.lib', 'user32.lib', 'advapi32.lib')
    foreach ($t in @('fuzz_mcp_vectors', 'fuzz_mcp_jsonrpc')) {
        $srcs = @('mcp\src\errors.cpp')
        if ($t -eq 'fuzz_mcp_vectors') { $srcs += 'mcp\src\vectors.cpp' }
        else { $srcs += @('mcp\src\jsonrpc_server.cpp','mcp\src\logging.cpp','mcp\src\prompts.cpp','mcp\src\resources.cpp',
                          'mcp\src\conf_file.cpp','mcp\src\fsqlctl.cpp','tests\fuzz\mcp_db_stub.cpp') }
        # libFuzzer's runtime on clang for Windows breaks the caught C++ exception objects
        # this target's error replies are, so that one is built as a plain executable
        # (the driver replays and mutates the corpus itself). The vectors target has no
        # exceptions and keeps the real libFuzzer run.
        # The flags are concatenated, not splatted: a one-element PowerShell array
        # collapses to a plain String when it comes out of an if-expression, and
        # splatting that String hands the compiler its characters one at a time.
        # That plain executable is built with UBSan, not ASan: with clang-cl's ASan runtime the caught C++
        # exception objects are bad here too (the first caught ToolError read through a null pointer inside
        # JsonRpcServer::handleLineImpl's catch block, with no memory error behind it), while the same
        # server code under UBSan (mcp\scripts\windows\build-ubsan.bat) runs its exceptions correctly.
        $fz = if ($t -eq 'fuzz_mcp_jsonrpc') { @('-fsanitize=undefined', '-fno-sanitize-recover=undefined', '/MT', '-DFSQL_FUZZ_STANDALONE') }
              else { @('-fsanitize=fuzzer,address') }
        $bin = Join-Path $outDir "$t.exe"
        $log = Join-Path $outDir "$t.build.log"
        $compileArgs = $common + $fz + @("tests\fuzz\$t.cpp") + $srcs + @("/Fe$bin") + $libs
        & $script:ClangCl $compileArgs *> $log
        if ($LASTEXITCODE -ne 0) { Fail "67 mcp_fuzz: $t failed to build; see $log"; continue }
        $seed = Join-Path $outDir "${t}_seed"; New-Item -ItemType Directory -Force -Path $seed | Out-Null
        $corpus = Join-Path $script:Here "tests\fuzz\corpus_$($t -replace '^fuzz_','')"
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $bin
        foreach ($a in @($seed, $corpus, "-max_total_time=$fuzzTime", '-print_final_stats=1')) { $psi.ArgumentList.Add($a) }
        # The plain executable has no libFuzzer runtime, so ASan can resolve frame names from
        # the PDB; the real libFuzzer target keeps symbolize=0.
        $psi.EnvironmentVariables['ASAN_OPTIONS'] = if ($t -eq 'fuzz_mcp_jsonrpc') { 'detect_leaks=0:symbolize=1' } else { 'detect_leaks=0:symbolize=0' }
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit([int](([int]$fuzzTime + 240) * 1000))) { try { $proc.Kill() } catch { } ; $proc.WaitForExit() }
        if ($proc.ExitCode -eq 0) { Pass "67 mcp_fuzz: $t (${fuzzTime}s, corpus-seeded)" }
        else {
            $runLog = Join-Path $outDir "$t.run.log"
            ($o.Result + "`n" + $e.Result) | Out-File -FilePath $runLog -Encoding utf8
            Fail "67 mcp_fuzz: $t exited $($proc.ExitCode); see $runLog"
            # CI cannot open the file, so the end of it goes into the job output.
            Get-Content -LiteralPath $runLog -Tail 60 | ForEach-Object { Write-Host "    | $_" }
        }
    }
}

# Gate 68: the shared MCP conformance driver. It starts the servers it needs
# itself -- both protocol eras, with and without a bearer token, in read-only
# mode, with the operator switches on and off -- and checks the behaviour
# against the published rules. It is the same driver file in every engine's
# repository.
function Gate-68-McpConformance {
    $driver = Join-Path $script:Here 'mcp\tests\mcp_conformance.py'
    if (-not (Test-Path -LiteralPath $driver)) { Skip '68 mcp_conformance (mcp\tests\mcp_conformance.py not present)'; return }
    $py = Get-PythonExe
    if (-not $py) { Skip '68 mcp_conformance (no python on PATH -- the conformance driver needs it)'; return }
    # The server refuses to start without its two lock files, so a tree
    # without them cannot run this gate at all.
    foreach ($lock in @('.mcp-schema-lock', '.mcp-safety-annotations-lock')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Here ("mcp\" + $lock)))) {
            Skip "68 mcp_conformance (missing lock file: $lock)"; return
        }
    }
    $mcpExe = Get-McpServerExe '68 mcp_conformance'
    if (-not $mcpExe) { return }
    $work = Join-Path $env:TEMP "fractalsql_bt_mcp_conformance_$($MdbMajor -replace '\D','')"
    if (Test-Path $work) { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    # The server looks for its two lock files beside the executable when no
    # path is configured, and that is what lets it start from any working
    # directory.
    $exeDir = Split-Path -Parent $mcpExe
    foreach ($lock in @('.mcp-schema-lock', '.mcp-safety-annotations-lock')) {
        $src = Join-Path $script:Here ("mcp\" + $lock)
        $dst = Join-Path $exeDir $lock
        if ((Test-Path -LiteralPath $src) -and ($src -ne $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        }
    }

    # The config-write checks edit the daemon's configuration file and ask the
    # daemon to reload it. The driver gets a COPY of that file, so a test
    # never edits the configuration the running daemon was started with.
    $confCopy = Join-Path $work 'fractalsqld.conf'
    if ($script:FsqdConf -and (Test-Path -LiteralPath $script:FsqdConf)) {
        Copy-Item -LiteralPath $script:FsqdConf -Destination $confCopy -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $confCopy)) { New-Item -ItemType File -Path $confCopy -Force | Out-Null }

    $vars = @{
        MCP_SERVER_EXE       = $mcpExe
        MCP_SERVER_CWD       = $work
        MCPC_TOKEN           = 'conformance-token'
        MCPC_GATE            = '68'
        MCPC_LOCK_DIR        = (Join-Path $script:Here 'mcp')
        MCPC_PASSTHROUGH_ENV = 'MARIADB_HOST,MARIADB_PORT,MARIADB_DATABASE,MARIADB_USER,MARIADB_PASSWORD,FSQLCTL_SOCKET,FSQLCTL_KEY,FSQLCTL_CONF'
        MCPC_READ_TOOL       = 'fractal_version'
        MCPC_READ_ARGS       = '{}'
        MCPC_STATE_TOOL      = 'fractal_diversify_enable'
        MCPC_STATE_ARGS      = '{}'
        MCPC_STATE_READER    = 'fractal_explain_result'
        MCPC_DESTRUCTIVE_TOOL = 'fractal_diversify_enable'
        MCPC_DESTRUCTIVE_ARGS = '{}'
        MCPC_SAFE_KEY        = 'reasoning_model'
        MCPC_UNSAFE_KEY      = 'reasoning_url'
        MCP_HERE             = (Join-Path $script:Here 'mcp')
        MARIADB_HOST         = '127.0.0.1'
        MARIADB_PORT         = "$($script:Port)"
        MARIADB_DATABASE     = 'fractalsql_bt'
        MARIADB_USER         = 'root'
        MARIADB_PASSWORD     = ''
        FSQLCTL_SOCKET       = $script:FsqdPipe
        FSQLCTL_KEY          = $script:FsqdKey
        FSQLCTL_CONF         = $confCopy
    }
    $old = @{}
    foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
    $log = Join-Path $work 'conformance.log'
    try {
        & $py -u $driver 2>&1 | Out-File -FilePath $log -Encoding utf8
        $rc = $LASTEXITCODE
    }
    finally {
        foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k], 'Process') }
    }
    $out = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
    if (($rc -eq 0) -and ($out -match 'ALL GREEN')) {
        $n = ([regex]::Matches($out, '(?m)^PASS')).Count
        Pass "68 mcp_conformance: $n checks passed (protocol eras, authentication, framing, operator switches, catalog)"
    }
    else {
        # The driver's own failure lines, not the server's log: they say which
        # rule was broken and what was seen instead.
        ($out -split "`n" | Where-Object { $_ -match '^(FAIL|SKIP) ' } | Select-Object -First 12) | ForEach-Object { Write-Host "    $_" }
        # The servers' own log lines are in the driver's log file, which is gone once the job ends: print the tail here.
        if (Test-Path -LiteralPath $log) {
            Write-Host "    --- tail of the conformance log"
            Get-Content -LiteralPath $log -Tail 60 | ForEach-Object { Write-Host "    | $_" }
        }
        Fail "68 mcp_conformance: the conformance driver reported failures (exit $rc; full log $log)"
    }
}

function Run-Gates([string[]]$Gates) {
    Write-Host "== MariaDB $MdbMajor (Windows) =="
    if ($Gates -contains "01") {
        if (-not (Gate-01-Build)) { return }
    }
    # Gate 30 (fuzz smoke) is standalone like gate 01 -- links only
    # src\fractalsql_parse.c directly, no extension DLL, no mariadbd.exe,
    # no cluster at all.
    if ($Gates -contains "30") { Gate-30-FuzzSmoke }
    # Gate 41 (parse_probe) is standalone like gate 30 -- it links
    # src/fractalsql_parse.c directly, no extension DLL, no mariadbd.exe,
    # no cluster at all.
    if ($Gates -contains "41") { Gate-41-ParseProbe }
    if ($Gates -contains "37") { Gate-37-OomInjection }
    if ($Gates -contains "38") { Gate-38-FatalSignal }
    if ($Gates -contains "46") { Gate-46-LedgerTsan }
    if ($Gates -contains "53") { Gate-53-DaemonFrames }
    if ($Gates -contains "54") { Gate-54-DaemonConfBoot }
    if ($Gates -contains "56") { Gate-56-LedgerFiles }
    if ($Gates -contains "57") { Gate-57-FaultSweeps }
    if ($Gates -contains "59") { Gate-59-ProviderReload }
    if ($Gates -contains "61") { Gate-61-DaemonLimits }
    if ($Gates -contains "62") { Gate-62-ProviderEnv }
    if ($Gates -contains "63") { Gate-63-DirectCalls }
    if ($Gates -contains "64") { Gate-64-DirectFaults }
    if ($Gates -contains "65") { Gate-65-McpFaults }
    if ($Gates -contains "67") { Gate-67-McpFuzz }
    $needDb = $Gates | Where-Object { $_ -in @("02","03","04","05","06","07","08","10","11","12","13","14","15","16","17","18","19","20","21","22","23","24","25","26","27","28","29","31","32","33","34","35","36","39","40","42","43","44","45","47","48","49","50","51","52","55","58","60","66","68") }
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
                "39" { Gate-39-McpSmoke }
                "40" { Gate-40-McpHttps }
                "42" { Gate-42-VectorsProbe }
                "43" { Gate-43-DbProbe }
                "44" { Gate-44-ConcurrencyProbe }
                "45" { Gate-45-DomainAgents }
                "47" { Gate-47-LedgerChain }
                "48" { Gate-48-T2SReviewIsolation }
                "49" { Gate-49-ConfigOverlay }
                "50" { Gate-50-Kits }
                "51" { Gate-51-UdfSweeps }
                "52" { Gate-52-Validators }
                "55" { Gate-55-LedgerForged }
                "58" { Gate-58-EnterpriseLoading }
                "60" { Gate-60-ScriptedReplies }
                "66" { Gate-66-McpCli }
                "68" { Gate-68-McpConformance }
            }
        }
        Mdb-Teardown
    }
}

try {
    if ($Gate -ne "") { Run-Gates @($Gate -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }) }
    elseif ($Quick) { Run-Gates $QuickGates }
    elseif ($Fuzz) { Run-Gates $FuzzGates }
    else { Run-Gates $DefaultGates }
} finally {
    Mdb-Teardown
}

# The coverage report runs AFTER the teardown: the daemon is stopped by
# then, so the .profraw it flushed on its timer is complete and no
# other process is writing to it.
if ($Coverage) { Write-CoverageReport }

if ($script:Failed) { Write-Host "`nbuild_test: FAIL" -ForegroundColor Red; exit 1 }
else { Write-Host "`nbuild_test: PASS" -ForegroundColor Green; exit 0 }
