#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh: post-build validation gate runner for
# fractalsql-mariadb. Mirrors what CI runs, so local == CI. Modeled
# directly on fractalsql-postgresql's build_test.sh (same gate-numbering
# convention, same PASS/FAIL/SKIP harness shape). Gates 03/04/10/12/13/
# 20-25 below cover the full UDF/procedure surface: Discovery, Text-to-
# SQL, the Vectorizer, Analytics, Diversify, the Vector tier, Cognition,
# Agency, and Enterprise activation gating. Gates 05/07/08/14-18 (the
# reasoning-VFS-ABI-level "evil plugin" gates and their embed/authz/
# soak/crash siblings) are ALSO ported now -- see the reasoning-tier
# bullet below for how. Deliberately still NOT ported: the guc_superuser
# gate (09) and a real (non-mock) enterprise-.so gate (26 in postgres's
# numbering; this repo's own 26/27/28 cover related but different real-
# .so ground), each with its own documented reason, not a placeholder.
#
# Architecture differences from the postgres template (read before
# assuming a gate ported 1:1):
#   * ONE fractalsql.so covers every supported MariaDB major (10.6 /
#     10.11 / 11.4 LTS / 12.2 rolling): the UDF ABI (UDF_INIT/UDF_ARGS/
#     MYSQL_ERRMSG_SIZE) has been stable across all of them. So unlike
#     postgres's build_test.sh (PGXS rebuild + reinstall PER major),
#     gate_01_build here compiles ONCE; --mdb <major> only selects which
#     mariadbd binary the live-cluster gates start against.
#   * No CREATE EXTENSION. "Install" = point mariadbd at a scratch
#     --plugin-dir containing fractalsql.so, then run
#     `mariadb ... < sql/install_udf.sql` (CREATE FUNCTION ... SONAME).
#   * Reasoning-tier gates (03/04/13/20-24) dispatch through the REAL
#     fractalsql-reasoning-http.so plugin against a deterministic local
#     mock (scripts/ci/mock_llm.py, started in mdb_setup before
#     mariadbd) rather than postgres's fake in-process reasoning-VFS
#     plugin approach, exercising the actual dlopen/curl/HTTP path,
#     just with a canned server on the other end. Gates 05/07/14/15/18
#     instead swap FRACTALSQL_REASONING_PLUGIN to a reasoning-VFS-ABI-
#     level test fixture (tests/evil_*.c, tests/retry_reasoning_plugin.c
#     -- pure C against the shared vendored fractalsql_sql.h, copied
#     verbatim from fractalsql-postgresql's own tests/, which reference
#     no postgres- or mariadb-specific API at all) via
#     mdb_swap_reasoning_plugin(), a restart-based swap (see that
#     function's own comment: FRACTALSQL_REASONING_PLUGIN is a process
#     environment variable read once at mysqld startup, no live-reload
#     the way postgres's fractalsql.reasoning_plugin GUC has). A real,
#     MariaDB-specific wrinkle these gates had to account for: the evil
#     plugins' call_count statics are process-wide, and unlike postgres
#     (fork-per-backend, so a fresh psql -c connection gets a freshly
#     dlopen'd plugin with call_count=0 again) MariaDB is one shared
#     process for every connection -- call_count keeps incrementing
#     across every call for the process's whole lifetime. So gates
#     05/07 restart before EACH of their three call sites (GENERATE/
#     bare fractal_reason/fractal_t2s_review), not once for the whole
#     gate; see gate_05_evil_overread's own header comment for the full
#     account. mock_reasoning_plugin.c and mock_embed_plugin.c (the
#     postgres files providing a well-behaved fallback plugin) were NOT
#     needed here: mariadb's own baseline (the real HTTP wrapper against
#     scripts/ci/mock_llm.py) already serves that role, restored via
#     mdb_restore_reasoning_plugin() at the end of every evil-plugin
#     gate. Also NOT needed: mock_embed_plugin.c specifically, since
#     mock_llm.py's embeddings route already returns the same canned
#     [0.1,0.2,0.3] vector postgres's mock_embed_plugin.c hardcodes.
#   * 06 still uses a standalone evil UDF (tests/evil_crash_udf.c) that
#     segfaults when called. This is a genuinely different, simpler
#     claim than the reasoning-plugin crash gates above (see gate 06's
#     own header comment), not a stand-in for them.
#   * 09 guc_superuser has NO MariaDB equivalent to port, permanently:
#     not "blocked," genuinely not applicable. Cognition-tier config
#     lives in mysqld process environment variables
#     (FRACTALSQL_REASONING_PLUGIN etc.), not sysvars, specifically
#     because MariaDB's plugin-interface-version gate would break the
#     one-.so-per-(arch,libc) distribution model (see fractalsql_
#     cognition.c's file header for the full account); there is no
#     sysvar surface for a superuser-only restriction to exist on.
#   * 26 (a real, non-mock enterprise .so) is not ported for the same
#     reason this repo's Enterprise tier stops short of the ledger's
#     actual storage layer: see src/fractalsql_enterprise.c's file
#     header. 25 below covers what IS real and testable: the
#     dlopen/dlsym activation-gating wiring itself, which would need a
#     purpose-built stub .so to exercise against a loaded library
#     (scripts/ci has no fixture for it yet, a reasonable follow-up).
#   * MariaDB's mariadbd has NO Postgres-postmaster-style built-in
#     auto-restart-after-crash. Postgres's fork-per-backend model means
#     ANY backend crashing makes the postmaster tear down and reinit
#     shared memory and come back up on its own (restart_after_crash=on
#     by default): that is a real architectural guarantee this harness
#     can just observe. mariadbd has no equivalent: a UDF call
#     segfaulting takes down the WHOLE (single, mostly-threaded) mysqld
#     process, and nothing built into mariadbd brings it back. The
#     platform-level guarantee actually worth testing is narrower:
#     InnoDB's own crash recovery (redo-log replay on next startup, so
#     committed data survives); getting the PROCESS itself to come
#     back requires an outer supervisor. This script uses
#     `mariadbd-safe` (confirmed via a real mariadb:11.4 container this
#     is the current name; MariaDB packaging renamed the classic
#     `mysqld_safe` at some point, both names are checked) when
#     available and falls back to a small manual respawn loop if
#     neither is found. Gate 06 verifies BOTH halves separately: (a) the
#     supervisor actually respawns mariadbd, (b) InnoDB crash recovery
#     leaves prior committed data intact. Do not conflate this with
#     postgres's gate 06 claim: it is a different, weaker platform
#     guarantee, tested honestly rather than assumed equivalent.
#
# Gates (see the header of each gate_* function below for full detail):
#   01  build            compile fractalsql.so via `make`             ~5s
#   02  smoke            install + fractalsql_version/_edition +      ~5s
#                        fractal_search convergence
#   03  schema_context   fractal_schema_context: real table/column/     ~1s
#                        comment/FK introspection
#   04  text_to_sql      fractal_text_to_sql GENERATE/ALLOWLIST/        ~2s
#                        EXPLAIN-equivalent round trip (mock LLM) +
#                        direct allowlist rejection checks
#   05  evil_overread    non-NUL-terminated reasoning response, at    ~30s
#                        all 3 dispatch call sites, doesn't crash
#   06  crash_recovery   evil UDF segfaults mariadbd; supervisor      ~15s
#                        respawns it; prior committed data intact
#                        (tests/evil_crash_udf.c)
#   07  evil_lying_length lying response_len_out (32 MiB over an 8B   ~30s
#                        buffer), at all 3 call sites, rejected clean
#   08  authz            fractal_schema_context: a role with no        ~2s
#                        grant on a table can't see its structure
#   10  dos_and_injection allowlist: stacked statements, INTO OUTFILE,  ~1s
#                        CTE-feeding-DELETE all rejected
#   11  scout            fractal_explore: full population returned,   ~2s
#                        disperses across the 3-cluster inline corpus
#   12  soak             30x fractal_search in a row, no crash          ~3s
#   13  vectorizer_embed real INSERT -> trigger -> enqueue ->            ~2s
#                        process_queue -> embed write-back round trip
#                        (mock embeddings endpoint), plus a
#                        direct fractal_embed() call
#   14  retry            fractal_text_to_sql's attempt_loop: rejected   ~10s
#                        1st attempt, feedback threaded into 2nd
#   15  embed            fractal_embed edge cases (NULL, bad plugin    ~15s
#                        path, over-limit array) + vectorizer
#                        injection/double-create rejections
#   16  embed_authz      vectorizer INVOKER security: owner can         ~2s
#                        vectorize its own table, an outsider's
#                        process_queue() call fails, no data leaked
#   17  embed_soak       concurrent process_queue() workers, no          ~5s
#                        double-embed, none lost
#   18  embed_crash      real crash mid-process_queue (tests/evil_    ~15s
#                        crash_plugin.c, distinct from 06's UDF);
#                        stale_after_secs reclaim recovers the row
#   19  sfs_bounds       fractal_search's k bounds (1..1000000) and    ~1s
#                        MAX_QUERY_BYTES (4 MiB) rejection
#   20  analytics        fractal_dimension_dfa/_boxcount/_drift,         ~2s
#                        fractal_optimize_portfolio, real results
#                        against adequately-sized data
#   21  diversify        fractal_diversify_enable/_set_params/           ~1s
#                        _disable + fractal_explain_result
#   22  vector_tier      a representative slice of the 13 Vector-tier    ~1s
#                        functions
#   23  cognition        fractal_reason against the mock LLM, NULL       ~1s
#                        query -> NULL result
#   24  agents           Agency-tier engines E (recall_hybrid) and F      ~2s
#                        (recommend_diverse, both pure retrieval, no
#                        LLM) + C (route_task, real LLM via the mock)
#   25  enterprise       ledger/audit functions correctly refuse with     ~1s
#                        FRACTALSQL_ENTERPRISE_LIB unset
#   29  think            FRACTALSQL_HTTP_THINK/_THINK_PROVIDER/           ~10s
#                        _NATIVE_URL/_NUM_CTX bridge into FSQL_REASONING_
#                        HTTP_* reaches the plugin (unset, configured,
#                        and never leaking into fractal_embed)
#
# NOT ported, each for its own documented reason (see the architecture-
# differences block above, not a TODO backlog):
#   09  guc_superuser     (permanently N/A, no sysvar surface exists
#                          by design)
#   postgres's 26 (a real, non-mock enterprise .so) has no 1:1 match
#   here in this numbering -- this repo's OWN 26/27/28 below already
#   cover real-.so ground (activation gating, the CONNECT-queryable
#   ledger mirror, Ed25519 signature verification), just not postgres's
#   exact assertions, since the two Enterprise-tier implementations
#   have genuinely diverged (see src/fractalsql_enterprise.c's header).
#
# Gate sets:
#   QUICK   = 01 02
#   DEFAULT = 01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20
#             21 22 23 24 25 29
#   (26/27/28 stay opt-in: each needs a real, licensed enterprise .so
#   this public repo doesn't ship -- see gate_26_enterprise_active's own
#   header comment.)
#
# Usage:
#   ./build_test.sh                  # DEFAULT against MDB_MAJOR (default 11.4)
#   ./build_test.sh --quick
#   ./build_test.sh --mdb 10.6
#   ./build_test.sh --cross          # DEFAULT against every installed major
#   ./build_test.sh --gate 06
#   ./build_test.sh --list
#   ./build_test.sh --coverage       # gcov-instrumented build; DEFAULT gates
#   ./build_test.sh --asan           # ASan-instrumented (see docker/Dockerfile.test)
#   ./build_test.sh --ubsan
#
# Environment:
#   MDB_MAJOR              target major (default: 11.4)
#   MDB_BINDIR              override mariadbd/mariadb-install-db location
#   FSQL_TEST_TIMEOUT_MULT  scales gate 06's respawn-poll budget
#                           (default 1; auto-defaults to 3 under
#                           --asan/--ubsan, same rationale as postgres's
#                           build_test.sh; unverified locally, since this
#                           has not yet been run against real ASan/UBSan
#                           hardware)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

TMPROOT="$(cd /tmp && pwd -P)"

DEFAULT_GATES=(01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 29)
QUICK_GATES=(01 02)

MDB_MAJOR="${MDB_MAJOR:-11.4}"
MODE="default"
ONE_GATE=""
COVERAGE=0
ASAN=0
UBSAN=0

if [ -n "${FSQL_TEST_TIMEOUT_MULT:-}" ]; then
  TIMEOUT_MULT="$FSQL_TEST_TIMEOUT_MULT"
elif [ "$ASAN" -eq 1 ] || [ "$UBSAN" -eq 1 ]; then
  TIMEOUT_MULT=3
else
  TIMEOUT_MULT=1
fi

if [ -t 1 ]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; Z="\033[0m"; else G=""; R=""; Y=""; Z=""; fi
pass() { printf "  [${G}PASS${Z}] %s\n" "$1"; }
fail() { printf "  [${R}FAIL${Z}] %s\n" "$1"; FAILED=1; }
skip() { printf "  [${Y}SKIP${Z}] %s\n" "$1"; }

usage() { sed -n '4,160p' "$0"; exit 0; }

# Platform-correct include/<dir>/ subdir + shared-library extension for
# the vendored enterprise artifact, used by gates 26/27/28. Mirrors this
# file's own uname-based platform detection (mdb_bindir, and the
# fsql_platform local used for the reasoning-VFS test-fixture compiles
# in mdb_setup): "linux-x86_64"/"linux-aarch64" + .so on Linux,
# "darwin-x86_64"/"darwin-arm64" + .dylib on macOS (confirmed against
# fractalsql-core's own darwin release artifact naming -- e.g.
# libfractalsql-community-sovereign-c.dylib -- not assumed). Best-effort
# on Darwin specifically: never exercised on real Darwin hardware in
# this session (no such machine available here), unlike every Linux gate
# in this file, which was. If darwin-gate-matrix ever fails here, this
# function is the first place to check.
fsql_ent_platform_dir() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) echo "darwin-$arch" ;;
    *)      echo "linux-$arch" ;;
  esac
}
fsql_ent_so_ext() { [ "$(uname -s)" = "Darwin" ] && echo "dylib" || echo "so"; }
fsql_ent_so_path() {
  echo "$HERE/include/$(fsql_ent_platform_dir)/libfractalsql-enterprise-sovereign-c.$(fsql_ent_so_ext)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)   MODE="quick" ;;
    --cross)   MODE="cross" ;;
    --mdb)     MDB_MAJOR="$2"; shift ;;
    --gate)    ONE_GATE="$2"; shift ;;
    --coverage) COVERAGE=1 ;;
    --asan)    ASAN=1 ;;
    --ubsan)   UBSAN=1 ;;
    --list)    printf "gates: %s\n" "${DEFAULT_GATES[*]}"; exit 0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

