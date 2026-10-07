#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# build_test.sh: post-build validation gate runner for
# fractalsql-mariadb. Mirrors what CI runs, so local == CI. Numbered
# gates with a shared PASS/FAIL/SKIP harness shape. Gates 03/04/10/12/13/
# 20-25 below cover the full UDF/procedure surface: Discovery, Text-to-
# SQL, the Vectorizer, Analytics, Diversify, the Vector tier, Cognition,
# Agency, and Enterprise activation gating. Gates 05/07/08/14-18 (the
# reasoning-VFS-ABI-level "evil plugin" gates and their embed/authz/
# soak/crash siblings) are ALSO ported now -- see the reasoning-tier
# bullet below for how. Deliberately still NOT ported: a superuser-only
# config gate (09) and a real (non-mock) enterprise-.so gate (this
# repo's own 26/27/28 cover related but different real-.so ground),
# each with its own documented reason, not a placeholder.
#
# gate_01_build compiles service/ (fractalsqld plus the thin GPL-2.0-only
#   shim) and runs its license/boundary/symbol scans and its spike/CLI
#   self-tests. Every gate from 02 on starts fractalsqld (daemon_start)
#   and runs mariadbd with only the shim loaded -- every UDF call crosses
#   the socket to the daemon.
#
# Architecture differences that shape what each gate can claim (read
# before assuming a gate maps 1:1 from other database ecosystems):
#   * ONE fractalsql.so (the shim) and ONE fractalsqld cover every
#     supported MariaDB major (10.6 / 10.11 / 11.4 LTS / 12.3 LTS): the
#     UDF ABI (UDF_INIT/UDF_ARGS/MYSQL_ERRMSG_SIZE) has been stable
#     across all of them, and the daemon is a separate process the
#     major doesn't touch at all. So gate_01_build here compiles ONCE;
#     --mdb <major> only selects which mariadbd binary the live-cluster
#     gates start against.
#   * No CREATE EXTENSION. "Install" = point mariadbd at a scratch
#     --plugin-dir containing fractalsql.so, then run
#     `mariadb ... < sql/install_udf.sql` (CREATE FUNCTION ... SONAME).
#   * Reasoning-tier gates (03/04/13/20-24) dispatch through the REAL
#     fractalsql-reasoning-http.so plugin against a deterministic local
#     mock (scripts/ci/mock_llm.py, started in mdb_setup before
#     mariadbd) rather than a fake in-process reasoning-VFS plugin
#     approach, exercising the actual dlopen/curl/HTTP path,
#     just with a canned server on the other end. Gates 05/07/14/15/18
#     instead swap FRACTALSQL_REASONING_PLUGIN to a reasoning-VFS-ABI-
#     level test fixture (tests/evil_*.c, tests/retry_reasoning_plugin.c
#     -- pure C against the shared vendored fractalsql_sql.h, with no
#     server-specific API reference at all) via
#     mdb_swap_reasoning_plugin(), a restart-based swap (see that
#     function's own comment: FRACTALSQL_REASONING_PLUGIN is a process
#     environment variable read once at mysqld startup, no live-reload
#     -- it is not a server system variable). A real,
#     MariaDB-specific wrinkle these gates had to account for: the evil
#     plugins' call_count statics are process-wide, and (unlike a
#     per-connection process model, where a fresh connection gets a
#     freshly dlopen'd plugin with call_count=0 again) MariaDB is one
#     shared process for every connection -- call_count keeps incrementing
#     across every call for the process's whole lifetime. So gates
#     05/07 restart before EACH of their three call sites (GENERATE/
#     bare fractal_reason/fractal_t2s_review), not once for the whole
#     gate; see gate_05_evil_overread's own header comment for the full
#     account. A well-behaved fallback mock plugin was NOT
#     needed here: mariadb's own baseline (the real HTTP wrapper against
#     scripts/ci/mock_llm.py) already serves that role, restored via
#     mdb_restore_reasoning_plugin() at the end of every evil-plugin
#     gate. Also NOT needed: a hardcoded-vector embed mock specifically,
#     since mock_llm.py's embeddings route already returns the same
#     canned [0.1,0.2,0.3] vector such a fixture would hardcode.
#   * 06 still uses a standalone evil UDF (tests/evil_crash_udf.c) that
#     segfaults when called. This is a genuinely different, simpler
#     claim than the reasoning-plugin crash gates above (see gate 06's
#     own header comment), not a stand-in for them.
#   * 09 superuser-only config has NO MariaDB equivalent to port, permanently:
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
#   * MariaDB's mariadbd has NO built-in auto-restart-after-crash.
#     A multi-process server with an outer supervising daemon can
#     tear down and reinit shared memory after any child crash and
#     come back up on its own: that is a real architectural guarantee
#     such a platform can just observe. mariadbd has no equivalent: a
#     UDF call segfaulting takes down the WHOLE (single, mostly-threaded)
#     mysqld process, and nothing built into mariadbd brings it back. The
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
#     leaves prior committed data intact. Do not overstate what this
#     gate proves: it is a different, weaker platform
#     guarantee, tested honestly rather than assumed equivalent.
#
# Gates (see the header of each gate_* function below for full detail):
#   01  build            compile the shim + fractalsqld via          ~5s
#                        `make -C service`, scan, self-test
#   02  smoke            install + fractal_version/_edition +      ~5s
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
#   11  scout            fractal_search_explore: full population returned,   ~2s
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
#                        the failed row goes back to 'pending' with
#                        attempts incremented, and the next
#                        process_queue call retries it
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
#   30  fuzz_smoke       FUZZ ONLY (--fuzz, not in DEFAULT/QUICK). Builds  ~90s
#                        + briefly runs (FSQL_FUZZ_TIME seconds each,
#                        default 30) libFuzzer drivers against the 3
#                        hand-rolled parsers in src/fractalsql_parse.c
#                        (factored out of fractalsql.c specifically so
#                        they can link standalone, no mariadbd needed):
#                        parse_vector_csv (highest priority -- parses
#                        fractal_embed()'s raw response from whatever
#                        embedding endpoint FRACTALSQL_HTTP_EMBED_URL
#                        points at, genuinely externally-adversarial
#                        input), parse_corpus and parse_index_csv (SQL-
#                        caller-supplied text, lower external-adversary
#                        risk, included as defense-in-depth for the same
#                        hand-rolled-strtod-scan class of bug). No live
#                        cluster needed. Requires a libFuzzer-capable
#                        clang (set FSQL_FUZZ_CC to override
#                        auto-detection); skips cleanly if none is found.
#   31  sql_agent_savepoint  fractal_sql_agent's auto_execute INSERT/    ~10s
#                        UPDATE branch: SAVEPOINT/ROLLBACK TO SAVEPOINT
#                        scopes a failed execution's rollback to just
#                        that call, not the whole transaction, and the
#                        same fixed savepoint name is reusable across
#                        repeated calls in one transaction (restarts
#                        with FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=
#                        select_insert_update; drives GENERATE through
#                        the real mock_llm.py via a marker-routed reply)
#   32  new_primitives    the newest analytics/vector-math UDFs, known-   ~3s
#                        answer asserted: change_point_detect,
#                        periodogram, state_fingerprint (determinism,
#                        byte packing), cycle_detect (period-2 closes,
#                        distinct states do not), tda_persistence_
#                        diagram (two-cluster betti1=20, n_h0_bars=10,
#                        max_dim=0 -> betti1 null), optimize_subset
#                        (score near the hand-computed optimum, <=2
#                        nonzero weights), lp_distance (p=2/p=1),
#                        quantize_int8 (dequantization within rounding
#                        error), quantize_binary + hamming_distance
#                        (0 for identical, 1 for one flipped sign,
#                        unequal-length rejection)
#   33  conf_gate       the daemon conf's privacy gate (validate_cfg) ~4s
#                        at startup and at reload: 0644 refuses to boot
#                        and makes reload refuse, 0600 again accepted;
#                        four bad provider values refuse, each named in
#                        the daemon's log; unknown key warns+ignored;
#                        CRLF conf boots
#   34  reasoning_conf  the reasoning tier's conf-live rotation:        ~3s
#                        `reasoning_url` through `fsqlctl reload` only
#                        (dead port -> no reply, mock -> the canned
#                        reply, key removed -> env fallback)
#
# NOT ported, each for its own documented reason (see the architecture-
# differences block above, not a TODO backlog):
#   09  superuser-only     (permanently N/A, no sysvar surface exists
#                          by design)
#   26 (a real, non-mock enterprise .so) has no 1:1 match
#   here in this numbering -- this repo's OWN 26/27/28 below already
#   cover real-.so ground (activation gating, the CONNECT-queryable
#   ledger mirror, Ed25519 signature verification), just with this
#   repo's own assertion set, since its Enterprise-tier implementation
#   stands on its own (see src/fractalsql_enterprise.c's header).
#
# Gate sets:
#   QUICK   = 01 02
#   DEFAULT = 01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20
#             21 22 23 24 25 26 29 31 32 33 34 35 36
#   FUZZ    = 30                                       --fuzz runs ONLY gate 30 -- no cluster, standalone
#   FAULT   = 37 38                                     --fault runs DEFAULT, then ADDS gates 37-38 after it
#                                                       (37 restarts fractalsqld hundreds of times on top of
#                                                       the default run -- real wall-time, no crashes expected;
#                                                       38 deliberately SIGABRTs the daemon once to prove
#                                                       on_fatal logs and exits cleanly, then restarts it)
#   (26/27/28 stay opt-in: each needs a real, licensed enterprise .so
#   this public repo doesn't ship -- see gate_26_enterprise_active's own
#   header comment.)
#
# Usage:
#   ./build_test.sh                  # DEFAULT against MDB_MAJOR (default 11.4)
#   ./build_test.sh --quick
#   ./build_test.sh --mdb 10.6
#   ./build_test.sh --cross          # DEFAULT against every installed major
#   ./build_test.sh --fuzz           # gate 30 only -- libFuzzer smoke, no cluster
#   ./build_test.sh --fault          # DEFAULT, then the OOM-injection sweep (37) and the
#                                    # fatal-signal handler check (38) after it
#   ./build_test.sh --gate 06
#   ./build_test.sh --list
#   ./build_test.sh --coverage       # gcov-instrumented build; DEFAULT gates;
#                                    # lcov/genhtml report after (needs lcov+genhtml on PATH)
#   ./build_test.sh --asan           # ASan-instrumented fractalsql.so, LD_PRELOADed
#                                    # into mariadbd (skips the cluster gates on
#                                    # Darwin -- see mdb_setup's ASan branch)
#   ./build_test.sh --ubsan
#   ./build_test.sh --tsan           # TSan-instrumented fractalsqld ONLY (the
#                                    # shim is never instrumented, same as
#                                    # --asan/--ubsan) -- unlike --asan, this
#                                    # needs nothing injected into mariadbd at
#                                    # all, since fractalsqld is a standalone
#                                    # process built with the runtime linked in
#                                    # from the start. Not combinable with
#                                    # --asan (rejected up front with a clear
#                                    # error -- their runtimes can't link into
#                                    # the same binary). No Windows support:
#                                    # MSVC/clang-cl implement no
#                                    # -fsanitize=thread at all.
#
# Environment:
#   MDB_MAJOR              target major (default: 11.4)
#   MDB_BINDIR              override mariadbd/mariadb-install-db location
#   FSQL_TEST_TIMEOUT_MULT  scales gate 06's respawn-poll budget
#                           (default 1; auto-defaults to 3 under
#                           --asan/--ubsan, 5 under --tsan; both defaults
#                           are unverified against real sanitizer
#                           hardware in this session -- bump explicitly
#                           if gate 06 times out on a real run)
#   FSQL_FUZZ_CC            libFuzzer-capable clang for gate 30 (default:
#                           auto-detect clang-18/17/16/15/clang on PATH,
#                           probed for -fsanitize=fuzzer support before
#                           use -- a bare `clang` shadowed by an
#                           unrelated toolchain is a real failure mode,
#                           not hypothetical).
#   FSQL_FUZZ_TIME          seconds per fuzz target in gate 30 (default
#                           30). This is a pre-push SMOKE run, not a
#                           campaign -- bump it locally for real
#                           crash-finding, same binaries either way.
#   FSQL_OOM_MAX_N          allocation-count sweep ceiling per UDF in
#                           gate 37 (default 200). Each N restarts
#                           fractalsqld fresh (see tests/oom_preload.c),
#                           so this is real wall-time too, just smaller
#                           per-step than gate 30's.

set -uo pipefail

# Captured before the arg-parsing loop below consumes "$@" via `shift` --
# needed later to re-exec this same invocation under setarch (--tsan
# only; see that check further down).
ORIG_ARGV=("$@")

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

TMPROOT="$(cd /tmp && pwd -P)"

DEFAULT_GATES=(01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 29 31 32 33 34 35 36)
QUICK_GATES=(01 02)
FUZZ_GATES=(30)
FAULT_GATES=(37 38)

MDB_MAJOR="${MDB_MAJOR:-11.4}"
MODE="default"
ONE_GATE=""
COVERAGE=0
ASAN=0
UBSAN=0
TSAN=0

if [ -t 1 ]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; Z="\033[0m"; else G=""; R=""; Y=""; Z=""; fi
pass() { printf "  [${G}PASS${Z}] %s\n" "$1"; }
fail() { printf "  [${R}FAIL${Z}] %s\n" "$1"; FAILED=1; }
skip() { printf "  [${Y}SKIP${Z}] %s\n" "$1"; }

usage() { sed -n '4,160p' "$0"; exit 0; }

# Copy the redirected .gcda files back next to their .gcno (one plain
# file copy per instrumented TU, not the hot-path gcov flushing) and
# generate an lcov report. Called once after the gate matrix finishes.
run_coverage_report() {
  local f found=0
  # The adapter objects' .gcno now live in service/build/daemon/ (that's
  # where service/Makefile compiles ../src/*.c to), not next to src/*.c
  # the way the old in-process root Makefile left them -- a .gcda has
  # to land next to its .gcno for lcov to pair them. The daemon
  # executable precompiles there too (service/Makefile), so its own
  # .gcda joins the list.
  for f in fractalsql fractalsql_parse fractalsql_session fractalsql_vector fractalsql_cognition fractalsql_textsql fractalsql_enterprise fractalsqld; do
    local gcda_src
    gcda_src="$(find "$GCOV_PREFIX" -name "${f}.gcda" 2>/dev/null | head -1)"
    [ -n "$gcda_src" ] && { cp "$gcda_src" "service/build/daemon/${f}.gcda"; found=1; }
  done
  if [ "$found" -eq 0 ]; then
    fail "coverage: no .gcda produced (was --coverage gate 01 build ok?)"
    return
  fi

  if ! command -v lcov >/dev/null 2>&1; then
    skip "coverage: lcov not installed, skipping report"
    return
  fi
  lcov --capture --directory service/build/daemon --output-file /tmp/fractalsql_bt_coverage_raw.info \
       --rc branch_coverage=1 >/tmp/fractalsql_bt_lcov.log 2>&1 \
    || { fail "coverage: lcov capture failed, see /tmp/fractalsql_bt_lcov.log"; return; }

  # Extract just this extension's own sources: the capture also picks up
  # the handful of lines pulled in from system headers like mysql.h,
  # which aren't our code and nobody's asking about their coverage.
  lcov --extract /tmp/fractalsql_bt_coverage_raw.info '*/src/*.c' '*/daemon/fractalsqld.c' \
       --output-file /tmp/fractalsql_bt_coverage.info \
       --rc branch_coverage=1 >>/tmp/fractalsql_bt_lcov.log 2>&1

  echo ""
  echo "=== coverage (src/*.c, daemon/fractalsqld.c) ==="
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRF:/ { brf += $2 } /^BRH:/ { brh += $2 }
    END {
      printf "  lines:     %d/%d", lh, lf
      if (lf > 0) printf " (%.1f%%)", 100*lh/lf
      print ""
      printf "  functions: %d/%d", fnh, fnf
      if (fnf > 0) printf " (%.1f%%)", 100*fnh/fnf
      print ""
      printf "  branches:  %d/%d", brh, brf
      if (brf > 0) printf " (%.1f%%)", 100*brh/brf
      print ""
    }' /tmp/fractalsql_bt_coverage.info

  if command -v genhtml >/dev/null 2>&1; then
    genhtml /tmp/fractalsql_bt_coverage.info --output-directory coverage_html \
            --rc branch_coverage=1 >/tmp/fractalsql_bt_genhtml.log 2>&1 \
      && pass "coverage: report at coverage_html/index.html" \
      || fail "coverage: genhtml failed, see /tmp/fractalsql_bt_genhtml.log"
  fi
  rm -rf "$GCOV_PREFIX"
}

# Resolves a sanitizer runtime's real .so path for LD_PRELOAD (--asan /
# --ubsan): `cc -print-file-name=libasan.so` on EL/RHEL-family distros
# often returns a LINKER SCRIPT (ASCII text with INPUT(...) directives),
# not an ELF -- LD_PRELOAD rejects those with "file too short". Falls
# back to the versioned ELF resolved via ldconfig when that happens (a
# generic gcc/clang toolchain concern, not MariaDB-specific).
resolve_san_rt() {
  local libname="$1"
  if [ "$(uname -s)" = "Darwin" ]; then
    # Best-effort, same caveat as this file's fsql_ent_platform_dir:
    # never exercised on real Darwin hardware in this session. Apple
    # clang has no libasan.so/libubsan.so -- compiler-rt ships a unified
    # dylib under the active toolchain's resource dir instead.
    local resdir; resdir="$(${CC:-cc} -print-resource-dir 2>/dev/null)"
    [ -n "$resdir" ] || { printf ''; return; }
    case "$libname" in
      libasan.so)  printf '%s' "$resdir/lib/darwin/libclang_rt.asan_osx_dynamic.dylib" ;;
      libubsan.so) printf '%s' "$resdir/lib/darwin/libclang_rt.ubsan_osx_dynamic.dylib" ;;
      *)           printf '' ;;
    esac
    return
  fi
  local rt
  rt="$(${CC:-cc} -print-file-name="$libname" 2>/dev/null)"
  if [ -f "$rt" ] && ! file -b "$rt" | grep -qE 'ELF|shared object'; then
    local stem="${libname%.so}"
    local cand
    cand="$(ldconfig -p 2>/dev/null \
            | awk -v s="$stem" '$1 ~ "^"s"\\.so\\.[0-9]+$" {print $NF; exit}')"
    [ -n "$cand" ] && [ -f "$cand" ] && rt="$cand"
  fi
  printf '%s' "$rt"
}