FAILED=0
BIN=""; DATADIR=""; SOCK=""; PORT=""; PIDFILE=""; PLUGDIR=""; SUPERVISOR_PID=""; MOCK_LLM_PID=""
CRASH_SO=""

# mdb_bindir <major> -- locates mariadbd + mariadb-install-db +
# mariadb-admin + mysqld_safe for the requested major. Mirrors
# postgres's build_test.sh's pg_bindir() shape (env override, then
# Darwin/Homebrew, then Linux system paths) but MariaDB's own packaging
# does NOT install per-major binaries side-by-side the way Postgres's
# postgresql-<N> packages do: one system normally has exactly one
# mariadbd on PATH at a time (matching MDB_MAJOR is the caller's/CI's
# job: run this against a matching official Docker image, or a host
# with only that major's packages installed, see
# docker/Dockerfile.test and .github/workflows/build-test.yml).
mdb_bindir() {
  if [ -n "${MDB_BINDIR:-}" ]; then
    echo "$MDB_BINDIR"
    return
  fi
  if [ "$(uname -s)" = "Darwin" ]; then
    # Homebrew's mariadb formula is NOT per-major the way postgresql@<N>
    # is (confirmed: no mariadb@10.6/mariadb@11.4 formulae exist as of
    # this writing) -- `brew install mariadb` gives whatever major
    # Homebrew currently tracks. This means macOS CI cannot enforce the
    # same per-major matrix Linux/Windows get; see build-test.yml's
    # darwin-gate-matrix job comment for how it handles this (single
    # cell, not a 4-major matrix).
    local brew_bin
    if command -v brew >/dev/null 2>&1; then
      brew_bin="$(brew --prefix mariadb 2>/dev/null)/bin"
    else
      brew_bin="/opt/homebrew/opt/mariadb/bin"
    fi
    if [ -x "$brew_bin/mariadbd" ]; then
      echo "$brew_bin"
    else
      echo "$brew_bin"
    fi
    return
  fi
  # Linux: check common sbin locations, then PATH.
  for d in /usr/sbin /usr/local/sbin /usr/mysql/bin; do
    [ -x "$d/mariadbd" ] && { echo "$d"; return; }
  done
  if command -v mariadbd >/dev/null 2>&1; then
    dirname "$(command -v mariadbd)"
    return
  fi
  echo "/usr/sbin"
}

# mdb_installdb_bin / mdb_admin_bin: mariadb-install-db and
# mariadb-admin sometimes live in a different dir than mariadbd
# (bin/ vs sbin/) depending on distro packaging; probe both alongside
# whatever mdb_bindir resolved.
mdb_sibling() {
  local base="$1" name="$2"
  for d in "$base" "${base%/sbin}/bin" /usr/bin /usr/local/bin; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return; }
  done
  command -v "$name" 2>/dev/null
}