# Platform-correct include/<dir>/ subdir + shared-library extension for
# the vendored enterprise artifact, used by gates 26/27/28. Mirrors this
# file's own uname-based platform detection (mdb_bindir, and the
# fsql_platform local used for the reasoning-VFS test-fixture compiles
# in mdb_setup): "linux-x86_64"/"linux-aarch64" + .so on Linux,
# "darwin-x86_64"/"darwin-arm64" + .dylib on macOS (confirmed against
# the FractalSQL core's own darwin release artifact naming -- e.g.
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
  # FSQL_ENT_SO lets the licensed artifact live outside the repo tree.
  if [ -n "${FSQL_ENT_SO:-}" ]; then echo "$FSQL_ENT_SO"; return; fi
  echo "$HERE/include/$(fsql_ent_platform_dir)/libfractalsql-enterprise-sovereign-c.$(fsql_ent_so_ext)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --quick)   MODE="quick" ;;
    --cross)   MODE="cross" ;;
    --mdb)     MDB_MAJOR="$2"; shift ;;
    --gate)    ONE_GATE="$2"; shift ;;
    --fuzz)    MODE="fuzz" ;;
    --fault)   MODE="fault" ;;
    --coverage) COVERAGE=1 ;;
    --asan)    ASAN=1 ;;
    --ubsan)   UBSAN=1 ;;
    --tsan)    TSAN=1 ;;
    --list)    printf "gates: %s\nfuzz gates: %s\nfault gates: %s\n" "${DEFAULT_GATES[*]}" "${FUZZ_GATES[*]}" "${FAULT_GATES[*]}"; exit 0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# ASan and TSan runtimes cannot link into the same binary (the compiler
# rejects it); catch this here with a clear message instead of letting
# gate 01's build fail with a raw compiler/linker error.
if [ "$ASAN" -eq 1 ] && [ "$TSAN" -eq 1 ]; then
  echo "ERROR: --asan and --tsan cannot be combined -- their runtimes cannot link into the same binary. Run one at a time." >&2
  exit 2
fi

# Must run AFTER the arg-parsing loop above -- ASAN/UBSAN/COVERAGE are
# still 0 at the point this file declares them, so checking them any
# earlier (as a prior version of this block did) always took the
# unset-flags branch even when --asan/--ubsan/--coverage was actually
# passed on the command line. Caught via a real Docker run: --coverage
# hit "GCOV_PREFIX: unbound variable" in run_coverage_report because
# this export never fired, and --asan's TIMEOUT_MULT never actually
# auto-bumped to 3 either.
if [ -n "${FSQL_TEST_TIMEOUT_MULT:-}" ]; then
  TIMEOUT_MULT="$FSQL_TEST_TIMEOUT_MULT"
elif [ "$TSAN" -eq 1 ]; then
  TIMEOUT_MULT=5
elif [ "$ASAN" -eq 1 ] || [ "$UBSAN" -eq 1 ]; then
  TIMEOUT_MULT=3
else
  TIMEOUT_MULT=1
fi

# --tsan: a TSan-instrumented binary can FATAL at process startup
# ("ThreadSanitizer: unexpected memory mapping") on a kernel whose ASLR
# entropy is higher than TSan's shadow-memory layout assumes -- hit live
# on this repo's own dev host, not hypothetical. Fix: re-exec this whole
# script under `setarch -R` (ASLR off for the re-exec'd process tree),
# before fractalsqld or any other subprocess starts. Re-exec the WHOLE
# script rather than just the daemon launch further down, since the
# daemon is forked from this same shell later and needs to inherit the
# disabled-ASLR personality from its parent.
#
# `command -v setarch` alone isn't enough to trust here: the binary can
# exist on PATH and still fail at runtime (confirmed live -- inside a
# container with a seccomp profile that blocks the personality() syscall,
# setarch exits "Operation not permitted" even though it's present). So
# this probes a real invocation, not just PATH presence, and falls back
# to a WARNING instead of a hard failure if the probe fails.
# FSQL_BT_TSAN_SETARCHED guards against re-exec'ing a second time once
# already inside the setarch'd process.
if [ "$TSAN" -eq 1 ] && [ "$(uname -s)" != "Darwin" ] && [ -z "${FSQL_BT_TSAN_SETARCHED:-}" ]; then
  if setarch "$(uname -m)" -R true >/dev/null 2>&1; then
    export FSQL_BT_TSAN_SETARCHED=1
    exec setarch "$(uname -m)" -R "$0" "${ORIG_ARGV[@]}"
  else
    echo "WARNING: --tsan requested but 'setarch $(uname -m) -R' did not" >&2
    echo "         succeed (missing, or blocked by a sandbox/seccomp" >&2
    echo "         profile) -- continuing without disabling ASLR. TSan" >&2
    echo "         may FATAL non-deterministically on this kernel." >&2
  fi
fi

# --coverage: redirect gcov's live .gcda writes to /tmp for the run, so
# mariadbd (which loads the instrumented fractalsql.so and every other
# instrumented .o linked into it) writes there instead of next to the
# checkout. GCOV_PREFIX_STRIP counts path components to drop from the
# .gcno-embedded absolute path before prefixing with GCOV_PREFIX --
# computed from $HERE's own depth so this isn't hardcoded to one
# checkout location. Exported unconditionally (harmless no-op without a
# --coverage build); mdb_setup's mariadbd/mysqld_safe launch inherits it
# since it forks from this same shell.
if [ "$COVERAGE" -eq 1 ]; then
  export GCOV_PREFIX="/tmp/fractalsql_bt_gcov_$$"
  export GCOV_PREFIX_STRIP=$(( $(echo "$HERE" | tr -cd '/' | wc -c) ))
  mkdir -p "$GCOV_PREFIX"
fi

FAILED=0
BIN=""; DATADIR=""; SOCK=""; PORT=""; PIDFILE=""; PLUGDIR=""; SUPERVISOR_PID=""; MOCK_LLM_PID=""
CRASH_SO=""
FSQD_PID=""; CUR_VER=""

# mdb_bindir <major> -- locates mariadbd + mariadb-install-db +
# mariadb-admin + mysqld_safe for the requested major. Resolution
# order: env override, then Darwin/Homebrew, then Linux system paths.
# MariaDB's own packaging
# does NOT install per-major binaries side-by-side: one system normally has exactly one
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
    # Homebrew's mariadb formula is NOT versioned by major
    # (confirmed: no mariadb@10.6/mariadb@11.4 formulae exist as of
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

# fractalsqld is started before mariadbd, with the same environment the
# gate exported (reasoning, enterprise, ledger paths), so every gate's
# config reaches the daemon that runs every UDF body. Plugin-swap gates
# restart through mdb_teardown/mdb_setup and so restart the daemon too;
# the in-place restart helper restarts it explicitly.
daemon_start() {
  local tag="${CUR_VER//./_}"
  FSQD_SOCK="$TMPROOT/fractalsql_bt_fsqd_${tag}.sock"
  local key="$TMPROOT/fractalsql_bt_fsqd_${tag}.key"
  FSQD_CONF="$TMPROOT/fractalsql_bt_fsqd_${tag}.conf"
  FSQD_KEY="$key"
  rm -f "$FSQD_SOCK"
  openssl rand -hex 32 > "$key" && chmod 600 "$key" || return 1
  printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n' \
    "$FSQD_SOCK" "$key" "$(id -u)" > "$FSQD_CONF"
  # The conf file now carries the provider keys (fractalsql_provider.h)
  # whose values may include plaintext secrets, and is therefore gated
  # like the key file at startup and at every reload.
  chmod 600 "$FSQD_CONF"
  export FRACTALSQL_CONFIG="$FSQD_CONF"
  "$HERE/service/build/fractalsqld" -c "$FSQD_CONF" </dev/null \
    >>/tmp/fractalsql_bt_fsqd_${tag}.log 2>&1 &
  FSQD_PID=$!
  local i
  for i in $(seq 1 50); do
    [ -S "$FSQD_SOCK" ] && return 0
    sleep 0.1
  done
  echo "fractalsqld did not open $FSQD_SOCK (see /tmp/fractalsql_bt_fsqd_${tag}.log)" >&2
  return 1
}

daemon_stop() {
  [ -n "$FSQD_PID" ] && kill "$FSQD_PID" >/dev/null 2>&1
  [ -n "$FSQD_PID" ] && wait "$FSQD_PID" 2>/dev/null
  FSQD_PID=""
  [ -n "${FSQD_SOCK:-}" ] && rm -f "$FSQD_SOCK"
  return 0
}

# mdb_setup <major>: builds a scratch plugin-dir containing
# fractalsql.so + the evil-crash UDF .so, initializes a throwaway
# datadir, and starts mariadbd against it (via mysqld_safe if
# available, else a manual respawn-loop supervisor; see gate 06's own
# header comment for why this distinction matters). Returns 1 (skip) if
# mariadbd for this major cannot be found at all, or 3 (skip, message
# printed by this function) for --asan on Darwin against a
# non-instrumented mariadbd -- see the ASan branch's own comment.
mdb_setup() {
  local v="$1"
  CUR_VER="$v"
  BIN="$(mdb_bindir "$v")"
  if [ ! -x "$BIN/mariadbd" ] && ! command -v mariadbd >/dev/null 2>&1; then
    return 1
  fi
  local mariadbd_bin; mariadbd_bin="$([ -x "$BIN/mariadbd" ] && echo "$BIN/mariadbd" || command -v mariadbd)"
  # The run is labelled with $v, so the server must be that major. Without
  # this, --mdb 11.4 on a 10.11 host ran the gates on 10.11 and said 11.4.
  local found_ver; found_ver="$("$mariadbd_bin" --version 2>/dev/null | sed -n 's/.* Ver \([0-9][0-9.]*\).*/\1/p' | head -1)"
  case "$found_ver." in
    "$v."*) ;;
    *) echo "mdb_setup: $mariadbd_bin is '${found_ver:-unknown}', not $v (set MDB_BINDIR to a $v install)" >&2
       return 2 ;;
  esac
  local installdb_bin; installdb_bin="$(mdb_sibling "$BIN" mariadb-install-db)"
  # MariaDB 10.6 is the tool-rename transition major: Homebrew's
  # mariadb@10.6 bottle still ships only the pre-rename
  # mysql_install_db, no mariadb-install-db (10.11+ ship the new name).
  # Fall back to it -- the 10.6 script takes the same
  # --defaults-file/--datadir/--auth-root-authentication-method flags
  # (caught live on a macos-14 darwin-gate-matrix cell: 10.6 failed
  # cluster setup with "mariadb-install-db or mariadb client not
  # found" while 11.4 passed this check).
  [ -n "$installdb_bin" ] || installdb_bin="$(mdb_sibling "$BIN" mysql_install_db)"
  local admin_bin;     admin_bin="$(mdb_sibling "$BIN" mariadb-admin)"
  local client_bin;    client_bin="$(mdb_sibling "$BIN" mariadb)"
  [ -n "$installdb_bin" ] && [ -n "$client_bin" ] || { echo "mariadb-install-db or mariadb client not found" >&2; return 2; }

  DATADIR="/tmp/fractalsql_bt_data_${v//./_}"
  SOCK="/tmp/fractalsql_bt_sock_${v//./_}/mysql.sock"
  PLUGDIR="$TMPROOT/fractalsql_bt_plugin_${v//./_}"
  PIDFILE="/tmp/fractalsql_bt_pid_${v//./_}.pid"
  CNF="$TMPROOT/fractalsql_bt_cnf_${v//./_}.cnf"
  PORT=$(( 13300 + $(echo "$v" | tr -d '.') % 100 ))
  rm -rf "$DATADIR" "$(dirname "$SOCK")" "$PLUGDIR"
  mkdir -p "$DATADIR" "$(dirname "$SOCK")" "$PLUGDIR"
  # Config isolation: hand every server process below a minimal
  # defaults file. Without it, a distro-installed mariadbd also reads
  # the host's own /etc/mysql config (caught live on an Ubuntu 24.04
  # host: provider_*=force_plus_permanent lines in the system config
  # pointed the scratch daemon at plugin files it was never given,
  # aborting cluster setup). Container CI has no /etc/mysql config,
  # which is why this never surfaced there.
  : > "$CNF"

  cp "$HERE/service/build/fractalsql.so" "$PLUGDIR/fractalsql.so" || return 2
  # Reasoning-tier gates (03/04/13/22/23) dispatch through the real
  # fractalsql-reasoning-http.so plugin against a deterministic local
  # mock (scripts/ci/mock_llm.py), exercising the FULL real path (UDF
  # -> fsql_load_reasoning -> curl -> HTTP -> response parse), not a
  # fake in-process substitute. Started here, before mariadbd, since
  # FRACTALSQL_REASONING_PLUGIN/HTTP_URL/HTTP_EMBED_URL must be in
  # mariadbd's OWN process environment at exec time (read once, lazily,
  # per process).
  # Vendored per-platform: "linux-x86_64"/"linux-aarch64" on Linux,
  # "darwin-arm64"/"darwin-x86_64" on macOS (same naming fsql_platform
  # below resolves; the darwin file is a Mach-O under the same .so
  # name, matching what the darwin release zip's install.sh stages).
  # Hardcoding linux-x86_64 here would copy the Linux ELF on macOS: cp
  # itself succeeds (the repo checkout carries every platform's dir),
  # but mariadbd's dlopen of an ELF on Mach-O then fails, and every
  # HTTP-backed gate (04 text_to_sql, 13 vectorizer, 15/17/18 embed,
  # 23 cognition) NULLs while the locally-compiled fixture gates
  # (05/07/14/15/29) still pass -- caught live on darwin-gate-matrix.
  local fsql_platform; fsql_platform="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
  # install -m 0755, not cp: the vendored blob's mode is whatever the
  # git tree carries, and dlopen on macOS refuses to mmap(PROT_EXEC) a
  # .so lacking the exec bit (Linux never checks it, so only the darwin
  # runs would break -- with a bare NULL from the UDF, no logged cause).
  install -m 0755 "$HERE/include/$fsql_platform/fractalsql-reasoning-http.so" "$PLUGDIR/fractalsql-reasoning-http.so" || return 2
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
  daemon_start || return 2

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
  # fractalsql_sql.h (the evil/retry fixtures reference no
  # server-specific API at all). -Iinclude/<platform> gives
  # fractalsql_sql.h/fractalsql.h; $mdb_cflags is NOT needed for these
  # (they never include mysql.h), unlike CRASH_SO above. Recompiled
  # every mdb_setup call since mdb_teardown wipes the whole $PLUGDIR.
  EVIL_REASONING_SO="$PLUGDIR/evil_nonterminating.so"
  LYING_SO="$PLUGDIR/evil_lying_length.so"
  CRASH_REASONING_SO="$PLUGDIR/evil_crash_reasoning.so"
  EVIL_EMBED_SO="$PLUGDIR/evil_embed.so"
  RETRY_SO="$PLUGDIR/retry_reasoning.so"
  THINK_SO="$PLUGDIR/think_reasoning.so"
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

  "$installdb_bin" --defaults-file="$CNF" --datadir="$DATADIR" --auth-root-authentication-method=normal \
    >/tmp/fractalsql_bt_setup_${v//./_}.log 2>&1 \
    || { tail -30 /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }

  # --asan/--ubsan: fractalsql.so was just built with -fsanitize=... by
  # gate_01_build, but mariadbd itself (a plain, non-instrumented binary
  # from the target major's own package/image) has to be told to load
  # the matching sanitizer runtime BEFORE it starts, or the dlopen'd
  # instrumented code fails with undefined __asan_*/__ubsan_* symbols.
  # LD_PRELOAD does that on Linux (exported here, function-scoped -- so
  # the fixture `cc` compiles just above are never preloaded with it,
  # and it reaches mariadbd through mysqld_safe's own exec chain below).
  #
  # Darwin is different twice over:
  #   * dyld ignores LD_PRELOAD entirely; its equivalent is
  #     DYLD_INSERT_LIBRARIES (a Homebrew mariadbd lives outside
  #     SIP-protected paths, so the var should not be silently stripped).
  #   * Even with the right variable, injecting ASan into a host binary
  #     that was NOT itself compiled with -fsanitize=address does not
  #     work on modern macOS: dyld's chained fixups bind libSystem calls
  #     before a late-injected runtime can install ASan's malloc/free
  #     interceptors, and the ASan runtime then aborts the host with
  #     "Interceptors are not working ... loaded too late" -- killing
  #     the whole (single, threaded) mariadbd process, which surfaces to
  #     the client as ERROR 2013 Lost connection at the first CREATE
  #     FUNCTION (caught live on the darwin-asan CI cell, 2026-09). The
  #     dylib loads fine; only the interceptors are the problem, and
  #     code signing has nothing to do with it. So: detect a plain
  #     (non-instrumented) mariadbd up front and skip the cluster gates
  #     cleanly instead of hard-failing cluster setup. Full-cluster ASan
  #     on macOS requires a source-built ASan mariadbd; the Linux and
  #     Windows ASan cells cover this same portable C source.
  #   * UBSan needs none of this: Apple's -fsanitize=undefined links its
  #     trapping runtime statically into the instrumented objects, so no
  #     preloaded dylib is required. The ubsan branch below therefore
  #     deliberately keeps its "missing dylib on Darwin = nothing to
  #     preload" posture rather than growing this same injection logic
  #     (verified green end-to-end on the darwin-ubsan CI cell) -- do
  #     not consistency-fix it back.
  if [ "$ASAN" -eq 1 ]; then
    if [ "$(uname -s)" = "Darwin" ] \
       && ! otool -L "$mariadbd_bin" 2>/dev/null | grep -qi 'libclang_rt\.asan\|libasan'; then
      skip "MariaDB $v cluster setup (Darwin ASan needs mariadbd itself built with -fsanitize=address; run against a source-built ASan mariadbd to exercise the cluster gates here -- Linux/Windows ASan CI already cover this same portable C source)"
      return 3
    fi
    local asan_rt; asan_rt="$(resolve_san_rt libasan.so)"
    [ -n "$asan_rt" ] && [ -f "$asan_rt" ] || { echo "ERROR: could not resolve libasan.so runtime" >&2; return 2; }
    if [ "$(uname -s)" = "Darwin" ]; then
      export DYLD_INSERT_LIBRARIES="$asan_rt"
    else
      export LD_PRELOAD="$asan_rt"
    fi
    export ASAN_OPTIONS="detect_leaks=0:halt_on_error=1"
  elif [ "$UBSAN" -eq 1 ]; then
    local ubsan_rt; ubsan_rt="$(resolve_san_rt libubsan.so)"
    if [ -n "$ubsan_rt" ] && [ -f "$ubsan_rt" ]; then
      export LD_PRELOAD="$ubsan_rt"
    elif [ "$(uname -s)" != "Darwin" ]; then
      echo "ERROR: could not resolve libubsan.so runtime" >&2; return 2
    fi
    export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
  elif [ "$TSAN" -eq 1 ]; then
    # Unlike ASan/UBSan above, nothing needs preloading into mariadbd and
    # there is no Darwin skip: fractalsqld is a standalone process (never
    # dlopen'd into mariadbd, same as the shim/daemon split described at
    # this file's own header) built directly with -fsanitize=thread by
    # gate_01_build, so the TSan runtime is already linked into it at
    # build time. The ASLR re-exec this file does further up (search
    # FSQL_BT_TSAN_SETARCHED) is the only platform workaround TSan needs
    # here.
    export TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1"
  fi

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
    "$mysqld_safe_bin" --defaults-file="$CNF" --ledir="$(dirname "$mariadbd_bin")" \
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
        "$mariadbd_bin" --defaults-file="$CNF" --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
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
  [ -n "$DATADIR" ] && pkill -f "mariadbd.*$DATADIR" >/dev/null 2>&1 || true
  [ -n "$MOCK_LLM_PID" ] && kill "$MOCK_LLM_PID" >/dev/null 2>&1
  # Preserve mariadbd's own stderr log before the wipe: mysqld_safe/
  # mariadbd-safe route mariadbd's stderr into the datadir <hostname>.err,
  # which is the ONLY place a sanitizer report (e.g. an ASan abort inside
  # mariadbd) or a UDF crash backtrace lands -- the captured server log
  # above carries only the supervisor's own output. Copied out with the
  # same <major-with-underscores> naming the other /tmp logs use, because
  # the run-level FAIL dump at the bottom of this script executes after
  # every run_major's teardown, when the datadir is already gone.
  local err_file
  for err_file in "$DATADIR"/*.err; do
    [ -f "$err_file" ] && cp "$err_file" "/tmp/fractalsql_bt_mariadbd_err_${DATADIR##*_}.log"
  done
  [ -n "$DATADIR" ] && rm -rf "$DATADIR"
  [ -n "$SOCK" ] && rm -rf "$(dirname "$SOCK")"
  [ -n "$PLUGDIR" ] && rm -rf "$PLUGDIR"
  daemon_stop
  DATADIR=""; SOCK=""; MOCK_LLM_PID=""
}

cleanup() {
  mdb_teardown 2>/dev/null || true
}
trap cleanup EXIT

# Restart mariadbd with FRACTALSQL_REASONING_PLUGIN pointed at $1
# instead of the real HTTP wrapper -- a restart-based swap, since the
# reasoning-plugin path reaches the daemon through its boot environment
# fallback, captured once when the daemon starts (the conf file's
# provider keys reload live instead -- gate 29's (d) scenarios exercise
# that path; these env-based scenarios remain restart-based as the
# env-only regression). Extra env assignments (e.g.
# FRACTALSQL_TEXT_TO_SQL_USE_REVIEW) can be exported by the caller
# before calling this, same restart, same constraint.
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
  daemon_stop
  daemon_start || return 1
  [ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" >/dev/null 2>&1
  sleep 1
  [ -n "$DATADIR" ] && pkill -f "mariadbd.*$DATADIR" >/dev/null 2>&1 || true
  sleep 1

  local mariadbd_bin; mariadbd_bin="$([ -x "$BIN/mariadbd" ] && echo "$BIN/mariadbd" || command -v mariadbd)"
  local mysqld_safe_bin
  mysqld_safe_bin="$(mdb_sibling "$BIN" mariadbd-safe)"
  [ -z "$mysqld_safe_bin" ] && mysqld_safe_bin="$(mdb_sibling "$BIN" mysqld_safe)"
  if [ -n "$mysqld_safe_bin" ]; then
    "$mysqld_safe_bin" --defaults-file="$CNF" --ledir="$(dirname "$mariadbd_bin")" \
      --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
      --plugin-dir="$PLUGDIR" --pid-file="$PIDFILE" \
      --skip-networking=0 --bind-address=127.0.0.1 \
      >>/tmp/fractalsql_bt_server_${MDB_MAJOR//./_}.log 2>&1 &
    SUPERVISOR_PID=$!
  else
    ( while true; do
        "$mariadbd_bin" --defaults-file="$CNF" --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
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

# Builds service/ (the shim + fractalsqld), runs its license/boundary/
# symbol scans, and its spike + fsqlctl CLI self-tests: frame-level auth,
# daemon death + reconnect, CLI independence -- protocol-level checks no
# numbered gate below exercises. A failure here fails every later gate.
# SPIKE_WORK lets a concurrent run for a different --mdb major use its
# own scratch dir.
gate_01_build() {
  local work="/tmp/fractalsql_bt_service_${MDB_MAJOR//./_}"
  export SPIKE_WORK="$work/spike"
  local log="/tmp/fractalsql_bt_build.log"
  local san_arg=""
  [ "$COVERAGE" -eq 1 ] && san_arg="COVERAGE=1"
  [ "$ASAN" -eq 1 ]     && san_arg="ASAN=1"
  [ "$UBSAN" -eq 1 ]    && san_arg="UBSAN=1"
  [ "$TSAN" -eq 1 ]     && san_arg="TSAN=1"
  if make -C "$HERE/service" clean >"$log" 2>&1 \
     && make -C "$HERE/service" $san_arg all scan >>"$log" 2>&1 \
     && [ -f "$HERE/service/build/fractalsql.so" ] && [ -x "$HERE/service/build/fractalsqld" ]; then
    pass "01 build (shim + fractalsqld), license scan, symbol scan"
  else
    fail "01 build: see $log"
    grep -iE "error|forbidden" "$log" | head -5 | sed 's/^/         /'
    return
  fi
  if sh "$HERE/service/tests/spike_test.sh" >/tmp/fractalsql_bt_spike.log 2>&1 \
     && sh "$HERE/service/tests/cli_test.sh" >>/tmp/fractalsql_bt_spike.log 2>&1; then
    pass "01 build: protocol self-test (spike + fsqlctl CLI)"
  else
    fail "01 build: protocol self-test failed, see /tmp/fractalsql_bt_spike.log"
    grep -E "\[FAIL\]" /tmp/fractalsql_bt_spike.log | head -5 | sed 's/^/         /'
  fi
}

gate_02_smoke() {
  local want_ver; want_ver="$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' src/fractalsql.c | head -1)"
  local ver; ver=$("${MARIADB[@]}" -N -e "SELECT fractal_version();" 2>&1)
  [ "$ver" = "$want_ver" ] && pass "02 smoke: version=$ver" || fail "02 smoke: version='$ver' (want $want_ver)"

  local ed; ed=$("${MARIADB[@]}" -N -e "SELECT fractal_edition();" 2>&1)
  [ -n "$ed" ] && ! grep <<< "$ed" -q "ERROR" && pass "02 smoke: edition=$ed" || fail "02 smoke: edition='$ed'"

  # fractal_search(vector_csv, query_csv, k, params) -> JSON string.
  # Convergence check: cosine similarity of
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
# architecture-differences comment for the platform claim this gate
# makes: (a) the supervisor respawns
# mariadbd, (b) InnoDB crash recovery leaves prior committed data
# intact. Uses a plain InnoDB table + row as the "canary".
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
  # The 12.x client reports an abrupt mid-query disconnect as a
  # TLS/SSL error ("unexpected eof while reading") rather than the
  # classic "Lost connection to MySQL server" text 10.6-11.4 use --
  # caught live on 12.2 (a real, version-specific error-message
  # difference, not a functional regression: the respawn +
  # data-integrity assertions right after this one still passed on
  # 12.x unchanged).
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
  # 3-cluster inline corpus, shaped for fractal_search_explore's
  # inline-CSV-corpus signature rather than a
  # table+column scan. fractal_search_explore(corpus_csv, query_csv, params)
  # has no table-scan mode in this repo's architecture by design.
  local corpus="["
  local i
  for i in $(seq 1 20); do corpus+="[1,0,0],"; done
  for i in $(seq 1 20); do corpus+="[0,1,0],"; done
  for i in $(seq 1 20); do corpus+="[0,0,1],"; done
  corpus="${corpus%,}]"

  local r; r=$("${MARIADB[@]}" -N -e "
    SELECT fractal_search_explore('$corpus', '[1,0,0]', '{\"population_size\":24,\"iterations\":12}');" 2>&1)

  local n; n=$(echo "$r" | grep -oE '"population"\s*:\s*\[' >/dev/null 2>&1 && \
               echo "$r" | tr ',' '\n' | grep -c '\[' || echo 0)
  if echo "$r" | grep -q '"population"'; then
    pass "11 scout: fractal_search_explore returns a population array"
  else
    fail "11 scout: fractal_search_explore='$r'"
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
# MAX_QUERY_BYTES (4 MiB) rejection -- a bounds-check gate, scoped to
# what fractal_search
# actually validates today (see the bounds check in
# fractal_search()/fractal_search_explore() in src/fractalsql.c).
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

  # A plain (non-versioned, non-hint) block comment is inert text, not
  # an exec comment (t2s_has_exec_comment only rejects /*! and /*+) --
  # this is the one allowlist input that drives t2s_skip_ws_comments'
  # own /* */ loop, t2s_count_statements' and t2s_has_into_outfile's
  # comment-skip branches, and t2s_has_exec_comment's plain-comment
  # skip loop all in one call; nothing else in this suite's allowlist
  # inputs contains a comment at all.
  local a3; a3=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('SELECT /* a plain comment */ 1'), '<PASS>');" 2>&1)
  [ "$a3" = "<PASS>" ] && pass "04 text_to_sql: a plain block comment is inert, not rejected" \
                        || fail "04 text_to_sql: expected the commented SELECT to pass, got: $a3"
}

# Adversarial reasoning plugin returning a non-NUL-terminated response
# flush against a guard page (tests/evil_nonterminating_plugin.c --
# pure C against the shared vendored fractalsql_sql.h, no
# server-specific API). Proves fractal_t2s_generate/fractal_reason/fractal_t2s_review
# all honor response_len_out and never treat `summary` as a NUL-
# terminated C string, at all three call sites that dispatch through
# fsql_dispatch_ai.
#
# IMPORTANT design note: the evil plugin's call_count is a process-wide
# static, but fractalsqld -- the daemon it loads into -- is ONE shared
# process for every connection's forwarded calls (a per-connection
# process model would dlopen the plugin fresh for each new connection,
# resetting call_count to 0) -- call_count keeps incrementing
# across every UDF call in the process's lifetime, connection or not.
# So this gate restarts mariadbd (via mdb_swap_reasoning_plugin) before
# EACH of the three call sites, not once for the whole gate: only that
# guarantees call_count=0 (matching FSQL_EVIL_TRIGGER_CALL's default,
# trigger=1) at every site actually under test, the guarantee a
# per-connection process model gets for free. Slower (3 restarts
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
# a missing NUL terminator (tests/evil_lying_length_plugin.c) --
# proves the length-bound check (FRACTAL_MAX_AI_
# RESPONSE_BYTES, src/fractalsql_cognition.c / fractalsql_textsql.c)
# rejects BEFORE any read past the real 8-byte buffer, not just that
# nothing crashes. MariaDB's UDF ABI has no SQL-visible
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
# introspection, and a grant must restore visibility. A confirmatory
# test for the privilege-bypass regression class (not assumed safe
# from reading the code), since this file's own header previously only
# asserted, not verified, that MariaDB's information_schema-backed
# INVOKER security handles this: information_schema.columns/tables
# themselves already filter by the CONNECTED user's privileges (a
# property of the catalog, not of fractal_schema_context's own SQL),
# so no extra explicit privilege check is needed inside the routine.
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
# (env var). tests/retry_reasoning_plugin.c returns a rejected DDL
# statement on GENERATE call 1, then
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
# bridge without needing a live LLM. The environment fallback is still
# captured once per daemon process, so the env-based scenarios (a)/(b)
# work through a restart (mdb_swap_reasoning_plugin); scenario (d)
# proves the live path: fractalsqld.conf is now the preferred provider
# source (fractalsql_provider.h), and `fsqlctl reload` pushes new
# THINK values into the RUNNING daemon without any restart.
gate_29_think() {
  # (a) unset -> nothing reaches the plugin (regression safety).
  mdb_swap_reasoning_plugin "$THINK_SO" \
    || { fail "29 think: plugin swap did not take effect"; mdb_restore_reasoning_plugin; return; }
  local out1; out1=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  echo "$out1" | grep -q "THINK=(unset)" && echo "$out1" | grep -q "THINK_PROVIDER=(unset)" \
    && echo "$out1" | grep -q "NATIVE_URL=(unset)" && echo "$out1" | grep -q "NUM_CTX=(unset)" \
    && pass "29 think: THINK unset -> no THINK-related env var reaches the plugin" \
    || fail "29 think: expected all 4 vars (unset), got: $out1"

  # (d, live) the conf file -- the preferred provider source -- carries
  # the same 4 keys the daemon's environment does NOT carry; a
  # payload-less `fsqlctl reload` pushes them into the running daemon
  # (daemon_check/apply_provider: clear the tier's loaded flag on apply),
  # and the next fractal_reason call re-loads the echo plugin and
  # reports the values, which can only have come from the reload.
  cp "$FSQD_CONF" "$FSQD_CONF.bak"
  printf 'think = low\nthink_provider = conf-live-think\nthink_native_url = http://127.0.0.1:9/api/chat\nthink_num_ctx = 2048\n' >> "$FSQD_CONF"
  chmod 600 "$FSQD_CONF"
  local outd1 rd1
  rd1=$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" \
        "$HERE/service/build/fsqlctl" reload 2>&1)
  [ "$rd1" = "reloaded: configuration swapped in" ] \
    && pass "29 think: reload accepts live provider keys" \
    || fail "29 think: fsqlctl reload with provider keys rc/err: $rd1"
  outd1=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  echo "$outd1" | grep -q "THINK=low" && echo "$outd1" | grep -q "THINK_PROVIDER=conf-live-think" \
    && echo "$outd1" | grep -q "NATIVE_URL=http://127.0.0.1:9/api/chat" \
    && echo "$outd1" | grep -q "NUM_CTX=2048" \
    && pass "29 think: fsqlctl reload pushed conf think keys into the RUNNING daemon (no restart)" \
    || fail "29 think: reload did not take effect live, got: $outd1"

  # (d, live) removing the keys reverts the tier to the boot-env
  # fallback -- here unset -- on the next dispatch.
  cp "$FSQD_CONF.bak" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"; rm -f "$FSQD_CONF.bak"
  rd1=$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" \
        "$HERE/service/build/fsqlctl" reload 2>&1)
  [ "$rd1" = "reloaded: configuration swapped in" ] \
    && pass "29 think: reload with the think keys removed" \
    || fail "29 think: removal reload rc/err: $rd1"
  local outd2; outd2=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  echo "$outd2" | grep -q "THINK=(unset)" \
    && pass "29 think: removing the conf keys reverts THINK to unset on the next call" \
    || fail "29 think: expected reversion to (unset), got: $outd2"

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

  # Unset EVERYTHING (b) set -- both spellings, bridge and native: a
  # leftover THINK=.../PROVIDER=ollama/NATIVE_URL=11434 would ride every
  # later daemon boot's env and route the reasoning tier at a dead port.
  unset FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER FRACTALSQL_HTTP_NATIVE_URL FRACTALSQL_HTTP_NUM_CTX \
        FSQL_REASONING_HTTP_THINK FSQL_REASONING_HTTP_THINK_PROVIDER FSQL_REASONING_HTTP_NATIVE_URL FSQL_REASONING_HTTP_NUM_CTX \
        FSQL_REASONING_HTTP_URL FRACTALSQL_HTTP_URL 2>/dev/null
  mdb_restore_reasoning_plugin
}

# Gate 33: the daemon conf's privacy gate (validate_cfg) and the
# providers' loud validation (validate_provider_cfg), both at startup
# and at `fsqlctl reload`:
#   (a) a 0644 (world-readable) conf refuses to boot an auxiliary
#       daemon -- named message on its stderr, no socket;
#   (b) the same refusal at reload, against the RUNNING daemon, with
#       the running configuration kept; 0600 again -> accepted;
#   (c) four bad provider values each refuse, naming the offending
#       key in the daemon's log while the running configuration stays;
#   (d) an unknown key (a typo'd reasoning_url) warns and is ignored;
#   (e) a CRLF-written conf boots -- the parser trims the \r.
gate_33_conf_gate() {
  local tag="${CUR_VER//./_}"
  local fsqd_bin="$HERE/service/build/fractalsqld"
  local ctl_bin="$HERE/service/build/fsqlctl"
  local main_log="/tmp/fractalsql_bt_fsqd_${tag}.log"
  local rd L i

  # The daemon's stderr log appends across restarts and /tmp outlives
  # this run, so each assertion greps only bytes written since a byte
  # offset captured just before the action under test.
  # wc -c's output is right-padded with spaces on BSD/macOS ("   18306")
  # but not on GNU/Linux -- tr strips it either way so log_from's
  # arithmetic always sees a clean integer. Without this, macOS's stock
  # bash (still 3.2, frozen there for licensing reasons) rejects the
  # padded value with "syntax error: operand expected" inside $(( ));
  # Linux's bash tolerates it, which is why this only ever broke there.
  log_mark() { wc -c < "$main_log" 2>/dev/null | tr -d '[:space:]' || echo 0; }
  log_from() { tail -c +"$(( $1 + 1 ))" "$main_log" 2>/dev/null; }
  fsq_reload() {
    FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1
  }
  # Drop one exact line from FSQD_CONF in place, keeping its 0600 (cat
  # into the same inode -- a moved-in temp file would land 0644).
  fsq_del_conf_line() {
    local tmp; tmp="$(mktemp)"
    grep -v -F -x "$2" "$1" > "$tmp" || true
    cat "$tmp" > "$1"; rm -f "$tmp"
  }

  local aux_conf="$TMPROOT/fsqdbg_${tag}.conf" aux_key="$TMPROOT/fsqdbg_${tag}.key" \
        aux_sock="$TMPROOT/fsqdbg_${tag}.sock" aux_log="/tmp/fractalsql_bt_fsqdbg_${tag}.log"

  # (a) 0644 conf -> auxiliary daemon refuses to boot.
  cp "$FSQD_KEY" "$aux_key"; chmod 600 "$aux_key"
  printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n' \
    "$aux_sock" "$aux_key" "$(id -u)" > "$aux_conf"
  chmod 644 "$aux_conf"
  rm -f "$aux_sock"; : > "$aux_log"
  "$fsqd_bin" -c "$aux_conf" </dev/null >>"$aux_log" 2>&1 &
  local aux_pid=$!
  for i in $(seq 1 30); do
    kill -0 "$aux_pid" 2>/dev/null || break
    [ -S "$aux_sock" ] && break
    sleep 0.1
  done
  if grep -q "grants access to other users" "$aux_log" \
      && ! kill -0 "$aux_pid" 2>/dev/null \
      && [ ! -S "$aux_sock" ]; then
    pass "33 conf_gate: 0644 conf -> auxiliary daemon refuses to boot"
  else
    kill "$aux_pid" 2>/dev/null || true
    fail "33 conf_gate: 0644 conf did not refuse startup; log: $(cat "$aux_log")"
  fi

  # (b) world-readable conf -> reload refuses and keeps the running
  # configuration; 0600 again -> accepted. fsqlctl prefixes the daemon's
  # reply ("fsqlctl: reload failed: ARGS: "), so match the tail text.
  chmod 644 "$FSQD_CONF"
  rd=$(fsq_reload)
  if echo "$rd" | grep -qF "reload failed: key/config file permissions rejected"; then
    chmod 600 "$FSQD_CONF"
    if rd=$(fsq_reload) && [ "$rd" = "reloaded: configuration swapped in" ]; then
      pass "33 conf_gate: 0644 conf -> reload refuses (running config kept), 0600 again -> accepted"
    else
      fail "33 conf_gate: reload after chmod 0600 failed: $rd"
    fi
  else
    chmod 600 "$FSQD_CONF"
    fsq_reload >/dev/null 2>&1 || true
    fail "33 conf_gate: world-readable conf did not refuse the reload: '$rd'"
  fi

  # (c) loud provider refusals: append one bad line, reload, assert the
  # refusal plus the key named in the daemon's log, drop the line again.
  # A refused reload keeps the running configuration.
  local spec bad_key bad_msg
  for spec in \
    "t2s_max_attempts = 15|t2s_max_attempts: must be an integer in \\[1,10\\] (got 15)" \
    "think_num_ctx = nonsense|think_num_ctx: must be an integer in \\[1,10000000\\] (got -1)" \
    "reasoning_url = |reasoning_url: value must not be empty" \
    "t2s_allowed_statements = delete|t2s_allowed_statements: must be"; do
    bad_key="${spec%%|*}"; bad_msg="${spec#*|}"
    L=$(log_mark)
    printf '%s\n' "$bad_key" >> "$FSQD_CONF"
    rd=$(fsq_reload)
    if echo "$rd" | grep -qF "reload failed: provider settings rejected" \
        && log_from "$L" | grep -q "$bad_msg"; then
      pass "33 conf_gate: '$bad_key' -> reload refused, key named in the daemon's log"
    else
      fail "33 conf_gate: expected refusal for '$bad_key', got '$rd' / log: $(log_from "$L" | tail -3)"
    fi
    fsq_del_conf_line "$FSQD_CONF" "$bad_key"
  done

  # (d) unknown key: WARN + ignored, reload still succeeds.
  L=$(log_mark)
  printf 'reasning_url = http://127.0.0.1:9/warnprobe\n' >> "$FSQD_CONF"
  rd=$(fsq_reload); out=$(log_from "$L" | tail -3)
  if [ "$rd" = "reloaded: configuration swapped in" ] \
      && echo "$out" | grep -q "config: unknown key 'reasning_url' ignored"; then
    pass "33 conf_gate: unknown key warns and is ignored (reload succeeds)"
  else
    fail "33 conf_gate: unknown-key reload/log: '$rd' / $out"
  fi
  fsq_del_conf_line "$FSQD_CONF" "reasning_url = http://127.0.0.1:9/warnprobe"

  # (e) CRLF-written conf boots (the parser trims the \r off values).
  printf 'socket_path = %s\r\nhmac_key_file = %s\r\nallowed_uids = %s\r\n' \
    "$aux_sock" "$aux_key" "$(id -u)" > "$aux_conf"
  chmod 600 "$aux_conf"
  rm -f "$aux_sock"; : > "$aux_log"
  "$fsqd_bin" -c "$aux_conf" </dev/null >>"$aux_log" 2>&1 &
  aux_pid=$!
  for i in $(seq 1 50); do [ -S "$aux_sock" ] && break; sleep 0.1; done
  if [ -S "$aux_sock" ]; then
    pass "33 conf_gate: CRLF conf boots (values parsed through the trailing \\r)"
  else
    fail "33 conf_gate: CRLF conf never opened its socket; log: $(cat "$aux_log")"
  fi
  if kill -0 "$aux_pid" 2>/dev/null; then kill "$aux_pid"; wait "$aux_pid" 2>/dev/null; fi
  rm -f "$aux_conf" "$aux_key" "$aux_log"
}