# mdb_setup <major>: builds a scratch plugin-dir containing
# fractalsql.so + the evil-crash UDF .so, initializes a throwaway
# datadir, and starts mariadbd against it (via mysqld_safe if
# available, else a manual respawn-loop supervisor; see gate 06's own
# header comment for why this distinction matters). Returns 1 (skip) if
# mariadbd for this major cannot be found at all.
mdb_setup() {
  local v="$1"
  BIN="$(mdb_bindir "$v")"
  if [ ! -x "$BIN/mariadbd" ] && ! command -v mariadbd >/dev/null 2>&1; then
    return 1
  fi
  local mariadbd_bin; mariadbd_bin="$([ -x "$BIN/mariadbd" ] && echo "$BIN/mariadbd" || command -v mariadbd)"
  local installdb_bin; installdb_bin="$(mdb_sibling "$BIN" mariadb-install-db)"
  local admin_bin;     admin_bin="$(mdb_sibling "$BIN" mariadb-admin)"
  local client_bin;    client_bin="$(mdb_sibling "$BIN" mariadb)"
  [ -n "$installdb_bin" ] && [ -n "$client_bin" ] || { echo "mariadb-install-db or mariadb client not found" >&2; return 2; }

  DATADIR="/tmp/fractalsql_bt_data_${v//./_}"
  SOCK="/tmp/fractalsql_bt_sock_${v//./_}/mysql.sock"
  PLUGDIR="$TMPROOT/fractalsql_bt_plugin_${v//./_}"
  PIDFILE="/tmp/fractalsql_bt_pid_${v//./_}.pid"
  PORT=$(( 13300 + $(echo "$v" | tr -d '.') % 100 ))
  rm -rf "$DATADIR" "$(dirname "$SOCK")" "$PLUGDIR"
  mkdir -p "$DATADIR" "$(dirname "$SOCK")" "$PLUGDIR"

  cp "$HERE/fractalsql.so" "$PLUGDIR/fractalsql.so" || return 2
  # Reasoning-tier gates (03/04/13/22/23) dispatch through the real
  # fractalsql-reasoning-http.so plugin against a deterministic local
  # mock (scripts/ci/mock_llm.py), exercising the FULL real path (UDF
  # -> fsql_load_reasoning -> curl -> HTTP -> response parse), not a
  # fake in-process substitute. Started here, before mariadbd, since
  # FRACTALSQL_REASONING_PLUGIN/HTTP_URL/HTTP_EMBED_URL must be in
  # mariadbd's OWN process environment at exec time (read once, lazily,
  # per process).
  cp "$HERE/include/linux-x86_64/fractalsql-reasoning-http.so" "$PLUGDIR/fractalsql-reasoning-http.so" || return 2
  local mock_port=$(( 18300 + $(echo "$v" | tr -d '.') % 100 ))
  python3 "$HERE/scripts/ci/mock_llm.py" "$mock_port" \
    >/tmp/fractalsql_bt_mockllm_${v//./_}.log 2>&1 &
  MOCK_LLM_PID=$!
  # Plain bash /dev/tcp, not curl: Dockerfile.test's apt-get list has no
  # reason to carry a whole extra HTTP client just for a readiness poll
  # (caught live: `curl: command not found` under the minimal image --
  # bash's own /proc/net/tcp-backed /dev/tcp pseudo-device needs nothing
  # extra).
  local mi
  for mi in $(seq 1 20); do
    (exec 3<>"/dev/tcp/127.0.0.1/$mock_port") 2>/dev/null && { exec 3>&-; break; }
    sleep 0.2
  done
  # ${VAR:-default}, not a plain export: gates 05/07/14/15/18 need
  # FRACTALSQL_REASONING_PLUGIN pointed at a reasoning-VFS-ABI-level
  # fixture (evil/retry, no HTTP involved at all) INSTEAD of the real
  # HTTP wrapper for the duration of one restart cycle -- they export
  # their own value and call mdb_setup directly (mirroring gates
  # 26/27/28's FRACTALSQL_ENTERPRISE_LIB pattern), and an unconditional
  # export here would silently stomp that override back to the HTTP
  # wrapper on every single restart, defeating the swap entirely.
  export FRACTALSQL_REASONING_PLUGIN="${FRACTALSQL_REASONING_PLUGIN:-$PLUGDIR/fractalsql-reasoning-http.so}"
  export FRACTALSQL_HTTP_URL="http://127.0.0.1:$mock_port/v1/chat/completions"
  export FRACTALSQL_HTTP_EMBED_URL="http://127.0.0.1:$mock_port/v1/embeddings"
  export FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1

  # Same header-resolution fallback chain as the Makefile: prefer
  # mariadb_config, then mysql_config, then the common packaged path.
  local mdb_cflags
  mdb_cflags="$(mariadb_config --cflags 2>/dev/null)"
  [ -z "$mdb_cflags" ] && mdb_cflags="$(mysql_config --cflags 2>/dev/null)"
  [ -z "$mdb_cflags" ] && mdb_cflags="-I/usr/include/mariadb"
  CRASH_SO="$PLUGDIR/evil_crash.so"
  cc -shared -fPIC -std=c99 $mdb_cflags tests/evil_crash_udf.c -o "$CRASH_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }

  # Reasoning-VFS-ABI-level test fixtures for gates 05/07/14/15/18 (see
  # tests/*.c's own file headers): pure C against the shared vendored
  # fractalsql_sql.h, portably copied from fractalsql-postgresql's own
  # tests/ (that repo's evil/retry plugins reference no postgres- or
  # mariadb-specific API at all). -Iinclude/<platform> gives
  # fractalsql_sql.h/fractalsql.h; $mdb_cflags is NOT needed for these
  # (they never include mysql.h), unlike CRASH_SO above. Recompiled
  # every mdb_setup call since mdb_teardown wipes the whole $PLUGDIR.
  EVIL_REASONING_SO="$PLUGDIR/evil_nonterminating.so"
  LYING_SO="$PLUGDIR/evil_lying_length.so"
  CRASH_REASONING_SO="$PLUGDIR/evil_crash_reasoning.so"
  EVIL_EMBED_SO="$PLUGDIR/evil_embed.so"
  RETRY_SO="$PLUGDIR/retry_reasoning.so"
  THINK_SO="$PLUGDIR/think_reasoning.so"
  local fsql_platform; fsql_platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
  local fsql_inc="-I$HERE/include/$fsql_platform -I$HERE/include"
  cc -shared -fPIC -std=c99 $fsql_inc tests/evil_nonterminating_plugin.c -o "$EVIL_REASONING_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  cc -shared -fPIC -std=c99 $fsql_inc tests/evil_lying_length_plugin.c -o "$LYING_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  cc -shared -fPIC -std=c99 $fsql_inc tests/evil_crash_plugin.c -o "$CRASH_REASONING_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  cc -shared -fPIC -std=c99 $fsql_inc tests/evil_embed_plugin.c -o "$EVIL_EMBED_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  cc -shared -fPIC -std=c99 $fsql_inc tests/retry_reasoning_plugin.c -o "$RETRY_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  cc -shared -fPIC -std=c99 $fsql_inc tests/think_reasoning_plugin.c -o "$THINK_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }

  "$installdb_bin" --datadir="$DATADIR" --auth-root-authentication-method=normal \
    >/tmp/fractalsql_bt_setup_${v//./_}.log 2>&1 \
    || { tail -30 /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }

  # Modern MariaDB packaging (confirmed directly: mariadb:11.4 official
  # image) renamed mysqld_safe -> mariadbd-safe; check both names since
  # older majors in the compat matrix may still ship the old one.
  local mysqld_safe_bin
  mysqld_safe_bin="$(mdb_sibling "$BIN" mariadbd-safe)"
  [ -z "$mysqld_safe_bin" ] && mysqld_safe_bin="$(mdb_sibling "$BIN" mysqld_safe)"
  if [ -n "$mysqld_safe_bin" ]; then
    # mysqld_safe IS the standard MariaDB/MySQL crash-respawn
    # supervisor: it watches the mariadbd child and restarts it on
    # abnormal exit, which is exactly the platform behavior gate 06
    # needs to observe.
    "$mysqld_safe_bin" --ledir="$(dirname "$mariadbd_bin")" \
      --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
      --plugin-dir="$PLUGDIR" --pid-file="$PIDFILE" \
      --skip-networking=0 --bind-address=127.0.0.1 \
      >/tmp/fractalsql_bt_server_${v//./_}.log 2>&1 &
    SUPERVISOR_PID=$!
  else
    # Fallback: a minimal manual respawn loop. Weaker than mysqld_safe
    # (no log-rotation/crash-detection sophistication) but sufficient
    # to prove the specific claim gate 06 checks: SOMETHING brings
    # mariadbd back after a UDF-triggered crash.
    ( while true; do
        "$mariadbd_bin" --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
          --plugin-dir="$PLUGDIR" --pid-file="$PIDFILE" \
          --skip-networking=0 --bind-address=127.0.0.1 \
          >>/tmp/fractalsql_bt_server_${v//./_}.log 2>&1
        sleep 0.5
      done ) &
    SUPERVISOR_PID=$!
  fi

  local i
  for i in $(seq 1 $(( 30 * TIMEOUT_MULT ))); do
    "$client_bin" --socket="$SOCK" -uroot -e "SELECT 1;" >/dev/null 2>&1 && break
    sleep 0.5
  done
  "$client_bin" --socket="$SOCK" -uroot -e "SELECT 1;" >/dev/null 2>&1 \
    || { tail -30 /tmp/fractalsql_bt_server_${v//./_}.log >&2; return 2; }

  # A database must exist and be selected before install_udf.sql runs:
  # the Vectorizer's tables/view (fractal_vectorizers, fractal_
  # vectorizer_queue, ...) are real CREATE TABLE/CREATE VIEW statements,
  # unlike an earlier CREATE-FUNCTION-only install, which needed no
  # database context at all. A bare `mariadb -uroot` here (no -D) fails
  # install_udf.sql with "ERROR 1046: No database selected".
  "$client_bin" --socket="$SOCK" -uroot -e "CREATE DATABASE IF NOT EXISTS fractalsql_bt;" \
    >/tmp/fractalsql_bt_setup_${v//./_}.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }

  MARIADB=("$client_bin" --socket="$SOCK" -uroot -D fractalsql_bt)
  ADMIN=("$admin_bin" --socket="$SOCK" -uroot)

  "${MARIADB[@]}" < sql/install_udf.sql >/tmp/fractalsql_bt_setup_${v//./_}.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  # install_agents.sql registers the 15 Agency-tier procedures gate 24
  # needs. Without this, gate 24's CALLs fail "PROCEDURE ... does not
  # exist", the exact same install-completeness gap docker/Dockerfile's
  # own docker-entrypoint-initdb.d 10-/11- ordering already accounts for.
  "${MARIADB[@]}" < sql/install_agents.sql >>/tmp/fractalsql_bt_setup_${v//./_}.log 2>&1 \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  return 0
}

mdb_teardown() {
  [ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" >/dev/null 2>&1
  [ -n "${ADMIN:-}" ] && "${ADMIN[@]}" shutdown >/dev/null 2>&1
  sleep 1
  pkill -f "mariadbd.*$DATADIR" >/dev/null 2>&1 || true
  [ -n "$MOCK_LLM_PID" ] && kill "$MOCK_LLM_PID" >/dev/null 2>&1
  [ -n "$DATADIR" ] && rm -rf "$DATADIR"
  [ -n "$SOCK" ] && rm -rf "$(dirname "$SOCK")"
  [ -n "$PLUGDIR" ] && rm -rf "$PLUGDIR"
  DATADIR=""; SOCK=""; MOCK_LLM_PID=""
}

cleanup() {
  mdb_teardown 2>/dev/null || true
}
trap cleanup EXIT

# Restart mariadbd with FRACTALSQL_REASONING_PLUGIN pointed at $1
# instead of the real HTTP wrapper -- mirrors postgres's pg_swap_plugin,
# restart-based (not a live SET) since FRACTALSQL_REASONING_PLUGIN is a
# process environment variable read once at mysqld startup, the same
# constraint gates 26/27/28 already work around for
# FRACTALSQL_ENTERPRISE_LIB. Extra env assignments (e.g.
# FRACTALSQL_TEXT_TO_SQL_USE_REVIEW) can be exported by the caller
# before calling this, same restart, since they're read the same way.
# Returns mdb_setup's own exit code.
mdb_swap_reasoning_plugin() {
  mdb_teardown
  export FRACTALSQL_REASONING_PLUGIN="$1"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# Restores the real HTTP-wrapper reasoning plugin + mock LLM server --
# the baseline every OTHER gate in this suite assumes -- and clears any
# text-to-sql env overrides a gate set. Call at the end of every gate
# that used mdb_swap_reasoning_plugin.
mdb_restore_reasoning_plugin() {
  mdb_teardown
  unset FRACTALSQL_REASONING_PLUGIN FRACTALSQL_TEXT_TO_SQL_USE_REVIEW \
        FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# Gate 18 ONLY: restore the real reasoning plugin the same way gate 06's
# crash-recovery supervisor itself would -- kill mariadbd and relaunch it
# against the SAME $DATADIR/$SOCK/$PORT/$PLUGDIR, no wipe, no re-run of
# install_udf.sql/install_agents.sql (routines already persisted in this
# datadir from the mdb_setup call that started it). mdb_restore_reasoning
# _plugin (above) is wrong for this one gate specifically: it calls
# mdb_setup, which unconditionally wipes $DATADIR -- fine for every other
# plugin-swap gate (nothing from before the swap needs to survive it),
# but gate 18's entire point is proving data survives a real crash +
# in-place respawn, so wiping it immediately afterward (to restore the
# plugin before the reclaim call) would destroy the very state being
# tested. $PLUGDIR already has fractalsql-reasoning-http.so in it
# regardless of which plugin FRACTALSQL_REASONING_PLUGIN pointed at
# (mdb_setup copies it in unconditionally, before ever reading that env
# var) -- confirmed live -- so only mariadbd itself needs restarting, not
# the whole cluster.
mdb_restart_inplace_reasoning_plugin() {
  export FRACTALSQL_REASONING_PLUGIN="$1"
  [ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" >/dev/null 2>&1
  sleep 1
  pkill -f "mariadbd.*$DATADIR" >/dev/null 2>&1 || true
  sleep 1

  local mariadbd_bin; mariadbd_bin="$([ -x "$BIN/mariadbd" ] && echo "$BIN/mariadbd" || command -v mariadbd)"
  local mysqld_safe_bin
  mysqld_safe_bin="$(mdb_sibling "$BIN" mariadbd-safe)"
  [ -z "$mysqld_safe_bin" ] && mysqld_safe_bin="$(mdb_sibling "$BIN" mysqld_safe)"
  if [ -n "$mysqld_safe_bin" ]; then
    "$mysqld_safe_bin" --ledir="$(dirname "$mariadbd_bin")" \
      --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
      --plugin-dir="$PLUGDIR" --pid-file="$PIDFILE" \
      --skip-networking=0 --bind-address=127.0.0.1 \
      >>/tmp/fractalsql_bt_server_${MDB_MAJOR//./_}.log 2>&1 &
    SUPERVISOR_PID=$!
  else
    ( while true; do
        "$mariadbd_bin" --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
          --plugin-dir="$PLUGDIR" --pid-file="$PIDFILE" \
          --skip-networking=0 --bind-address=127.0.0.1 \
          >>/tmp/fractalsql_bt_server_${MDB_MAJOR//./_}.log 2>&1
        sleep 0.5
      done ) &
    SUPERVISOR_PID=$!
  fi

  local i
  for i in $(seq 1 $(( 30 * TIMEOUT_MULT ))); do
    "${MARIADB[@]}" -e "SELECT 1;" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 2
}

# --- gates --------------------------------------------------------------

gate_01_build() {
  make clean >/dev/null 2>&1
  local cov_arg="" san_arg=""
  [ "$COVERAGE" -eq 1 ] && cov_arg="COVERAGE=1"
  [ "$ASAN" -eq 1 ]  && san_arg="ASAN=1"
  [ "$UBSAN" -eq 1 ] && san_arg="UBSAN=1"
  # NOTE: Makefile does not currently define COVERAGE=1/ASAN=1/UBSAN=1
  # targets (unlike postgres's PGXS-driven Makefile, which passes these
  # straight through to PG_CPPFLAGS/SHLIB_LINK). A follow-up should
  # extend Makefile's CFLAGS/LDFLAGS to honor these the same way
  # docker/Dockerfile.test's FSQL_SAN_MODE build-arg expects. Until
  # then, --coverage/--asan/--ubsan build the SAME unsanitized binary
  # as a plain `make`, so gate 06's supervisor-respawn assertion still
  # runs, but it is not actually exercising instrumented code. Flagged
  # here rather than silently no-op'd.
  if make $cov_arg $san_arg >/tmp/fractalsql_bt_build.log 2>&1 && [ -f "$HERE/fractalsql.so" ]; then
    pass "01 build"
  else
    fail "01 build: see /tmp/fractalsql_bt_build.log"
    grep -iE "error:" /tmp/fractalsql_bt_build.log | head -3 | sed 's/^/         /'
  fi
}

gate_02_smoke() {
  local want_ver; want_ver="$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' src/fractalsql.c | head -1)"
  local ver; ver=$("${MARIADB[@]}" -N -e "SELECT fractalsql_version();" 2>&1)
  [ "$ver" = "$want_ver" ] && pass "02 smoke: version=$ver" || fail "02 smoke: version='$ver' (want $want_ver)"

  local ed; ed=$("${MARIADB[@]}" -N -e "SELECT fractalsql_edition();" 2>&1)
  [ -n "$ed" ] && ! grep <<< "$ed" -q "ERROR" && pass "02 smoke: edition=$ed" || fail "02 smoke: edition='$ed'"

  # fractal_search(vector_csv, query_csv, k, params) -> JSON string.
  # Convergence check mirrors postgres's gate 02: cosine similarity of
  # best_point to the query should be ~1 (best_point lies on the ray
  # through the origin and the query for a cosine-distance objective).
  local r; r=$("${MARIADB[@]}" -N -e "
    SELECT fractal_search(
      '[[1,0],[0,1],[0.6,0.8]]', '[0.6,0.8]', 3,
      '{\"iterations\":50,\"population_size\":30}'
    );" 2>&1)
  if echo "$r" | grep -q '"best_point"'; then
    pass "02 smoke: fractal_search returns best_point"
  else
    fail "02 smoke: fractal_search='$r'"
  fi
}

# Deliberately-segfaulting UDF. See this script's top-of-file
# architecture-differences comment for why this is NOT the same claim
# as postgres's gate 06: it tests (a) the supervisor respawns
# mariadbd, (b) InnoDB crash recovery leaves prior committed data
# intact. Uses a plain InnoDB table + row as the "canary", same
# technique as postgres's gate 06.
gate_06_crash_recovery() {
  "${MARIADB[@]}" -e "
    CREATE DATABASE IF NOT EXISTS bt;
    USE bt;
    CREATE TABLE IF NOT EXISTS canary (id INT PRIMARY KEY, note VARCHAR(32)) ENGINE=InnoDB;
    INSERT INTO canary VALUES (1, 'canary') ON DUPLICATE KEY UPDATE note='canary';
  " >/dev/null 2>&1

  "${MARIADB[@]}" -e "
    DROP FUNCTION IF EXISTS bt_evil_crash;
    CREATE FUNCTION bt_evil_crash RETURNS INTEGER SONAME 'evil_crash.so';
  " >/dev/null 2>&1

  local r; r=$("${MARIADB[@]}" -N -e "SELECT bt_evil_crash();" 2>&1)
  # MariaDB 12.2's client reports an abrupt mid-query disconnect as a
  # TLS/SSL error ("unexpected eof while reading") rather than the
  # classic "Lost connection to MySQL server" text 10.6-11.4 use --
  # caught live (a real, version-specific error-message difference, not
  # a functional regression: the respawn + data-integrity assertions
  # right after this one still passed on 12.2 unchanged).
  if echo "$r" | grep -qiE "lost connection|server has gone away|can't connect|tls/ssl error|unexpected eof"; then
    pass "06 crash_recovery: triggering connection dropped as expected"
  else
    fail "06 crash_recovery: expected the connection to drop, got: $r"
  fi

  local up=0 i tries=$(( 30 * TIMEOUT_MULT ))
  for i in $(seq 1 "$tries"); do
    "${MARIADB[@]}" -e "SELECT 1;" >/dev/null 2>&1 && { up=1; break; }
    sleep 0.5
  done
  [ "$up" -eq 1 ] && pass "06 crash_recovery: supervisor respawned mariadbd (within ${tries}x0.5s)" \
                   || fail "06 crash_recovery: mariadbd did not come back within $(( tries / 2 ))s"

  if [ "$up" -eq 1 ]; then
    local n; n=$("${MARIADB[@]}" -N -e "SELECT note FROM bt.canary WHERE id=1;" 2>&1)
    [ "$n" = "canary" ] && pass "06 crash_recovery: prior committed data intact after recovery" \
                         || fail "06 crash_recovery: canary row wrong/missing after recovery: '$n'"
    # Functions registered via CREATE FUNCTION ... SONAME are persisted
    # in the mysql.func system table and MariaDB reloads them
    # automatically on the respawned instance's startup. Re-registering
    # here is defensive (a fresh datadir init would need it), not
    # assumed necessary; drop the evil UDF either way so later gates on
    # a --cross re-run don't trip over it.
    "${MARIADB[@]}" -e "DROP FUNCTION IF EXISTS bt_evil_crash;" >/dev/null 2>&1
  else
    fail "06 crash_recovery: mariadbd never came back; remaining gates in this run may fail"
  fi
}

gate_11_scout() {
  # 3-cluster inline corpus (mirrors postgres's gate 11 shape, adapted
  # to fractal_explore's inline-CSV-corpus signature rather than a
  # table+column scan. fractal_explore(corpus_csv, query_csv, params)
  # has no table-scan mode in this repo's architecture, unlike
  # postgres's fractal_search_explore(table_name, vector_col, ...)).
  local corpus="["
  local i
  for i in $(seq 1 20); do corpus+="[1,0,0],"; done
  for i in $(seq 1 20); do corpus+="[0,1,0],"; done
  for i in $(seq 1 20); do corpus+="[0,0,1],"; done
  corpus="${corpus%,}]"

  local r; r=$("${MARIADB[@]}" -N -e "
    SELECT fractal_explore('$corpus', '[1,0,0]', '{\"population_size\":24,\"iterations\":12}');" 2>&1)

  local n; n=$(echo "$r" | grep -oE '"population"\s*:\s*\[' >/dev/null 2>&1 && \
               echo "$r" | tr ',' '\n' | grep -c '\[' || echo 0)
  if echo "$r" | grep -q '"population"'; then
    pass "11 scout: fractal_explore returns a population array"
  else
    fail "11 scout: fractal_explore='$r'"
  fi

  if command -v jq >/dev/null 2>&1; then
    local psize; psize=$(echo "$r" | jq -r '.population | length' 2>/dev/null)
    [ "$psize" = "24" ] && pass "11 scout: population has 24 particles" \
                         || fail "11 scout: expected 24 particles, got: $psize"
    local islands; islands=$(echo "$r" | jq -r '
      [.population[] | if .[0] > .[1] and .[0] > .[2] then 0
                        elif .[1] > .[0] and .[1] > .[2] then 1
                        else 2 end] | unique | length' 2>/dev/null)
    [ "${islands:-0}" -gt 1 ] 2>/dev/null && pass "11 scout: particles disperse across >1 island" \
                                            || fail "11 scout: expected dispersion, got islands=$islands"
  else
    skip "11 scout: population-size/dispersion checks (jq not installed)"
  fi
}

# fractal_search's k bounds (1..1000000, checked at UDF init time) and
# MAX_QUERY_BYTES (4 MiB) rejection. Mirrors postgres's gate 19
# validate_sfs_params() bounds check, scoped to what fractal_search
# actually validates today (see the bounds check in
# fractal_search()/fractal_explore() in src/fractalsql.c).
gate_19_sfs_bounds() {
  local r; r=$("${MARIADB[@]}" -N -e "
    SELECT fractal_search('[[1,0]]', '[1,0]', 0, '{}');" 2>&1)
  echo "$r" | grep -qiE "k must be 1\.\.1000000|error" \
    && pass "19 sfs_bounds: k=0 rejected" \
    || fail "19 sfs_bounds: expected k=0 rejection, got: $r"

  local r2; r2=$("${MARIADB[@]}" -N -e "
    SELECT fractal_search('[[1,0]]', '[1,0]', 2000000, '{}');" 2>&1)
  echo "$r2" | grep -qiE "k must be 1\.\.1000000|error" \
    && pass "19 sfs_bounds: k=2000000 rejected" \
    || fail "19 sfs_bounds: expected k=2000000 rejection, got: $r2"

  # 4 MiB + 1 byte query string. MAX_QUERY_BYTES check is on
  # args->lengths[1] (the raw query_csv byte length), not the parsed
  # vector, so a big padded-but-otherwise-valid-looking string is enough
  # to trip it without needing a real 4M-element vector.
  local big; big="[$(printf '1,%.0s' $(seq 1 2100000))1]"   # > 4 MiB of text
  # Piped via stdin, not -e: a >4MiB argv string blows the OS ARG_MAX
  # limit ("Argument list too long") before mariadb even starts --
  # confirmed directly (this is what -e originally did here). Piping
  # avoids argv entirely; the byte count still reaches
  # fractal_search's args->lengths[1] check the same way.
  local r3; r3=$(printf "SELECT fractal_search('[[1,0]]', '%s', 1, '{}');" "$big" \
                 | "${MARIADB[@]}" -N 2>&1)
  echo "$r3" | grep -qiE "error|NULL" \
    && pass "19 sfs_bounds: oversized query (>4MiB) rejected" \
    || fail "19 sfs_bounds: expected oversized-query rejection, got: ${r3:0:120}..."
}

# fractal_schema_context: real table/column/comment/FK introspection.
# No LLM needed, pure information_schema.
gate_03_schema_context() {
  "${MARIADB[@]}" -e "
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
  " > /tmp/fractalsql_bt_gate03.log 2>&1

  grep -q "bt_customers" /tmp/fractalsql_bt_gate03.log \
    && pass "03 schema_context: table name present" \
    || fail "03 schema_context: table name missing: $(tail -1 /tmp/fractalsql_bt_gate03.log)"
  grep -q "Registered customers" /tmp/fractalsql_bt_gate03.log \
    && pass "03 schema_context: table comment present" \
    || fail "03 schema_context: table comment missing"
  grep -q "Customer full name" /tmp/fractalsql_bt_gate03.log \
    && pass "03 schema_context: column comment present" \
    || fail "03 schema_context: column comment missing"
  grep -qi "FOREIGN KEY" /tmp/fractalsql_bt_gate03.log \
    && pass "03 schema_context: foreign key present" \
    || fail "03 schema_context: foreign key missing"

  local err; err=$("${MARIADB[@]}" -N -e "
    CALL fractal_schema_context('[\"nonexistent_bt_table\"]', @c2);" 2>&1)
  echo "$err" | grep -qi "not found or not visible" \
    && pass "03 schema_context: nonexistent table SIGNALs cleanly" \
    || fail "03 schema_context: expected a clean SIGNAL, got: $err"
}

# fractal_text_to_sql: GENERATE (via the mock LLM, which
# always replies a fenced ```sql SELECT 1``` block, see mdb_setup's
# reasoning-tier wiring and scripts/ci/mock_llm.py's own comment on
# why one universal reply serves every reasoning-tier gate) ->
# ALLOWLIST -> EXPLAIN-equivalent -> return. Rejection-path coverage is
# via fractal_t2s_check_allowlist() directly (deterministic, no need to
# coax a specific bad reply out of the mock).
gate_04_text_to_sql() {
  local sql err
  read -r sql err < <("${MARIADB[@]}" -N -e "
    CALL fractal_text_to_sql('irrelevant -- mock always replies the same', NULL, @s, @e);
    SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1 | tr '\t' ' ')
  [ "$sql" = "SELECT" ] \
    && pass "04 text_to_sql: GENERATE/ALLOWLIST/EXPLAIN round trip returned real SQL" \
    || fail "04 text_to_sql: expected 'SELECT 1', got sql='$sql' err='$err'"

  # Direct allowlist checks. No LLM, deterministic, covers the
  # rejection paths gate 10 (DoS/injection) also exercises a subset of.
  local a1; a1=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT 1'), '<PASS>');" 2>&1)
  [ "$a1" = "<PASS>" ] && pass "04 text_to_sql: plain SELECT passes allowlist" \
                        || fail "04 text_to_sql: expected plain SELECT to pass, got: $a1"

  local a2; a2=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('DROP TABLE bt_customers'), '<PASS>');" 2>&1)
  [ "$a2" != "<PASS>" ] && pass "04 text_to_sql: DDL rejected by allowlist" \
                         || fail "04 text_to_sql: expected DROP TABLE to be rejected"
}

# Adversarial reasoning plugin returning a non-NUL-terminated response
# flush against a guard page (tests/evil_nonterminating_plugin.c,
# copied verbatim from fractalsql-postgresql's tests/ -- pure C against
# the shared vendored fractalsql_sql.h, no postgres/mariadb-specific
# API). Proves fractal_t2s_generate/fractal_reason/fractal_t2s_review
# all honor response_len_out and never treat `summary` as a NUL-
# terminated C string, at all three call sites that dispatch through
# fsql_dispatch_ai.
#
# IMPORTANT MariaDB-specific design note: the evil plugin's call_count
# is a process-wide static (matches postgres's plugin file verbatim),
# but unlike postgres (one fresh forked backend process per connection,
# so a fresh psql -c invocation gets call_count=0 again) MariaDB is ONE
# shared process for every connection -- call_count keeps incrementing
# across every UDF call in the process's lifetime, connection or not.
# So this gate restarts mariadbd (via mdb_swap_reasoning_plugin) before
# EACH of the three call sites, not once for the whole gate: only that
# guarantees call_count=0 (matching FSQL_EVIL_TRIGGER_CALL's default,
# trigger=1) at every site actually under test, the same guarantee
# postgres gets for free from fork-per-backend. Slower (3 restarts
# instead of 1) but the only way this is correct here.
gate_05_evil_overread() {
  mdb_swap_reasoning_plugin "$EVIL_REASONING_SO" \
    || { fail "05 evil_overread: plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r; r=$("${MARIADB[@]}" -N -e "CALL fractal_text_to_sql('q', NULL, @s, @e); SELECT @s, @e;" 2>&1)
  local up1; up1=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  [ "$up1" = "1" ] && pass "05 evil_overread: GENERATE path (fractal_text_to_sql) survived" \
                    || fail "05 evil_overread: GENERATE path -- mariadbd did not survive: $r"

  mdb_swap_reasoning_plugin "$EVIL_REASONING_SO" \
    || { fail "05 evil_overread: plugin swap (reason) did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  local up2; up2=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  [ "$up2" = "1" ] && pass "05 evil_overread: bare fractal_reason() survived" \
                    || fail "05 evil_overread: bare fractal_reason() -- mariadbd did not survive: $r2"

  mdb_swap_reasoning_plugin "$EVIL_REASONING_SO" \
    || { fail "05 evil_overread: plugin swap (review) did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r3; r3=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1');" 2>&1)
  local up3; up3=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  [ "$up3" = "1" ] && pass "05 evil_overread: fractal_t2s_review() survived" \
                    || fail "05 evil_overread: fractal_t2s_review() -- mariadbd did not survive: $r3"

  mdb_restore_reasoning_plugin
}

# Same three call sites as gate 05, but the adversarial claim is a
# lying response_len_out (32 MiB, over a real 8-byte buffer) instead of
# a missing NUL terminator (tests/evil_lying_length_plugin.c, verbatim
# from postgres) -- proves the length-bound check (FRACTAL_MAX_AI_
# RESPONSE_BYTES, src/fractalsql_cognition.c / fractalsql_textsql.c)
# rejects BEFORE any read past the real 8-byte buffer, not just that
# nothing crashes. Unlike postgres's grep for "implausible response
# length" (a live error message), MariaDB's UDF ABI has no SQL-visible
# error text for this class of rejection (see this file's own header
# comment on *error=1 collapsing to a silent NULL) -- so the assertion
# here is "result IS NULL, mariadbd still up", the same two-part check
# gate 25 already uses for the enterprise ledger's own not-loaded case.
# Same process-wide call_count / per-call-site restart requirement as
# gate 05 above.
gate_07_evil_lying_length() {
  mdb_swap_reasoning_plugin "$LYING_SO" \
    || { fail "07 evil_lying_length: plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r; r=$("${MARIADB[@]}" -N -e "CALL fractal_text_to_sql('q', NULL, @s, @e); SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1)
  local up1; up1=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  if [ "$up1" != "1" ]; then
    fail "07 evil_lying_length: GENERATE path -- mariadbd did not survive: $r"
  elif [[ "$r" == *"<NULL>"* ]]; then
    pass "07 evil_lying_length: GENERATE path rejected cleanly (out_sql NULL, no crash)"
  else
    fail "07 evil_lying_length: GENERATE path -- expected a clean rejection, got: $r"
  fi

  mdb_swap_reasoning_plugin "$LYING_SO" \
    || { fail "07 evil_lying_length: plugin swap (reason) did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_reason(CONNECTION_ID(), 'q'), '<NULL>');" 2>&1)
  local up2; up2=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  if [ "$up2" != "1" ]; then
    fail "07 evil_lying_length: bare fractal_reason() -- mariadbd did not survive: $r2"
  elif [ "$r2" = "<NULL>" ]; then
    pass "07 evil_lying_length: bare fractal_reason() rejected cleanly"
  else
    fail "07 evil_lying_length: bare fractal_reason() -- expected NULL, got: $r2"
  fi

  mdb_swap_reasoning_plugin "$LYING_SO" \
    || { fail "07 evil_lying_length: plugin swap (review) did not take effect"; mdb_restore_reasoning_plugin; return; }
  local r3; r3=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1'), '<NULL>');" 2>&1)
  local up3; up3=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  if [ "$up3" != "1" ]; then
    fail "07 evil_lying_length: fractal_t2s_review() -- mariadbd did not survive: $r3"
  elif [ "$r3" = "<NULL>" ]; then
    pass "07 evil_lying_length: fractal_t2s_review() rejected cleanly"
  else
    fail "07 evil_lying_length: fractal_t2s_review() -- expected NULL, got: $r3"
  fi

  mdb_restore_reasoning_plugin
}

# fractal_schema_context's privilege boundary: a role with no grant on
# a table must not see its column/comment/FK structure via schema
# introspection, and a grant must restore visibility. Same regression
# CLASS postgres's gate 08 proves for its own has_table_privilege
# bypass bug -- ported here as a confirmatory test (not assumed safe
# from reading the code), since this file's own header previously only
# asserted, not verified, that MariaDB's information_schema-backed
# INVOKER security handles this: information_schema.columns/tables
# themselves already filter by the CONNECTED user's privileges (a
# property of the catalog, not of fractal_schema_context's own SQL),
# unlike postgres's pg_attribute/pg_constraint, which are globally
# readable catalogs postgres's fractal_schema_context had to add an
# explicit has_table_privilege() check for.
gate_08_authz() {
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_secret;
    CREATE TABLE bt_secret (id BIGINT PRIMARY KEY AUTO_INCREMENT, ssn VARCHAR(20)) COMMENT='PII - restricted';
    DROP USER IF EXISTS 'bt_lowpriv'@'localhost';
    CREATE USER 'bt_lowpriv'@'localhost';
    -- Two grants, neither touching bt_secret, both confirmed live to be
    -- REQUIRED (not just sufficient) before this test reaches its actual
    -- point: (1) EXECUTE, db-scoped (ON fractalsql_bt.*, not ON
    -- PROCEDURE ...one_routine) -- a routine-level-only grant does NOT
    -- populate mysql.db, and MariaDB's initial USE/-D db-select check
    -- (mysql_change_db) only consults mysql.db/mysql.user, never
    -- mysql.procs_priv, so a routine-only grant left every connection
    -- refused with 'Access denied ... to database' before the CALL was
    -- even reached. (2) CREATE TEMPORARY TABLES -- fractal_schema_
    -- context's body (sql/install_udf.sql) stages its working set in
    -- _fractalsql_t2s_schema_tmp; SQL SECURITY INVOKER means that temp
    -- table is created under the CALLING user's own privileges too, and
    -- without this grant the same 'Access denied ... to database' fires
    -- from inside the procedure regardless of table_names_json's
    -- content (confirmed live with an EMPTY array -- not a bt_secret-
    -- specific symptom). Neither grant touches bt_secret's own
    -- SELECT privilege, keeping this test's actual point (table-level
    -- privilege gates column/comment visibility) intact.
    GRANT EXECUTE, CREATE TEMPORARY TABLES ON fractalsql_bt.* TO 'bt_lowpriv'@'localhost';
    FLUSH PRIVILEGES;
  " >/dev/null 2>&1

  local lowpriv=("${MARIADB[0]}" --socket="$SOCK" -u bt_lowpriv -D fractalsql_bt -N)
  local r; r=$("${lowpriv[@]}" -e "CALL fractal_schema_context('[\"bt_secret\"]', @c); SELECT @c;" 2>&1)
  if echo "$r" | grep -q "ssn"; then
    fail "08 authz: low-priv user saw bt_secret's columns (info disclosure): $r"
  elif echo "$r" | grep -qiE "not found|not visible|does not exist"; then
    pass "08 authz: low-priv user correctly blocked from bt_secret"
  else
    fail "08 authz: unexpected result: $r"
  fi

  "${MARIADB[@]}" -e "GRANT SELECT ON fractalsql_bt.bt_secret TO 'bt_lowpriv'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1
  local r2; r2=$("${lowpriv[@]}" -e "CALL fractal_schema_context('[\"bt_secret\"]', @c); SELECT @c;" 2>&1)
  echo "$r2" | grep -q "ssn" && pass "08 authz: SELECT grant restores visibility" \
                              || fail "08 authz: granted user still blocked: $r2"

  "${MARIADB[@]}" -e "DROP USER IF EXISTS 'bt_lowpriv'@'localhost'; DROP TABLE IF EXISTS bt_secret;" >/dev/null 2>&1
}

# Retry-with-feedback: fractal_text_to_sql's own internal attempt_loop
# (sql/install_udf.sql), driven by FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS
# (env var, this port's equivalent of postgres's fractalsql.text_to_
# sql_max_attempts GUC). tests/retry_reasoning_plugin.c (verbatim from
# postgres) returns a rejected DDL statement on GENERATE call 1, then
# "SELECT 1" on call 2 -- exercising the loop's v_feedback-into-v_prompt
# rebuild branch, which every other gate leaves untouched (they all run
# at the default max_attempts, but never hit a REJECTED first attempt
# that needs a second). FSQL_REASONING_HTTP_RESPONSE_MODE=code tells
# the plugin to skip its own ```sql fencing (see the plugin's own
# comment): fractal_t2s_generate always expects/returns fenced text
# extracted already, so an unfenced response here matches its actual
# contract with a real reasoning plugin.
gate_14_retry() {
  export FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=2
  export FSQL_REASONING_HTTP_RESPONSE_MODE=code
  rm -f /tmp/fractalsql_bt_retry_prompt.txt
  mdb_swap_reasoning_plugin "$RETRY_SO" \
    || { fail "14 retry: plugin swap did not take effect"; unset FSQL_REASONING_HTTP_RESPONSE_MODE; mdb_restore_reasoning_plugin; return; }

  local sql err
  read -r sql err < <("${MARIADB[@]}" -N -e "
    CALL fractal_text_to_sql('q', NULL, @s, @e);
    SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1 | tr '\t' ' ')
  [ "$sql" = "SELECT" ] && pass "14 retry: succeeded on 2nd attempt after 1st was rejected" \
                          || fail "14 retry: expected eventual success (SELECT 1...), got sql='$sql' err='$err'"

  local prompt; prompt=$(cat /tmp/fractalsql_bt_retry_prompt.txt 2>/dev/null)
  echo "$prompt" | grep -qi "rejected" \
    && pass "14 retry: attempt-1 rejection reason fed back into attempt-2 prompt" \
    || fail "14 retry: retry prompt missing feedback text: '$prompt'"

  unset FSQL_REASONING_HTTP_RESPONSE_MODE
  mdb_restore_reasoning_plugin
}

# THINK bridge: FRACTALSQL_HTTP_THINK/_THINK_PROVIDER/_NATIVE_URL/
# _NUM_CTX -> FSQL_REASONING_HTTP_THINK/_THINK_PROVIDER/_NATIVE_URL/
# _NUM_CTX (fractalsql_cognition.c's apply_reason_env_locked /
# apply_embed_env_locked). tests/think_reasoning_plugin.c echoes back
# whatever actually landed in its own process environment, proving the
# bridge without needing a live LLM. Config is read once per mariadbd
# process and cached for its lifetime (see fractalsql_cognition.c's
# THE setenv() RACE comment), so each scenario below needs its own
# mdb_swap_reasoning_plugin restart -- can't toggle mid-process.
gate_29_think() {
  # (a) unset -> nothing reaches the plugin (regression safety).
  mdb_swap_reasoning_plugin "$THINK_SO" \
    || { fail "29 think: plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }
  local out1; out1=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  echo "$out1" | grep -q "THINK=(unset)" && echo "$out1" | grep -q "THINK_PROVIDER=(unset)" \
    && echo "$out1" | grep -q "NATIVE_URL=(unset)" && echo "$out1" | grep -q "NUM_CTX=(unset)" \
    && pass "29 think: THINK unset -> no THINK-related env var reaches the plugin" \
    || fail "29 think: expected all 4 vars (unset), got: $out1"
  mdb_restore_reasoning_plugin

  # (b) configured -> the bridge carries every value through.
  export FRACTALSQL_HTTP_THINK=medium
  export FRACTALSQL_HTTP_THINK_PROVIDER=ollama
  export FRACTALSQL_HTTP_NATIVE_URL=http://127.0.0.1:11434/api/chat
  export FRACTALSQL_HTTP_NUM_CTX=8192
  mdb_swap_reasoning_plugin "$THINK_SO" \
    || { fail "29 think: plugin swap did not take effect (configured)"; \
         unset FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER FRACTALSQL_HTTP_NATIVE_URL FRACTALSQL_HTTP_NUM_CTX; \
         mdb_restore_reasoning_plugin; return; }
  local out2; out2=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  echo "$out2" | grep -q "THINK=medium" && echo "$out2" | grep -q "THINK_PROVIDER=ollama" \
    && echo "$out2" | grep -q "NATIVE_URL=http://127.0.0.1:11434/api/chat" && echo "$out2" | grep -q "NUM_CTX=8192" \
    && pass "29 think: configured THINK/THINK_PROVIDER/NATIVE_URL/NUM_CTX all reach the plugin" \
    || fail "29 think: expected all 4 configured values in plugin output, got: $out2"

  # (c) embed tier: THINK still configured, must never reach fractal_embed
  # (apply_embed_env_locked's explicit unsetenv). FRACTALSQL_HTTP_EMBED_URL
  # is already exported by mdb_setup itself (mock LLM server).
  # fractal_embed() runs the plugin's response through parse_vector_csv(),
  # so the KEY=value text the reason-tier checks above grep for would
  # just fail to parse as a vector -- the query text "EMBED_PROBE" tells
  # think_reasoning_plugin.c's generate() to answer with a 4-element
  # 1/0-per-var numeric vector instead (see that file's header comment).
  local out3; out3=$("${MARIADB[@]}" -N -e "SELECT fractal_embed(CONNECTION_ID(), 'EMBED_PROBE');" 2>&1)
  [ "$out3" = "[0,0,0,0]" ] \
    && pass "29 think: fractal_embed never sees THINK even when configured for the chat tiers" \
    || fail "29 think: THINK leaked into the embed tier: $out3"

  unset FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER FRACTALSQL_HTTP_NATIVE_URL FRACTALSQL_HTTP_NUM_CTX
  mdb_restore_reasoning_plugin
}

# DoS/injection caps on the text-to-sql allowlist gate. No
# LLM needed, fractal_t2s_check_allowlist is pure text validation.
gate_10_dos_and_injection() {
  local r1; r1=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_t2s_check_allowlist('SELECT 1; DROP TABLE bt_customers'), '<PASS>');" 2>&1)
  [ "$r1" != "<PASS>" ] && pass "10 dos_and_injection: stacked statement rejected" \
                         || fail "10 dos_and_injection: expected stacked-statement rejection"

  local r2; r2=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_t2s_check_allowlist('SELECT * FROM bt_customers INTO OUTFILE \'/tmp/x\''), '<PASS>');" 2>&1)
  [ "$r2" != "<PASS>" ] && pass "10 dos_and_injection: INTO OUTFILE rejected" \
                         || fail "10 dos_and_injection: expected INTO OUTFILE rejection"

  local r3; r3=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_t2s_check_allowlist('WITH cte AS (SELECT id FROM bt_customers) DELETE FROM bt_customers WHERE id IN (SELECT id FROM cte)'), '<PASS>');" 2>&1)
  [ "$r3" != "<PASS>" ] && pass "10 dos_and_injection: CTE-feeding-DELETE rejected" \
                         || fail "10 dos_and_injection: expected CTE-feeding-DELETE rejection"
}

# 30x fractal_search in a row. No crash, no leak-driven slowdown.
# Lightweight stand-in for postgres's soak gate (same idea: repeated
# calls hold up), scoped to what's cheap to run in CI (no LLM).
gate_12_soak() {
  local i ok=1
  for i in $(seq 1 30); do
    "${MARIADB[@]}" -N -e "SELECT fractal_search('[[1,0,0],[0,1,0],[0,0,1]]', '[0.6,0.8,0]', 2, '{}');" \
      2>/tmp/fractalsql_bt_soak.log | grep -q '"best_point"' || { ok=0; break; }
  done
  [ "$ok" -eq 1 ] && pass "12 soak: 30x fractal_search all returned a valid result" \
                   || fail "12 soak: a soak iteration failed: $(cat /tmp/fractalsql_bt_soak.log)"
}

# Vectorizer pipeline, real dispatch through fractal_embed against the
# mock embeddings endpoint. Not a "no plugin configured" error-path-
# only check: a genuine INSERT -> trigger -> enqueue -> process_queue
# -> real embed write-back round trip.
gate_13_vectorizer_embed() {
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_docs;
    CREATE TABLE bt_docs (id BIGINT PRIMARY KEY AUTO_INCREMENT, content TEXT, embedding TEXT);
    CALL fractal_vectorizer_create('bt_docs', 'content', 'embedding', NULL, @vid);
    INSERT INTO bt_docs (content) VALUES ('hello world');
    CALL fractal_vectorizer_process_queue(10, 600);
  " >/tmp/fractalsql_bt_gate13.log 2>&1

  local emb; emb=$("${MARIADB[@]}" -N -e "SELECT embedding FROM bt_docs WHERE id=1;" 2>&1)
  echo "$emb" | grep -q "0.1" \
    && pass "13 vectorizer_embed: process_queue wrote back the mock embedding" \
    || fail "13 vectorizer_embed: expected an embedding containing 0.1, got: $emb"

  local direct; direct=$("${MARIADB[@]}" -N -e "SELECT fractal_embed(CONNECTION_ID(), 'test input');" 2>&1)
  echo "$direct" | grep -q "0.1" \
    && pass "13 vectorizer_embed: fractal_embed() direct call works" \
    || fail "13 vectorizer_embed: fractal_embed() unexpected: $direct"
}

# fractal_embed()'s own edge cases (gate 13 already proves the happy
# path against the real HTTP mock) plus the vectorizer's injection/
# double-create rejections. NULL input and a nonexistent plugin path
# both collapse to a silent NULL under MariaDB's UDF ABI (no SQL-visible
# error text the way postgres's psql output greps for "must not be
# NULL"/"failed to load reasoning plugin") -- the assertions here are
# "result IS NULL, mariadbd still up", matching gate 07's posture.
# tests/evil_embed_plugin.c (verbatim from postgres) returns
# MAX_EMBED_DIM+1 (16385) floats as a bracketed JSON array straight
# through the reasoning-VFS-ABI generate() callback (no HTTP-wrapper
# JSON-unwrapping in between, unlike the real plugin) -- proves
# fractal_embed's own n > FRACTAL_MAX_EMBED_DIM check
# (src/fractalsql_cognition.c) rejects cleanly rather than truncating.
gate_15_embed() {
  local rnull; rnull=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), NULL), '<NULL>');" 2>&1)
  [ "$rnull" = "<NULL>" ] && pass "15 embed: NULL input rejected cleanly" \
                           || fail "15 embed: NULL input expected NULL, got: $rnull"

  mdb_swap_reasoning_plugin "$HERE/.gate15_nonexistent.so" \
    || { fail "15 embed: bad-path restart did not take effect"; mdb_restore_reasoning_plugin; return; }
  local rbad; rbad=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), 'x'), '<NULL>');" 2>&1)
  local upbad; upbad=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  if [ "$upbad" != "1" ]; then
    fail "15 embed: nonexistent plugin path -- mariadbd did not survive: $rbad"
  elif [ "$rbad" = "<NULL>" ]; then
    pass "15 embed: nonexistent plugin path rejected cleanly"
  else
    fail "15 embed: nonexistent plugin path expected NULL, got: $rbad"
  fi

  mdb_swap_reasoning_plugin "$EVIL_EMBED_SO" \
    || { fail "15 embed: evil_embed plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }
  local revil; revil=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_embed(CONNECTION_ID(), 'x'), '<NULL>');" 2>&1)
  [ "$revil" = "<NULL>" ] \
    && pass "15 embed: over-limit embedding array (16385) rejected, not silently truncated" \
    || fail "15 embed: expected a clean NULL rejection, got: $revil"
  mdb_restore_reasoning_plugin

  "${MARIADB[@]}" -e "
    DELETE FROM fractal_vectorizers WHERE source_table = 'bt_embed_docs';
    DROP TABLE IF EXISTS bt_embed_docs;
    CREATE TABLE bt_embed_docs (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
    INSERT INTO bt_embed_docs (body) VALUES ('a'), ('b');
  " >/dev/null 2>&1

  # Injection-shaped source_table: fractal_vectorizer_create resolves
  # it via information_schema.tables (an exact-match lookup), so an
  # injection payload simply never matches any real table and SIGNALs
  # 'source_table not found' -- proven here, not assumed from reading
  # the SIGNAL in sql/install_udf.sql.
  local rinj; rinj=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_create('bt_embed_docs''; DROP TABLE bt_embed_docs; --', 'body', 'embedding', NULL, @vid);" 2>&1)
  local ninj; ninj=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM bt_embed_docs;" 2>&1)
  [ "$ninj" = "2" ] && pass "15 embed: injection-shaped source_table did not execute (bt_embed_docs intact)" \
                     || fail "15 embed: bt_embed_docs row count changed (n=$ninj) -- injection may have executed"
  echo "$rinj" | grep -qi "not found" \
    && pass "15 embed: injection-shaped source_table cleanly rejected" \
    || fail "15 embed: unexpected result: $rinj"

  "${MARIADB[@]}" -e "CALL fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding', NULL, @vzid); SELECT @vzid INTO @g15_vzid;" >/dev/null 2>&1
  local vzid; vzid=$("${MARIADB[@]}" -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_docs' AND text_col='body' AND embedding_col='embedding';" 2>&1)

  local rdup; rdup=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_create('bt_embed_docs', 'body', 'embedding', NULL, @vid2);" 2>&1)
  echo "$rdup" | grep -q "already exists" \
    && pass "15 embed: double-create rejected with a clean, specific error" \
    || fail "15 embed: expected a clean double-create rejection, got: $rdup"

  local n; n=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 600);" 2>&1)
  [ "$n" = "2" ] && pass "15 embed: process_queue processed 2 backfilled rows" \
                  || fail "15 embed: process_queue expected 2, got: $n"

  local embedded; embedded=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM bt_embed_docs WHERE embedding LIKE '%0.1%';" 2>&1)
  [ "$embedded" = "2" ] && pass "15 embed: both rows got the real embedding written back" \
                         || fail "15 embed: expected 2 rows with the embedding, got: $embedded"

  local status; status=$("${MARIADB[@]}" -N -e "SELECT status FROM fractal_vectorizer_status WHERE vectorizer_id = $vzid;" 2>&1)
  [ "$status" = "done" ] && pass "15 embed: vectorizer status shows done, no failures" \
                          || fail "15 embed: expected status 'done', got: $status"

  "${MARIADB[@]}" -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_docs'; DROP TABLE IF EXISTS bt_embed_docs;" >/dev/null 2>&1
}

# Vectorizer authz, the same regression class as gate 08 applied to
# fractal_vectorizer_process_queue: it is SQL SECURITY INVOKER (sql/
# install_udf.sql's own header comment on why this one must not use
# MariaDB's DEFINER default), so a CALLER with no SELECT on the source
# table gets a real permission-denied failure on its dynamic SELECT,
# recorded per-row rather than silently succeeding or leaking data --
# proven live, not assumed from the SQL SECURITY clause alone.
gate_16_embed_authz() {
  "${MARIADB[@]}" -e "
    DROP USER IF EXISTS 'bt_embed_owner'@'localhost';
    CREATE USER 'bt_embed_owner'@'localhost';
    GRANT ALL PRIVILEGES ON fractalsql_bt.* TO 'bt_embed_owner'@'localhost';
    DROP USER IF EXISTS 'bt_embed_outsider'@'localhost';
    CREATE USER 'bt_embed_outsider'@'localhost';
    -- Same two db-selectability requirements gate 08 hit (db-scoped
    -- EXECUTE, CREATE TEMPORARY TABLES -- see that gate's comment for
    -- why a routine-only EXECUTE grant is not enough), PLUS explicit
    -- SELECT/UPDATE on the vectorizer's own shared admin tables: this
    -- SQL SECURITY INVOKER procedure's cursor/UPDATEs against fractal_
    -- vectorizer_queue and fractal_vectorizers run under the CALLING
    -- (outsider's) privileges too, so without these the call fails on
    -- THOSE tables rather than reaching the intended failure point (its
    -- dynamic SELECT against the OWNER's bt_embed_owned, which this
    -- user deliberately gets no grant on at all).
    GRANT EXECUTE, CREATE TEMPORARY TABLES ON fractalsql_bt.* TO 'bt_embed_outsider'@'localhost';
    GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizer_queue TO 'bt_embed_outsider'@'localhost';
    GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizers TO 'bt_embed_outsider'@'localhost';
    GRANT SELECT ON fractalsql_bt.fractal_vectorizer_status TO 'bt_embed_outsider'@'localhost';
    GRANT SELECT, UPDATE ON fractalsql_bt.fractal_vectorizer_rate_window TO 'bt_embed_outsider'@'localhost';
    FLUSH PRIVILEGES;
  " >/dev/null 2>&1

  local owner=("${MARIADB[0]}" --socket="$SOCK" -u bt_embed_owner -D fractalsql_bt -N)
  local outsider=("${MARIADB[0]}" --socket="$SOCK" -u bt_embed_outsider -D fractalsql_bt -N)

  "${owner[@]}" -e "
    DROP TABLE IF EXISTS bt_embed_owned;
    CREATE TABLE bt_embed_owned (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, embedding TEXT);
    INSERT INTO bt_embed_owned (body) VALUES ('owner data');
    CALL fractal_vectorizer_create('bt_embed_owned', 'body', 'embedding', NULL, @vid);
  " >/tmp/fractalsql_bt_gate16.log 2>&1
  local vzid; vzid=$("${owner[@]}" -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_owned';" 2>&1)
  case "$vzid" in
    ''|*[!0-9]*) fail "16 embed_authz: owner could not create its own vectorizer: $(cat /tmp/fractalsql_bt_gate16.log)" ;;
    *) pass "16 embed_authz: owner created a vectorizer on its own table" ;;
  esac

  local qn; qn=$("${owner[@]}" -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='pending';" 2>&1)
  [ "$qn" = "1" ] && pass "16 embed_authz: backfill enqueued the pre-existing row" \
                   || fail "16 embed_authz: expected 1 pending row, got: $qn"

  "${outsider[@]}" -e "CALL fractal_vectorizer_process_queue(10, 600);" >/dev/null 2>&1
  local statuses; statuses=$("${owner[@]}" -e "SELECT DISTINCT status FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1)
  [ "$statuses" = "failed" ] \
    && pass "16 embed_authz: outsider's process_queue() call left the row 'failed', not processed" \
    || fail "16 embed_authz: expected 'failed' after the outsider's call, got: $statuses"

  local errtext; errtext=$("${owner[@]}" -e "
    SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id=$vzid AND status='failed';" 2>&1)
  echo "$errtext" | grep -qi "denied" \
    && pass "16 embed_authz: failure reason names a permission error, not a data value" \
    || fail "16 embed_authz: expected a permission-denied error, got: $errtext"

  local leaked; leaked=$("${owner[@]}" -e "SELECT embedding FROM bt_embed_owned WHERE embedding IS NOT NULL;" 2>&1)
  [ -z "$leaked" ] && pass "16 embed_authz: no embedding was written by the unauthorized outsider's call" \
                    || fail "16 embed_authz: an embedding was written despite the outsider lacking SELECT: $leaked"

  "${MARIADB[@]}" -e "
    DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_owned';
    DROP TABLE IF EXISTS bt_embed_owned;
    DROP USER IF EXISTS 'bt_embed_owner'@'localhost';
    DROP USER IF EXISTS 'bt_embed_outsider'@'localhost';
  " >/dev/null 2>&1
}

# Concurrent fractal_vectorizer_process_queue() calls against a SHARED
# queue -- mirrors gate 12's soak pattern (background subshells, one
# process per worker). Proves the atomic claim-UPDATE (sql/install_udf
# .sql's own header comment, divergence 4: an UPDATE...JOIN...LIMIT
# claim instead of postgres's SELECT...FOR UPDATE SKIP LOCKED) actually
# gives each row to exactly one worker under real concurrent callers,
# not just in isolation.
EMBED_SOAK_ROWS=60
EMBED_SOAK_WORKERS=6

gate_17_embed_soak() {
  "${MARIADB[@]}" -e "
    DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_soak';
    DROP TABLE IF EXISTS bt_embed_soak;
    CREATE TABLE bt_embed_soak (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
  " >/dev/null 2>&1
  local i insert_vals=""
  for i in $(seq 1 "$EMBED_SOAK_ROWS"); do insert_vals+="('row $i'),"; done
  "${MARIADB[@]}" -e "INSERT INTO bt_embed_soak (body) VALUES ${insert_vals%,};" >/dev/null 2>&1
  "${MARIADB[@]}" -e "CALL fractal_vectorizer_create('bt_embed_soak', 'body', 'embedding', NULL, @vid);" >/dev/null 2>&1
  local vzid; vzid=$("${MARIADB[@]}" -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_soak';" 2>&1)
  local queued; queued=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='pending';" 2>&1)
  if [ "$queued" != "$EMBED_SOAK_ROWS" ]; then
    fail "17 embed_soak: setup: expected $EMBED_SOAK_ROWS queued rows, got $queued"
    return
  fi

  local outdir="/tmp/fractalsql_bt_embed_soak_$$"
  rm -rf "$outdir"; mkdir -p "$outdir"
  local pids=() w
  for w in $(seq 1 "$EMBED_SOAK_WORKERS"); do
    (
      local total=0 i rc=0
      for i in $(seq 1 $(( EMBED_SOAK_ROWS / EMBED_SOAK_WORKERS + 3 ))); do
        local n; n=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(5, 600);" 2>&1)
        case "$n" in ''|*[!0-9]*) rc=1 ;; *) total=$(( total + n )) ;; esac
      done
      echo "$rc $total" > "$outdir/worker_$w.rc"
    ) &
    pids+=("$!")
  done
  local p; for p in "${pids[@]}"; do wait "$p"; done

  local failed_workers=0 sum_processed=0
  for w in $(seq 1 "$EMBED_SOAK_WORKERS"); do
    local wrc wtotal; read -r wrc wtotal < "$outdir/worker_$w.rc" 2>/dev/null
    [ "$wrc" = "0" ] || failed_workers=$((failed_workers + 1))
    sum_processed=$(( sum_processed + ${wtotal:-0} ))
  done
  rm -rf "$outdir"

  [ "$failed_workers" -eq 0 ] && pass "17 embed_soak: $EMBED_SOAK_WORKERS concurrent workers, no call errored" \
                                || fail "17 embed_soak: $failed_workers/$EMBED_SOAK_WORKERS workers had a failed call"
  [ "$sum_processed" -eq "$EMBED_SOAK_ROWS" ] \
    && pass "17 embed_soak: exactly $EMBED_SOAK_ROWS rows processed total (no double-count, none lost)" \
    || fail "17 embed_soak: expected $EMBED_SOAK_ROWS processed summed across workers, got $sum_processed"

  local done_n; done_n=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid AND status='done';" 2>&1)
  [ "$done_n" = "$EMBED_SOAK_ROWS" ] && pass "17 embed_soak: all $EMBED_SOAK_ROWS queue rows are 'done'" \
                                      || fail "17 embed_soak: expected $EMBED_SOAK_ROWS 'done', got $done_n"

  local embedded_n; embedded_n=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM bt_embed_soak WHERE embedding LIKE '%0.1%';" 2>&1)
  [ "$embedded_n" = "$EMBED_SOAK_ROWS" ] && pass "17 embed_soak: all $EMBED_SOAK_ROWS rows embedded exactly once" \
                                          || fail "17 embed_soak: expected $EMBED_SOAK_ROWS embedded, got $embedded_n"

  "${MARIADB[@]}" -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_soak'; DROP TABLE IF EXISTS bt_embed_soak;" >/dev/null 2>&1
}

# Real crash mid-process_queue(), via tests/evil_crash_plugin.c (a
# reasoning-VFS-ABI plugin whose generate() writes through NULL --
# distinct from tests/evil_crash_udf.c, the plain crashing MariaDB UDF
# gate 06 already uses, which has nothing to do with the reasoning
# path). MariaDB-specific finding, verified against sql/install_udf
# .sql's actual fractal_vectorizer_process_queue body (not assumed from
# postgres's equivalent claim): unlike postgres, where the WHOLE PL/
# pgSQL function body is one implicit transaction so a mid-call crash
# reverts every row it touched back to 'pending', a MariaDB stored
# PROCEDURE has no such wrapping -- each UPDATE inside the per-row loop
# autocommits on its own. So a crash mid-batch leaves the CURRENT row
# genuinely stuck in 'processing' (not reverted), exactly the case
# stale_after_secs exists to reclaim -- the correct, MariaDB-real
# recovery path is "the next process_queue call (with a short
# stale_after) reclaims and reprocesses it," not "the row reverted on
# its own." This gate proves THAT claim, not postgres's, since they are
# genuinely different guarantees on the two platforms.
gate_18_embed_crash() {
  # Swap plugin BEFORE creating the fixture table: mdb_swap_reasoning_
  # plugin restarts via mdb_teardown+mdb_setup, which brings up a FRESH
  # cluster (fresh datadir), same as every other plugin-swap gate in
  # this file -- confirmed live, creating the table first left it wiped
  # out from under the very next statement. The crash this gate
  # actually tests comes later, from a real process_queue() crash
  # followed by gate 06's own in-place supervisor respawn (same
  # datadir, no wipe) -- that recovery path is what needs to preserve
  # bt_embed_crash, not this initial plugin-activation restart.
  mdb_swap_reasoning_plugin "$CRASH_REASONING_SO" \
    || { fail "18 embed_crash: plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }

  "${MARIADB[@]}" -e "
    DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_crash';
    DROP TABLE IF EXISTS bt_embed_crash;
    CREATE TABLE bt_embed_crash (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT NOT NULL, embedding TEXT);
    INSERT INTO bt_embed_crash (body) VALUES ('a');
    CALL fractal_vectorizer_create('bt_embed_crash', 'body', 'embedding', NULL, @vid);
  " >/dev/null 2>&1
  local vzid; vzid=$("${MARIADB[@]}" -N -e "SELECT id FROM fractal_vectorizers WHERE source_table='bt_embed_crash';" 2>&1)

  "${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 600);" >/tmp/fractalsql_bt_gate18.log 2>&1

  local up=0 i tries=$(( 30 * TIMEOUT_MULT )) within_budget=0
  for i in $(seq 1 $(( tries * 2 ))); do
    "${MARIADB[@]}" -N -e "SELECT 1;" >/dev/null 2>&1 && { up=1; [ "$i" -le "$tries" ] && within_budget=1; break; }
    sleep 0.5
  done
  [ "$within_budget" -eq 1 ] && pass "18 embed_crash: mariadbd auto-restarted" \
                              || fail "18 embed_crash: mariadbd did not come back within $(( tries / 2 ))s"
  if [ "$up" -ne 1 ]; then
    fail "18 embed_crash: mariadbd never came back -- remaining gates will run against the crash plugin"
    return
  fi

  # Restore the real plugin BEFORE running any more SQL against this
  # process -- otherwise the process_queue call below (which needs
  # working fractal_embed) would itself hit the crash plugin again.
  # In-place (same $DATADIR), NOT mdb_restore_reasoning_plugin: see
  # mdb_restart_inplace_reasoning_plugin's own comment for why -- this
  # gate's whole point is that bt_embed_crash and its 'processing' row
  # survive the crash, and a fresh mdb_setup would wipe both.
  mdb_restart_inplace_reasoning_plugin "$PLUGDIR/fractalsql-reasoning-http.so" \
    || { fail "18 embed_crash: could not restart mariadbd in place with the real plugin restored"; mdb_restore_reasoning_plugin; return; }

  local stuck; stuck=$("${MARIADB[@]}" -N -e "SELECT status FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1)
  [ "$stuck" = "processing" ] \
    && pass "18 embed_crash: the in-flight row is stuck 'processing' after the crash (no wrapping transaction to revert it, see this gate's header comment)" \
    || fail "18 embed_crash: expected 'processing' immediately post-crash/restore, got: $stuck"

  # Reclaim: a call with stale_after_secs=0 immediately reclaims any
  # 'processing' row (see the procedure's own reclaim UPDATE, top of
  # its body) and reprocesses it normally.
  local n; n=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 0);" 2>&1)
  [ "$n" = "1" ] && pass "18 embed_crash: stale reclaim (stale_after_secs=0) recovered the stuck row" \
                  || fail "18 embed_crash: expected 1 row reclaimed+processed, got: $n"

  local done_n; done_n=$("${MARIADB[@]}" -N -e "SELECT count(*) FROM bt_embed_crash WHERE embedding LIKE '%0.1%';" 2>&1)
  [ "$done_n" = "1" ] && pass "18 embed_crash: the row is correctly embedded after recovery" \
                       || fail "18 embed_crash: expected 1 embedded row after recovery, got: $done_n"

  "${MARIADB[@]}" -e "DELETE FROM fractal_vectorizers WHERE source_table='bt_embed_crash'; DROP TABLE IF EXISTS bt_embed_crash;" >/dev/null 2>&1
}

# Analytics tier: fractal_dimension_dfa/_boxcount/_drift,
# fractal_optimize_portfolio. Uses adequately-sized synthetic data:
# see this repo's own comment on fractal_dimension_dfa/_boxcount in
# src/fractalsql.c for why "n >= 16"/"n >= 8" (the DOCUMENTED minimums)
# are NOT sufficient in practice (the real minimums are far higher,
# ~24 and ~500 respectively). This gate uses inputs comfortably above
# both real thresholds so it actually exercises success, not just
# documents the gap again.
gate_20_analytics() {
  local series; series="[$(python3 -c "import random; random.seed(1); print(','.join(str(round(random.gauss(0,1),4)) for _ in range(80)))")]"
  local dfa; dfa=$("${MARIADB[@]}" -N -e "SELECT fractal_dimension_dfa('$series');" 2>&1)
  [[ "$dfa" =~ ^[0-9.-] ]] && pass "20 analytics: fractal_dimension_dfa returned a real value ($dfa)" \
                            || fail "20 analytics: fractal_dimension_dfa='$dfa'"

  local drift; drift=$("${MARIADB[@]}" -N -e "SELECT fractal_dimension_drift('$series', 32);" 2>&1)
  echo "$drift" | grep -q '"drift"' && pass "20 analytics: fractal_dimension_drift returned a real result" \
                                     || fail "20 analytics: fractal_dimension_drift='$drift'"

  local pts; pts="[$(python3 -c "import random; random.seed(2); print(','.join(str(round(random.uniform(0,1),4)) for _ in range(1000)))")]"
  local bc; bc=$("${MARIADB[@]}" -N -e "SELECT fractal_dimension_boxcount('$pts', 2);" 2>&1)
  [[ "$bc" =~ ^[0-9.-] ]] && pass "20 analytics: fractal_dimension_boxcount returned a real value ($bc)" \
                           || fail "20 analytics: fractal_dimension_boxcount='$bc'"

  local opt; opt=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{}');" 2>&1)
  echo "$opt" | grep -q '"sharpe"' && pass "20 analytics: fractal_optimize_portfolio returned a real result" \
                                    || fail "20 analytics: fractal_optimize_portfolio='$opt'"
}

# Diversify/Repulsion controls. No LLM.
gate_21_diversify() {
  local en; en=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_enable(CONNECTION_ID());" 2>&1)
  [ "$en" = "0" ] && pass "21 diversify: enable" || fail "21 diversify: enable='$en'"

  local sp; sp=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_set_params(CONNECTION_ID(), '{\"window_n\":5}');" 2>&1)
  [ "$sp" = "0" ] && pass "21 diversify: set_params" || fail "21 diversify: set_params='$sp'"

  local ex; ex=$("${MARIADB[@]}" -N -e "SELECT fractal_explain_result(CONNECTION_ID());" 2>&1)
  echo "$ex" | grep -q "diversify_enabled" && pass "21 diversify: explain_result" \
                                            || fail "21 diversify: explain_result='$ex'"

  local dis; dis=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_disable(CONNECTION_ID());" 2>&1)
  [ "$dis" = "0" ] && pass "21 diversify: disable" || fail "21 diversify: disable='$dis'"
}

# Vector tier: a representative slice of the 13 functions.
# No LLM.
gate_22_vector_tier() {
  local sim; sim=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_cosine_similarity('[1,0,0]', '[1,0,0]');" 2>&1)
  [ "$sim" = "1" ] && pass "22 vector_tier: cosine_similarity(identical)=1" \
                    || fail "22 vector_tier: cosine_similarity='$sim'"

  local norm; norm=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_norm('[3,4,0]');" 2>&1)
  [ "$norm" = "5" ] && pass "22 vector_tier: norm([3,4,0])=5" \
                     || fail "22 vector_tier: norm='$norm'"

  local add; add=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_add('[1,2,3]', '[1,1,1]');" 2>&1)
  echo "$add" | grep -q '^\[2,3,4\]$' && pass "22 vector_tier: add" || fail "22 vector_tier: add='$add'"

  local dims; dims=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_dims('[1,2,3,4]');" 2>&1)
  [ "$dims" = "4" ] && pass "22 vector_tier: dims" || fail "22 vector_tier: dims='$dims'"
}

# Cognition tier: fractal_reason against the mock LLM.
gate_23_cognition() {
  local r; r=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1)
  echo "$r" | grep -qi "sql" && pass "23 cognition: fractal_reason returned the mock's reply" \
                              || fail "23 cognition: fractal_reason='$r'"

  local rnull; rnull=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), NULL);" 2>&1)
  [ "$rnull" = "NULL" ] && pass "23 cognition: NULL query -> NULL result" \
                         || fail "23 cognition: expected NULL, got: $rnull"
}

# Agency tier: a representative slice. E (recall_hybrid,
# pure retrieval, no LLM), F (recommend_diverse, pure retrieval, no
# LLM), C (route_task, real LLM via the mock). The other 12 engines
# follow the identical composition pattern (base primitive + optional
# fractal_reason) already exercised by 22/23/this gate; not each
# re-tested individually here to keep CI runtime bounded.
gate_24_agents() {
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_memories, bt_caps;
    CREATE TABLE bt_memories (id BIGINT PRIMARY KEY AUTO_INCREMENT, region VARCHAR(20), vec TEXT, content VARCHAR(100));
    INSERT INTO bt_memories (region, vec, content) VALUES ('east','[1,0,0]','shipped'), ('west','[0,1,0]','refunded');
    CREATE TABLE bt_caps (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb TEXT);
    INSERT INTO bt_caps (emb) VALUES ('[1,0,0]'), ('[0,1,0]');
  " >/tmp/fractalsql_bt_gate24.log 2>&1

  local re; re=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_recall_hybrid('bt_memories','vec','[1,0,0]','region','east',5,'content', @r);
    SELECT @r;" 2>&1)
  echo "$re" | grep -q "shipped" && pass "24 agents: recall_hybrid (E) found the real cohort content" \
                                  || fail "24 agents: recall_hybrid='$re'"

  local rf; rf=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_recommend_diverse('bt_memories','vec','[1,0,0]',2, @r2);
    SELECT @r2;" 2>&1)
  echo "$rf" | grep -q "item_id" && pass "24 agents: recommend_diverse (F) returned real scored items" \
                                  || fail "24 agents: recommend_diverse='$rf'"

  local rc; rc=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_route_task('[0.9,0.1,0]','bt_caps','emb',1000,100, @r3);
    SELECT @r3;" 2>&1)
  echo "$rc" | grep -q "routed_to" && pass "24 agents: route_task (C) composed telemetry + real LLM reasoning" \
                                    || fail "24 agents: route_task='$rc'"

  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_patients;
    CREATE TABLE bt_patients (id BIGINT PRIMARY KEY, age INT, \`condition\` VARCHAR(32), vitals TEXT);
    INSERT INTO bt_patients VALUES
        (1, 72, 'sepsis', '[0.9,-0.8,0.7,0.6]'),
        (2, 81, 'sepsis', '[0.85,-0.75,0.65,0.55]'),
        (3, 64, 'sepsis', '[0.1,0.1,0.1,0.1]');
  " >>/tmp/fractalsql_bt_gate24.log 2>&1

  local rg; rg=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_patient_deterioration_triage(
        'bt_patients', 'vitals', '[0.9,-0.8,0.7,0.6]', '[0.1,0.1,0.1,0.1]', '[0.95,-0.85,0.75,0.65]',
        (SELECT CONCAT('[', GROUP_CONCAT(id), ']') FROM bt_patients WHERE age > 65 AND \`condition\`='sepsis'),
        5, @rg);
    SELECT JSON_LENGTH(JSON_EXTRACT(@rg, '\$.cohort_matches'));" 2>&1)
  [ "$rg" = "2" ] && pass "24 agents: patient_deterioration_triage (H) cohort_matches now honors p_k (got 2 of 2 qualifying rows)" \
                   || fail "24 agents: patient_deterioration_triage cohort_matches length='$rg'"
}

# Enterprise tier: with FRACTALSQL_ENTERPRISE_LIB unset (the
# default, this harness never sets it), every exposed function must
# refuse cleanly, never crash or silently no-op.
gate_25_enterprise() {
  local r; r=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r" = "NULL" ] && pass "25 enterprise: ledger functions correctly refuse when not loaded" \
                     || fail "25 enterprise: expected NULL/refusal, got: $r"

  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT fractal_audit_unpack('x');" 2>&1)
  [ "$r2" = "NULL" ] && pass "25 enterprise: audit_unpack correctly refuses when not loaded" \
                      || fail "25 enterprise: expected NULL/refusal, got: $r2"
}

# Enterprise tier: with a REAL enterprise .so loaded (opt-in only, not
# in DEFAULT_GATES). The enterprise core library is a licensed artifact
# not shipped in this public repo, so this gate SKIPs cleanly unless a
# real libfractalsql-enterprise-sovereign-c.so has been staged locally
# at $ENT_SO by hand (see fractalsql-core's own releases for that
# artifact -- this harness never fetches or ships it). Restarts
# mariadbd with FRACTALSQL_ENTERPRISE_LIB set (env-var-only config,
# read once at process startup, so this cannot be a live SET), then
# restores the dormant default afterward so later gates in the same
# run see the unset baseline again.
#
# Confirmed live (2026-08-30): the ledger now has a real file-backed
# storage VFS (src/fractalsql_enterprise.c), so flush/load genuinely
# persist and rehydrate the Truth/Shadow ledgers -- including across a
# mariadbd restart, exercised below. This gate asserts: activation
# gating works, flush persists a real file, load rehydrates it (proven
# across a full server restart, not just within one session),
# fractal_ledger_verify's O(n) chain walk reports the persisted rows,
# and a byte-level tamper to the persisted file is caught (both by
# verify, and by load's O(1) tip check when the tamper is in the
# latest record).
gate_26_enterprise_active() {
  local ent_so; ent_so="$(fsql_ent_so_path)"
  if [ ! -f "$ent_so" ]; then
    skip "26 enterprise_active: no enterprise .so staged at $ent_so (opt-in gate, licensed artifact not shipped here)"
    return
  fi

  local ledger_path="$HERE/.gate26_ledger.dat"
  rm -f "$ledger_path"

  mdb_teardown
  export FRACTALSQL_ENTERPRISE_LIB="$ent_so"
  export FRACTALSQL_ENTERPRISE_LEDGER_PATH="$ledger_path"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_LEDGER_PATH
    rm -f "$ledger_path"
    fail "26 enterprise_active: restart with FRACTALSQL_ENTERPRISE_LIB set failed (rc=$setup_rc)"
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi

  local tc; tc=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$tc" = "0" ] && pass "26 enterprise_active: truth_count succeeds once the library loads (activation gating works)" \
                   || fail "26 enterprise_active: expected 0 from a freshly loaded library, got: $tc"

  local rh; rh=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_reset_hard(CONNECTION_ID());" 2>&1)
  [ "$rh" = "0" ] && pass "26 enterprise_active: reset_hard succeeds (no storage touched)" \
                   || fail "26 enterprise_active: expected 0 from reset_hard, got: $rh"

  "${MARIADB[@]}" -e "SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive', 500);" >/dev/null 2>&1
  local fl; fl=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_flush(CONNECTION_ID());" 2>&1)
  [ "$fl" = "0" ] && [ -s "$ledger_path" ] \
                   && pass "26 enterprise_active: flush genuinely persists to a real ledger file" \
                   || fail "26 enterprise_active: expected flush=0 and a non-empty $ledger_path, got flush=$fl, file: $(ls -la "$ledger_path" 2>&1)"

  local v1; v1=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID());" 2>&1)
  [ "$v1" = '{"ok":true,"rows_verified":1}' ] && pass "26 enterprise_active: fractal_ledger_verify confirms the 1-row chain" \
                                               || fail "26 enterprise_active: expected 1-row ok verify, got: $v1"

  # Cross-PROCESS rehydration: restart mariadbd (in-memory ledgers reset
  # to empty by construction), then load must pull the persisted blob
  # back from the file, not from any surviving process state.
  mdb_teardown >/dev/null 2>&1
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local ld; ld=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_load(CONNECTION_ID());" 2>&1)
  [ "$ld" = "0" ] && pass "26 enterprise_active: load rehydrates the persisted ledger across a mariadbd restart" \
                   || fail "26 enterprise_active: expected load=0 after restart, got: $ld"

  # Tamper the latest record: both verify and load's O(1) tip check must
  # catch it (a shallow tamper, in scope for the tip check).
  python3 -c "
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(-5, 2)
    b = f.read(1)
    f.seek(-5, 2)
    f.write(bytes([b[0] ^ 0xFF]))
" "$ledger_path" 2>/dev/null

  local v2; v2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID());" 2>&1)
  [[ "$v2" == '{"ok":false,'* ]] && pass "26 enterprise_active: fractal_ledger_verify detects a byte-level tamper" \
                                  || fail "26 enterprise_active: expected a tamper-detected verify report, got: $v2"

  local ld2; ld2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_load(CONNECTION_ID());" 2>&1)
  [ "$ld2" = "NULL" ] && pass "26 enterprise_active: load refuses a tampered latest record (O(1) tip check)" \
                       || fail "26 enterprise_active: expected NULL (refused) loading a tampered ledger, got: $ld2"

  unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_LEDGER_PATH
  rm -f "$ledger_path"
  mdb_teardown
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# Enterprise tier: the CSV mirror + MariaDB CONNECT storage engine make
# the ledger genuinely SQL-queryable (sql/install_enterprise_connect.sql).
# Opt-in like gate 26 (needs the same real enterprise .so), AND needs
# ha_connect.so findable on this host: docker/Dockerfile.test installs
# mariadb-plugin-connect, but this gate also SKIPs cleanly on a bare host
# that doesn't have it, rather than failing. Confirmed live (2026-08-31):
# CREATE TABLE ... ENGINE=CONNECT TABLE_TYPE=CSV over the mirror file
# gives real SELECT/WHERE/ORDER BY, READONLY=1 blocks INSERT/UPDATE/
# DELETE (the hash-chain in the binary file remains the sole write path),
# fractal_audit_log's kind=2 entries are queryable, and
# fractal_audit_unpack(FROM_BASE64(blob_b64)) decodes a real persisted
# QTL blob straight from SQL with no export UDF needed.
gate_27_enterprise_connect() {
  local ent_so; ent_so="$(fsql_ent_so_path)"
  if [ ! -f "$ent_so" ]; then
    skip "27 enterprise_connect: no enterprise .so staged at $ent_so (opt-in gate, licensed artifact not shipped here)"
    return
  fi

  # MariaDB's own plugin-naming convention keeps the .so extension even
  # on macOS (unlike general Mach-O shared libraries' usual .dylib) --
  # a reasonable inference from how this repo's own fractalsql.so/
  # fractalsql-reasoning-http.so are named identically cross-platform in
  # install-test.yml's macos-install job, not independently confirmed for
  # ha_connect.so specifically since CONNECT was never test-installed on
  # real Darwin hardware in this session. Candidate paths cover Debian/
  # Ubuntu (Dockerfile.test's mariadb-plugin-connect package) and
  # Homebrew's mariadb formula (brew --prefix mariadb)/lib/plugin --
  # best-effort like fsql_ent_so_path above, SKIPs cleanly either way if
  # none exist rather than guessing wrong.
  local connect_so="" candidates="/usr/lib/mysql/plugin/ha_connect.so /usr/lib/mariadb/plugin/ha_connect.so"
  if command -v brew >/dev/null 2>&1; then
    candidates="$candidates $(brew --prefix mariadb 2>/dev/null)/lib/plugin/ha_connect.so"
  fi
  for p in $candidates; do
    [ -f "$p" ] && connect_so="$p" && break
  done
  if [ -z "$connect_so" ]; then
    skip "27 enterprise_connect: ha_connect.so not found (install mariadb-plugin-connect to run this gate)"
    return
  fi

  local ledger_path="$HERE/.gate27_ledger.dat"
  rm -f "$ledger_path" "$ledger_path.csv"

  mdb_teardown
  export FRACTALSQL_ENTERPRISE_LIB="$ent_so"
  export FRACTALSQL_ENTERPRISE_LEDGER_PATH="$ledger_path"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_LEDGER_PATH
    rm -f "$ledger_path" "$ledger_path.csv"
    fail "27 enterprise_connect: restart with FRACTALSQL_ENTERPRISE_LIB set failed (rc=$setup_rc)"
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi

  cp "$connect_so" "$PLUGDIR/ha_connect.so"
  local ir; ir=$("${MARIADB[@]}" -e "INSTALL SONAME 'ha_connect';" 2>&1)
  [ -z "$ir" ] && pass "27 enterprise_connect: INSTALL SONAME 'ha_connect' succeeds" \
                || fail "27 enterprise_connect: INSTALL SONAME 'ha_connect' failed: $ir"

  # Seed one QTL entry (kind=1) and one audit entry (kind=2) in a SINGLE
  # session/connection -- fractal_feedback_report's result_handle and
  # fractal_ledger_flush's in-memory ledger are per-CONNECTION_ID(), so
  # this must be one client invocation, not several (each `mariadb -e`
  # call is its own connection with its own CONNECTION_ID()).
  cat > /tmp/fsql_gate27_seed.sql <<'SQL'
SELECT fractal_diversify_enable(CONNECTION_ID());
SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive', 500);
SELECT fractal_feedback_report(CONNECTION_ID(), 2, 'negative');
SELECT fractal_ledger_flush(CONNECTION_ID());
SELECT fractal_audit_log('gate27_test', JSON_OBJECT('probe', 1));
SQL
  "${MARIADB[@]}" < /tmp/fsql_gate27_seed.sql >/dev/null 2>&1

  local install_sql; install_sql=$(sed \
    -e "s#fractalsql_ledger.dat.csv#$ledger_path.csv#" \
    "$HERE/sql/install_enterprise_connect.sql")
  local cr; cr=$(printf '%s\n' "$install_sql" | "${MARIADB[@]}" 2>&1)
  [ -z "$cr" ] && pass "27 enterprise_connect: CREATE TABLE ... ENGINE=CONNECT succeeds" \
                || fail "27 enterprise_connect: CREATE TABLE failed: $cr"

  local kc; kc=$("${MARIADB[@]}" -N -e "SELECT COUNT(*) FROM fractalsql_ledger WHERE kind=1;" 2>&1)
  [ "$kc" = "1" ] && pass "27 enterprise_connect: SELECT ... WHERE kind=1 sees the flushed QTL row" \
                   || fail "27 enterprise_connect: expected 1 kind=1 row, got: $kc"

  local ac; ac=$("${MARIADB[@]}" -N -e "SELECT COUNT(*) FROM fractalsql_ledger WHERE kind=2;" 2>&1)
  [ "$ac" = "1" ] && pass "27 enterprise_connect: SELECT ... WHERE kind=2 sees the fractal_audit_log row" \
                   || fail "27 enterprise_connect: expected 1 kind=2 row, got: $ac"

  local unpacked; unpacked=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_audit_unpack(FROM_BASE64(blob_b64)) FROM fractalsql_ledger WHERE kind=1 ORDER BY id DESC LIMIT 1;" 2>&1)
  case "$unpacked" in
    *'"doc_id":1'*'"signal":"truth"'*) pass "27 enterprise_connect: fractal_audit_unpack(FROM_BASE64(...)) decodes the real flushed entry from SQL" ;;
    *) fail "27 enterprise_connect: expected a decoded truth entry for doc_id=1, got: $unpacked" ;;
  esac

  local wr; wr=$("${MARIADB[@]}" -e "INSERT INTO fractalsql_ledger (id,kind) VALUES (99,1);" 2>&1)
  case "$wr" in
    *'read only'*) pass "27 enterprise_connect: READONLY=1 blocks a stray INSERT (mirror can't be corrupted via SQL)" ;;
    *) fail "27 enterprise_connect: expected a read-only rejection, got: $wr" ;;
  esac

  unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_LEDGER_PATH
  rm -f "$ledger_path" "$ledger_path.csv" /tmp/fsql_gate27_seed.sql
  mdb_teardown
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# Enterprise tier: Ed25519 detached-signature verification of the
# enterprise .so (src/fractalsql_enterprise.c's ent_verify_signature,
# gated into ensure_enterprise_lib()). Opt-in like gates 26/27 (needs
# the real enterprise .so); additionally needs a real sibling <so>.sig
# file staged next to it (ships in fractalsql-core's own release
# tarball, alongside the .so -- this harness never fetches or ships
# either). SKIPs cleanly when either is absent. Confirmed live
# (2026-08-31), all four paths: a real, valid .sig loads successfully
# (proves the embedded FSQL_ENTERPRISE_PUBKEY is the genuine
# FractalSQLabs key, not just "verification code exists"); a
# corrupt/wrong .sig always refuses; a missing .sig refuses only when
# FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE is set; a missing .sig with
# that unset still loads (backward-compatible default).
gate_28_enterprise_signature() {
  local ent_so; ent_so="$(fsql_ent_so_path)"
  local ent_sig="$ent_so.sig"
  if [ ! -f "$ent_so" ]; then
    skip "28 enterprise_signature: no enterprise .so staged at $ent_so (opt-in gate, licensed artifact not shipped here)"
    return
  fi
  if [ ! -f "$ent_sig" ]; then
    skip "28 enterprise_signature: no $ent_sig staged (opt-in gate, ships in fractalsql-core's release tarball)"
    return
  fi

  # Phase 1: the REAL signature -- proves the embedded pubkey actually
  # matches FractalSQLabs's real signing key, not just that the
  # verification code runs without crashing.
  mdb_teardown
  export FRACTALSQL_ENTERPRISE_LIB="$ent_so"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    unset FRACTALSQL_ENTERPRISE_LIB
    fail "28 enterprise_signature: restart with a real signed .so failed (rc=$setup_rc)"
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi
  local r1; r1=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r1" = "0" ] && pass "28 enterprise_signature: a real, validly-signed .so loads (embedded pubkey matches FractalSQLabs's real key)" \
                   || fail "28 enterprise_signature: expected 0 with the real .sig present, got: $r1"

  # Phase 2: corrupt .sig (64 random bytes, right length, wrong content)
  # -- always fatal, regardless of FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE.
  local bad_dir="$HERE/.gate28_badsig"
  rm -rf "$bad_dir"; mkdir -p "$bad_dir"
  cp "$ent_so" "$bad_dir/lib.so"
  head -c 64 /dev/urandom > "$bad_dir/lib.so.sig"

  mdb_teardown
  export FRACTALSQL_ENTERPRISE_LIB="$bad_dir/lib.so"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r2" = "NULL" ] && pass "28 enterprise_signature: a corrupt/wrong .sig refuses to load" \
                      || fail "28 enterprise_signature: expected NULL (refused) with a corrupt .sig, got: $r2"

  # Phase 3: missing .sig + REQUIRE_SIGNATURE=1 -- refuses.
  rm -f "$bad_dir/lib.so.sig"
  mdb_teardown
  export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local r3; r3=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r3" = "NULL" ] && pass "28 enterprise_signature: a missing .sig refuses when REQUIRE_SIGNATURE is set" \
                      || fail "28 enterprise_signature: expected NULL (refused), got: $r3"

  # Phase 4: missing .sig + REQUIRE_SIGNATURE unset -- loads unverified
  # (backward-compatible default, matching postgres's own default).
  mdb_teardown
  unset FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local r4; r4=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r4" = "0" ] && pass "28 enterprise_signature: a missing .sig loads unverified by default" \
                   || fail "28 enterprise_signature: expected 0 (loaded unverified), got: $r4"

  unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE
  rm -rf "$bad_dir"
  mdb_teardown
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# --- run ------------------------------------------------------------

run_major() {
  local v="$1"; shift
  local gates=("$@")
  printf "== MariaDB %s ==\n" "$v"

  for g in "${gates[@]}"; do [ "$g" = "01" ] && gate_01_build; done

  local need_db=0
  for g in "${gates[@]}"; do
    case "$g" in 02|03|04|05|06|07|08|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28) need_db=1 ;; esac
  done
  if [ "$need_db" -eq 1 ]; then
    mdb_setup "$v"; local rc=$?
    if [ "$rc" -eq 1 ]; then skip "MariaDB $v runtime gates (mariadbd not found for this major)"; return; fi
    if [ "$rc" -ne 0 ]; then fail "MariaDB $v cluster setup"; return; fi
    for g in "${gates[@]}"; do
      case "$g" in
        02) gate_02_smoke ;;
        03) gate_03_schema_context ;;
        04) gate_04_text_to_sql ;;
        05) gate_05_evil_overread ;;
        06) gate_06_crash_recovery ;;
        07) gate_07_evil_lying_length ;;
        08) gate_08_authz ;;
        10) gate_10_dos_and_injection ;;
        11) gate_11_scout ;;
        12) gate_12_soak ;;
        13) gate_13_vectorizer_embed ;;
        14) gate_14_retry ;;
        15) gate_15_embed ;;
        16) gate_16_embed_authz ;;
        17) gate_17_embed_soak ;;
        18) gate_18_embed_crash ;;
        19) gate_19_sfs_bounds ;;
        20) gate_20_analytics ;;
        21) gate_21_diversify ;;
        22) gate_22_vector_tier ;;
        23) gate_23_cognition ;;
        24) gate_24_agents ;;
        25) gate_25_enterprise ;;
        26) gate_26_enterprise_active ;;
        27) gate_27_enterprise_connect ;;
        28) gate_28_enterprise_signature ;;
        29) gate_29_think ;;
      esac
    done
    mdb_teardown
  fi
}

if [ -n "$ONE_GATE" ]; then
  run_major "$MDB_MAJOR" "$ONE_GATE"
elif [ "$MODE" = "quick" ]; then
  run_major "$MDB_MAJOR" "${QUICK_GATES[@]}"
elif [ "$MODE" = "cross" ]; then
  for v in 10.6 10.11 11.4 12.2; do run_major "$v" "${DEFAULT_GATES[@]}"; done
else
  run_major "$MDB_MAJOR" "${DEFAULT_GATES[@]}"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then printf "${G}build_test: PASS${Z}\n"; exit 0
else printf "${R}build_test: FAIL${Z}\n"; exit 1; fi