# Gate 34: the reasoning tier's conf-live rotation -- the conf's
# `reasoning_url` pushed into the RUNNING daemon by reload alone (no
# restart, mariadbd untouched), against the real reasoning plugin and
# mock_llm.py. The tier re-resolves its provider config on the next
# fractal_text_to_sql call after every apply, so each step's probe
# reflects the value pushed in that step; the mock always replies a
# fenced ```sql SELECT 1```, so a 'SELECT 1' hit IS the mock's reply
# and its absence after a conf change proves the value moved.
gate_34_reasoning_conf_live() {
  local ctl_bin="$HERE/service/build/fsqlctl"
  local mock_url="${FRACTALSQL_HTTP_URL:-}"
  if [ -z "$mock_url" ]; then
    fail "34 reasoning_conf: FRACTALSQL_HTTP_URL not exported (mdb_setup missing?)"
    return
  fi

  fsq_reload() {
    FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1
  }
  # One full GENERATE probe through the REAL reasoning tier, echoing
  # both outcome fields onto one line.
  t2s_probe() {
    "${MARIADB[@]}" -N -e "
      CALL fractal_text_to_sql('q', NULL, @s, @e);
      SELECT IFNULL(@s,'<NULL>'), IFNULL(@e,'<NULL>');" 2>&1 | tr '\t\n' '  '
  }

  cp "$FSQD_CONF" "$FSQD_CONF.g34"
  # (1) dead endpoint: the pushed reasoning_url moves live, and the
  # next call finds no provider there (127.0.0.1:1 refuses instantly,
  # so no timeout is involved).
  printf 'reasoning_url = http://127.0.0.1:1/v1/chat/completions\n' >> "$FSQD_CONF"
  chmod 600 "$FSQD_CONF"
  local rd out
  rd=$(fsq_reload) || true; out=$(t2s_probe)
  if [ "$rd" = "reloaded: configuration swapped in" ] \
      && [ "$out" = "${out#*SELECT 1*}" ]; then
    pass "34 reasoning_conf: dead reasoning_url moved live (no mock reply on the next call)"
  else
    fail "34 reasoning_conf: dead reasoning_url not enforced: reload='$rd' reply='$out'"
  fi
  # (2) back to the mock endpoint: the canned reply returns through the
  # pushed value alone.
  cp "$FSQD_CONF.g34" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  printf 'reasoning_url = %s\n' "$mock_url" >> "$FSQD_CONF"
  rd=$(fsq_reload) || true
  out=$(t2s_probe)
  if [ "$rd" = "reloaded: configuration swapped in" ] \
      && [ "$out" != "${out#*SELECT 1*}" ]; then
    pass "34 reasoning_conf: good reasoning_url moved live (mock reply on the next call)"
  else
    fail "34 reasoning_conf: good reasoning_url did not round-trip: reload='$rd' reply='$out'"
  fi
  # (3) key removed: the daemon leaves its boot-environment fallback
  # (the same mock URL) in effect -- the reply keeps working.
  cp "$FSQD_CONF.g34" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"; rm -f "$FSQD_CONF.g34"
  rd=$(fsq_reload) || true; out=$(t2s_probe)
  if [ "$rd" = "reloaded: configuration swapped in" ] \
      && [ "$out" != "${out#*SELECT 1*}" ]; then
    pass "34 reasoning_conf: key removed, tier still served by its env fallback"
  else
    fail "34 reasoning_conf: after key removal the tier lost its provider: reload='$rd' reply='$out'"
  fi
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
# Same soak idea (repeated
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
# error text for this class of rejection) -- the assertions here are
# "result IS NULL, mariadbd still up", matching gate 07's posture.
# tests/evil_embed_plugin.c returns
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
# claim rather than a row-locking SELECT claim) actually
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
# reading it): a MariaDB stored
# PROCEDURE body is not wrapped in one implicit transaction the way
# some engines wrap a whole procedure call -- each UPDATE inside the
# per-row loop
# autocommits on its own. The daemon crash surfaces
# to the procedure as fractal_embed returning NULL, not as a hang --
# so the row is marked 'pending' with attempts incremented immediately,
# the same path an ordinary embedding failure takes (see
# docs/fractalsql-daemon.md's "embedding queue" section), not a time-based
# staleness reclaim. The correct, MariaDB-real recovery path is "the next
# process_queue call sees 'pending' and retries it," not "the row
# reverted on its own." This gate proves THAT claim, since it is the
# guarantee this platform actually gives.
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

  # A daemon crash surfaces as a failed embedding dispatch. process_queue
  # records that as a retry: the row goes back to 'pending' with one
  # attempt counted, and the next call processes it.
  local stuck; stuck=$("${MARIADB[@]}" -N -e "SELECT CONCAT(status, ':', attempts) FROM fractal_vectorizer_queue WHERE vectorizer_id=$vzid;" 2>&1)
  [ "$stuck" = "pending:1" ] \
    && pass "18 embed_crash: the failed dispatch is scheduled for retry (pending, attempts=1)" \
    || fail "18 embed_crash: expected 'pending:1' immediately post-crash/restore, got: $stuck"

  # The retry runs now that the real plugin is restored.
  local n; n=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 0);" 2>&1)
  [ "$n" = "1" ] && pass "18 embed_crash: the retry processed the row after the daemon was restored" \
                  || fail "18 embed_crash: expected 1 row retried+processed, got: $n"

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

  # parse_diffusion_mode (fractalsql.c): omitting the params key above
  # never calls it at all. Named explicitly here for both its accepted
  # values and its error branch (an unrecognized mode string).
  local opt_gauss; opt_gauss=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{\"diffusion_mode\":\"gaussian\"}');" 2>&1)
  echo "$opt_gauss" | grep -q '"sharpe"' && pass "20 analytics: fractal_optimize_portfolio diffusion_mode=gaussian" \
                                          || fail "20 analytics: diffusion_mode=gaussian='$opt_gauss'"
  local opt_levy; opt_levy=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{\"diffusion_mode\":\"levy\"}');" 2>&1)
  echo "$opt_levy" | grep -q '"sharpe"' && pass "20 analytics: fractal_optimize_portfolio diffusion_mode=levy" \
                                         || fail "20 analytics: diffusion_mode=levy='$opt_levy'"
  local opt_bad; opt_bad=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_optimize_portfolio('[0.1,0.15]', '[0.04,0.01,0.01,0.03]', 2, '{\"diffusion_mode\":\"bogus\"}'), '<NULL>');" 2>&1)
  [ "$opt_bad" = "<NULL>" ] && pass "20 analytics: fractal_optimize_portfolio rejects an unrecognized diffusion_mode" \
                             || fail "20 analytics: expected NULL for a bad diffusion_mode, got: $opt_bad"

  # Named Feature Store: fractal_store_morphology (upsert) +
  # fractal_mine_topology_negatives (brute-force k-NN via the existing
  # fractal_vector_l2_squared UDF). No LLM.
  "${MARIADB[@]}" -e "
    DELETE FROM fractalsql_feature_store WHERE doc_id IN (1,2,3);
    CALL fractal_store_morphology(1, '[0,0,0]');
    CALL fractal_store_morphology(2, '[1,1,1]');
    CALL fractal_store_morphology(3, '[5,5,5]');
  " >/tmp/fractalsql_bt_gate20_fs.log 2>&1

  local knn; knn=$("${MARIADB[@]}" -N -e "
    CALL fractal_mine_topology_negatives('[0.9,0.9,0.9]', 2, @r);
    SELECT @r;" 2>&1)
  echo "$knn" | grep -q '"doc_id": *2' \
    && pass "20 analytics: fractal_mine_topology_negatives ranks the nearest stored vector (doc_id=2) first" \
    || fail "20 analytics: fractal_mine_topology_negatives='$knn'"
  # Arithmetic coercion: BSD wc (macOS) pads pipe counts with leading
  # spaces; $(( )) strips them so GNU and BSD agree.
  [ "$(( $(echo "$knn" | grep -o '"doc_id"' | wc -l) ))" = "2" ] \
    && pass "20 analytics: fractal_mine_topology_negatives honors k=2 (returned exactly 2 rows)" \
    || fail "20 analytics: expected 2 result rows, got: $knn"

  # Upsert: re-store doc_id 3 with a vector identical to the surrogate --
  # it must now rank first, proving ON DUPLICATE KEY UPDATE actually
  # overwrote the row rather than leaving the original [5,5,5] in place.
  local knn2; knn2=$("${MARIADB[@]}" -N -e "
    CALL fractal_store_morphology(3, '[0.9,0.9,0.9]');
    CALL fractal_mine_topology_negatives('[0.9,0.9,0.9]', 1, @r2);
    SELECT @r2;" 2>&1)
  echo "$knn2" | grep -q '"doc_id": *3' \
    && pass "20 analytics: fractal_store_morphology upsert overwrites an existing doc_id's features" \
    || fail "20 analytics: expected doc_id=3 after upsert, got: $knn2"

  local bad_doc; bad_doc=$("${MARIADB[@]}" -N -e "CALL fractal_store_morphology(-1, '[1,2,3]');" 2>&1)
  echo "$bad_doc" | grep -qi "doc_id must be" \
    && pass "20 analytics: fractal_store_morphology rejects a negative doc_id" \
    || fail "20 analytics: expected a doc_id rejection, got: $bad_doc"

  local bad_arr; bad_arr=$("${MARIADB[@]}" -N -e "CALL fractal_store_morphology(4, 'not json');" 2>&1)
  echo "$bad_arr" | grep -qi "must be a non-empty JSON array" \
    && pass "20 analytics: fractal_store_morphology rejects a malformed feature_array" \
    || fail "20 analytics: expected a feature_array rejection, got: $bad_arr"

  local bad_k; bad_k=$("${MARIADB[@]}" -N -e "CALL fractal_mine_topology_negatives('[0,0,0]', 0, @r3);" 2>&1)
  echo "$bad_k" | grep -qi "k must be" \
    && pass "20 analytics: fractal_mine_topology_negatives rejects k < 1" \
    || fail "20 analytics: expected a k rejection, got: $bad_k"

  "${MARIADB[@]}" -e "DELETE FROM fractalsql_feature_store WHERE doc_id IN (1,2,3);" >/dev/null 2>&1
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

  # 4 more session-scoped functions with no gate at all before this:
  # detect_collapse, session_close, feedback_report, isolate_background.
  local coll; coll=$("${MARIADB[@]}" -N -e "SELECT fractal_detect_collapse(CONNECTION_ID());" 2>&1)
  [ "$coll" = "NULL" ] \
    && pass "21 diversify: detect_collapse is NULL before any diversify-aware search ran" \
    || fail "21 diversify: expected NULL, got: $coll"

  local fb; fb=$("${MARIADB[@]}" -N -e "SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'positive');" 2>&1)
  [ "$fb" = "0" ] && pass "21 diversify: feedback_report(positive, 3 args)" \
                   || fail "21 diversify: feedback_report='$fb'"

  local fb4; fb4=$("${MARIADB[@]}" -N -e "SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'dwell', 500);" 2>&1)
  [ "$fb4" = "0" ] && pass "21 diversify: feedback_report(dwell, 4 args with dwell_ms)" \
                    || fail "21 diversify: feedback_report (4-arg)='$fb4'"

  local fb_bad; fb_bad=$("${MARIADB[@]}" -N -e "SELECT fractal_feedback_report(CONNECTION_ID(), 1, 'bogus');" 2>&1)
  [ "$fb_bad" = "NULL" ] \
    && pass "21 diversify: feedback_report rejects an unrecognized kind" \
    || fail "21 diversify: expected NULL for a bad kind, got: $fb_bad"

  local iso; iso=$("${MARIADB[@]}" -N -e "SELECT fractal_isolate_background(CONNECTION_ID(), 1);" 2>&1)
  [ "$iso" = "0" ] && pass "21 diversify: isolate_background" \
                    || fail "21 diversify: isolate_background='$iso'"

  local close; close=$("${MARIADB[@]}" -N -e "SELECT fractal_session_close(CONNECTION_ID());" 2>&1)
  [ "$close" = "0" ] && pass "21 diversify: session_close" \
                      || fail "21 diversify: session_close='$close'"

  local dis; dis=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_disable(CONNECTION_ID());" 2>&1)
  [ "$dis" = "0" ] && pass "21 diversify: disable" || fail "21 diversify: disable='$dis'"

  # The session registry's LRU eviction path (evict_one_lru/bucket_
  # unlink/lru_unlink/entry_destroy in src/fractalsql_session.c) only
  # runs once live entries reach FSQL_SESSION_MAX_ENTRIES (4096) --
  # session_id is a plain caller-supplied BIGINT, not tied to the
  # connection's own CONNECTION_ID(), so one connection issuing 4200
  # distinct literal session_ids is enough to force it without opening
  # thousands of real connections. Proof bar is "doesn't crash /
  # corrupt the registry," same as every other session_id here: the
  # LAST call (long past the eviction point) must still succeed
  # cleanly, which it can't if evicting an earlier entry corrupted the
  # bucket/LRU list it was unlinked from.
  local evict_sql; evict_sql=$(python3 -c "
for i in range(1, 4201):
    print(f'SELECT fractal_diversify_enable({i});')
")
  local evict_out; evict_out=$("${MARIADB[@]}" -N 2>&1 <<SQL
$evict_sql
SQL
)
  echo "$evict_out" | grep -qi "error" \
    && fail "21 diversify: session eviction -- unexpected error in a 4200-session batch: $(echo "$evict_out" | grep -i error | head -1)" \
    || pass "21 diversify: 4200 distinct sessions forced LRU eviction with no error"
  local evict_tail; evict_tail=$(echo "$evict_out" | tail -1)
  [ "$evict_tail" = "0" ] \
    && pass "21 diversify: the last session past the eviction point still enables cleanly" \
    || fail "21 diversify: expected 0 from the last call, got: $evict_tail"
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

  # The 3 of the 13 vector-tier functions no gate called at all before
  # this: normalize, scale, negative_inner_product.
  # float32 storage, not exact decimal: 0.6/0.8 round-trip through
  # fractal_vector's actual (every binding's) float32 precision as
  # 0.600000024/0.800000012 -- confirmed live.
  local norm2; norm2=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_normalize('[3,4,0]');" 2>&1)
  echo "$norm2" | grep -q '^\[0\.600000024,0\.800000012,0\]$' \
    && pass "22 vector_tier: normalize([3,4,0]) -> unit vector [0.6,0.8,0]" \
    || fail "22 vector_tier: normalize='$norm2'"
  local norm2_null; norm2_null=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_normalize(NULL);" 2>&1)
  [ "$norm2_null" = "NULL" ] && pass "22 vector_tier: normalize(NULL) -> NULL" \
                              || fail "22 vector_tier: expected NULL, got: $norm2_null"

  local scale; scale=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_scale('[1,2,3]', 2);" 2>&1)
  echo "$scale" | grep -q '^\[2,4,6\]$' && pass "22 vector_tier: scale([1,2,3], 2) -> [2,4,6]" \
                                         || fail "22 vector_tier: scale='$scale'"
  local scale_null; scale_null=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_scale(NULL, 2);" 2>&1)
  [ "$scale_null" = "NULL" ] && pass "22 vector_tier: scale(NULL, ...) -> NULL" \
                              || fail "22 vector_tier: expected NULL, got: $scale_null"

  local nip; nip=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_negative_inner_product('[1,0,0]', '[1,0,0]');" 2>&1)
  [ "$nip" = "-1" ] && pass "22 vector_tier: negative_inner_product(identical unit vectors) = -1" \
                     || fail "22 vector_tier: negative_inner_product='$nip'"
  local nip_null; nip_null=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_negative_inner_product(NULL, '[1,0,0]');" 2>&1)
  [ "$nip_null" = "NULL" ] && pass "22 vector_tier: negative_inner_product(NULL, ...) -> NULL" \
                            || fail "22 vector_tier: expected NULL, got: $nip_null"

  local l2; l2=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_l2_distance('[0,0,0]', '[3,4,0]');" 2>&1)
  [ "$l2" = "5" ] && pass "22 vector_tier: l2_distance([0,0,0],[3,4,0])=5" \
                   || fail "22 vector_tier: l2_distance='$l2'"

  # cosine_distance had no caller at all before this: every other gate
  # only ever exercises its sibling cosine_similarity.
  local cd; cd=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_cosine_distance('[1,0,0]', '[1,0,0]');" 2>&1)
  [ "$cd" = "0" ] && pass "22 vector_tier: cosine_distance(identical)=0" \
                   || fail "22 vector_tier: cosine_distance='$cd'"
  local cd_null; cd_null=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_cosine_distance(NULL, '[1,0,0]');" 2>&1)
  [ "$cd_null" = "NULL" ] && pass "22 vector_tier: cosine_distance(NULL, ...) -> NULL" \
                           || fail "22 vector_tier: expected NULL, got: $cd_null"

  local f8f; f8f=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_from_float8_array('[1,2,3]');" 2>&1)
  echo "$f8f" | grep -q '^\[1,2,3\]$' && pass "22 vector_tier: from_float8_array canonicalizes [1,2,3]" \
                                       || fail "22 vector_tier: from_float8_array='$f8f'"
  local f8t; f8t=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_to_float8_array('[1,2,3]');" 2>&1)
  echo "$f8t" | grep -q '^\[1,2,3\]$' && pass "22 vector_tier: to_float8_array canonicalizes [1,2,3]" \
                                       || fail "22 vector_tier: to_float8_array='$f8t'"
}

# Cognition tier: fractal_reason against the mock LLM.
gate_23_cognition() {
  local r; r=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1)
  echo "$r" | grep -qi "sql" && pass "23 cognition: fractal_reason returned the mock's reply" \
                              || fail "23 cognition: fractal_reason='$r'"

  local rnull; rnull=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), NULL);" 2>&1)
  [ "$rnull" = "NULL" ] && pass "23 cognition: NULL query -> NULL result" \
                         || fail "23 cognition: expected NULL, got: $rnull"

  # fractal_t2s_review's normal (non-adversarial) dispatch path has no
  # other gate: 05/07 only call it with evil plugins, which never reach
  # the real PASS/FAIL-text branches below the dispatch itself. The
  # mock's default reply never starts with "pass", so an ordinary call
  # already exercises the FAIL/return-critique-text branch; the marker
  # routes a second call to a reply that does, for the PASS branch.
  local rev_fail; rev_fail=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1');" 2>&1)
  [ "$rev_fail" != "NULL" ] && pass "23 cognition: t2s_review returns the critique text on a non-PASS reply" \
                             || fail "23 cognition: expected non-NULL critique text, got: $rev_fail"

  local rev_pass; rev_pass=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_t2s_review(CONNECTION_ID(), 'FRACTALSQL_BT_REVIEW_PASS_MARKER', 'SELECT 1');" 2>&1)
  [ "$rev_pass" = "NULL" ] && pass "23 cognition: t2s_review returns NULL (PASS) on a passing reply" \
                            || fail "23 cognition: expected NULL (PASS), got: $rev_pass"
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

  # detect_loop (O), rewritten onto SimHash fingerprints + streaming
  # Brent cycle detection + a DFA-over-L2-norms check. The near-identical
  # "cognitive wobble" log must close a cycle and flag loop_detected --
  # live-verified: its two states' SimHash fingerprints COLLAPSE to one
  # fingerprint (the vectors differ by 0.005 on two of three dims, under
  # random-hyperplane rounding), so this is a period-1 cycle (cycle_len
  # 1) rather than period-2; a second log with genuinely distinct states
  # below asserts the real period-2 path.
  local dl_log; dl_log="$(python3 -c "
import json
print(json.dumps([[0.5,0.5,0.5] if i % 2 == 0 else [0.505,0.495,0.5] for i in range(20)], separators=(',',':')))
")"
  local dl; dl=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_detect_loop('bt_wobble', '$dl_log', 16, 42.0, 2, @dlr);
    SELECT @dlr;" 2>&1)
  echo "$dl" | grep -Eq '"loop_detected" *: *(true|1)' \
    && pass "24 agents: detect_loop flags the near-identical wobble log" \
    || fail "24 agents: detect_loop wobble='$dl'"
  echo "$dl" | grep -Eq '"cycle_detected" *: *"?(true|1)"?' \
    && pass "24 agents: detect_loop cycle check fired on the wobble log" \
    || fail "24 agents: detect_loop cycle='$dl'"
  # Genuinely distinct alternating states (directions 30+ degrees apart,
  # so no fingerprint collapse): the 20-state log must close a real
  # period-2 cycle -- cycle_len 2, at_index 3 (Brent's checkpoint
  # schedule closes it on the 4th state).
  local dl_log3; dl_log3="$(python3 -c "
import json
print(json.dumps([[0.5,0.5,0.5] if i % 2 == 0 else [0.9,0.1,0.5] for i in range(20)], separators=(',',':')))
")"
  local dl3; dl3=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_detect_loop('bt_wobble2', '$dl_log3', 64, 42.0, 0, @dlr3);
    SELECT @dlr3;" 2>&1)
  # ("cycle_len" comes back "2" quoted on 11.4 but 2 unquoted on 10.6 --
  # MariaDB's JSON_OBJECT integer serialization differs by major --
  # accept both spellings.)
  echo "$dl3" | grep -Eq '"cycle_len" *: *"?2"?' \
    && echo "$dl3" | grep -Eq '"loop_detected" *: *(true|1)' \
    && pass "24 agents: detect_loop closes a true period-2 cycle on distinct states (cycle_len 2)" \
    || fail "24 agents: detect_loop distinct-states='$dl3' (expected cycle_len 2, loop_detected true)"
  # A constant state log: the cycle check still fires, but every L2
  # norm is identical so the DFA-over-norms branch must be SKIPPED
  # (the core DFA errors on degenerate constant input) -- dfa_exponent
  # stays null, and the call must not abort the statement.
  local dl_log2; dl_log2="$(python3 -c "
import json
print(json.dumps([[0.5,0.5,0.5] for _ in range(8)], separators=(',',':')))
")"
  local dl2; dl2=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_detect_loop('bt_constant', '$dl_log2', 16, 42.0, 0, @dlr2);
    SELECT @dlr2;" 2>&1)
  # ("cycle_detected" comes back "1" quoted here but 1 unquoted on the
  # wobble CALL above -- MariaDB's JSON_OBJECT boolean serialization is
  # inconsistent by value -- accept both spellings.)
  echo "$dl2" | grep -Eq '"cycle_detected" *: *"?(true|1)"?' \
    && pass "24 agents: detect_loop constant-state log closes a cycle" \
    || fail "24 agents: detect_loop constant='$dl2'"
  echo "$dl2" | grep -Eq '"dfa_exponent" *: *null' \
    && pass "24 agents: detect_loop skips the DFA on degenerate constant norms (dfa_exponent null, no abort)" \
    || fail "24 agents: detect_loop constant dfa='$dl2' (expected dfa_exponent null)"

  # outlier_intercept (H-adjacent safety barrier), now with an explicit
  # metric argument. cosine (the default) intercepts a probe near a
  # known-bad state; l2 on a far probe does not; a nonsense metric
  # must SIGNAL, not silently fall back.
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_bad_states;
    CREATE TABLE bt_bad_states (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb TEXT);
    INSERT INTO bt_bad_states (emb) VALUES ('[1,0,0]'), ('[0.9,0.1,0]');
  " >/tmp/fractalsql_bt_gate24_bad.log 2>&1

  local oi1; oi1=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_outlier_intercept('[1.0,0.05,0]', 'bt_bad_states', 'emb', 0.5, 'cosine', @oi1);
    SELECT @oi1;" 2>&1)
  # (outlier_intercept serializes "intercepted" as a quoted "1"/"0"
  # string, not a JSON boolean -- accept both spellings.)
  echo "$oi1" | grep -Eq '"intercepted" *: *"?(true|1)"?' \
    && pass "24 agents: outlier_intercept cosine intercepts a probe near a known-bad state" \
    || fail "24 agents: outlier_intercept cosine='$oi1'"
  local oi2; oi2=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_outlier_intercept('[0.0,1.0,0.0]', 'bt_bad_states', 'emb', 0.5, 'l2', @oi2);
    SELECT @oi2;" 2>&1)
  echo "$oi2" | grep -Eq '"intercepted" *: *"?(false|0)"?' \
    && echo "$oi2" | grep -Eq '"metric" *: *"l2"' \
    && pass "24 agents: outlier_intercept l2 does not intercept a far probe (metric echoed)" \
    || fail "24 agents: outlier_intercept l2='$oi2'"
  local oi3; oi3=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_outlier_intercept('[1,0,0]', 'bt_bad_states', 'emb', 0.5, 'manhattan', @oi3);" 2>&1)
  echo "$oi3" | grep -qi "metric must be" \
    && pass "24 agents: outlier_intercept SIGNALs on an unknown metric" \
    || fail "24 agents: expected a metric rejection, got: $oi3"

  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS bt_bad_states;" >/dev/null 2>&1
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
# ALLOWLIST -> auto_execute pipeline; gate 24 above exercises the
# PL/SQL-recipe agents built on top of them, not this layer itself.
#
# FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update is
# required for fractal_t2s_check_allowlist to accept an INSERT
# candidate at all (select-only by default) -- a restart-based env var
# (read once at mysqld startup), so this gate does its own
# mdb_teardown/mdb_setup restart. Deliberately NOT
# mdb_swap_reasoning_plugin: that helper also overrides
# FRACTALSQL_REASONING_PLUGIN, and this gate needs the REAL HTTP
# plugin against scripts/ci/mock_llm.py to stay active -- mock_llm.py
# has been taught a marker-routed canned INSERT reply for exactly this
# gate (see its own GATE31_MARKER), not a fake reasoning-VFS plugin.
gate_31_sql_agent_savepoint() {
  export FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update
  mdb_teardown
  if ! mdb_setup "$MDB_MAJOR" >/tmp/fractalsql_bt_gate31_restart.log 2>&1; then
    fail "31 sql_agent_savepoint: could not restart cluster with FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update set"
    unset FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS
    mdb_restore_reasoning_plugin >/dev/null 2>&1
    return
  fi

  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_sql_agent_sp;
    CREATE TABLE bt_sql_agent_sp (id INT PRIMARY KEY, val VARCHAR(20));
    INSERT INTO bt_sql_agent_sp (id, val) VALUES (99, 'prior');
  " >/tmp/fractalsql_bt_gate31.log 2>&1

  # One connection, one open transaction: a real prior COMMITted write
  # (id=99, above), then three fractal_sql_agent calls whose GENERATE
  # step always comes back with the SAME candidate ("INSERT ... VALUES
  # (1, 'x')", via mock_llm.py's marker route) -- the first succeeds
  # (id=1 doesn't exist yet), the second and third both collide with
  # the PRIMARY KEY id=1 already wrote and must each roll back to the
  # SAVEPOINT cleanly, proving the fixed savepoint name can be reused
  # repeatedly within one transaction after a prior ROLLBACK, not just
  # after a RELEASE.
  local out; out=$("${MARIADB[@]}" -N -e "
    START TRANSACTION;
    CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '[\"bt_sql_agent_sp\"]', 1, TRUE, @sql1, @status1, @result1);
    CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '[\"bt_sql_agent_sp\"]', 1, TRUE, @sql2, @status2, @result2);
    CALL fractal_sql_agent('FRACTALSQL_BT_GATE31_MARKER insert one canary row', '[\"bt_sql_agent_sp\"]', 1, TRUE, @sql3, @status3, @result3);
    SELECT @status1, @result1, @status2, @result2, @status3, @result3;
    COMMIT;
  " 2>&1)

  echo "$out" | grep -qi "^ERROR" \
    && fail "31 sql_agent_savepoint: a raw SQL error escaped the procedure instead of a reported status: $out"

  local status1 result1 status2 result2 status3 result3
  status1=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $1}')
  result1=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $2}')
  status2=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $3}')
  result2=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $4}')
  status3=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $5}')
  result3=$(printf '%s\n' "$out" | awk -F'\t' 'NR==1{print $6}')

  [ "$status1" = "executed" ] && echo "$result1" | grep -q '"rows": *1' \
    && pass "31 sql_agent_savepoint: first INSERT executed cleanly (rows:1)" \
    || fail "31 sql_agent_savepoint: first call expected status=executed/rows:1, got status='$status1' result='$result1'"

  [ "$status2" = "execution_failed" ] \
    && pass "31 sql_agent_savepoint: second (colliding) INSERT reported execution_failed via ROLLBACK TO SAVEPOINT, not a raw error" \
    || fail "31 sql_agent_savepoint: second call expected status=execution_failed, got status='$status2' result='$result2'"

  [ "$status3" = "execution_failed" ] \
    && pass "31 sql_agent_savepoint: third call reused the same fixed SAVEPOINT name after the second call's rollback, no 'savepoint does not exist'" \
    || fail "31 sql_agent_savepoint: third call expected status=execution_failed, got status='$status3' result='$result3'"

  # The actual SAVEPOINT proof: id=99 (committed before any of the three
  # calls) AND id=1 (the first call's own successful write, same
  # transaction as the second/third calls' failures) BOTH survive --
  # ROLLBACK TO SAVEPOINT scoped each failed call's rollback to just its
  # own statement, never the whole transaction.
  local cnt; cnt=$("${MARIADB[@]}" -N -e "SELECT COUNT(*) FROM bt_sql_agent_sp;" 2>&1)
  [ "$cnt" = "2" ] \
    && pass "31 sql_agent_savepoint: both the prior commit (id=99) and the first call's write (id=1) survive -- no phantom rows from the two rolled-back calls" \
    || fail "31 sql_agent_savepoint: expected exactly 2 surviving rows (id=1,99), COUNT(*)=$cnt"

  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS bt_sql_agent_sp;" >/dev/null 2>&1
  unset FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS
  mdb_restore_reasoning_plugin >/dev/null 2>&1
}

# The newest analytics/vector-math UDFs, known-answer asserted. No LLM.
# Every assertion here is convention-independent where the underlying
# convention lives in the vendored core (e.g. quantize_binary's sign-bit
# polarity): hamming(quantize(v), quantize(v))=0 and
# hamming(quantize(v), quantize(one sign flipped))=1 hold regardless of
# which bit value "positive" packs as.
gate_32_new_primitives() {
  # --- fractal_change_point_detect: step up at t=50 in a 100-sample
  # series with a non-degenerate (sine) wobble, window=16, threshold=2.
  # At least one flagged boundary must land near the true split. A
  # constant-series wobble would risk the pooled-stddev denominator
  # being 0, so the wobble is real, not cosmetic.
  local step; step="$(python3 -c "
import math
print(','.join('%.4f' % (0.2*math.sin(0.5*i) if i < 50 else 5.2+0.2*math.cos(0.5*i)) for i in range(100)))
")"
  local cp; cp=$("${MARIADB[@]}" -N -e "SELECT fractal_change_point_detect('[$step]', 16, 2.0, 16);" 2>&1)
  local cp_ok=0 cp_v
  for cp_v in $(echo "$cp" | tr -d '[]' | tr ',' ' '); do
    awk "BEGIN{exit !($cp_v >= 30 && $cp_v <= 70)}" && cp_ok=1
  done
  [ "$cp_ok" = "1" ] && pass "32 new_primitives: change_point_detect flags a boundary near the t=50 step ($cp)" \
                    || fail "32 new_primitives: change_point_detect='$cp' (no boundary in [30,70])"

  local cp_bad; cp_bad=$("${MARIADB[@]}" -N -e "SELECT fractal_change_point_detect('[1,2,3]', 0, 2.0, 16);" 2>&1)
  # Empirical contract on this server family: a UDF whose main function
  # sets *error (no init message) surfaces as a NULL result, not a
  # statement error -- assert that, not an ERROR banner.
  [ "$cp_bad" = "NULL" ] \
    && pass "32 new_primitives: change_point_detect rejects window < 1 (NULL)" \
    || fail "32 new_primitives: expected NULL for window < 1, got: $cp_bad"

  # --- fractal_periodogram: 64 samples of sin(2*pi*t/8) -> an exact
  # k=8/64 bin at 0.125 cycles/sample as the top-power peak.
  local sine; sine="$(python3 -c "
import math
print(','.join('%.6f' % (0.5*math.sin(2*math.pi*i/8)) for i in range(64)))
")"
  local pg; pg=$("${MARIADB[@]}" -N -e "SELECT fractal_periodogram('$sine', 4);" 2>&1)
  echo "$pg" | grep -q '"freqs"' \
    && pass "32 new_primitives: periodogram returned peaks" \
    || fail "32 new_primitives: periodogram='$pg'"

  local pg_top; pg_top=$("${MARIADB[@]}" -N -e "SELECT JSON_EXTRACT('$pg', '\$.freqs[0]');" 2>&1)
  if awk "BEGIN{exit !($pg_top > 0.124 && $pg_top < 0.126)}" 2>/dev/null; then
    pass "32 new_primitives: periodogram top freq is the true 0.125 bin (got $pg_top)"
  else
    fail "32 new_primitives: periodogram top freq='$pg_top' (expected 0.125)"
  fi

  # --- fractal_state_fingerprint: 128 bits -> exactly 16 packed bytes,
  # all in [0,255], byte-for-byte deterministic across identical calls
  # (seeded random hyperplanes).
  local fp1 fp2 n_fp
  fp1=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('1,2,3', 128, 42);" 2>&1)
  n_fp=$(echo "$fp1" | tr -d '[]' | tr ',' '\n' | grep -c .)
  [ "$n_fp" = "16" ] && pass "32 new_primitives: state_fingerprint 128 bits -> 16 bytes" \
                     || fail "32 new_primitives: state_fingerprint byte count=$n_fp ('$fp1')"
  echo "$fp1" | tr -d '[]' | tr ',' '\n' | grep -v '^$' | awk '$1 < 0 || $1 > 255 {exit 1}' \
    && pass "32 new_primitives: state_fingerprint bytes all in [0,255]" \
    || fail "32 new_primitives: state_fingerprint out-of-range byte in '$fp1'"
  fp2=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('1,2,3', 128, 42);" 2>&1)
  [ "$fp1" = "$fp2" ] && pass "32 new_primitives: state_fingerprint is deterministic (same seed, same bytes)" \
                      || fail "32 new_primitives: state_fingerprint differs across identical calls: '$fp1' vs '$fp2'"

  # --- fractal_cycle_detect: fingerprints of A,B,A,B,A,B (concatenated
  # 64-bit fingerprint bytes). Live-verified: Brent's checkpoint
  # schedule needs roughly twice the period in stream length to close,
  # so a bare A,B,A does NOT report a cycle -- the 6-element stream
  # does (cycle_len=2, at_index=3). Negative case uses A,B,D with
  # mutually non-collinear state vectors: SimHash fingerprints of
  # SCALAR-MULTIPLE states are byte-identical (live-verified: '9,9,9'
  # and '4,4,4' collide -- both on the (1,1,1) diagonal), so the
  # negative case needs a different direction, not a different magnitude.
  local fpA fpB fpD sA sB sD
  fpA=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('1,2,3', 64, 7);" 2>&1)
  fpB=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('9,9,9', 64, 7);" 2>&1)
  fpD=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('4,5,6', 64, 7);" 2>&1)
  sA="${fpA#[}"; sA="${sA%]}"
  sB="${fpB#[}"; sB="${sB%]}"
  sD="${fpD#[}"; sD="${sD%]}"
  local cy; cy=$("${MARIADB[@]}" -N -e "SELECT fractal_cycle_detect('$sA,$sB,$sA,$sB,$sA,$sB', 8, 0);" 2>&1)
  echo "$cy" | grep -Eq '"detected" *: *true' \
    && pass "32 new_primitives: cycle_detect closes the A,B,A,B,A,B period-2 stream ($cy)" \
    || fail "32 new_primitives: cycle_detect(A,B,A,B,A,B)='$cy'"
  echo "$cy" | grep -Eq '"cycle_len" *: *2' \
    && pass "32 new_primitives: cycle_detect reports cycle_len=2" \
    || fail "32 new_primitives: cycle_detect cycle_len='$cy'"
  local cy2; cy2=$("${MARIADB[@]}" -N -e "SELECT fractal_cycle_detect('$sA,$sB,$sD', 8, 0);" 2>&1)
  echo "$cy2" | grep -Eq '"detected" *: *(false|0)' \
    && pass "32 new_primitives: cycle_detect reports no cycle for three distinct states" \
    || fail "32 new_primitives: cycle_detect(A,B,D)='$cy2' (expected detected:false)"

  # --- fractal_tda_persistence_diagram: 12 points in two tight 6-point
  # clusters far apart. Each cluster forms a complete graph under
  # thresh=1.0, so the 1-skeleton cycle rank is 15 edges - 6 vertices
  # + 1 component = 10 per cluster = 20 total; h0 is 5 bars per
  # cluster = 10. max_dim=0 must leave betti1 null (scope note: the
  # 1-skeleton cycle rank, not full simplicial H1).
  local pts; pts="$(python3 -c "
a = [0.0,0.0, 0.1,0.0, 0.05,0.0866, 0.1,0.0866, 0.02,0.05, 0.08,0.03]
b = [10.0+x for x in a]
print(','.join('%.4f' % v for v in a + b))
")"
  local tda; tda=$("${MARIADB[@]}" -N -e "SELECT fractal_tda_persistence_diagram('$pts', 2, 1, 1.0, 64);" 2>&1)
  echo "$tda" | grep -Eq '"betti1" *: *20' \
    && pass "32 new_primitives: tda_persistence_diagram two-cluster betti1=20 (2 x (15-6+1))" \
    || fail "32 new_primitives: tda_persistence_diagram='$tda' (expected betti1=20)"
  echo "$tda" | grep -Eq '"n_h0_bars" *: *10' \
    && pass "32 new_primitives: tda_persistence_diagram n_h0_bars=10 (2 x 5 merge bars)" \
    || fail "32 new_primitives: tda_persistence_diagram n_h0_bars='$tda' (expected 10)"
  local tda0; tda0=$("${MARIADB[@]}" -N -e "SELECT fractal_tda_persistence_diagram('$pts', 2, 0, 1.0, 64);" 2>&1)
  echo "$tda0" | grep -Eq '"betti1" *: *null' \
    && pass "32 new_primitives: tda_persistence_diagram max_dim=0 leaves betti1 null" \
    || fail "32 new_primitives: tda max_dim=0 betti1='$tda0' (expected null)"

  # --- fractal_optimize_subset: value-weighted allocation with bounds
  # 0.6 per item and at-most-2 nonzero. Live-verified: bounds must
  # leave the allocation FEASIBLE -- weights sum to 1.0, so with k=2
  # each cap must allow the pair to reach 1.0 (0.6+0.4 works; the
  # [0.4]*5 caps would cap the pair at 0.8 < 1.0 and the infeasible
  # instance comes back NULL rather than an error). With feasible
  # [0.6]*5 caps the optimum puts 0.6 on the largest value (0.15) and
  # 0.4 on the second (0.12) -> score exactly 0.138.
  local os; os=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_subset('[0.12,0.09,0.15,0.06,0.11]', '[0.6,0.6,0.6,0.6,0.6]', 2, '{}');" 2>&1)
  echo "$os" | grep -q '"weights"' \
    && pass "32 new_primitives: optimize_subset returned a weights array" \
    || fail "32 new_primitives: optimize_subset='$os'"
  local os_score; os_score=$("${MARIADB[@]}" -N -e "SELECT JSON_EXTRACT('$os', '\$.score');" 2>&1)
  awk "BEGIN{exit !($os_score > 0.1378 && $os_score < 0.1382)}" \
    && pass "32 new_primitives: optimize_subset hits the exact 0.138 optimum (got $os_score)" \
    || fail "32 new_primitives: optimize_subset score='$os_score' (expected 0.138)"
  local os_infeas; os_infeas=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_subset('[0.12,0.09,0.15,0.06,0.11]', '[0.4,0.4,0.4,0.4,0.4]', 2, '{}');" 2>&1)
  [ "$os_infeas" = "NULL" ] \
    && pass "32 new_primitives: optimize_subset infeasible instance (caps 0.4x5 < 1.0 at k=2) returns NULL" \
    || fail "32 new_primitives: infeasible optimize_subset='$os_infeas' (expected NULL)"
  local os_w; os_w=$("${MARIADB[@]}" -N -e "SELECT JSON_EXTRACT('$os', '\$.weights');" 2>&1)
  local os_nz; os_nz=0
  for cp_v in $(echo "$os_w" | tr -d '[]' | tr ',' ' '); do
    awk "BEGIN{exit !($cp_v > 0.0000001)}" && os_nz=$((os_nz + 1))
  done
  [ "$os_nz" -le 2 ] && pass "32 new_primitives: optimize_subset honors the at-most-2-nonzero cap ($os_nz nonzero)" \
                     || fail "32 new_primitives: optimize_subset nonzero weights=$os_nz ('$os_w')"

  # --- fractal_vector_lp_distance: p=2 -> 5.0, p=1 -> 7.0.
  local lp; lp=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_lp_distance('[3,4,0]', '[0,0,0]', 2.0);" 2>&1)
  awk "BEGIN{exit !($lp > 4.999 && $lp < 5.001)}" \
    && pass "32 new_primitives: lp_distance p=2 ([3,4] from origin) = 5" \
    || fail "32 new_primitives: lp_distance p=2='$lp'"
  local lp1; lp1=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_lp_distance('[3,4,0]', '[0,0,0]', 1.0);" 2>&1)
  awk "BEGIN{exit !($lp1 > 6.999 && $lp1 < 7.001)}" \
    && pass "32 new_primitives: lp_distance p=1 ([3,4] from origin) = 7" \
    || fail "32 new_primitives: lp_distance p=1='$lp1'"

  # --- fractal_vector_quantize_int8: dequantization v[i] ~= values[i]
  # * scale must hold to within rounding error, and values stay int8.
  local q8; q8=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_quantize_int8('[1,-2,3]');" 2>&1)
  echo "$q8" | grep -q '"scale"' \
    && pass "32 new_primitives: quantize_int8 returned {scale,values}" \
    || fail "32 new_primitives: quantize_int8='$q8'"
  local q8_scale q8_vals
  q8_scale=$("${MARIADB[@]}" -N -e "SELECT JSON_EXTRACT('$q8', '\$.scale');" 2>&1)
  q8_vals=$("${MARIADB[@]}" -N -e "SELECT JSON_EXTRACT('$q8', '\$.values');" 2>&1)
  echo "$q8_scale" | awk -v s_in="$q8_scale" -v vals="$q8_vals" '
    function abs(x) { return x < 0 ? -x : x }
    BEGIN {
      n = split(vals, v, /[,\[\]]/); j = 0
      for (i = 1; i <= n; i++) if (v[i] != "") q[++j] = v[i] + 0
      if (j != 3) exit 1
      s = s_in + 0
      if (s <= 0) exit 1
      # dequantization must land back on the source vector within half a
      # quantization step (round-to-nearest int8)
      if (abs(q[1]*s - 1) > s*0.6) exit 1
      if (abs(q[2]*s + 2) > s*0.6) exit 1
      if (abs(q[3]*s - 3) > s*0.6) exit 1
      if (q[1] < -127 || q[1] > 127 || q[2] < -127 || q[2] > 127 || q[3] < -127 || q[3] > 127) exit 1
    }' \
    && pass "32 new_primitives: quantize_int8 dequantizes [1,-2,3] within rounding error" \
    || fail "32 new_primitives: quantize_int8 scale='$q8_scale' values='$q8_vals' (dequantization out of tolerance)"

  # --- fractal_vector_quantize_binary + fractal_vector_hamming_distance:
  # 2 dims pack into 1 byte; identical vectors -> 0; one flipped sign
  # -> 1. (The sign-bit polarity itself is the vendored core's choice;
  # these assertions hold either way.)
  local qb; qb=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_quantize_binary('[1,-1]');" 2>&1)
  local qb_n; qb_n=$(echo "$qb" | tr -d '[]' | tr ',' '\n' | grep -c .)
  [ "$qb_n" = "1" ] && pass "32 new_primitives: quantize_binary 2 dims -> 1 packed byte" \
                    || fail "32 new_primitives: quantize_binary byte count=$qb_n ('$qb')"
  local hm0 hm1
  hm0=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_hamming_distance('$qb', '$qb');" 2>&1)
  [ "$hm0" = "0" ] && pass "32 new_primitives: hamming_distance(identical) = 0" \
                   || fail "32 new_primitives: hamming_distance(identical)='$hm0'"
  local qb2; qb2=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_quantize_binary('[1,1]');" 2>&1)
  local hm1; hm1=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_hamming_distance('$qb', '$qb2');" 2>&1)
  [ "$hm1" = "1" ] && pass "32 new_primitives: hamming_distance(one flipped sign) = 1" \
                   || fail "32 new_primitives: hamming_distance(flipped sign)='$hm1'"
  local hm_bad; hm_bad=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_hamming_distance('[1]', '[1,2]');" 2>&1)
  # Same *error -> NULL contract as the change_point rejection above.
  [ "$hm_bad" = "NULL" ] \
    && pass "32 new_primitives: hamming_distance rejects unequal byte lengths (NULL)" \
    || fail "32 new_primitives: expected NULL for unequal byte lengths, got: $hm_bad"
}

# The four Analytics-tier mesh/graph morphology UDFs (src/fractalsql.c):
# fractal_vascular_network, fractal_cortical_folding,
# fractal_nerve_plexus_metric, fractal_morphological_complexity. Each
# is registered in sql/install_udf.sql but had no gate at all before
# this one -- not a coverage gap in the usual sense, a missing test.
# fractal_cortical_folding's happy path is small, fixed, hand-computable
# geometry (a regular tetrahedron + its 4 faces): plain convex-hull/mesh-
# area computational geometry, no statistical floor to clear. The other
# three all also compute a "fractal_dimension" field via the vendored
# core's fsqli_boxcount_dimension (src/fractal_dim/boxcount.c), which
# needs enough points for its internal eps-sweep to find at least 3
# "intermediate" octave levels (occupied cells > 0 and occupied*3 <
# n_points) -- small hand-placed geometry (a chain, a single
# bifurcation, a cube's 8 corners) always failed this, regardless of
# topology, until sized up to what simulating the exact algorithm
# showed was enough (see each one's own comment below for the number
# and why). The error cases exercise each function's own arg-shape/
# bounds validation in src/fractalsql.c (NULL args, non-divisible CSV
# length, an out-of-range node/vertex index, dim <= 0, too few points
# for a non-degenerate box count) -- same NULL-on-*error/*is_null
# convention as every other UDF here, so `-N` reports both the same way.
gate_36_morphology_metrics() {
  # fractal_vascular_network(node_coords_csv, edges_csv, edge_arc_length_csv):
  # a 3000-node random recursive tree (node i, i>=1, attaches to a
  # random earlier node) spread over a real 3D volume. The node count
  # isn't about the tree/tortuosity math at all (a handful of nodes
  # computes those fields fine) -- it's fsqli_boxcount_dimension
  # (src/fractal_dim/boxcount.c in the vendored core), which this UDF
  # calls internally for *out_fractal_dimension and requires at least
  # 3 of its 12 octave-spaced eps levels to land in the "intermediate"
  # regime (occupied cells > 0 and occupied*3 < n_points) -- a 3D point
  # cloud needs roughly 2000+ points to reliably clear that floor
  # (confirmed by simulating the exact algorithm: 500 points leaves
  # only 2 valid levels, 3000 gives 3 consistently across seeds).
  # arc_length is each edge's true Euclidean length times 1.05 (a
  # believable 5% tortuosity margin, and safely >= the straight-line
  # length no matter how Python's and the core's float math round the
  # last digit -- unlike passing the bare Euclidean distance back,
  # which risked tortuosity landing a hair under its >= 1.0 floor).
  local vn_csv; vn_csv=$(python3 -c "
import random, math
random.seed(1)
n = 3000
pts = [(random.uniform(0, 10), random.uniform(0, 10), random.uniform(0, 10)) for _ in range(n)]
edges = []
arcs = []
for i in range(1, n):
    j = random.randint(0, i - 1)
    edges += [j, i]
    dx, dy, dz = pts[i][0]-pts[j][0], pts[i][1]-pts[j][1], pts[i][2]-pts[j][2]
    arcs.append(math.sqrt(dx*dx + dy*dy + dz*dz) * 1.05)
coords = ','.join(f'{c:.6f}' for p in pts for c in p)
print(coords)
print(','.join(str(e) for e in edges))
print(','.join(f'{a:.6f}' for a in arcs))
")
  local vn_coords vn_edges vn_arcs
  vn_coords=$(sed -n '1p' <<< "$vn_csv"); vn_edges=$(sed -n '2p' <<< "$vn_csv"); vn_arcs=$(sed -n '3p' <<< "$vn_csv")
  # 3000 nodes' worth of CSV blows well past ARG_MAX as a `-e` argument
  # (confirmed live: "Argument list too long") -- a heredoc feeds the
  # query over a pipe instead, with no argv size limit at all.
  local vn; vn=$("${MARIADB[@]}" -N 2>&1 <<SQL
SELECT fractal_vascular_network('$vn_coords', '$vn_edges', '$vn_arcs');
SQL
)
  echo "$vn" | grep -q '"mean_tortuosity"' && echo "$vn" | grep -q '"fractal_dimension"' \
    && pass "36 morphology: fractal_vascular_network returns mean_tortuosity/fractal_dimension" \
    || fail "36 morphology: expected a well-formed result, got: $vn"

  local vn_null; vn_null=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_vascular_network(NULL, '0,1,1,2', '1,1');" 2>&1)
  [ "$vn_null" = "NULL" ] && pass "36 morphology: fractal_vascular_network(NULL, ...) -> NULL" \
                           || fail "36 morphology: expected NULL, got: $vn_null"

  local vn_oob; vn_oob=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_vascular_network('0,0,0,1,0,0,2,0,0', '0,1,1,3', '1,1');" 2>&1)
  [ "$vn_oob" = "NULL" ] \
    && pass "36 morphology: fractal_vascular_network rejects an out-of-range node index" \
    || fail "36 morphology: expected NULL for an OOB edge index, got: $vn_oob"

  local vn_shape; vn_shape=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_vascular_network('0,0,0,1,0,0', '0,1,1,2', '1,1');" 2>&1)
  [ "$vn_shape" = "NULL" ] \
    && pass "36 morphology: fractal_vascular_network rejects node_coords not divisible by 3" \
    || fail "36 morphology: expected NULL for a malshaped node_coords, got: $vn_shape"

  # fractal_cortical_folding(vertices_csv, faces_csv): a regular
  # tetrahedron (4 non-coplanar vertices) and its 4 triangular faces.
  local cf; cf=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_cortical_folding('0,0,0,1,0,0,0,1,0,0,0,1', '0,1,2,0,1,3,0,2,3,1,2,3');" 2>&1)
  echo "$cf" | grep -q '"gyrification_index"' \
    && pass "36 morphology: fractal_cortical_folding returns a gyrification_index" \
    || fail "36 morphology: expected a well-formed result, got: $cf"

  local cf_null; cf_null=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_cortical_folding(NULL, '0,1,2,0,1,3,0,2,3,1,2,3');" 2>&1)
  [ "$cf_null" = "NULL" ] && pass "36 morphology: fractal_cortical_folding(NULL, ...) -> NULL" \
                           || fail "36 morphology: expected NULL, got: $cf_null"

  local cf_oob; cf_oob=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_cortical_folding('0,0,0,1,0,0,0,1,0,0,0,1', '0,1,2,0,1,3,0,2,3,1,2,4');" 2>&1)
  [ "$cf_oob" = "NULL" ] \
    && pass "36 morphology: fractal_cortical_folding rejects an out-of-range face index" \
    || fail "36 morphology: expected NULL for an OOB face index, got: $cf_oob"

  # fractal_nerve_plexus_metric(node_coords_csv, dim, edges_csv): same
  # random-recursive-tree shape and same fsqli_boxcount_dimension floor
  # as fractal_vascular_network above, but in 2D -- box-counting's
  # eps-sweep clears its own "3 valid levels" floor at a much smaller N
  # in 2D than 3D (simulated: 500 points already gives exactly 3; 2000
  # gives a comfortable margin of 4).
  local np_csv; np_csv=$(python3 -c "
import random
random.seed(2)
n = 2000
pts = [(random.uniform(0, 10), random.uniform(0, 10)) for _ in range(n)]
edges = []
for i in range(1, n):
    j = random.randint(0, i - 1)
    edges += [j, i]
coords = ','.join(f'{c:.6f}' for p in pts for c in p)
print(coords)
print(','.join(str(e) for e in edges))
")
  local np_coords np_edges
  np_coords=$(sed -n '1p' <<< "$np_csv"); np_edges=$(sed -n '2p' <<< "$np_csv")
  local np; np=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_nerve_plexus_metric('$np_coords', 2, '$np_edges');" 2>&1)
  echo "$np" | grep -q '"fiber_length_density"' \
    && pass "36 morphology: fractal_nerve_plexus_metric returns fiber_length_density" \
    || fail "36 morphology: expected a well-formed result, got: $np"

  local np_dim0; np_dim0=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_nerve_plexus_metric('0,0,1,0,2,0', 0, '0,1,1,2');" 2>&1)
  [ "$np_dim0" = "NULL" ] && pass "36 morphology: fractal_nerve_plexus_metric rejects dim <= 0" \
                           || fail "36 morphology: expected NULL for dim=0, got: $np_dim0"

  local np_oob; np_oob=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_nerve_plexus_metric('0,0,1,0,2,0', 2, '0,1,1,3');" 2>&1)
  [ "$np_oob" = "NULL" ] \
    && pass "36 morphology: fractal_nerve_plexus_metric rejects an out-of-range node index" \
    || fail "36 morphology: expected NULL for an OOB edge index, got: $np_oob"

  # fractal_morphological_complexity(points_csv, dim): 2000 random
  # points in 2D -- same fsqli_boxcount_dimension floor as
  # fractal_nerve_plexus_metric above (dim=2 chosen deliberately: this
  # UDF's own dim is a free caller choice, and 2D clears the box-
  # counting floor at a far smaller N than 3D would need). A small
  # fixed lattice (8 corners, even a 27-point 3x3x3 grid) is nowhere
  # close, in either dimension; the ">= 8 pts" floor the comment at
  # this UDF's call site documents is necessary, not sufficient.
  local mc_csv; mc_csv=$(python3 -c "
import random
random.seed(3)
print(','.join(f'{random.uniform(0, 10):.6f}' for _ in range(2000 * 2)))
")
  local mc; mc=$("${MARIADB[@]}" -N -e "SELECT fractal_morphological_complexity('$mc_csv', 2);" 2>&1)
  echo "$mc" | grep -q '"dimension"' && echo "$mc" | grep -q '"lacunarity"' \
    && pass "36 morphology: fractal_morphological_complexity returns dimension/lacunarity" \
    || fail "36 morphology: expected a well-formed result, got: $mc"

  local mc_dim0; mc_dim0=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_morphological_complexity('0,0,0,1,0,0,0,1,0,0,0,1', 0);" 2>&1)
  [ "$mc_dim0" = "NULL" ] && pass "36 morphology: fractal_morphological_complexity rejects dim <= 0" \
                           || fail "36 morphology: expected NULL for dim=0, got: $mc_dim0"

  local mc_few; mc_few=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_morphological_complexity('0,0,0,1,0,0,0,1,0,0,0,1', 3);" 2>&1)
  [ "$mc_few" = "NULL" ] \
    && pass "36 morphology: fractal_morphological_complexity rejects too few points for a box count" \
    || fail "36 morphology: expected NULL for a too-small point cloud, got: $mc_few"

  local mc_null; mc_null=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_morphological_complexity(NULL, 3);" 2>&1)
  [ "$mc_null" = "NULL" ] && pass "36 morphology: fractal_morphological_complexity(NULL, ...) -> NULL" \
                           || fail "36 morphology: expected NULL, got: $mc_null"
}

# FAULT only (--fault) -- not in DEFAULT or QUICK; --fault runs DEFAULT
# first and adds this gate after it, restarting fractalsqld hundreds of
# times on top of that (real wall-time: see FSQL_OOM_MAX_N). Sweeps
# tests/oom_preload.c's FSQL_OOM_FAIL_AT over 1..max_n for each of 7
# UDFs spanning every layer reachable without extra per-trial setup --
# fractalsql_vector.c (fractal_vector_scale), the vendored core's main
# search engine (fractal_search), fractalsql.c's two CSV parsers
# (fractal_morphological_complexity for parse_vector_csv,
# fractal_search_explore for parse_corpus), fractalsql_cognition.c's
# dispatch path (fractal_reason), fractalsql_textsql.c's allowlist
# scanner (fractal_t2s_check_allowlist, pure text, no LLM round trip),
# and fractalsql_session.c's registry (fractal_diversify_enable) --
# every allocation fractalsqld makes while serving ONE call, across
# all of these, gets a turn at failing. The enterprise storage layer
# (fractal_audit_log/fractal_ledger_*) needs the mock loaded first --
# gate 35's own job, not duplicated here.
#
# This is NOT testing something fractalsql-core's own tests/fault/
# (Gates 26/28 there) already cover: that harness drives the vendored
# core's .so directly through its own fixtures, never through this
# repo's UDF/daemon layer at all, so it has never once exercised the
# `if (ptr == NULL) { ...; return NULL; }` checks this repo's OWN code
# makes after its OWN malloc calls (src/fractalsql.c, fractalsql_
# vector.c, fractalsql_enterprise.c, service/daemon/fractalsqld.c). A
# crash from an allocation failure anywhere during one of these calls
# -- including inside the statically-linked core, since it runs in the
# same fractalsqld process -- is this gate's one and only failure
# condition, same PASS_NORMAL/PASS_OOM-both-fine/CRASH-only-fails
# convention fractalsql-core's own fault_runner.py uses: a clean
# NULL/*error result is success here, whether the injected failure
# landed in this repo's code or the core's own (re-confirming the
# core survives an OOM it already proved upstream isn't new value, but
# it's a harmless side effect of restarting the DAEMON process, not
# something this gate goes out of its way to do).
#
# Crash detection reads the daemon's own log for "FATAL" -- the exact
# string on_fatal()/the Windows-equivalent signal handler in service/
# daemon/fractalsqld.c prints right before re-raising a caught fatal
# signal -- rather than inferring a crash from the SQL client's own
# error text, which can't tell "fractalsqld died" apart from "the
# query cleanly failed" on its own.
gate_37_oom_injection() {
  local tag="${CUR_VER//./_}"
  local main_log="/tmp/fractalsql_bt_fsqd_${tag}.log"
  local oom_so="$TMPROOT/fractalsql_bt_oom_preload_${tag}.so"
  local max_n="${FSQL_OOM_MAX_N:-200}"

  # wc -c's output is right-padded with spaces on BSD/macOS ("   18306")
  # but not on GNU/Linux -- tr strips it either way so log_from's
  # arithmetic always sees a clean integer. Without this, macOS's stock
  # bash (still 3.2, frozen there for licensing reasons) rejects the
  # padded value with "syntax error: operand expected" inside $(( ));
  # Linux's bash tolerates it, which is why this only ever broke there.
  log_mark() { wc -c < "$main_log" 2>/dev/null | tr -d '[:space:]' || echo 0; }
  log_from() { tail -c +"$(( $1 + 1 ))" "$main_log" 2>/dev/null; }

  cc -O2 -fPIC -shared -o "$oom_so" tests/oom_preload.c -ldl \
      2>/tmp/fractalsql_bt_gate37_build.log \
    || { cat /tmp/fractalsql_bt_gate37_build.log >&2; \
         fail "37 oom_injection: oom_preload.so failed to build"; return; }

  # Spans every layer this gate can reach without extra per-trial setup
  # (fractal_audit_log/fractal_ledger_* need the enterprise mock loaded
  # first -- gate 35's own job, not duplicated here): fractalsql_vector.c,
  # the vendored core's main search engine, fractalsql.c's CSV parsing
  # (parse_vector_csv via morphological_complexity, parse_corpus via
  # search_explore), fractalsql_cognition.c's dispatch path, fractalsql_
  # textsql.c's allowlist scanner, and fractalsql_session.c's registry.
  local names=(vector_scale search morphological_complexity search_explore reason allowlist diversify_enable)
  local sqls=(
    "SELECT fractal_vector_scale('[1,2,3]', 2);"
    "SELECT fractal_search('[[1,0],[0,1],[0.6,0.8]]', '[0.6,0.8]', 3, '{\"iterations\":20,\"population_size\":10}');"
    "SELECT fractal_morphological_complexity('0.1,0.2,0.4,0.9,0.8,0.1,0.3,0.7,0.6,0.6,0.2,0.8,0.9,0.3,0.5,0.5,0.7,0.2,0.1,0.9', 2);"
    "SELECT fractal_search_explore('[[0.1,0.1],[0.9,0.9],[0.2,0.8]]', '[0.5,0.5]', '{\"population_size\":10,\"iterations\":5,\"walk\":0}');"
    "SELECT fractal_reason(CONNECTION_ID(), 'ping');"
    "SELECT fractal_t2s_check_allowlist('SELECT 1');"
    "SELECT fractal_diversify_enable(CONNECTION_ID());"
  )

  local idx
  for idx in "${!names[@]}"; do
    local name="${names[$idx]}" sql="${sqls[$idx]}"
    local crashes=0 first_crash="" n
    for n in $(seq 1 "$max_n"); do
      daemon_stop
      local L; L=$(log_mark)
      LD_PRELOAD="$oom_so" FSQL_OOM_FAIL_AT="$n" daemon_start >/dev/null 2>&1
      if [ -S "$FSQD_SOCK" ]; then
        "${MARIADB[@]}" --connect-timeout=3 -N -e "$sql" >/dev/null 2>&1
      fi
      if log_from "$L" | grep -q "FATAL"; then
        crashes=$((crashes + 1))
        [ -z "$first_crash" ] && first_crash="$n"
      fi
    done
    if [ "$crashes" -eq 0 ]; then
      pass "37 oom_injection: $name -- no crash across $max_n injected allocation-failure points"
    else
      fail "37 oom_injection: $name -- crashed on $crashes/$max_n injected failure points (first at #$first_crash, see $main_log)"
    fi
  done

  daemon_stop
  daemon_start >/dev/null 2>&1
}

# on_fatal (service/daemon/fractalsqld.c): the daemon's own fatal-signal
# handler for SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL. Nothing else in this
# suite ever reaches it -- every other gate's crash detection (gate 37
# above, gate 06's crash recovery) relies on a REAL bug or a deliberately
# crashing evil plugin tripping a signal on its own; nothing sends one on
# purpose to confirm the handler itself behaves. SIGABRT is the one
# reachable from a plain `kill`, no debugger or deliberately-corrupting
# payload needed. on_fatal logs one diagnostic line to stderr, restores
# the signal's default disposition, then re-raises it -- so the daemon
# is expected to actually die here; this gate's own job afterward is
# putting it back for whatever gate runs next.
gate_38_fatal_signal() {
  local tag="${CUR_VER//./_}"
  local main_log="/tmp/fractalsql_bt_fsqd_${tag}.log"

  # wc -c's output is right-padded with spaces on BSD/macOS ("   18306")
  # but not on GNU/Linux -- tr strips it either way so log_from's
  # arithmetic always sees a clean integer. Without this, macOS's stock
  # bash (still 3.2, frozen there for licensing reasons) rejects the
  # padded value with "syntax error: operand expected" inside $(( ));
  # Linux's bash tolerates it, which is why this only ever broke there.
  log_mark() { wc -c < "$main_log" 2>/dev/null | tr -d '[:space:]' || echo 0; }
  log_from() { tail -c +"$(( $1 + 1 ))" "$main_log" 2>/dev/null; }

  if [ -z "$FSQD_PID" ]; then
    fail "38 fatal_signal: no running daemon PID to signal"
    return
  fi

  local L; L=$(log_mark)
  local pid="$FSQD_PID"
  kill -ABRT "$pid"

  local i gone=0
  for i in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || { gone=1; break; }
    sleep 0.1
  done
  wait "$pid" 2>/dev/null
  FSQD_PID=""

  if [ "$gone" -eq 1 ] && log_from "$L" | grep -q "FATAL SIGABRT"; then
    pass "38 fatal_signal: on_fatal logs the crash and the daemon actually exits on SIGABRT"
  else
    fail "38 fatal_signal: expected a logged FATAL SIGABRT + process exit (gone=$gone), log: $(log_from "$L" | tail -3)"
  fi

  rm -f "$FSQD_SOCK"
  daemon_start >/dev/null 2>&1 \
    || fail "38 fatal_signal: failed to restart the daemon afterward"
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

  # Every OTHER enterprise UDF gates on the exact same ensure_enterprise_
  # lib() == false check as the two above -- each is its own function
  # (own _init/_deinit/main, its own line/function-coverage credit), so
  # calling only truth_count/audit_unpack left the other 10 completely
  # uncalled. All 12 take non-NULL args here specifically so the call
  # reaches the ensure_enterprise_lib() check at all, rather than
  # returning early on a NULL-arg check that runs first in a few of
  # these (the multimodal family).
  local fn
  for fn in fractal_ledger_flush fractal_ledger_load fractal_ledger_compact \
            fractal_ledger_reset_soft fractal_ledger_reset_hard fractal_ledger_shadow_count; do
    local rfn; rfn=$("${MARIADB[@]}" -N -e "SELECT $fn(CONNECTION_ID());" 2>&1)
    [ "$rfn" = "NULL" ] && pass "25 enterprise: $fn refuses when not loaded" \
                         || fail "25 enterprise: expected NULL from $fn, got: $rfn"
  done

  local ral; ral=$("${MARIADB[@]}" -N -e "SELECT fractal_audit_log('t', '{}');" 2>&1)
  [ "$ral" = "NULL" ] && pass "25 enterprise: fractal_audit_log refuses when not loaded" \
                       || fail "25 enterprise: expected NULL from fractal_audit_log, got: $ral"

  local rpm; rpm=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_optimize_portfolio_multimodal('[1,2]', '[1,0,0,1]', 1, 1, 0.5, 0.5, 1);" 2>&1)
  [ "$rpm" = "NULL" ] && pass "25 enterprise: fractal_optimize_portfolio_multimodal refuses when not loaded" \
                       || fail "25 enterprise: expected NULL, got: $rpm"

  local rpmx; rpmx=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_optimize_portfolio_multimodal_ex('[1,2]', '[1,0,0,1]', 1, 1, 0.5, 0.5, 1, 0, 'gaussian');" 2>&1)
  [ "$rpmx" = "NULL" ] && pass "25 enterprise: fractal_optimize_portfolio_multimodal_ex refuses when not loaded" \
                        || fail "25 enterprise: expected NULL, got: $rpmx"

  local rpmp; rpmp=$("${MARIADB[@]}" -N -e \
    "SELECT fractal_optimize_portfolio_multimodal_pareto('[1,2]', '[1,0,0,1]', 1, 1, 1, 1, 0, 'gaussian');" 2>&1)
  [ "$rpmp" = "NULL" ] && pass "25 enterprise: fractal_optimize_portfolio_multimodal_pareto refuses when not loaded" \
                        || fail "25 enterprise: expected NULL, got: $rpmp"
}

# Enterprise tier: with a REAL enterprise .so loaded (opt-in only, not
# in DEFAULT_GATES). The enterprise core library is a licensed artifact
# not shipped in this public repo, so this gate SKIPs cleanly unless a
# real libfractalsql-enterprise-sovereign-c.so has been staged locally
# at $ENT_SO by hand (see the FractalSQL core's own releases for that
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
    skip "26 enterprise_active: no enterprise library found (include/)"
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
    skip "27 enterprise_connect: no enterprise library found (include/)"
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

  # Rewriting just the filename inside install_enterprise_connect.sql
  # would leave its CONCAT(@@GLOBAL.datadir, ...) prefix glued onto our
  # absolute $ledger_path.csv -- a path that can't exist, which CONNECT
  # reads back as zero rows with no error. Override the ledger file via
  # the script's own @fsql_ledger_csv session variable instead.
  local install_sql
  install_sql="SET @fsql_ledger_csv = '$ledger_path.csv';
$(cat "$HERE/sql/install_enterprise_connect.sql")"
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
# file staged next to it (ships in the FractalSQL core's own release
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
    skip "28 enterprise_signature: no enterprise library found (include/)"
    return
  fi
  if [ ! -f "$ent_sig" ]; then
    skip "28 enterprise_signature: no signature file staged"
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
  # (backward-compatible default).
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

# Enterprise tier, in DEFAULT_GATES (unlike 26/27/28): exercises
# fractalsql_enterprise.c's OWN integration code -- ensure_enterprise_
# lib()'s dlopen/dlsym/signature-verification machinery, every
# fractal_ledger_*/fractal_optimize_portfolio_multimodal* UDF's own
# arg validation + ctx acquire/release + success/failure branch, the
# enterprise_lib/_ledger_path/_ledger_key provider-reload path
# (fractalsql_provider.h), and the "refuse to change enterprise_lib
# live while loaded" guard -- using tests/mock_enterprise_core.c, a
# fixture this harness builds itself, NOT the real licensed core (see
# that file's own header for exactly what it can and cannot stand in
# for). audit_log/audit_unpack/ledger_verify's deep storage/HMAC/
# tamper-detection logic is this repo's OWN code regardless of what's
# loaded, so it gets covered here for real, same as gate 26 proves
# with the real artifact -- the mock only needs to satisfy the
# dlopen/dlsym gate for that code to become reachable at all. What
# this CANNOT cover (needs the real, licensed .so / the offline-held
# FractalSQLabs private key): a real enterprise_lib actually persisting
# ctx-internal state through flush/load (gate 26), and ENT_SIG_OK
# (gate 28) -- both stay opt-in.
gate_35_enterprise_mock() {
  local tag="${CUR_VER//./_}"
  local main_log="/tmp/fractalsql_bt_fsqd_${tag}.log"
  local mock_so="$TMPROOT/fractalsql_bt_mock_ent_${tag}.so"
  local fail_sentinel="$TMPROOT/fractalsql_bt_mock_ent_fail_${tag}"
  local ledger_path="$HERE/.gate35_ledger.dat"
  local ctl_bin="$HERE/service/build/fsqlctl"
  local badsig_so="$mock_so.badsig.so"
  local nosig_so="$mock_so.nosig.so"
  local rd

  # wc -c's output is right-padded with spaces on BSD/macOS ("   18306")
  # but not on GNU/Linux -- tr strips it either way so log_from's
  # arithmetic always sees a clean integer. Without this, macOS's stock
  # bash (still 3.2, frozen there for licensing reasons) rejects the
  # padded value with "syntax error: operand expected" inside $(( ));
  # Linux's bash tolerates it, which is why this only ever broke there.
  log_mark() { wc -c < "$main_log" 2>/dev/null | tr -d '[:space:]' || echo 0; }
  log_from() { tail -c +"$(( $1 + 1 ))" "$main_log" 2>/dev/null; }
  fsq_reload() { FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1; }

  rm -f "$ledger_path" "$fail_sentinel" "$mock_so" "$badsig_so" "$badsig_so.sig" "$nosig_so"

  cc -shared -fPIC -std=c99 -I"$HERE/include/$(fsql_ent_platform_dir)" -I"$HERE/include" \
     tests/mock_enterprise_core.c -o "$mock_so" 2>/tmp/fractalsql_bt_gate35_build.log \
    || { cat /tmp/fractalsql_bt_gate35_build.log >&2; fail "35 enterprise_mock: mock .so failed to build"; return; }
  cp "$mock_so" "$badsig_so"
  head -c 64 /dev/urandom > "$badsig_so.sig"
  cp "$mock_so" "$nosig_so"

  mdb_teardown
  export FSQL_MOCK_ENT_FAIL="$fail_sentinel"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    unset FSQL_MOCK_ENT_FAIL
    fail "35 enterprise_mock: restart with FSQL_MOCK_ENT_FAIL set failed (rc=$setup_rc)"
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi

  local pre; pre=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$pre" = "NULL" ] && pass "35 enterprise_mock: truth_count refuses cleanly before enterprise_lib is set" \
                       || fail "35 enterprise_mock: expected NULL before enterprise_lib is set, got: $pre"

  # Path 1: a corrupt/wrong .sig is ALWAYS fatal -- no real signing key
  # needed to prove this (ent_verify_signature rejects on a MISMATCH,
  # which 64 random bytes reliably is).
  local L; L=$(log_mark)
  printf 'enterprise_lib = %s\n' "$badsig_so" >> "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (badsig path) rc/err: $rd"
  local r1; r1=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r1" = "NULL" ] && log_from "$L" | grep -q "failed signature verification" \
    && pass "35 enterprise_mock: a corrupt/wrong .sig refuses to load" \
    || fail "35 enterprise_mock: expected NULL + a logged refusal, got: $r1 / log: $(log_from "$L" | tail -3)"

  # Path 2: no .sig at all + enterprise_require_signature=1 -- fatal.
  # A fresh path (vs. path 1 above) so this gets its own dlopen/verify
  # attempt rather than hitting path 1's cached "already attempted".
  printf 'enterprise_lib = %s\nenterprise_require_signature = 1\n' "$nosig_so" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (nosig+require path) rc/err: $rd"
  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r2" = "NULL" ] && pass "35 enterprise_mock: a missing .sig refuses to load when enterprise_require_signature is set" \
                      || fail "35 enterprise_mock: expected NULL, got: $r2"

  # Path 3: no .sig, enterprise_require_signature back off -- loads
  # unverified (the backward-compatible default). This is the mock that
  # stays loaded for the rest of this gate.
  # enterprise_ledger_key here too: every ledger write/verify for the
  # rest of this gate runs HMAC-keyed (fsql_hmac_sha256 in
  # src/fractalsql_enterprise.c), not just the structural hash-chain-
  # only path gate 25/26 already cover.
  printf 'enterprise_lib = %s\nenterprise_ledger_path = %s\nenterprise_ledger_key = %s\nenterprise_require_signature = 0\n' \
    "$mock_so" "$ledger_path" "gate35-hmac-test-key" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (mock path) rc/err: $rd"
  local r3; r3=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r3" = "0" ] && pass "35 enterprise_mock: a missing .sig loads unverified by default once require_signature is off" \
                   || fail "35 enterprise_mock: expected 0, got: $r3"

  # Every ENT_LEDGER_VOID_UDF/COUNT_UDF wrapper's success branch.
  local fn
  for fn in fractal_ledger_flush fractal_ledger_compact fractal_ledger_reset_soft fractal_ledger_reset_hard fractal_ledger_load; do
    local r; r=$("${MARIADB[@]}" -N -e "SELECT $fn(CONNECTION_ID());" 2>&1)
    [ "$r" = "0" ] && pass "35 enterprise_mock: $fn succeeds while the mock is loaded" \
                    || fail "35 enterprise_mock: expected 0 from $fn, got: $r"
  done
  local sc; sc=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_shadow_count(CONNECTION_ID());" 2>&1)
  [ "$sc" = "0" ] && pass "35 enterprise_mock: shadow_count succeeds while the mock is loaded" \
                   || fail "35 enterprise_mock: expected 0 from shadow_count, got: $sc"

  # Failure branch: the sentinel flips the SAME mock's return codes
  # without touching the daemon's process environment again (see
  # tests/mock_enterprise_core.c's own header for why a file, not a
  # value, is the toggle).
  touch "$fail_sentinel"
  local rf; rf=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_flush(CONNECTION_ID());" 2>&1)
  [ "$rf" = "NULL" ] && pass "35 enterprise_mock: flush refuses cleanly (NULL, the UDF *error convention) when the mock reports failure" \
                      || fail "35 enterprise_mock: expected NULL with the fail sentinel set, got: $rf"
  rm -f "$fail_sentinel"

  # Deep storage layer -- entirely this repo's own code (ledger_write_
  # entry/read/scan, HMAC, chain hashing), reachable once ANYTHING is
  # loaded: audit_log/audit_unpack/ledger_verify never call back into
  # the dlopen'd library at all.
  "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.small', '{\"n\":1}');" >/dev/null 2>&1
  local v1; v1=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  [ "$v1" = '{"ok":true,"rows_verified":1}' ] \
    && pass "35 enterprise_mock: audit_log + ledger_verify round-trip a real chain entry" \
    || fail "35 enterprise_mock: expected 1-row ok verify, got: $v1"

  # Torn-tail repair (ledger_repair_torn_tail): write a 2nd record, then
  # truncate a few bytes off its tail to simulate a crash mid-append --
  # the next write (ledger_write_entry's own scan) must detect the torn
  # record, truncate the file back to the last complete one, and append
  # cleanly, rather than bricking the file for every future write.
  "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.torn', '{\"will\":\"be torn\"}');" >/dev/null 2>&1
  python3 -c "
import os, sys
p = sys.argv[1]
sz = os.path.getsize(p)
with open(p, 'r+b') as f:
    f.truncate(sz - 5)
" "$ledger_path" 2>/dev/null
  "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.after_repair', '{\"n\":3}');" >/dev/null 2>&1
  local v_repair; v_repair=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  [ "$v_repair" = '{"ok":true,"rows_verified":2}' ] \
    && pass "35 enterprise_mock: a torn tail is repaired on the next write (torn record discarded, new one appended)" \
    || fail "35 enterprise_mock: expected a 2-row ok verify after repair, got: $v_repair"

  # A payload past the 8192-byte default cap forces fractal_audit_
  # unpack's FSQL_ETRUNCATED retry loop.
  local big; big=$(python3 -c "print('A' * 9000)")
  local au; au=$("${MARIADB[@]}" -N -e "SELECT LENGTH(fractal_audit_unpack('$big'));" 2>&1)
  [ "$au" = "9000" ] && pass "35 enterprise_mock: audit_unpack grows its buffer past the 8192-byte default cap" \
                      || fail "35 enterprise_mock: expected length 9000, got: $au"

  # Byte-level tamper detection -- the same storage path gate 26 proves
  # with a real .so, here with no real .so at all.
  python3 -c "
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(-5, 2)
    b = f.read(1)
    f.seek(-5, 2)
    f.write(bytes([b[0] ^ 0xFF]))
" "$ledger_path" 2>/dev/null
  local v2; v2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  [[ "$v2" == '{"ok":false,'* ]] && pass "35 enterprise_mock: ledger_verify detects a byte-level tamper (no real .so needed)" \
                                  || fail "35 enterprise_mock: expected a tamper-detected report, got: $v2"

  # Portfolio multimodal family (all 3 optional symbols present here).
  local pm; pm=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42);" 2>&1)
  [[ "$pm" == '{"n_found":1,'* ]] && pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal returns a well-formed result" \
                                    || fail "35 enterprise_mock: expected a well-formed result, got: $pm"
  local pmx; pmx=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 0, 'gaussian');" 2>&1)
  [[ "$pmx" == '{"n_found":1,'* ]] && pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal_ex returns a well-formed result" \
                                     || fail "35 enterprise_mock: expected a well-formed result, got: $pmx"
  local pmp; pmp=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 2, 1, 42, 0, 'gaussian');" 2>&1)
  [[ "$pmp" == '{"n_found":1,'* ]] && pass "35 enterprise_mock: fractal_optimize_portfolio_multimodal_pareto returns a well-formed result" \
                                     || fail "35 enterprise_mock: expected a well-formed result, got: $pmp"

  # ledger_log_exit: the ledger write path's own diagnostic logger, hit
  # at every FSQL_ESTORAGE exit in ledger_write_entry -- no test before
  # this ever made that path actually fail I/O (a well-formed ledger_
  # path always opens fine). A ledger_path inside a mode-0555 directory
  # makes BOTH the "r+b" open (file doesn't exist yet) and the "w+b"
  # create fail with EACCES, landing on the "open new ledger" exit.
  # (The daemon itself never runs as root -- see validate_cfg's own
  # root refusal above -- so the permission bits are not bypassed.)
  local noperm_dir="$TMPROOT/fractalsql_bt_gate35_noperm_${tag}"
  mkdir -p "$noperm_dir" && chmod 0555 "$noperm_dir"
  local noperm_ledger="$noperm_dir/ledger.dat"
  printf 'enterprise_ledger_path = %s\n' "$noperm_ledger" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (noperm ledger_path) rc/err: $rd"
  local L2; L2=$(log_mark)
  local al_noperm; al_noperm=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.noperm', '{\"n\":1}'), '<NULL>');" 2>&1)
  [ "$al_noperm" = "<NULL>" ] && log_from "$L2" | grep -q "write path failed at open new ledger" \
    && pass "35 enterprise_mock: ledger_log_exit fires and audit_log refuses cleanly when the ledger dir is unwritable" \
    || fail "35 enterprise_mock: expected <NULL> + a logged ledger_log_exit, got: $al_noperm / log: $(log_from "$L2" | tail -3)"
  chmod 0755 "$noperm_dir"; rmdir "$noperm_dir" 2>/dev/null

  # Restore the real ledger_path for the rest of this gate.
  printf 'enterprise_ledger_path = %s\n' "$ledger_path" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (restore ledger_path) rc/err: $rd"

  # The reload-race guard fixed this session (fractalsql_enterprise_
  # apply_provider re-checks g_ent_loaded itself): enterprise_lib
  # cannot change live while a library is already loaded.
  printf 'enterprise_lib = %s\n' "$badsig_so" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [[ "$rd" == *"reload failed"* ]] \
    && pass "35 enterprise_mock: reload refuses to change enterprise_lib while it is loaded" \
    || fail "35 enterprise_mock: expected a refusal, got: $rd"
  local r4; r4=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r4" = "0" ] && pass "35 enterprise_mock: the refused reload left the mock loaded and working" \
                   || fail "35 enterprise_mock: expected 0 (still loaded), got: $r4"

  unset FSQL_MOCK_ENT_FAIL
  rm -f "$ledger_path" "$fail_sentinel" "$mock_so" "$badsig_so" "$badsig_so.sig" "$nosig_so"
  mdb_teardown
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# FUZZ only -- not in DEFAULT or QUICK, run via --fuzz. No live cluster
# needed: builds + briefly runs libFuzzer drivers against the three
# hand-rolled parsers this repo has that read externally-influenceable
# text into a fixed-size buffer (src/fractalsql_parse.c -- factored out
# of src/fractalsql.c specifically so these can be linked standalone,
# without mysql.h/a running mariadbd; see that file's own header
# comment). parse_vector_csv is the highest-priority target: it parses
# fractal_embed()'s raw response from whatever embedding endpoint
# FRACTALSQL_HTTP_EMBED_URL points at, i.e. genuinely attacker-
# controlled bytes if that endpoint is malicious or merely buggy. The
# other two (parse_corpus, parse_index_csv) parse SQL-caller-supplied
# text (fractal_search's corpus argument, the Analytics-tier edge/face
# index arguments) -- lower external-adversary risk, included as
# defense-in-depth for the same hand-rolled-strtod-scan class of bug.
#
# This is a SMOKE run (FSQL_FUZZ_TIME seconds per target, default 30),
# not a real fuzzing campaign -- it exists to catch a regression before
# push. Run a real multi-hour campaign locally (same binaries, higher
# -max_total_time) before relying on this gate to have found everything.
gate_30_fuzz_smoke() {
  local cc="${FSQL_FUZZ_CC:-}"
  if [ -z "$cc" ]; then
    local candidate
    for candidate in clang-18 clang-17 clang-16 clang-15 clang; do
      if command -v "$candidate" >/dev/null 2>&1; then cc="$candidate"; break; fi
    done
  fi
  if [ -z "$cc" ] || ! command -v "$cc" >/dev/null 2>&1; then
    skip "30 fuzz_smoke (no clang found -- set FSQL_FUZZ_CC to a libFuzzer-capable clang)"
    return
  fi
  # The clang resolved above might not actually have libFuzzer support
  # (e.g. a bare `clang` shadowed by an unrelated toolchain's shim) --
  # verify with a trivial compile before trusting it for the real
  # targets, rather than failing confusingly three functions down.
  local probe_src probe_bin
  probe_src="$(mktemp /tmp/fractalsql_bt_fuzzprobe_XXXXXX.c)"
  probe_bin="${probe_src%.c}"
  printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){(void)d;(void)n;return 0;}\n' > "$probe_src"
  if ! "$cc" -fsanitize=fuzzer "$probe_src" -o "$probe_bin" >/dev/null 2>&1; then
    rm -f "$probe_src" "$probe_bin"
    skip "30 fuzz_smoke ($cc lacks -fsanitize=fuzzer support -- set FSQL_FUZZ_CC)"
    return
  fi
  rm -f "$probe_src" "$probe_bin"

  local fuzz_time="${FSQL_FUZZ_TIME:-30}"
  mkdir -p /tmp/fractalsql_bt_fuzz

  local target
  for target in parse_vector_csv parse_corpus parse_index_csv; do
    local bin="/tmp/fractalsql_bt_fuzz/fuzz_$target"
    local buildlog="/tmp/fractalsql_bt_fuzz_${target}_build.log"
    if ! "$cc" -std=c99 -O1 -g -fsanitize=fuzzer,address -fno-sanitize-recover=address \
        -Isrc \
        src/fractalsql_parse.c src/fractalsql_interrupt.c "tests/fuzz/fuzz_${target}.c" \
        -o "$bin" >"$buildlog" 2>&1; then
      fail "30 fuzz_smoke: $target -- build failed, see $buildlog"
      continue
    fi

    local runlog="/tmp/fractalsql_bt_fuzz_${target}_run.log"
    # symbolize=0: this is a pre-push smoke run, not a crash-triage
    # session -- a crash still saves its input to disk for offline
    # repro (with full symbolization) via `$bin <crash-file>` (see the
    # fail message below). Without this, the FIRST new-coverage event
    # (libFuzzer's "NEW_FUNC" print) makes the sanitizer runtime spawn
    # an external llvm-symbolizer subprocess to resolve the address --
    # confirmed hanging indefinitely under this repo's own sandboxed
    # dev environment (near-zero CPU usage while blocked, reproduced
    # identically with and without -fsanitize=address, and NOT
    # reproducible as a real infinite loop in parse_vector_csv/
    # parse_corpus/parse_index_csv themselves via 5M+ direct fuzz-style
    # calls against each function with a wall-clock alarm(); confirmed
    # fixed by this exact env var). Cheap, safe insurance against the
    # same class of subprocess-spawn restriction on a locked-down CI
    # runner, not just this one sandbox.
    if ASAN_OPTIONS=detect_leaks=0:symbolize=0 UBSAN_OPTIONS=symbolize=0 \
        "$bin" -max_total_time="$fuzz_time" -print_final_stats=1 \
        "tests/fuzz/corpus_${target}/" >"$runlog" 2>&1; then
      local execs; execs=$(grep -o "number_of_executed_units: [0-9]*" "$runlog" | grep -o "[0-9]*")
      pass "30 fuzz_smoke: $target -- ${fuzz_time}s clean (${execs:-?} execs, no crash)"
    else
      fail "30 fuzz_smoke: $target -- crash/hang found, see $runlog (repro: $bin <crash-file>)"
    fi
    rm -f "$bin"
  done
}

# --- run ------------------------------------------------------------

run_major() {
  local v="$1"; shift
  local gates=("$@")
  printf "== MariaDB %s ==\n" "$v"

  for g in "${gates[@]}"; do [ "$g" = "01" ] && gate_01_build; done
  # Gate 30 (fuzz smoke) is standalone like gate 01 -- links
  # src/fractalsql_parse.c + src/fractalsql_interrupt.c directly, no
  # extension .so, no mariadbd, no cluster at all.
  for g in "${gates[@]}"; do [ "$g" = "30" ] && gate_30_fuzz_smoke; done

  local need_db=0
  for g in "${gates[@]}"; do
    case "$g" in 02|03|04|05|06|07|08|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|31|32|33|34|35|36|37|38) need_db=1 ;; esac
  done
  if [ "$need_db" -eq 1 ]; then
    mdb_setup "$v"; local rc=$?
    if [ "$rc" -eq 1 ]; then skip "MariaDB $v runtime gates (mariadbd not found for this major)"; return; fi
    # rc=3: mdb_setup printed its own [SKIP] message (darwin-asan against
    # a non-instrumented mariadbd) -- nothing more to add here.
    if [ "$rc" -eq 3 ]; then return; fi
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
        33) gate_33_conf_gate ;;
        34) gate_34_reasoning_conf_live ;;
        31) gate_31_sql_agent_savepoint ;;
        32) gate_32_new_primitives ;;
        35) gate_35_enterprise_mock ;;
        36) gate_36_morphology_metrics ;;
        37) gate_37_oom_injection ;;
        38) gate_38_fatal_signal ;;
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
  for v in 10.6 10.11 11.4 12.3; do run_major "$v" "${DEFAULT_GATES[@]}"; done
elif [ "$MODE" = "fuzz" ]; then
  run_major "$MDB_MAJOR" "${FUZZ_GATES[@]}"
elif [ "$MODE" = "fault" ]; then
  run_major "$MDB_MAJOR" "${DEFAULT_GATES[@]}" "${FAULT_GATES[@]}"
else
  run_major "$MDB_MAJOR" "${DEFAULT_GATES[@]}"
fi

[ "$COVERAGE" -eq 1 ] && run_coverage_report

echo ""
# On any gate FAIL, print the tails of the diagnostic logs whose
# contents nothing else in the run has shown: the captured server log
# (supervisor output; with --defaults-file the vendored reasoning
# plugin's "fractalsql-reasoning-http: ..." lines can only surface
# here), mariadbd's own stderr (preserved from the datadir .err by
# mdb_teardown -- the only place a sanitizer report or UDF crash
# backtrace lands) and the mock LLM's request log -- the only cause
# record for a bare-NULL UDF result. Mirrors
# build_test.ps1's Mdb-Teardown FAIL dump 1:1.
if [ "$FAILED" -ne 0 ]; then
  for log in \
    "/tmp/fractalsql_bt_server_${MDB_MAJOR//./_}.log" \
    "/tmp/fractalsql_bt_mockllm_${MDB_MAJOR//./_}.log" \
    "/tmp/fractalsql_bt_mariadbd_err_${MDB_MAJOR//./_}.log"; do
    if [ -f "$log" ]; then
      printf -- "--- tail of %s ---\n" "$log"
      tail -40 "$log"
      echo ""
    fi
  done
fi
if [ "$FAILED" -eq 0 ]; then printf "${G}build_test: PASS${Z}\n"; exit 0
else printf "${R}build_test: FAIL${Z}\n"; exit 1; fi
