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
#   67  mcp_fuzz         FUZZ ONLY (--fuzz). libFuzzer targets over the MCP    ~60s
#                        server: JsonRpcServer::handleLine with stub tools
#                        and the argument-coercion / secret-redaction
#                        functions. No cluster needed; same clang
#                        requirement and FSQL_FUZZ_TIME budget as gate 30.
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
#   39  mcp_smoke       the full MCP session against the scratch        ~10s
#                        cluster: initialize, the 93-tool catalog,
#                        per-tier tools/call round trips (happy paths
#                        and clean error paths), $/cancel with KILL
#                        QUERY, resources+prompts, and the S-FT-004
#                        partial-reasoning case through the admin
#                        tools (spec 8.3; driver: mcp/tests/
#                        mcp_smoke_client.py; self-skips without a
#                        toolchain, mirrors build_test.ps1's own gate)
#   46  ledger_tsan     TSAN ONLY (--tsan, not in DEFAULT). The
#                        concurrent-ledger-write runner
#                        (service/tests/ledger_concurrency_runner.c)
#                        under ThreadSanitizer: 8 threads appending to
#                        ONE ledger file at once, which is the shape
#                        the daemon's own N client connections produce
#                        (the ledger is a file with a process-wide
#                        lock, not a database table). The runner links
#                        the same adapter objects the daemon links, so
#                        the code under test is the shipped code. It
#                        also re-walks the resulting chain: every
#                        record links to its predecessor's hash, every
#                        hash and MAC recomputes, and no append was
#                        lost or duplicated. Skips (rather than
#                        passes) when the run is not instrumented --
#                        an uninstrumented runner cannot observe a
#                        race, so "no race found" would mean nothing.
#   50  kits            the twenty-nine newer industry kits (demo/demo-       ~15s
#                        vertical-{ev-battery-lifecycle,adas-safety-
#                        validation,v2x-warranty-triage,critical-
#                        inventory-routing,heavy-industry-predictive-
#                        maintenance,climatech-grid-balancing,hazmat-
#                        occupational-triage,scenario-planning-
#                        simulation,avionics-fault-prediction,
#                        satellite-constellation-coverage,telecom-
#                        account-anomaly-screening,telecom-traffic-
#                        routing,climatech-emissions-monitoring,
#                        climatech-risk-exposure,rf-spectrum-sensing}
#                        .sql): each is piped through the scratch
#                        cluster's client, raises no SQL error (the
#                        scenario kit's plan_explore needs an
#                        embedding endpoint: at most one expected),
#                        prints no NaN, and reproduces its headline
#                        result on its deterministic fixture
#   51  udf_sweeps      every UDF called with malformed, extreme and
#                        oversize arguments (0-8 arguments of mixed
#                        types and NULL, each seed call with one argument
#                        at a time set to an edge value, numeric series of
#                        many lengths and shapes, JSON parameter objects
#                        in many spellings, inputs past the 4 MiB limit,
#                        the session configuration functions across every
#                        key), then the enterprise functions again with
#                        the mock core loaded. Passes when the daemon is
#                        still running and answering and logged no FATAL.
#                        FSQL_ROBUST_STRIDE=N runs every Nth statement of
#                        each sweep (default 1: all of them, about a
#                        minute); the sweeps are generated by
#                        tests/robustness/udf_sweep.py
#   52  validators      the text-to-SQL allowlist (under both
#                        t2s_allowed_statements settings) and the
#                        audit-log JSON check against the tables in
#                        tests/robustness/: every statement or payload
#                        with its correct verdict
#   53  daemon_frames   authenticated but malformed protocol frames for
#                        every opcode (tests/robustness/frame_fuzz.py)
#   54  daemon_conf_boot  configuration files and command lines the daemon
#                        must accept or refuse at startup
#   55  ledger_forged   ledgers built by hand with tests/robustness/
#                        ledger_forge.py, valid and corrupted in every way
#                        the integrity check should notice, under a
#                        matching key, no key and the wrong key
#   56  ledger_files    unusable, read-only and missing ledger paths
#   58  enterprise_loading  fourteen enterprise_lib / signature
#                        combinations (not a library, empty file, wrong or
#                        mismatched signatures, no required symbols, an
#                        unsigned library with and without
#                        enterprise_require_signature): none that should be
#                        refused may load, none may take the daemon down
#   59  provider_reload  live reloads of the provider settings: every key
#                        removed, changed and restored in turn with a
#                        reasoning, embedding and text-to-SQL call after
#                        each, refused invalid values leave the running
#                        settings alone, and fractal_t2s_config() shows
#                        what the daemon is using
#   60  scripted_replies  tests/scripted_reasoning_plugin.c returns
#                        scripted replies (normal, empty, an error code, no
#                        summary at all, past the 16 MiB limit): fractal_
#                        reason, fractal_t2s_generate and fractal_t2s_review
#                        pass the good ones through and refuse the broken
#                        ones, and the review verdict follows its rule
#   61  daemon_limits   a throwaway daemon with max_connections = 3 and
#                        a one-second idle timeout: the fourth connection
#                        is refused, a closed connection frees its slot, a
#                        silent one is closed, and a reload applies a new
#                        limit but refuses one that moves the socket or the
#                        key file
#   62  provider_env    provider settings that come from the daemon's
#                        environment: applied, ignored when out of range,
#                        and overridden by the same key in the file
#   63  direct_calls   service/tests/udf_direct.c calls the UDF entry points,
#                        the configuration library, the session registry and
#                        the provider settings directly, with edge-value
#                        arguments, an interruption at each poll and scripted
#                        reasoning replies, in the community configuration and
#                        again with the enterprise mock core loaded. FSQL_
#                        DIRECT_STRIDE (default 3) thins the mutated calls
#   64  direct_faults  FAULT ONLY (--fault, Linux): the same driver with an
#                        injected failure at every allocation and file call
#                        of each call, round and apply
#   57  fault_sweeps    FAULT ONLY (--fault, Linux). One injected
#                        allocation failure at every point of a long list
#                        of calls, one injected file-system failure at
#                        every point of the ledger code, and failures
#                        during daemon startup, socket and thread failures
#                        (accept, recv, send, pthread_create and the rest)
#                        while the daemon serves, all against one long-lived
#                        daemon armed through tests/oom_preload.c. The
#                        socket sweep tries FSQL_SYS_MAX_K (default 30)
#                        call numbers under nine errno values.
#                        FSQL_OOM_MAX_N (default 45) caps the allocation
#                        number tried per call, FSQL_IO_MAX_M (default 400)
#                        the file-call number; a sweep also stops once the
#                        failure point is past the end of the call
#
# NOT ported, each for its own documented reason (see the architecture-
# differences block above, not a TODO backlog):
#   09  superuser-only     (permanently N/A, no sysvar surface exists
#                          by design)
#   53 54 56 57 59 61 62 63 64 (robustness gates) are POSIX only: they talk to
#   the daemon over its Unix socket, rebuild it under LD_PRELOAD, signal it or
#   link the adapter objects with a POSIX-only driver, and the Windows daemon
#   listens on a named pipe instead. 51 52 55 58 60 need only the SQL layer
#   and the pipe, and build_test.ps1 runs them
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
#             21 22 23 24 25 26 29 31 32 33 34 35 36 39
#   FUZZ    = 30                                       --fuzz runs ONLY gate 30 -- no cluster, standalone
#   FAULT   = 37 38 57                                  --fault runs DEFAULT, then ADDS gates 37, 38 and 57 after it
#                                                       (37 restarts fractalsqld hundreds of times on top of
#                                                       the default run -- real wall-time, no crashes expected;
#                                                       38 deliberately SIGABRTs the daemon once to prove
#                                                       on_fatal logs and exits cleanly, then restarts it;
#                                                       57 arms one long-lived daemon with an injected
#                                                       allocation or file-system failure per trial)
#   TSAN    = 46                                       --tsan runs DEFAULT, then ADDS gate 46 after it
#                                                       (46 only means anything in an instrumented build, so it
#                                                       is not in DEFAULT; a plain run would report a
#                                                       meaningless "no race found" every time)
#   (26/27/28 stay opt-in: each needs a real, licensed enterprise .so
#   this public repo doesn't ship -- see gate_26_enterprise_active's own
#   header comment.)
#
# Usage:
#   ./build_test.sh                  # DEFAULT against MDB_MAJOR (default 11.4)
#   ./build_test.sh --quick
#   ./build_test.sh --mdb 10.6
#   ./build_test.sh --cross          # DEFAULT against every installed major
#   ./build_test.sh --profile        # Linux: valgrind memcheck over the UDF shim, the fractalsqld daemon (the engine) and
#                                    # the MCP server: mariadbd and the daemon under valgrind with the demo kits, the MCP
#                                    # probes, and the running MCP server; tests/valgrind_run.sh. Fails on a memcheck error or
#                                    # definite/indirect leak with a frame in our code. Not in any gate set.
#   ./build_test.sh --fuzz           # gates 30 and 67 -- libFuzzer smoke (extension parsers,
#                                    # then the MCP server's request handling), no cluster
#   ./build_test.sh --fault          # DEFAULT, then the OOM-injection sweep (37), the
#                                    # fatal-signal handler check (38) and the fault
#                                    # sweeps (57) after it
#   ./build_test.sh --gate 06
#   ./build_test.sh --gate mcp       # only the MCP server gates (39 40 42 43 44 66; plus 65
#                                    # with --fault), after gate 01. Combine with --asan,
#                                    # --ubsan or --tsan to run the server itself sanitized.
#   ./build_test.sh --list
#   ./build_test.sh --coverage       # gcov-instrumented build; the DEFAULT gates plus the fault gates (as --fault);
#                                    # the report must reach FSQL_COV_MIN (default 80)% lines, functions and branches;
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
#   FSQL_OOM_GATE37_MAX_N   allocation-count sweep ceiling per UDF in
#                           gate 37 alone (default: FSQL_OOM_MAX_N, else
#                           200; gate 57 reads FSQL_OOM_MAX_N, default 45).
#                           Each N restarts
#                           fractalsqld fresh (see tests/oom_preload.c),
#                           so this is real wall-time too, just smaller
#                           per-step than gate 30's.

set -uo pipefail
# Test fixtures ship an unsigned mock enterprise core; the product default (signature required) is exercised explicitly in gate 28.
export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE="${FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE:-0}"
# Test fixtures load unsigned mock reasoning plugins; the product default (a valid signature required) is bypassed explicitly here.
export FSQL_REASONING_REQUIRE_SIGNATURE="${FSQL_REASONING_REQUIRE_SIGNATURE:-0}"

# Captured before the arg-parsing loop below consumes "$@" via `shift` --
# needed later to re-exec this same invocation under setarch (--tsan
# only; see that check further down).
ORIG_ARGV=("$@")

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# GNU timeout is `timeout` on Linux, `gtimeout` on macOS (Homebrew coreutils) and absent from a bare
# macOS. Gates that bound a long run use ${BT_TIMEOUT_BIN:+$BT_TIMEOUT_BIN <seconds>} in front of the
# command; with no timeout available the command simply runs unbounded.
BT_TIMEOUT_BIN=""
for _bt_t in timeout gtimeout; do
  if command -v "$_bt_t" >/dev/null 2>&1; then BT_TIMEOUT_BIN="$_bt_t"; break; fi
done
unset _bt_t
cd "$HERE"

TMPROOT="$(cd /tmp && pwd -P)"

DEFAULT_GATES=(01 02 03 04 05 06 07 08 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 29 31 32 33 34 35 36 39 40 41 42 43 44 45 47 48 49 50 51 52 53 54 55 56 58 59 60 61 62 63 66 68 69 70 71 72 73 74 75 76)
QUICK_GATES=(01 02)
FUZZ_GATES=(30 67)
FAULT_GATES=(37 38 57 64 65)
# Gate 46 (the TSan ledger-concurrency runner) is --tsan-only, like this
# repo's other sanitizer-specific work: it links a standalone runner
# that hammers the ledger from N threads, and only means anything when
# the code under test was itself built with -fsanitize=thread. Not in
# DEFAULT_GATES -- running it uninstrumented proves nothing.
TSAN_GATES=(46)

MDB_MAJOR="${MDB_MAJOR:-11.4}"
MODE="default"
ONE_GATE=""
COVERAGE=0
ASAN=0
UBSAN=0
TSAN=0

if [ -t 1 ]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; Z="\033[0m"; else G=""; R=""; Y=""; Z=""; fi
pass() { printf "  [${G}PASS${Z}] %s\n" "$1"; }
fail() {
  # A sanitizer runtime that refused to start in the HOST process (the
  # Darwin DYLD_INSERT_LIBRARIES preload path) says nothing about the
  # extension: report it as a skip, not a failure. Any other failure is
  # still a real FAIL.
  if [ -n "${SAN_RUNTIME_REFUSED:-}" ]; then
    SAN_RUNTIME_REFUSED=""
    skip "$1 -- skipped: the sanitizer runtime refused to start in this host process (Darwin DYLD_INSERT_LIBRARIES; not an extension failure)"
    return 0
  fi
  printf "  [${R}FAIL${Z}] %s\n" "$1"; FAILED=1
}
skip() { printf "  [${Y}SKIP${Z}] %s\n" "$1"; }

# Runs a command, and if the sanitizer runtime refused to start in the
# host process, records that fact (SAN_RUNTIME_REFUSED=1) so the next
# fail() reports a SKIP instead. The command's own output is still
# printed and its exit status still returned.
san_aware_run() {
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qE "Interceptors are not working|loaded too late"; then
    SAN_RUNTIME_REFUSED=1
  fi
  return $rc
}

usage() { sed -n '4,160p' "$0"; exit 0; }

# drop_scope_exit_branches <in.info> <out.info>
# The mcp/ server is heavy template C++ (nlohmann json, std::string): at the
# CLOSING line of a scope -- a bare "}", "} );", "} } );" -- gcc/gcov report
# a "branch" for every temporary's destructor and cleanup edge. They are
# compiler-generated, carry no source-level decision, and are not tagged as
# exception edges, so the 'e'-block filter alone leaves them in the
# denominator (on a 4k-line server it was about 1,000 of 8,700 branches, e.g.
# 76 "missed" on the single "}" that ends resources.cpp's table builder).
# Drops BRDA records whose source line is only closing punctuation, plus those on
# tool-table registration rows (see the comment at the second rule), and
# recomputes BRF/BRH per file; prints the number dropped (and how many of those
# were registration rows) on stderr.
drop_scope_exit_branches() {
  local in="$1" out="$2"
  awk -v outfile="$out" '
    function flush(   i, brf, brh, p) {
      brf = 0; brh = 0
      for (i = 1; i <= nl; i++) if (keep[i] && substr(L[i], 1, 5) == "BRDA:") {
        split(substr(L[i], 6), p, ",")
        brf++; if (p[4] != "-" && p[4] + 0 > 0) brh++
      }
      for (i = 1; i <= nl; i++) {
        if (!keep[i]) continue
        if (substr(L[i], 1, 4) == "BRF:") print "BRF:" brf > outfile
        else if (substr(L[i], 1, 4) == "BRH:") print "BRH:" brh > outfile
        else print L[i] > outfile
      }
    }
    BEGIN { nl = 0 }
    {
      line = $0
      if (substr(line, 1, 3) == "SF:") {
        file = substr(line, 4); n = 0; delete src
        while ((getline sl < file) > 0) { n++; src[n] = sl }
        close(file)
      }
      L[++nl] = line; keep[nl] = 1
      if (substr(line, 1, 5) == "BRDA:") {
        split(substr(line, 6), p, ",")
        if (src[p[1] + 0] ~ /^[ \t]*[})\];,]+[ \t})\];,]*$/) { keep[nl] = 0; dropped++ }
        # A tool-table registration row: "t.push_back( ToolSpec{ name, category, ..., lambda } );".
        # It is declarative (no decision in the row itself -- the handler lambda is on its own
        # lines and stays counted), but the aggregate initialiser builds a std::vector of params,
        # a std::function and several strings in one expression, and gcov attributes about six
        # unwind/cleanup branches per row that no input can reach (78 rows, ~470 of them).
        else if (index(src[p[1] + 0], "t.push_back( ToolSpec{") > 0) { keep[nl] = 0; dropped++; reg++ }
      }
      if (line == "end_of_record") { flush(); nl = 0; delete keep; delete L }
    }
    END { print dropped + 0, reg + 0 > "/dev/stderr" }
  ' "$in" 2>"$out.dropped"
  read -r SCOPE_EXIT_DROPPED REG_ROW_DROPPED < "$out.dropped" 2>/dev/null || true
  rm -f "$out.dropped"
}

# MCP server coverage (mcp/src/*.cpp, mcp/src/adapters/*.cpp). Only produced
# when the MCP gates ran an instrumented binary (see mcp_resolve_exe). The
# .gcda files were redirected to $GCOV_PREFIX like the daemon's, so each is
# copied back next to its .gcno first. The instrumented objects are removed
# afterwards so a later plain run does not pick up an instrumented binary.
run_mcp_coverage_report() {
  local g tail found=0 ngcno
  ngcno="$(find "$HERE/mcp/src" -name '*.gcno' 2>/dev/null | wc -l | tr -d '[:space:]')"
  # Match on the trailing mcp/src/... part, not on the checkout's own name,
  # so a different mount point or a symlinked checkout cannot hide the files.
  while IFS= read -r g; do
    tail="${g##*/mcp/src/}"
    [ -f "$HERE/mcp/src/${tail%.gcda}.gcno" ] || continue
    cp "$g" "$HERE/mcp/src/$tail" && found=1
  done < <(find "$GCOV_PREFIX" -path '*/mcp/src/*.gcda' 2>/dev/null)
  if [ "$found" -eq 0 ]; then
    skip "coverage: no mcp/src/*.gcda produced ($ngcno .gcno present, $(find "$GCOV_PREFIX" -name '*.gcda' 2>/dev/null | wc -l | tr -d '[:space:]') .gcda under the redirect dir; the MCP gates did not run an instrumented server, see their own skip/fail reasons above)"
    return
  fi
  if ! command -v lcov >/dev/null 2>&1; then
    skip "coverage: lcov not installed, skipping the MCP report"
    return
  fi
  # --ignore-errors mismatch: nlohmann::json.hpp is instantiated per TU and
  # geninfo's merge step trips on its exception tags across TUs even though
  # every TU's own counts are right. no_exception_branch=1 goes to genhtml
  # only: passed to geninfo it zeroes BRF/BRH for this lcov version.
  lcov --capture --directory mcp/src --output-file "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" \
       --rc branch_coverage=1 --ignore-errors mismatch >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1 \
    || { fail "coverage: mcp lcov capture failed; see $TMPROOT/fractalsql_bt_lcov.log"; return; }
  lcov --extract "$TMPROOT/fractalsql_bt_mcp_coverage_raw.info" '*/mcp/src/*' \
       --output-file "$TMPROOT/fractalsql_bt_mcp_coverage.info" \
       --rc branch_coverage=1 >>"$TMPROOT/fractalsql_bt_lcov.log" 2>&1
  drop_scope_exit_branches "$TMPROOT/fractalsql_bt_mcp_coverage.info" "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

  echo ""
  echo "=== coverage (mcp/src/*.cpp) ==="
  echo "  (branch counts exclude exception edges, $(( ${SCOPE_EXIT_DROPPED:-0} - ${REG_ROW_DROPPED:-0} )) compiler records on closing-brace lines"
  echo "   and ${REG_ROW_DROPPED:-0} records on tool-table registration rows)"
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRDA:/ {
      split($2, p, ",")
      if (substr(p[2], 1, 1) != "e") {
        brf++
        if (p[4] != "-" && p[4]+0 > 0) brh++
      }
    }
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
    }' "$TMPROOT/fractalsql_bt_mcp_coverage_f.info"

  if command -v genhtml >/dev/null 2>&1; then
    genhtml "$TMPROOT/fractalsql_bt_mcp_coverage_f.info" --output-directory coverage_html_mcp \
            --rc branch_coverage=1 --rc no_exception_branch=1 >>"$TMPROOT/fractalsql_bt_genhtml.log" 2>&1 \
      && pass "coverage: mcp report at coverage_html_mcp/index.html" \
      || fail "coverage: mcp genhtml failed; see $TMPROOT/fractalsql_bt_genhtml.log"
  fi
  find "$HERE/mcp/src" \( -name '*.gcno' -o -name '*.gcda' \) -delete 2>/dev/null
  make -C "$HERE/mcp" clean >/dev/null 2>&1
}

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
  # Every instrumented object, found from its .gcno rather than from a
  # fixed list, so a source file added later is reported without anyone
  # remembering to extend this loop (fractalsql_config.c and
  # fractalsql_config_udf.c were missing from the old list).
  local gcno
  for gcno in service/build/daemon/*.gcno; do
    [ -e "$gcno" ] || continue
    f="$(basename "$gcno" .gcno)"
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
  #
  # NOTE: no_exception_branch=1 is NOT passed to lcov --capture/
  # --extract (only to genhtml, below) -- confirmed empirically that
  # passing it to geninfo at capture time zeroes out BRF/BRH entirely
  # for this lcov/geninfo version (2.0-1) when combined with
  # --branch-coverage, a geninfo bug in that combination, not a sign the
  # setting itself is wrong. It works correctly when passed to genhtml
  # alone, reading the already-captured .info's per-branch exception tag
  # at render time.
  lcov --extract /tmp/fractalsql_bt_coverage_raw.info '*/src/*.c' '*/daemon/fractalsqld.c' \
       --output-file /tmp/fractalsql_bt_coverage.info \
       --rc branch_coverage=1 >>/tmp/fractalsql_bt_lcov.log 2>&1

  echo ""
  echo "=== coverage (src/*.c, daemon/fractalsqld.c) ==="
  # Computed directly from the .info file's own LF/LH/FNF/FNH totals
  # (lcov 2.0-1's --list renderer miscomputes its Rate% column against
  # this intermediate gcov-JSON-derived .info -- seen in the PG runner,
  # a nonsensical 1170% function rate -- even though the underlying
  # LF:/LH:/etc. totals, and genhtml's own report built from the same
  # file, are both correct), but branches are summed directly from the
  # raw BRDA: lines rather than trusted from the .info's own BRF:/BRH:
  # fields, EXCLUDING exception-tagged branches (an 'e' prefix on
  # BRDA's block-number field). A no-op for src/*.c and the daemon
  # (plain C has no exceptions, so nothing is ever 'e'-tagged there),
  # but this way the text summary always matches what genhtml's
  # --rc no_exception_branch=1 report shows.
  awk -F: '
    /^LF:/ { lf += $2 } /^LH:/ { lh += $2 }
    /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
    /^BRDA:/ {
      split($2, p, ",")
      if (substr(p[2], 1, 1) != "e") {
        brf++
        if (p[4] != "-" && p[4]+0 > 0) brh++
      }
    }
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

  # The floor: lines, functions and branches each at or above FSQL_COV_MIN (default 80) -- enforced for the full measurement only
  # (--coverage over the default and fault gates); a partial run just reports.
  if [ "${COV_FULL:-0}" -eq 1 ]; then
    local floor="${FSQL_COV_MIN:-80}" pct
    pct="$(awk -F: '
      /^LF:/ { lf += $2 } /^LH:/ { lh += $2 } /^FNF:/ { fnf += $2 } /^FNH:/ { fnh += $2 }
      /^BRDA:/ { split($2, p, ","); if (substr(p[2], 1, 1) != "e") { brf++; if (p[4] != "-" && p[4]+0 > 0) brh++ } }
      END { printf "%.1f %.1f %.1f", (lf ? 100*lh/lf : 100), (fnf ? 100*fnh/fnf : 100), (brf ? 100*brh/brf : 100) }' /tmp/fractalsql_bt_coverage.info)"
    local m name v i=0
    for name in lines functions branches; do
      i=$((i + 1)); v="$(printf '%s' "$pct" | cut -d' ' -f$i)"
      if awk -v v="$v" -v t="$floor" 'BEGIN { exit !(v + 0 >= t + 0) }'; then pass "coverage: $name $v% (floor $floor%)"
      else fail "coverage: $name $v% is below the $floor% floor"; fi
    done
  fi

  if command -v genhtml >/dev/null 2>&1; then
    genhtml /tmp/fractalsql_bt_coverage.info --output-directory coverage_html \
            --rc branch_coverage=1 --rc no_exception_branch=1 >/tmp/fractalsql_bt_genhtml.log 2>&1 \
      && pass "coverage: report at coverage_html/index.html" \
      || fail "coverage: genhtml failed, see /tmp/fractalsql_bt_genhtml.log"
  fi
  run_mcp_coverage_report
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
    --profile)  exec "$HERE/tests/valgrind_run.sh" ;;
    --asan)    ASAN=1 ;;
    --ubsan)   UBSAN=1 ;;
    --tsan)    TSAN=1 ;;
    --list)    printf "gates: %s\nfuzz gates: %s\nfault gates: %s\ntsan gates: %s (--tsan only)\n" "${DEFAULT_GATES[*]}" "${FUZZ_GATES[*]}" "${FAULT_GATES[*]}" "${TSAN_GATES[*]}"; exit 0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --coverage measures the whole suite: the default gates AND the fault gates (37, 57, 63/64, 65), whose allocation- and file-failure
# injection reaches the error paths the default gates cannot. (A run restricted to one gate, or to --quick/--fuzz/--cross, only reports.)
COV_FULL=0
if [ "$COVERAGE" -eq 1 ] && [ -z "$ONE_GATE" ] && { [ "$MODE" = default ] || [ "$MODE" = fault ]; }; then MODE="fault"; COV_FULL=1; fi

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
  # Keep the key file if there is one. The server's shim reads the key once
  # and holds it for the life of the server process, so a daemon restarted in
  # place (gates 37, 38 and 51-62 do that, without restarting the server) with
  # a NEW key would fail authentication on every call that follows.
  if [ ! -s "$key" ]; then
    openssl rand -hex 32 > "$key" || return 1
  fi
  chmod 600 "$key" || return 1
  printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n' \
    "$FSQD_SOCK" "$key" "$(id -u)" > "$FSQD_CONF"
  # The reasoning_plugin key rides in the conf, not only in the daemon's
  # boot environment, so the MCP gate's shutdown-drain phase can SWAP it
  # live (the admin tier's fractal_daemon_config_set -> daemon RELOAD) to
  # point the daemon at a deterministically-slow reasoning fixture, and
  # put it back afterwards. The boot-environment fallback still applies
  # for a key the conf does not carry, so writing it here changes
  # nothing about which plugin the daemon uses -- it only makes the
  # value readable and writable through the admin tier.
  #
  # The value must be the plugin's own REAL path: the reasoning core
  # refuses a configured path that does not equal its own resolution
  # ("reasoning plugin path is not canonical"). $PLUGDIR is under
  # $TMPROOT, which on a macOS box is /var/folders/... -- a real path
  # there, but a /tmp symlink on some systems would not be, so resolve
  # it rather than trusting the string.
  #
  # cd+pwd -P, not `readlink -f`: BSD readlink has no -f on macOS
  # releases before 12, and `readlink -f` on a PATH THAT EXISTS still
  # fails there. `pwd -P` resolves every symlinked segment of the
  # directory and is POSIX everywhere.
  if [ -n "${FRACTALSQL_REASONING_PLUGIN:-}" ]; then
    local rp rpdir rpbase
    rpdir="$(dirname "$FRACTALSQL_REASONING_PLUGIN")"
    rpbase="$(basename "$FRACTALSQL_REASONING_PLUGIN")"
    rp="$(cd "$rpdir" 2>/dev/null && pwd -P)/$rpbase"
    [ -n "$rp" ] || rp="$FRACTALSQL_REASONING_PLUGIN"
    printf 'reasoning_plugin = %s\n' "$rp" >> "$FSQD_CONF"
  fi
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
  install -m 0644 "$HERE/include/$fsql_platform/fractalsql-reasoning-http.so.sig" "$PLUGDIR/fractalsql-reasoning-http.so.sig" || return 2
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
  REVIEW_MODE_SO="$PLUGDIR/review_mode_reasoning.so"
  SLOW_SO="$PLUGDIR/slow_reasoning.so"
  # The slow plugin is consumed by the MCP gate's shutdown-drain phase
  # (gate 39), which needs its path across the process boundary -- so it
  # is exported, not just a local. The other fixtures stay local: they
  # are only ever swapped in by a gate that runs in THIS shell.
  export MCP_SLOW_REASONING_PLUGIN="$SLOW_SO"
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
  # The text-to-SQL tier's REVIEW-ISOLATION fixture (gate 48): reports the
  # RESPONSE_MODE its own plugin instance was born with, captured at
  # fsql_reasoning_init time (see that file's own header for why
  # init-time capture is the only meaningful measurement).
  cc -shared -fPIC -std=c99 $fsql_inc tests/review_mode_reasoning_plugin.c -o "$REVIEW_MODE_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
    || { cat /tmp/fractalsql_bt_setup_${v//./_}.log >&2; return 2; }
  # A deterministically-SLOW reasoning plugin: generate() sleeps
  # FSQL_MOCK_SLOW_MS (default 3000) before answering. Used by the MCP
  # gate's shutdown-drain phase (gate 39) to hold a request genuinely
  # in flight at the moment the daemon is asked to shut down, so the
  # transport's drain-wait loop is actually exercised instead of losing
  # a sub-millisecond race every time.
  cc -shared -fPIC -std=c99 $fsql_inc tests/slow_reasoning_plugin.c -o "$SLOW_SO" 2>/tmp/fractalsql_bt_setup_${v//./_}.log \
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

# Restores the real HTTP-wrapper reasoning plugin WITHOUT wiping the
# datadir -- the in-place counterpart of mdb_restore_reasoning_plugin,
# for a gate whose assertions are about rows that already exist in the
# live database (the vectorizer queue). mdb_restore_reasoning_plugin
# calls mdb_setup, which unconditionally wipes $DATADIR -- that would
# destroy the very state the gate is inspecting. The plugin path is
# restored to the same default mdb_setup uses.
mdb_restore_reasoning_plugin_inplace() {
  export FRACTALSQL_REASONING_PLUGIN="$PLUGDIR/fractalsql-reasoning-http.so"
  mdb_restart_inplace_reasoning_plugin "$PLUGDIR/fractalsql-reasoning-http.so"
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
  # The server takes a moment to finish shutting down after the signal,
  # and the supervisor refuses to start a replacement while the old one
  # is still there ("A mysqld process already exists"), so the new
  # server would never come up. Wait for the old one to go, then clear
  # the pid file it leaves behind.
  local w
  for w in $(seq 1 120); do
    ps ax 2>/dev/null | grep -q "mariadbd [.]*$DATADIR" || break
    sleep 0.5
  done
  rm -f "$PIDFILE"

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
# Which sanitizers/instrumentation an already-built service/build/fractalsqld carries, from its symbols
# ("plain" when none). A binary left behind by an earlier --tsan/--asan/--coverage run must never be tested by a run
# that asked for something else (a TSan build does not even start on a kernel with a wide mmap layout).
service_flavor() {
  local b="$HERE/service/build/fractalsqld" syms f=""
  [ -x "$b" ] || { echo none; return; }
  syms="$({ nm -D "$b" 2>/dev/null; nm "$b" 2>/dev/null; } | awk '{print $NF}')"
  grep -q '^__tsan_'  <<< "$syms" && f="$f tsan"
  grep -q '^__asan_'  <<< "$syms" && f="$f asan"
  grep -q '^__ubsan_' <<< "$syms" && f="$f ubsan"
  grep -q '^__gcov_'  <<< "$syms" && f="$f coverage"
  echo "${f# }" | sed 's/^$/plain/'
}
wanted_service_flavor() {
  local f=""
  [ "$TSAN" -eq 1 ]     && f="$f tsan"
  [ "$ASAN" -eq 1 ]     && f="$f asan"
  [ "$UBSAN" -eq 1 ]    && f="$f ubsan"
  [ "$COVERAGE" -eq 1 ] && f="$f coverage"
  echo "${f# }" | sed 's/^$/plain/'
}
# Called when gate 01 is NOT part of the run (it rebuilds service/ itself): rebuild if the leftover binary is the
# wrong flavor.
ensure_service_flavor() {
  local have want san_arg=""
  have="$(service_flavor)"; want="$(wanted_service_flavor)"
  [ "$have" = "$want" ] && return 0
  [ "$have" = none ] && return 0      # nothing built yet: the gate that needs it reports that itself
  printf '  [info] service/build/fractalsqld is a "%s" build but this run wants "%s": rebuilding service/\n' "$have" "$want"
  [ "$COVERAGE" -eq 1 ] && san_arg="COVERAGE=1"
  [ "$ASAN" -eq 1 ]     && san_arg="ASAN=1"
  [ "$UBSAN" -eq 1 ]    && san_arg="UBSAN=1"
  [ "$TSAN" -eq 1 ]     && san_arg="TSAN=1"
  local log="/tmp/fractalsql_bt_build.log"
  if make -C "$HERE/service" clean >"$log" 2>&1 && make -C "$HERE/service" $san_arg all >>"$log" 2>&1; then
    pass "service flavor: rebuilt service/ as \"$want\""
  else
    fail "service flavor: rebuilding service/ as \"$want\" failed, see $log"
  fi
}

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

  # A UDF error message is NEVER empty.
  #
  # The shim's three error buffers (service/shim/fractalsql_shim.c) are
  # what carry a daemon-side error back to the client: the daemon's
  # text is copied into the shim's `err[FSQ_MSG_MAX]` buffer and then
  # handed to MariaDB's `message` parameter, which MariaDB prints
  # after "Can't initialize function '<fn>';" or "ERROR <n> at line
  # 1:". If that buffer were not initialised, an error path that
  # produced no text would hand MariaDB an empty -- or, worse, an
  # uninitialised -- string, and the user would be shown the
  # boilerplate with the actual reason missing.
  #
  # An init-time error is the case that carries the detail: the
  # function's own argument check rejects the call before it ever
  # runs, and the reason travels the whole way back. So the detail
  # after MariaDB's prefix must be present and must be the function's
  # own message. (The plan named gate 38 for this; gate 38 kills the
  # daemon to test its fatal-signal path, so there is no live daemon
  # there to ask. The smoke gate is where a UDF error can actually be
  # provoked, so the assertion lives here.)
  local uerr; uerr=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_add('[1,2,3]');" 2>&1)
  echo "$uerr" | grep -q "Can't initialize function 'fractal_vector_add'" \
    && pass "02 smoke: a UDF error reaches the client" \
    || fail "02 smoke: a UDF error did not reach the client: $uerr"
  echo "$uerr" | grep -q "expected 2 arguments, got 1" \
    && pass "02 smoke: a UDF error carries a non-empty detail message" \
    || fail "02 smoke: a UDF error's detail message was empty or lost: $uerr"
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

  # Integer arguments past int range. A value that wraps back into range
  # (2^32 plus a valid value) must be refused, not run as the smaller value;
  # a refused call answers NULL. Each row is "label|call with {N}|valid value".
  local wrap_rows=(
    "search_debug iterations|SELECT fractal_search_debug('[1,2,3]', {N}, 10, 2, 42);|20"
    "search_debug population|SELECT fractal_search_debug('[1,2,3]', 20, {N}, 2, 42);|10"
    "search_debug diffusion|SELECT fractal_search_debug('[1,2,3]', 20, 10, {N}, 42);|2"
    "state_fingerprint n_bits|SELECT fractal_state_fingerprint('1,2,3', {N}, 42);|64"
  )
  local wrap_row wrap_label wrap_sql wrap_base wrap_val wrap_out wrap_bad=()
  for wrap_row in "${wrap_rows[@]}"; do
    IFS='|' read -r wrap_label wrap_sql wrap_base <<< "$wrap_row"
    wrap_out=$("${MARIADB[@]}" -N -e "${wrap_sql//\{N\}/$wrap_base}" 2>&1)
    if [ "$wrap_out" = "NULL" ] || echo "$wrap_out" | grep -q "^ERROR"; then
      wrap_bad+=("$wrap_label: the valid value $wrap_base was refused"); continue
    fi
    wrap_val=$((wrap_base + 4294967296))
    wrap_out=$("${MARIADB[@]}" -N -e "${wrap_sql//\{N\}/$wrap_val}" 2>&1)
    [ "$wrap_out" = "NULL" ] || wrap_bad+=("$wrap_label: $wrap_val answered '${wrap_out:0:40}'")
  done
  if [ ${#wrap_bad[@]} -eq 0 ]; then
    pass "19 sfs_bounds: ${#wrap_rows[@]} integer arguments reject a value that wraps back into range"
  else
    fail "19 sfs_bounds: integer arguments past int range: ${wrap_bad[*]}"
  fi
  local rk; rk=$("${MARIADB[@]}" -N -e "SELECT fractal_search('[[1,0]]', '[1,0]', 4294967297, '{}');" 2>&1)
  echo "$rk" | grep -qiE "k must be 1\.\.1000000|error" \
    && pass "19 sfs_bounds: k=4294967297 (wraps to 1) rejected" \
    || fail "19 sfs_bounds: k that wraps to 1 was accepted: $rk"
  local rb; rb=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('1,2,3', 33554425, 42);" 2>&1)
  [ "$rb" = "NULL" ] \
    && pass "19 sfs_bounds: state_fingerprint refuses an n_bits past the 4 MiB ceiling" \
    || fail "19 sfs_bounds: state_fingerprint accepted n_bits past the ceiling: ${rb:0:60}"
  # The cost is n_bits x vector length, so that product is bounded as well.
  local rw; rw=$("${MARIADB[@]}" -N -e "SELECT fractal_state_fingerprint('1,2,3,4,5,6,7,8,9', 33554424, 42);" 2>&1)
  [ "$rw" = "NULL" ] \
    && pass "19 sfs_bounds: state_fingerprint refuses n_bits x length past the work bound" \
    || fail "19 sfs_bounds: state_fingerprint accepted n_bits x length past the work bound: ${rw:0:60}"
  # The other bounded costs. Values are built in SQL so no argument is large;
  # a refused call answers NULL.
  local rbig
  rbig=$("${MARIADB[@]}" -N -e "SELECT fractal_search_debug(CONCAT('[', REPEAT('0.5,', 999), '0.5]'), 1000, 1000, 8, 42);" 2>&1)
  [ "$rbig" = "NULL" ] \
    && pass "19 sfs_bounds: search_debug refuses iterations x population x diffusion x dim past the work bound" \
    || fail "19 sfs_bounds: search_debug accepted a search past the work bound: ${rbig:0:60}"
  rbig=$("${MARIADB[@]}" -N -e "SELECT fractal_periodogram(CONCAT(REPEAT('0.1,', 1048576), '0.1'), 3);" 2>&1)
  [ "$rbig" = "NULL" ] \
    && pass "19 sfs_bounds: periodogram refuses a series past 1048576 samples" \
    || fail "19 sfs_bounds: periodogram accepted a series past 1048576 samples: ${rbig:0:60}"
  rbig=$("${MARIADB[@]}" -N -e "SELECT fractal_dimension_boxcount(CONCAT(REPEAT('1,2,', 2097153), '3,4'), 2);" 2>&1)
  [ "$rbig" = "NULL" ] \
    && pass "19 sfs_bounds: boxcount refuses points x dim past the work bound" \
    || fail "19 sfs_bounds: boxcount accepted points x dim past the work bound: ${rbig:0:60}"
  rbig=$("${MARIADB[@]}" -N -e "SELECT fractal_dimension_boxcount('0,0,1,0,0,1,1,1,2,2,3,1,1,3,4,4,nan,5', 2);" 2>&1)
  [ "$rbig" = "NULL" ] \
    && pass "19 sfs_bounds: boxcount refuses a non-finite coordinate" \
    || fail "19 sfs_bounds: boxcount accepted a non-finite coordinate: ${rbig:0:60}"
  rbig=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_subset(CONCAT(REPEAT('5,', 5999), '5'), NULL, 3000, '{}');" 2>&1)
  [ "$rbig" = "NULL" ] \
    && pass "19 sfs_bounds: optimize_subset refuses items x k past the work bound" \
    || fail "19 sfs_bounds: optimize_subset accepted items x k past the work bound: ${rbig:0:60}"
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
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_fk_child, bt_fk_parent;
    CREATE TABLE bt_fk_parent (a BIGINT NOT NULL, b BIGINT NOT NULL, PRIMARY KEY (a, b));
    CREATE TABLE bt_fk_child (
      pa BIGINT NULL, pb BIGINT NULL,
      FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a, b)
        ON DELETE CASCADE ON UPDATE SET NULL
    );
  " >/tmp/fractalsql_bt_gate03_fk.log 2>&1 \
    || fail "03 schema_context: composite-FK fixture setup failed: $(tail -1 /tmp/fractalsql_bt_gate03_fk.log)"

  local ctxfk; ctxfk=$("${MARIADB[@]}" -N -e "
    CALL fractal_schema_context(NULL, @ctxfk); SELECT @ctxfk;" 2>&1)
  if printf '%s' "$ctxfk" | grep -q "FOREIGN KEY (pa, pb) REFERENCES bt_fk_parent(a, b)" \
     && printf '%s' "$ctxfk" | grep -q "ON UPDATE SET NULL" \
     && printf '%s' "$ctxfk" | grep -q "ON DELETE CASCADE"; then
    pass "03 schema_context: composite FK with ON UPDATE/ON DELETE actions"
  else
    fail "03 schema_context: composite FK with actions, got: $ctxfk"
  fi
  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS bt_fk_child; DROP TABLE IF EXISTS bt_fk_parent;" >/dev/null 2>&1
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

  # A candidate that starts with something that is not a statement
  # keyword at all. The allowlist's leading-statement classifier
  # (t2s_classify_leading_stmt) reports such input as "OTHER", and
  # "OTHER" is never a permitted statement type -- so the rejection
  # reason here is the statement-type one, not a parse failure. (This
  # repo's allowlist has no separate "does not start with a keyword"
  # message: the classifier's OTHER bucket IS that case.)
  local a4; a4=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('123 not a keyword'), '<PASS>');" 2>&1)
  [ "$a4" != "<PASS>" ] && pass "04 text_to_sql: a non-keyword start is rejected" \
                         || fail "04 text_to_sql: expected '123 not a keyword' to be rejected"

  # INSERT in select-only mode. The default allowed_statements is
  # "select", so an INSERT candidate must be refused by the statement
  # type check -- the mode-specific branch of the classifier, not the
  # DDL branch the DROP TABLE case above covers.
  local a5; a5=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist('INSERT INTO bt_customers (name) VALUES (''x'')'), '<PASS>');" 2>&1)
  [ "$a5" != "<PASS>" ] && pass "04 text_to_sql: INSERT rejected in select-only mode" \
                         || fail "04 text_to_sql: expected INSERT to be rejected in select-only mode"
  echo "$a5" | grep -qi "not permitted" \
    && pass "04 text_to_sql: the INSERT rejection names the statement type" \
    || fail "04 text_to_sql: expected a 'not permitted' reason for INSERT, got: $a5"

  # Empty candidate: the allowlist's own "SQL is empty" branch, called
  # directly (no LLM). The model's own "no SQL at all" path is
  # asserted separately below, through the mock's NO_SQL_MARKER route
  # -- a fixed fenced ```sql reply cannot reach it.
  local a6; a6=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_check_allowlist(''), '<PASS>');" 2>&1)
  [ "$a6" != "<PASS>" ] && pass "04 text_to_sql: an empty candidate is rejected, not passed through" \
                         || fail "04 text_to_sql: expected an empty candidate to be rejected"
  echo "$a6" | grep -qi "empty" \
    && pass "04 text_to_sql: the empty-candidate rejection says so" \
    || fail "04 text_to_sql: expected an 'empty' reason, got: $a6"

  # The model replies with PROSE and no SQL at all (the mock's
  # NO_SQL_MARKER route). The GENERATE step has no candidate to
  # allowlist, so this must fail with a specific reason -- "the model
  # response contained no SQL" -- rather than handing back a NULL
  # out_sql with no explanation, or a garbage statement.
  local a7; a7=$("${MARIADB[@]}" -N -e "
    CALL fractal_text_to_sql('FRACTALSQL_BT_NO_SQL_MARKER', NULL, @s, @e);
    SELECT IFNULL(@e,'<NULL>');" 2>&1)
  echo "$a7" | grep -q "contained no SQL" \
    && pass "04 text_to_sql: a prose-only model reply is reported as 'contained no SQL'" \
    || fail "04 text_to_sql: expected a 'contained no SQL' reason, got: $a7"
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
#   (c2) the three PATH-shaped provider keys refuse a relative path and
#       a ".." traversal, naming the key and the reason, while a
#       canonical absolute path for the same key is accepted;
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

  # (c2) PATH-shaped provider keys: a relative path and a ".."
  # traversal are refused at reload, each naming the key AND the reason
  # in the daemon's log, with the running configuration kept. These are
  # the three keys whose value IS a file path (reasoning_plugin,
  # enterprise_lib, enterprise_ledger_path); the daemon checks their
  # SHAPE at configuration time (fractal_config_validate_path in
  # src/fractalsql_config.c), not at plugin-load time, so the refusal
  # arrives with the key's name instead of a dlopen error.
  #
  # The conf is reset from a backup before every case rather than
  # having the one appended line deleted again: a duplicate key in the
  # conf resolves LAST-wins, so an appended second `reasoning_plugin`
  # line shadows the real one for the duration of the case -- the reset
  # is what puts the real one back.
  cp "$FSQD_CONF" "$FSQD_CONF.g33path"
  local pspec pkey prest pval pdesc
  for pspec in \
    "reasoning_plugin|relative/plugin.so|relative" \
    "reasoning_plugin|/opt/fractalsql/../etc/plugin.so|traversal" \
    "enterprise_lib|relative/enterprise.so|relative" \
    "enterprise_ledger_path|../ledger.csv|traversal"; do
    pkey="${pspec%%|*}"; prest="${pspec#*|}"; pval="${prest%%|*}"; pdesc="${prest#*|}"
    cp "$FSQD_CONF.g33path" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
    L=$(log_mark)
    printf '%s = %s\n' "$pkey" "$pval" >> "$FSQD_CONF"
    rd=$(fsq_reload)
    if echo "$rd" | grep -qF "reload failed: provider settings rejected" \
        && log_from "$L" | grep -qF "provider key $pkey: must be an absolute path with no '..' segments"; then
      pass "33 conf_gate: '$pkey' with a $pdesc path -> reload refused (key named in the daemon's log)"
    else
      fail "33 conf_gate: expected refusal for '$pkey' with a $pdesc path, got '$rd' / log: $(log_from "$L" | tail -3)"
    fi
  done

  # Control: the SAME key with a canonical absolute path is ACCEPTED,
  # so the refusals above are about the path's shape and not about the
  # key being present at all. $PLUGDIR/think_reasoning.so is absolute
  # (PLUGDIR lives under the resolved $TMPROOT), carries no "..", and
  # really exists -- a value the daemon can honour.
  cp "$FSQD_CONF.g33path" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  printf 'reasoning_plugin = %s\n' "$PLUGDIR/think_reasoning.so" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  if [ "$rd" = "reloaded: configuration swapped in" ]; then
    pass "33 conf_gate: the same key with a canonical absolute path is accepted (the refusal above is about the path's shape)"
  else
    fail "33 conf_gate: a canonical absolute reasoning_plugin was refused: $rd"
  fi
  # Put the real configuration back, and prove the restore took.
  cp "$FSQD_CONF.g33path" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  rd=$(fsq_reload)
  if [ "$rd" = "reloaded: configuration swapped in" ]; then
    pass "33 conf_gate: the conf is restored after the path cases (reload accepted again)"
  else
    fail "33 conf_gate: the conf restore reload failed: $rd"
  fi
  rm -f "$FSQD_CONF.g33path"

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

  # The "no visible tables" branch of fractal_schema_context: the
  # procedure must SIGNAL rather than return an empty context that a
  # later stage would treat as a perfectly good (but useless) schema.
  #
  # MARIADB SHAPE. A single-file engine has one database, so "a
  # table-less database" there is a separate DATABASE
  # file. MariaDB cannot reproduce that shape at all: a stored routine's
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
  local r_empty; r_empty=$("${MARIADB[@]}" -N -e "
    CALL fractal_schema_context('[]', @e);" 2>&1)
  printf '%s' "$r_empty" | grep -qi "no visible tables found" \
    && pass "10 dos_and_injection: schema_context with no visible tables reports no visible tables" \
    || fail "10 dos_and_injection: expected 'no visible tables found', got: $r_empty"
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

  # ---- vectorizer argument-validation cases -------------------------
  # Every one of these is a guard in the fractal_vectorizer_* procedures
  # themselves (sql/install_udf.sql). They are asserted here, against
  # the live procedures, rather than assumed from reading the SIGNALs.

  # A schema-qualified source_table. The procedure resolves it with an
  # exact-match lookup against information_schema.tables in the CURRENT
  # database, so "main.tbl" (or any other qualified form) can never
  # match a base table -- and it is rejected outright with a specific
  # message rather than being silently quoted as one identifier
  # (which is the shape of the bug this case exists to pin down:
  # a multi-segment identifier must not be quoted as a single segment).
  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS bt_vsq; CREATE TABLE bt_vsq (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);" >/dev/null 2>&1
  local rsq; rsq=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_create('fractalsql_bt.bt_vsq', 'body', 'emb', NULL, @vid);" 2>&1)
  echo "$rsq" | grep -qi "schema-qualified source_table is not supported" \
    && pass "13 vectorizer_embed: a schema-qualified source_table is rejected with a specific reason" \
    || fail "13 vectorizer_embed: expected a schema-qualified rejection, got: $rsq"

  # A digit-leading identifier. It cannot be a bare table name, and the
  # procedure's own lookup would simply not find it -- but the
  # rejection must be a clean SIGNAL, never a SQL-syntax error from
  # the trigger DDL the procedure builds.
  local rdig; rdig=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_create('1_leading_digit', 'body', 'emb', NULL, @vid);" 2>&1)
  echo "$rdig" | grep -qi "not found" \
    && pass "13 vectorizer_embed: a digit-leading source_table is rejected cleanly" \
    || fail "13 vectorizer_embed: expected a clean rejection, got: $rdig"

  # A NULL source_table: rejected, not treated as an empty table name.
  local rnullt; rnullt=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_create(NULL, 'body', 'emb', NULL, @vid);" 2>&1)
  [ -n "$rnullt" ] \
    && pass "13 vectorizer_embed: a NULL source_table is rejected" \
    || fail "13 vectorizer_embed: expected a NULL source_table to be rejected, got: $rnullt"

  # pause / resume / drop: a NULL id and a nonexistent id each. The
  # pause and resume procedures both use an UPDATE ... WHERE id = ?
  # + ROW_COUNT() guard, so a NULL id matches no row and must SIGNAL
  # rather than silently succeed; drop reads the row first and
  # SIGNALs on a NULL read.
  local rp; rp=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_pause(NULL);" 2>&1)
  echo "$rp" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: pause(NULL) rejected" \
    || fail "13 vectorizer_embed: expected pause(NULL) to be rejected, got: $rp"
  local rr; rr=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_resume(NULL);" 2>&1)
  echo "$rr" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: resume(NULL) rejected" \
    || fail "13 vectorizer_embed: expected resume(NULL) to be rejected, got: $rr"
  local rd; rd=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_drop(NULL);" 2>&1)
  echo "$rd" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: drop(NULL) rejected" \
    || fail "13 vectorizer_embed: expected drop(NULL) to be rejected, got: $rd"

  local rp9; rp9=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_pause(9999);" 2>&1)
  echo "$rp9" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: pause rejects a nonexistent id" \
    || fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rp9"
  local rr9; rr9=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_resume(9999);" 2>&1)
  echo "$rr9" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: resume rejects a nonexistent id" \
    || fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rr9"
  local rd9; rd9=$("${MARIADB[@]}" -N -e "CALL fractal_vectorizer_drop(9999);" 2>&1)
  echo "$rd9" | grep -qi "no vectorizer with that id" \
    && pass "13 vectorizer_embed: drop rejects a nonexistent id" \
    || fail "13 vectorizer_embed: expected a nonexistent-id rejection, got: $rd9"

  # A duplicate vectorizer: the same (source_table, text_col,
  # embedding_col) triple created twice. fractal_vectorizers carries
  # a UNIQUE constraint on that triple AND the procedure checks for an
  # existing row first -- both must produce a clean, specific error.
  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS bt_vdup; CREATE TABLE bt_vdup (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);" >/dev/null 2>&1
  local rdup2; rdup2=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_create('bt_vdup', 'body', 'emb', NULL, @v1);
    CALL fractal_vectorizer_create('bt_vdup', 'body', 'emb', NULL, @v2);" 2>&1)
  echo "$rdup2" | grep -qi "already exists" \
    && pass "13 vectorizer_embed: a duplicate source/text/embedding triple is rejected" \
    || fail "13 vectorizer_embed: expected a duplicate-create rejection, got: $rdup2"

  # A SCHEMA-QUALIFIED source_table, written straight into the
  # fractal_vectorizers REGISTRY TABLE rather than through
  # fractal_vectorizer_create.
  #
  # fractal_vectorizers is ordinary user-writable data, so a row can
  # carry a name that fractal_vectorizer_create would have rejected --
  # and a qualified name is the interesting one, because it is the one
  # that breaks when it is quoted. A vectorizer is bound to a BARE
  # table name in the current database: MariaDB resolves a trigger
  # body's routine against the TRIGGER's own schema, so a trigger on
  # another schema's table cannot reach the enqueue procedure at all
  # ("PROCEDURE other_schema._fractalsql_vectorizer_enqueue does not
  # exist" -- confirmed live), and a cross-schema vectorizer can never
  # work here. So the qualified name is unsupported, and the only
  # thing left to get right is HOW that is reported.
  #
  # Quoting "fsq_other.bt_vqual" as a SINGLE segment builds a
  # reference to a table whose literal name contains a dot, and the
  # server then reports "Table 'mydb.my_schema.my_tbl' doesn't
  # exist" -- which reads as "that table is missing" and names a
  # database-qualified identifier that never existed. The row must
  # instead fail with the real reason.
  "${MARIADB[@]}" -e "
    INSERT INTO fractal_vectorizers (source_table, source_pk_col, text_col, embedding_col, options)
      VALUES ('fsq_other.bt_vqual', 'id', 'body', 'emb', JSON_OBJECT('max_attempts', 1));
    INSERT INTO fractal_vectorizer_queue (vectorizer_id, source_pk_value)
      SELECT id, '1' FROM fractal_vectorizers WHERE source_table = 'fsq_other.bt_vqual';
  " >/dev/null 2>&1
  "${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 600);" >/dev/null 2>&1
  local rqual
  rqual=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(MAX(error), '<NO ERROR>') FROM fractal_vectorizer_queue
     WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'fsq_other.bt_vqual');" 2>&1)
  echo "$rqual" | grep -qi "not a bare table name" \
    && pass "13 vectorizer_embed: a qualified source_table in the registry fails with the real reason" \
    || fail "13 vectorizer_embed: expected a bare-table-name failure, got: $rqual"
  # The negative assertion: the malformed reference must never be
  # built. A "doesn't exist" here means the qualified name was
  # quoted as one segment and the server was left to report the
  # nonsense error.
  echo "$rqual" | grep -qi "doesn't exist" \
    && fail "13 vectorizer_embed: a qualified source_table was quoted as a single segment: $rqual" \
    || pass "13 vectorizer_embed: a qualified source_table is never quoted as a single segment"

  # An embed endpoint that is not configured: every queued row must
  # end up 'failed' with a clean error, never silently skipped and
  # never left in 'pending' forever.
  #
  # The reasoning plugin is swapped to a nonexistent path IN PLACE
  # (mdb_restart_inplace_reasoning_plugin, not mdb_swap_reasoning_
  # plugin): the vectorizer's rows are already queued in the live
  # database, and a full mdb_setup would wipe the datadir out from
  # under them. The in-place restart keeps the datadir, the routines
  # and the queue rows -- only the plugin the daemon loads changes.
  #
  # Note the retry semantics: fractal_embed returning NULL is a
  # RETRYABLE failure, so the row goes back to 'pending' with the
  # attempt counted until options.max_attempts (default 3) is
  # exhausted, and only then to 'failed'. So the queue is run the
  # number of times the retry policy needs before the rows are
  # terminally failed.
  mdb_restart_inplace_reasoning_plugin "$HERE/.gate13_nonexistent.so" \
    || { fail "13 vectorizer_embed: bad-path restart did not take effect"; mdb_restore_reasoning_plugin_inplace; return; }
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS bt_vnoembed;
    CREATE TABLE bt_vnoembed (id BIGINT PRIMARY KEY AUTO_INCREMENT, body TEXT, emb TEXT);
    INSERT INTO bt_vnoembed (body) VALUES ('a'), ('b');
    CALL fractal_vectorizer_create('bt_vnoembed', 'body', 'emb', NULL, @vid);
  " >/dev/null 2>&1
  local rfail
  local attempt
  for attempt in 1 2 3 4; do
    "${MARIADB[@]}" -N -e "CALL fractal_vectorizer_process_queue(10, 600);" >/dev/null 2>&1
  done
  # The vectorizer id is resolved by its source_table, not via the @vid
  # user variable set by the CREATE above. A MariaDB user variable
  # lives in the SESSION that set it, and the CREATE ran in a different
  # invocation than this query -- so "@vid" here is an undefined
  # variable, i.e. NULL, and "vectorizer_id = NULL" matches NO rows.
  # The assertion would then read FAILED=0 / PENDING=0 / <NO ERROR> and
  # pass for entirely the wrong reason (an empty result set is
  # indistinguishable from a correctly-failing queue). Resolving the id
  # by its source_table is session-independent and names exactly the
  # vectorizer this block created.
  rfail=$("${MARIADB[@]}" -N -e "
    SELECT CONCAT('FAILED=', COUNT(*)) FROM fractal_vectorizer_queue
     WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed') AND status = 'failed';
    SELECT CONCAT('PENDING=', COUNT(*)) FROM fractal_vectorizer_queue
     WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed') AND status = 'pending';
    SELECT IFNULL(MAX(error), '<NO ERROR>') FROM fractal_vectorizer_queue
     WHERE vectorizer_id = (SELECT id FROM fractal_vectorizers WHERE source_table = 'bt_vnoembed');" 2>&1)
  mdb_restore_reasoning_plugin_inplace
  printf '%s' "$rfail" | grep -q "FAILED=2" \
    && pass "13 vectorizer_embed: an unconfigured embed endpoint fails every row cleanly" \
    || fail "13 vectorizer_embed: expected 2 failed rows, got: $rfail"
  printf '%s' "$rfail" | grep -q "PENDING=0" \
    && pass "13 vectorizer_embed: an unconfigured embed endpoint leaves no row stuck in pending" \
    || fail "13 vectorizer_embed: expected no pending rows, got: $rfail"
  printf '%s' "$rfail" | grep -q "dispatch failed" \
    && pass "13 vectorizer_embed: the failed row carries a clean, specific error" \
    || fail "13 vectorizer_embed: expected a 'dispatch failed' error, got: $rfail"

  "${MARIADB[@]}" -e "
    DELETE FROM fractal_vectorizers WHERE source_table IN ('bt_vsq','bt_vdup','bt_vnoembed','fsq_other.bt_vqual');
    DROP TABLE IF EXISTS bt_vsq; DROP TABLE IF EXISTS bt_vdup; DROP TABLE IF EXISTS bt_vnoembed;
  " >/dev/null 2>&1
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

  # An input over the 4 MiB cap (FRACTAL_COGNITION_MAX_INPUT_BYTES in
  # src/fractalsql_cognition.c). A caller-controlled string that drives
  # an allocation and an outbound request body, uncapped, would let a
  # multi-GiB argument OOM-kill the server or build an abusive request
  # -- so the cap has to be enforced, not merely documented. The value
  # is built with REPEAT() rather than a literal so the test itself
  # does not carry 4 MiB of text.
  local rbig; rbig=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_embed(CONNECTION_ID(), REPEAT('x', 4194305)), '<NULL>');" 2>&1)
  [ "$rbig" = "<NULL>" ] \
    && pass "15 embed: input over the 4 MiB cap rejected" \
    || fail "15 embed: expected an over-cap input to be rejected, got: $rbig"
  local upbig; upbig=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  [ "$upbig" = "1" ] \
    && pass "15 embed: the server survived the over-cap input" \
    || fail "15 embed: mariadbd did not survive the over-cap input"

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
  # process_queue() only claims vectorizers registered by the calling account, so an
  # outsider's call is a no-op: the owner's row stays pending and is NOT marked failed by someone else.
  [ "$statuses" = "pending" ] \
    && pass "16 embed_authz: outsider's process_queue() call left the owner's row untouched ('pending')" \
    || fail "16 embed_authz: expected 'pending' after the outsider's call, got: $statuses"

  local errtext; errtext=$("${owner[@]}" -e "
    SELECT last_error FROM fractal_vectorizer_status WHERE vectorizer_id=$vzid AND status='failed';" 2>&1)
  [ -z "$errtext" ] \
    && pass "16 embed_authz: the outsider's call recorded no failure against the owner's vectorizer" \
    || fail "16 embed_authz: expected no failed row for the owner's vectorizer, got: $errtext"

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

  # The "diversify_enabled" field has to report the SESSION's own
  # state, and the session IS the connection -- so the enable and the
  # read have to happen in ONE connection. Every `mariadb -e` above is
  # its own connection with its own CONNECTION_ID(), which is why the
  # statements below are issued as a single -e.
  #
  # The flag used to be derived from the core's own params query,
  # which answers with the tunables whether or not the monitor is
  # actually running: the field therefore said "true" for EVERY
  # session, including one that had never enabled anything.
  local fresh; fresh=$("${MARIADB[@]}" -N -e "SELECT fractal_explain_result(CONNECTION_ID());" 2>&1)
  echo "$fresh" | grep -Eq '"diversify_enabled" *: *false' \
    && pass "21 diversify: a session that never enabled the monitor reports diversify_enabled=false" \
    || fail "21 diversify: a fresh session reported '$fresh' (expected diversify_enabled:false)"
  local enon; enon=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_enable(CONNECTION_ID()); SELECT fractal_explain_result(CONNECTION_ID());" 2>&1)
  echo "$enon" | grep -Eq '"diversify_enabled" *: *true' \
    && pass "21 diversify: the same session reports diversify_enabled=true once it enables the monitor" \
    || fail "21 diversify: after enable the session reported '$enon' (expected diversify_enabled:true)"
  local enoff; enoff=$("${MARIADB[@]}" -N -e "SELECT fractal_diversify_enable(CONNECTION_ID()); SELECT fractal_diversify_disable(CONNECTION_ID()); SELECT fractal_explain_result(CONNECTION_ID());" 2>&1)
  echo "$enoff" | grep -Eq '"diversify_enabled" *: *false' \
    && pass "21 diversify: disabling the monitor puts the flag back to false" \
    || fail "21 diversify: after disable the session reported '$enoff' (expected diversify_enabled:false)"

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

  # The NULL guard on a vector argument. The plan's own verification row
  # for the vector NULL guards names fractal_vector_add specifically, and
  # the guard it exercises is the shared FRACTAL_VECTOR_BINOP macro
  # (src/fractalsql_vector.c) -- so this asserts the macro that all
  # thirteen vector UDFs are built from, not one hand-written body. A
  # NULL argument must come back as a NULL result: never a crash, and
  # never a zero-length vector masquerading as an answer.
  local add_null; add_null=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_add(NULL, '[1,1,1]');" 2>&1)
  [ "$add_null" = "NULL" ] && pass "22 vector_tier: add(NULL, ...) -> NULL" \
                            || fail "22 vector_tier: expected NULL, got: $add_null"

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

  # A UDF error message is never EMPTY. The shim's three err buffers
  # are initialised and fsq_set_msg() falls back to a generic message
  # when the buffer has nothing in it, so a failing UDF must always
  # say SOMETHING to the client -- an empty error is the failure mode
  # this assertion exists to catch. The wrong-argument-count call is
  # the one that fails in _init, which is the path that carries a
  # message.
  local badinit; badinit=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_add('[1,2,3]');" 2>&1)
  echo "$badinit" | grep -qi "argument" \
    && pass "22 vector_tier: a UDF error message is never empty (it names the argument problem)" \
    || fail "22 vector_tier: expected a non-empty UDF error message naming the argument problem, got: '$badinit'"
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

  # The review PROMPT must not be truncated. It used to be assembled in
  # a fixed 8 KiB stack buffer, and a longer question was cut
  # mid-statement with the truncation never detected and never
  # reported: the model then graded a question the caller never sent --
  # and that PASS/FAIL verdict IS this function's return value, which
  # feeds straight back into the next GENERATE attempt as retry
  # feedback. The marker sits at the END of a 9 KiB question: cut at
  # 8 KiB it never reaches the mock, the mock answers with its default
  # (not a PASS), and the review returns the critique text instead of
  # NULL.
  local long_q rev_long
  long_q=$(python3 -c "print('A'*9000 + 'FRACTALSQL_BT_REVIEW_PASS_MARKER')")
  rev_long=$("${MARIADB[@]}" -N -e \
    "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), '$long_q', 'SELECT 1'), '<NULL>');" 2>&1)
  [ "$rev_long" = "<NULL>" ] \
    && pass "23 cognition: a 9 KiB question reaches the model in full (the review prompt is not truncated)" \
    || fail "23 cognition: a 9 KiB question was truncated before the model saw it (expected NULL, got: $rev_long)"
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

  # --- S-FT-004 partial-result honesty (opt-in agent_partial mode) -----
  # With the flag OFF (the documented default) a dead reasoning endpoint
  # leaves the agent's data half (dfa_exponent etc.) intact with a NULL
  # rationale and NO reasoning_step_failed detail -- the pre-existing
  # behavior, unchanged. With the flag ON (fractal_agent_partial_fail)
  # the same call additionally carries "reasoning_step_failed" with the
  # plugin's detail. The fractal_reason UDF itself is NOT rescued: see
  # agent_partial_or_error's contract in fractalsql_cognition.c -- with
  # the flag on it returns the sentinel document, which is what the
  # agent procedures split back into data + detail here. The endpoint is
  # repointed to a dead port through the daemon conf's reasoning_url key
  # + fsqlctl reload, the exact mechanism gate 34 exercises, so no mock
  # restart is involved; the conf is restored and reloaded before this
  # gate returns. Series: regime_triage takes an array-in series, no
  # table, so the whole pair needs nothing beyond this one fixture.
  local ctl_bin="$HERE/service/build/fsqlctl"
  local mock_url="${FRACTALSQL_HTTP_URL:-}"
  if [ -z "$mock_url" ]; then
    fail "24 agents: FRACTALSQL_HTTP_URL not exported (mdb_setup missing?)"
    return
  fi
  local series; series="$(python3 -c "
import json
print(json.dumps([round(0.1*i + (0.02 if i == 37 else 0.0), 6) for i in range(100)], separators=(',',':')))
")"

  cp "$FSQD_CONF" "$FSQD_CONF.g24"
  printf 'reasoning_url = http://127.0.0.1:1/v1/chat/completions\n' >> "$FSQD_CONF"
  chmod 600 "$FSQD_CONF"
  local rd
  rd=$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)
  if [ "$rd" != "reloaded: configuration swapped in" ]; then
    fail "24 agents: dead reasoning_url reload failed: '$rd'"
    cp "$FSQD_CONF.g24" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
    FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload >/dev/null 2>&1
    return
  fi

  # (a) flag OFF = default: data half, NULL rationale, no partial detail.
  # Everything rides ONE client invocation: the flag/sentinel are
  # session-scoped (fractal_session keyed by CONNECTION_ID()), and every
  # "${MARIADB[@]}" invocation is a fresh connection.
  local ra; ra=$("${MARIADB[@]}" -N -e "
    CALL fractal_agent_regime_triage('$series', NULL, NULL, NULL, @ra);
    SELECT @ra;" 2>&1)
  echo "$ra" | grep -Eq '"dfa_exponent" *: *"?-?[0-9]' \
    && echo "$ra" | grep -Eq '"rationale" *: *null' \
    && echo "$ra" | grep -Eq '"reasoning_step_failed" *: *null' \
    && pass "24 agents: partial mode off (default) keeps the data half with no reasoning_step_failed detail" \
    || fail "24 agents: flag-off default case broken: $ra"

  # (b) flag ON: same dead endpoint, opt in on the SAME connection, then
  # the agent doc gains reasoning_step_failed with the plugin's detail
  # while the data half stays intact.
  local rb; rb=$("${MARIADB[@]}" -N -e "
    SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'on');
    CALL fractal_agent_regime_triage('$series', NULL, NULL, NULL, @rb);
    SELECT @rb;" 2>&1)
  echo "$rb" | grep -q '^on$' \
    && echo "$rb" | grep -Eq '"dfa_exponent" *: *"?-?[0-9]' \
    && echo "$rb" | grep -Eq '"reasoning_step_failed" *: *"' \
    && echo "$rb" | grep -Eq "fractal_reason: (dispatch failed|failed to load reasoning plugin)" \
    && echo "$rb" | grep -Eq '"rationale" *: *null' \
    && pass "24 agents: partial mode on returns the data half plus reasoning_step_failed (sentinel split)" \
    || fail "24 agents: expected the partial document, got: $rb"

  # The client-visible detail is BOUNDED. The reasoning plugin's own
  # diagnostic is embedded in the agent document verbatim, so the
  # sentinel caps it (and says so when it has to cut). An uncapped
  # detail would let one plugin error fill the whole document. The value
  # is picked out as a JSON string literal (escapes included) and then
  # DECODED, so the length checked is what the client actually reads --
  # not the raw wire form, and not a greedy run to the last quote on the
  # line (which would also swallow whatever keys follow it).
  local dlen
  dlen=$(python3 - "$rb" <<'PYEOF'
import json, re, sys
txt = sys.argv[1] if len(sys.argv) > 1 else ""
m = re.search(r'"reasoning_step_failed"\s*:\s*("(?:[^"\\]|\\.)*")', txt)
if not m:
    print(-1)
else:
    try:
        print(len(json.loads(m.group(1))))
    except Exception:
        print(-1)
PYEOF
)
  if [ -n "$dlen" ] && [ "$dlen" -ge 0 ] && [ "$dlen" -le 512 ]; then
    pass "24 agents: the client-visible failure detail is bounded ($dlen chars)"
  else
    fail "24 agents: the client-visible failure detail is unbounded: $rb"
  fi

  # The sentinel leaks nowhere else: fractal_reason without the flag on
  # a fresh connection is a plain NULL here (the setup-error case stays
  # hard), and the flag-off session above saw none -- the agent split is
  # the only path that turns it into detail.
  local rr; rr=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_reason(CONNECTION_ID(), 'ping'), '<NULL>');" 2>&1)
  [ "$rr" = "<NULL>" ] \
    && pass "24 agents: fresh session without the opt-in still gets the plain failure NULL" \
    || fail "24 agents: expected a bare NULL from fractal_reason off-session, got: $rr"

  # Restore the live mock provider for any later reasoning case.
  cp "$FSQD_CONF.g24" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"; rm -f "$FSQD_CONF.g24"
  rd=$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)
  if [ "$rd" = "reloaded: configuration swapped in" ] \
      && echo "$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'ping');" 2>&1)" | grep -qv '^NULL$'; then
    pass "24 agents: mock reasoning provider restored after the partial pair"
  else
    fail "24 agents: mock reasoning provider NOT restored: reload='$rd'"
  fi
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

  # A power value large enough to need 300+ characters in "%.10f". The
  # emitters used to size their per-number buffer at 40 bytes, so the
  # snprintf truncated and the whole UDF refused (a truncated snprintf
  # is a hard error here, not a rounded value) -- the spectrum of a
  # legitimately huge series was a bare NULL. The buffers are now sized
  # for the worst case a finite double can print at.
  local pg_big; pg_big=$("${MARIADB[@]}" -N -e "SELECT fractal_periodogram('1e150,1e150,1e150,1e150', 2);" 2>&1)
  if echo "$pg_big" | grep -Eq '"freqs" *: *\[' && echo "$pg_big" | grep -Eq '"power" *: *\['; then
    pass "32 new_primitives: periodogram of a 1e150-magnitude series returns a full result (the power values need 300+ characters)"
  else
    fail "32 new_primitives: periodogram of a 1e150-magnitude series='$pg_big' (expected a freqs/power result)"
  fi

  # --- fractal_spectrogram_entropy: a pure tone (ordered, low entropy)
  # vs LCG noise (disordered, high entropy). The series are generated
  # here so no fixture file is needed; the JSON array is parsed with
  # python3 (no JSON_TABLE, which older server versions in the matrix
  # lack). Output is a BARE array of per-frame entropy in [0,1].
  local se_noise; se_noise="$(python3 -c "
x = 12345
out = []
for _ in range(128):
    x = (x * 1103515245 + 12345) % 2147483648
    out.append(str((x // 65536) % 1000))
print(','.join(out))
")"
  local se_tone; se_tone="$(python3 -c "
print(','.join(str([1,0,-1,0][i % 4]) for i in range(128)))
")"
  local se_t; se_t=$("${MARIADB[@]}" -N -e "SELECT fractal_spectrogram_entropy('$se_tone', 32, 16);" 2>&1)
  if python3 -c "
import json,sys
v = json.loads(sys.argv[1])
sys.exit(0 if len(v) == 7 and all(0.0 <= e <= 1.0 for e in v) and max(v) < 0.5 else 1)" "$se_t" 2>/dev/null; then
    pass "32 new_primitives: spectrogram_entropy reads a pure tone as ordered (7 frames, all < 0.5)"
  else
    fail "32 new_primitives: spectrogram_entropy tone='$se_t' (expected 7 frames in [0,0.5))"
  fi
  local se_n; se_n=$("${MARIADB[@]}" -N -e "SELECT fractal_spectrogram_entropy('$se_noise', 32, 32);" 2>&1)
  if python3 -c "
import json,sys
v = json.loads(sys.argv[1])
sys.exit(0 if len(v) == 4 and max(v) <= 1.0 and sum(v) / len(v) > 0.7 else 1)" "$se_n" 2>/dev/null; then
    pass "32 new_primitives: spectrogram_entropy reads noise as disordered (mean > 0.7, <= 1)"
  else
    fail "32 new_primitives: spectrogram_entropy noise='$se_n' (expected 4 frames, mean > 0.7)"
  fi
  local se_c; se_c=$("${MARIADB[@]}" -N -e "SELECT fractal_spectrogram_entropy('2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2', 8, 8);" 2>&1)
  [ "$se_c" = "[0.0000000000,0.0000000000]" ] \
    && pass "32 new_primitives: spectrogram_entropy reports a constant frame as 0.0, not NaN" \
    || fail "32 new_primitives: spectrogram_entropy constant frame='$se_c'"
  local se_m; se_m=$("${MARIADB[@]}" -N -e "SELECT JSON_LENGTH(fractal_spectrogram_entropy('$se_tone', 32, 16, 2));" 2>&1)
  [ "$se_m" = "2" ] \
    && pass "32 new_primitives: spectrogram_entropy honours max_frames" \
    || fail "32 new_primitives: spectrogram_entropy max_frames length='$se_m' (expected 2)"
  local se_null; se_null=$("${MARIADB[@]}" -N -e "SELECT fractal_spectrogram_entropy(NULL, 8);" 2>&1)
  [ "$se_null" = "NULL" ] \
    && pass "32 new_primitives: spectrogram_entropy(NULL) is NULL" \
    || fail "32 new_primitives: spectrogram_entropy(NULL)='$se_null'"
  # Same empirical contract as change_point_detect above: a UDF whose main
  # function sets *error surfaces as a NULL result. Every out-of-range
  # argument must be refused that way, never crash or return a short array.
  local se_bad se_case se_label se_arg
  for se_case in "window < 8|'$se_tone', 4" "window > 512|'$se_tone', 600" \
                 "hop < 1|'$se_tone', 16, 0" "max_frames < 1|'$se_tone', 16, 8, 0" \
                 "max_frames > 4096|'$se_tone', 16, 8, 5000" \
                 "a series shorter than the window|'1,2,3', 8" \
                 "a malformed series|'bad!vec', 8"; do
    se_label="${se_case%%|*}"; se_arg="${se_case#*|}"
    se_bad=$("${MARIADB[@]}" -N -e "SELECT fractal_spectrogram_entropy($se_arg);" 2>&1)
    [ "$se_bad" = "NULL" ] \
      && pass "32 new_primitives: spectrogram_entropy rejects $se_label (NULL)" \
      || fail "32 new_primitives: spectrogram_entropy $se_label expected NULL, got: ${se_bad:0:120}"
  done
  # Composition: 64 tone samples then 64 noise samples -> the entropy
  # series steps up and change_point_detect localizes it from the bare
  # array (the function's output feeds the next function directly).
  local se_mix; se_mix="$(python3 -c "
x = 12345
out = []
for i in range(128):
    x = (x * 1103515245 + 12345) % 2147483648
    out.append(str([1,0,-1,0][i % 4]) if i < 64 else str((x // 65536) % 1000))
print(','.join(out))
")"
  local se_cp; se_cp=$("${MARIADB[@]}" -N -e "SELECT fractal_change_point_detect(fractal_spectrogram_entropy('$se_mix', 16, 8), 3, 1.0, 16);" 2>&1)
  echo "$se_cp" | grep -Eq '[0-9]' && ! echo "$se_cp" | grep -q 'NULL' \
    && pass "32 new_primitives: spectrogram_entropy -> change_point_detect localizes a regime change ($se_cp)" \
    || fail "32 new_primitives: spectrogram_entropy regime change='$se_cp'"

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

  # A filtration scale large enough that the death value needs 150+
  # characters in "%.10f". The bar emitter used to size its buffer at
  # 128 bytes for TWO numbers plus their keys, so this truncated and
  # the whole UDF refused (a truncated snprintf is a hard error here)
  # -- the barcode of a legitimately huge-scale filtration was a bare
  # NULL. The buffer is now sized for the worst case a finite double
  # can print at.
  local tda_big; tda_big=$("${MARIADB[@]}" -N -e "SELECT fractal_tda_persistence_diagram('0,0,0,0,1e150,0,1e150,0', 2, 1, 1e151, 64);" 2>&1)
  if echo "$tda_big" | grep -Eq '"h0_bars" *: *\[' && echo "$tda_big" | grep -q '"death"'; then
    pass "32 new_primitives: tda_persistence_diagram of a 1e150-scale filtration returns a full barcode (the death values need 150+ characters)"
  else
    fail "32 new_primitives: tda_persistence_diagram of a 1e150-scale filtration='$tda_big' (expected an h0_bars barcode)"
  fi

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

  # --- argument-count and size caps on the reasoning-tier surface.
  # MariaDB's UDF ABI reports a bad argument count at INIT time
  # (fractal_reason_init's own arg_count check), which the server
  # surfaces as an ERROR on the CALL, not as a NULL result -- so these
  # assert on the error text, not on a NULL.
  local r_arity0; r_arity0=$("${MARIADB[@]}" -N -e "SELECT fractal_reason();" 2>&1)
  echo "$r_arity0" | grep -qi "expected 2 or 3" \
    && pass "32 new_primitives: fractal_reason() with zero arguments is rejected" \
    || fail "32 new_primitives: expected fractal_reason() to reject zero arguments, got: $r_arity0"
  local r_arity3; r_arity3=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q', 'ctx', 'extra');" 2>&1)
  echo "$r_arity3" | grep -qi "expected 2 or 3" \
    && pass "32 new_primitives: fractal_reason with four arguments is rejected" \
    || fail "32 new_primitives: expected fractal_reason to reject four arguments, got: $r_arity3"

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
  local r_t2s_big; r_t2s_big=$("${MARIADB[@]}" -N -e "
    SELECT IFNULL(fractal_t2s_generate(CONNECTION_ID(), REPEAT('x', 4194305), '{}', 'mariadb114'), '<NULL>');" 2>&1)
  echo "$r_t2s_big" | grep -q "<NULL>" \
    && pass "32 new_primitives: text_to_sql's generate step rejects a prompt over the 4 MiB cap" \
    || fail "32 new_primitives: expected an over-cap prompt to be rejected, got: $r_t2s_big"

  # fractal_vectorizer_process_queue's batch size. MariaDB's procedure
  # takes the batch size as a plain INT and applies it as a LIMIT in
  # the claim UPDATE, so an absurd value is not a crash but it IS an
  # unbounded single-transaction claim -- the queue's whole backlog in
  # one statement. This asserts the call is bounded rather than
  # rejected: MariaDB has no FSQLV_MAX_BATCH cap of its own, so the
  # honest assertion is that the call completes and processes a
  # bounded number of rows, and that the negative case (batch size 0)
  # processes nothing at all.
  local r_bq0; r_bq0=$("${MARIADB[@]}" -N -e "
    CALL fractal_vectorizer_process_queue(0, 600);
    SELECT COUNT(*) FROM fractal_vectorizer_queue WHERE status = 'processing';" 2>&1)
  echo "$r_bq0" | grep -q "^0$" \
    && pass "32 new_primitives: process_queue with batch size 0 claims no rows" \
    || fail "32 new_primitives: expected process_queue(0) to claim nothing, got: $r_bq0"
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
  local max_n="${FSQL_OOM_GATE37_MAX_N:-${FSQL_OOM_MAX_N:-200}}"

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
      # Only allocations made by this repository's own code (the daemon, the core linked into it, the vendored plugin) are counted
      # and failed: OpenSSL, which the signature check reaches, does not survive an allocation failing inside its own lazy
      # initialisation (a NULL lock in libcrypto), and that is not something this gate can fix or should be judged by.
      LD_PRELOAD="$oom_so" FSQL_OOM_ONLY_SO="fractalsql" FSQL_OOM_FAIL_AT="$n" daemon_start >/dev/null 2>&1
      if [ -S "$FSQD_SOCK" ]; then
        "${MARIADB[@]}" --connect-timeout=3 -N -e "$sql" >/dev/null 2>&1
      fi
      if log_from "$L" | rb_log_has_crash; then
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
  export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0   # explicit operator opt-out (the default is now ON)
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local r4; r4=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r4" = "0" ] && pass "28 enterprise_signature: a missing .sig loads when REQUIRE_SIGNATURE=0 (explicit opt-out)" \
                   || fail "28 enterprise_signature: expected 0 (loaded unverified), got: $r4"

  unset FRACTALSQL_ENTERPRISE_LIB
  export FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0
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
  L=$(log_mark)
  printf 'enterprise_lib = %s\nenterprise_require_signature = 1\n' "$nosig_so" >> "$FSQD_CONF"
  rd=$(fsq_reload)
  [ "$rd" = "reloaded: configuration swapped in" ] \
    || fail "35 enterprise_mock: reload (nosig+require path) rc/err: $rd"
  local r2; r2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" 2>&1)
  [ "$r2" = "NULL" ] && log_from "$L" | grep -q "no signature found for enterprise library" \
    && log_from "$L" | grep -q "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE" \
    && pass "35 enterprise_mock: a missing .sig refuses to load when enterprise_require_signature is set, and the log names the standard opt-out" \
    || fail "35 enterprise_mock: expected NULL + the refusal naming FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE, got: $r2 / log: $(log_from "$L" | tail -3)"

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

  # Engine-side latch behind the MCP server's FSQL_MCP_READ_ONLY switch.
  # fractal_lock_destructive(session_id) is one-way: afterwards the four
  # destructive ledger UDFs refuse for that session id (NULL, the UDF *error
  # convention) even though the mock core is loaded and they just succeeded
  # above; fractal_ledger_load overwrites the live ledger state, so it is latched too. One client
  # invocation is one connection, so CONNECTION_ID() is the same id throughout.
  # The latch is keyed by the session id the caller passes (see
  # docs/enterprise.md): a fresh connection has a new id and is not latched.
  local lk; lk=$("${MARIADB[@]}" -N -e "SELECT fractal_lock_destructive(CONNECTION_ID()); SELECT fractal_ledger_flush(CONNECTION_ID()); SELECT fractal_ledger_compact(CONNECTION_ID()); SELECT fractal_ledger_reset_soft(CONNECTION_ID()); SELECT fractal_ledger_reset_hard(CONNECTION_ID()); SELECT fractal_ledger_load(CONNECTION_ID());" 2>&1 | tr '\n' ' ')
  [ "$lk" = "1 NULL NULL NULL NULL NULL " ] \
    && pass "35 enterprise_mock: fractal_lock_destructive() latches flush/compact/reset_soft/reset_hard/load for the session id" \
    || fail "35 enterprise_mock: expected '1 NULL NULL NULL NULL NULL' after the latch, got: $lk"
  local lk2; lk2=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_reset_hard(CONNECTION_ID());" 2>&1)
  [ "$lk2" = "0" ] && pass "35 enterprise_mock: the latch is per session id (a fresh connection is not latched)" \
                    || fail "35 enterprise_mock: expected a fresh connection to be unlatched (0), got: $lk2"

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
  # The head record is not hand-written here: it carries an HMAC over its own
  # contents, so a head file written by hand would not verify. The row count
  # it records is derived from the chain itself, and the append below re-writes
  # the record -- the torn record the repair discards never counted.
  "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.after_repair', '{\"n\":3}');" >/dev/null 2>&1
  local v_repair; v_repair=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  [ "$v_repair" = '{"ok":true,"rows_verified":2}' ] \
    && pass "35 enterprise_mock: a torn tail is repaired on the next write (torn record discarded, new one appended)" \
    || fail "35 enterprise_mock: expected a 2-row ok verify after repair, got: $v_repair"

  # The portfolio decision's audit record must actually LAND. The
  # record's head embeds the Sharpe ratio as "%.10f", and a Sharpe
  # ratio large enough to need 150+ characters overflowed the old
  # fixed budget: the snprintf truncated, the write was SKIPPED, and
  # the decision's provenance silently vanished -- no error, no record,
  # just a missing row in the chain. An expected return that large is
  # legal input.
  #
  # The Sharpe ratio here is ret/risk with the risk floored at 1e-6
  # (the core's own variance floor), so a 1e250 expected return over
  # a 1e-300 variance gives a 257-digit Sharpe ratio -- a number no
  # fixed "a few hundred bytes" budget can hold.
  #
  # This sits BEFORE the byte-level tamper below on purpose: the
  # tamper deliberately breaks the chain, and a broken chain's verify
  # report carries no rows_verified count to compare against.
  local chain_before; chain_before=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  local pf; pf=$("${MARIADB[@]}" -N -e "SELECT fractal_optimize_portfolio('1e250,9e249', '1e-300,0,0,1e-300', 1, '{}');" 2>&1)
  local chain_after; chain_after=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
  local n_before n_after sharpe_digits
  n_before=$(echo "$chain_before" | sed -n 's/.*"rows_verified":\([0-9]*\).*/\1/p')
  n_after=$(echo "$chain_after" | sed -n 's/.*"rows_verified":\([0-9]*\).*/\1/p')
  sharpe_digits=$(echo "$pf" | sed -nE 's/.*"sharpe":-?([0-9]*)\..*/\1/p' | tr -d '\n' | wc -c | tr -d ' ')
  if [ -n "$n_before" ] && [ -n "$n_after" ] && [ "$n_after" -eq $((n_before + 1)) ] && [ "$sharpe_digits" -ge 138 ]; then
    pass "35 enterprise_mock: a portfolio decision with a $sharpe_digits-digit Sharpe ratio still lands its audit record"
  else
    fail "35 enterprise_mock: the portfolio audit record did not land (chain $n_before -> $n_after, sharpe digits $sharpe_digits; the call answered '$pf')"
  fi

  # The CSV mirror's `id` is the record's position in the CHAIN, not a
  # line count of the mirror file. Delete the mirror and the next
  # record must still be numbered by where it lands in the chain -- a
  # mirror that re-derives the id from its own line count would hand
  # out id 1 again and the mirror's "ORDER BY id" would no longer name
  # the same row the chain's tip does.
  if [ -f "$ledger_path.csv" ]; then
    rm -f "$ledger_path.csv"
    "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.mirror_id', JSON_OBJECT('n', 4));" >/dev/null 2>&1
    local mirror_id; mirror_id=$(sed -n '1s/^\([0-9]*\),.*/\1/p' "$ledger_path.csv" 2>/dev/null)
    if [ -n "$mirror_id" ] && [ "$mirror_id" -gt 1 ]; then
      pass "35 enterprise_mock: the mirror's id is the chain's record position ($mirror_id), not a restart at 1"
    else
      fail "35 enterprise_mock: the mirror's id restarted at '$mirror_id' instead of continuing the chain's numbering"
    fi
  else
    fail "35 enterprise_mock: mirror-id check: $ledger_path.csv does not exist (an earlier assertion in this gate must have failed to actually write the mirror)"
  fi

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
  # The refusal above kept the RUNNING daemon on the mock, but the
  # configuration file still names the bad library -- and the daemon reads
  # that file again the next time it starts. Put the mock back, so a
  # later restart in this gate starts with the library this gate tests.
  rb_conf_set enterprise_lib "$mock_so"

  # An EMPTY JSON object is well-formed JSON. The audit log's own
  # structural gate used to reject it -- a closing bracket demanded a
  # completed value, and an empty container has none -- so
  # fractal_audit_log(type, JSON_OBJECT()) wrote nothing to the chain
  # and returned a bare NULL, while the file's own comment claimed
  # JSON_OBJECT() output "clears this easily".
  local empty_obj; empty_obj=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.empty', '{}'), '<NULL>');" 2>&1)
  [ "$empty_obj" = "0" ] && pass "35 enterprise_mock: audit_log accepts an empty JSON object" \
                         || fail "35 enterprise_mock: audit_log with an empty JSON object answered '$empty_obj' (expected 0)"
  local empty_arr; empty_arr=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.empty_arr', '[]'), '<NULL>');" 2>&1)
  [ "$empty_arr" = "0" ] && pass "35 enterprise_mock: audit_log accepts an empty JSON array" \
                         || fail "35 enterprise_mock: audit_log with an empty JSON array answered '$empty_arr' (expected 0)"
  # A trailing separator is still NOT well-formed: the fix must not have
  # loosened the gate into accepting broken JSON.
  local trailing; trailing=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.trailing', '{\"a\":1,}'), '<NULL>');" 2>&1)
  [ "$trailing" = "<NULL>" ] && pass "35 enterprise_mock: audit_log still refuses a JSON payload with a trailing separator" \
                           || fail "35 enterprise_mock: audit_log with a trailing separator answered '$trailing' (expected <NULL>)"

  # A ZERO-LENGTH ledger file is not a corrupt ledger: it is a ledger
  # that was created but never got its header (a crash between the
  # create and the first append, an operator's `touch`, a copy that
  # lost its tail). There is no chain in it to lose. The write path
  # used to treat it as CORRUPT and refuse -- and because every later
  # write went through the same check, that one zero-byte file BRICKED
  # THE LEDGER PERMANENTLY: no record could ever be written again, and
  # the only way out was deleting the file by hand. It must instead be
  # re-headed and used normally.
  if [ -f "$ledger_path" ]; then
    : > "$ledger_path"
    rm -f "$ledger_path.head"   # this simulates a never-written file, not a wiped chain (the head record would flag the latter)
    local zlog; zlog=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.zero_byte', '{\"n\":1}'), '<NULL>');" 2>&1)
    local zver; zver=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    [ "$zlog" = "0" ] && [ "$zver" = '{"ok":true,"rows_verified":1}' ] \
      && pass "35 enterprise_mock: a zero-length ledger file is re-headed and used, not bricked" \
      || fail "35 enterprise_mock: a zero-length ledger answered '$zlog' / verify '$zver' (expected 0 / a 1-row ok verify)"
  else
    fail "35 enterprise_mock: zero-length ledger: $ledger_path does not exist (an earlier assertion in this gate must have failed to actually load the mock)"
  fi

  # A record header that CLAIMS a 4 GiB blob must not be believed.
  # The ledger's on-disk length field is a uint32_t, and the read path
  # sized two things from it: the blob allocation, and the hash-
  # recomputation buffer (LEDGER_HASH_LEN + blob_len + ...). That
  # second expression is computed in 32-bit UNSIGNED arithmetic, so a
  # claimed length near 2^32 WRAPS it round to a small number -- the
  # allocation came out 32 bytes while the memcpy right below it
  # copied the claimed length into it: a heap overflow in the daemon's
  # own address space, on both the O(1) tip check and the full chain
  # walk. The read path now bounds the claimed length
  # (LEDGER_MAX_BLOB_BYTES) and reports the record as corrupt.
  if [ -f "$ledger_path" ]; then
    python3 -c "
import struct, sys
hdr = b'FSQLLDGR' + bytes([1])
rec = struct.pack('<II', 2, 0xFFFFFFFF) + bytes([0,0,0,0]) + bytes(96) + struct.pack('<q', 0)
open(sys.argv[1], 'wb').write(hdr + rec)
" "$ledger_path"
    rm -f "$ledger_path.head"   # a hand-built file stands in for a fresh ledger; no earlier rows are expected
    local vlen; vlen=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    [ "$vlen" = '{"ok":false,"first_failure_id":1,"reason":"record blob length out of range"}' ] \
      && pass "35 enterprise_mock: a record header claiming a 4 GiB blob is refused as corrupt, not sized from" \
      || fail "35 enterprise_mock: a bogus 4 GiB blob length answered '$vlen' (expected the out-of-range refusal)"
    # The WRITE path must self-heal the same file: a record that cannot
    # be parsed ends the chain, so the repair step truncates there and
    # the next append starts a fresh, valid chain -- the alternative
    # (refusing the file) would leave the ledger permanently unwritable.
    local wlen wver
    wlen=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.corrupt_len', '{\"n\":1}'), '<NULL>');" 2>&1)
    wver=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    [ "$wlen" = "0" ] && [ "$wver" = '{"ok":true,"rows_verified":1}' ] \
      && pass "35 enterprise_mock: a corrupt-length record is repaired as a torn tail on the next write" \
      || fail "35 enterprise_mock: a corrupt-length record was not repaired (write '$wlen' / verify '$wver')"
  else
    fail "35 enterprise_mock: bogus blob length: $ledger_path does not exist (an earlier assertion in this gate must have failed to actually load the mock)"
  fi

  # --- the head record, the anchor log, and the audit redaction ---------
  #
  # The anchor log and the redaction mode are read from the daemon's
  # environment, and the daemon snapshots its environment when it starts
  # -- so the swap needs a daemon restart, not a config reload. The
  # configuration file is the one this gate has been driving all along,
  # so the restart continues from the same enterprise core, the same
  # ledger path and the same ledger key.
  if ! rb_daemon_restart FSQL_LEDGER_ANCHOR_LOG=stderr FSQL_AUDIT_REDACT=hash; then
    fail "35 enterprise_mock: the daemon did not restart with the anchor log and the redaction mode set"
  else
    # A fresh chain, so the head record below is this chain's own.
    rm -f "$ledger_path" "$ledger_path.head" "$ledger_path.csv"
    local anchored
    anchored=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('test.anchor', '{\"question\":\"a customer name\"}'), '<NULL>');" 2>&1)
    if [ "$anchored" != "0" ]; then
      fail "35 enterprise_mock: the anchor-log append answered '$anchored' (expected 0)"
    fi

    # The head record holds the chain's row count AND an HMAC over its own
    # contents, so a head file edited by hand does not verify.
    local headrec
    headrec=$(cat "$ledger_path.head" 2>/dev/null)
    case "$headrec" in
      *"kind=2 rows=1 mac="*)
        pass "35 enterprise_mock: the head record carries the chain's row count and a MAC of its own contents" ;;
      *)
        fail "35 enterprise_mock: the head record is '$headrec' (expected the kind, the row count and a MAC)" ;;
    esac

    local vhead
    vhead=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    [ "$vhead" = '{"ok":true,"rows_verified":1}' ] \
      && pass "35 enterprise_mock: the chain with an authenticated head record verifies clean" \
      || fail "35 enterprise_mock: expected a 1-row ok verify with the head record in place, got: $vhead"

    # The anchor log: one JSON line per append, naming the chain, its row
    # count and the newest entry hash of that chain.
    local anchor anchor_hash mirror_hash
    anchor=$(grep -o '{"event":"ledger_head","kind":2,"rows":1,"hash":"[0-9a-f]\{64\}"}' "$main_log" 2>/dev/null | tail -1)
    anchor_hash=$(printf '%s' "$anchor" | sed -n 's/.*"hash":"\([0-9a-f]\{64\}\)".*/\1/p')
    # The CSV mirror's last row carries the same entry hash, so the anchor
    # line names the chain's actual tip.
    mirror_hash=$(awk -F, 'END{print $6}' "$ledger_path.csv" 2>/dev/null)
    if [ -n "$anchor_hash" ] && [ "$anchor_hash" = "$mirror_hash" ]; then
      pass "35 enterprise_mock: the anchor log publishes one line per append, and its hash is the chain's newest entry hash"
    else
      fail "35 enterprise_mock: the anchor log line is '$anchor' (hash '$anchor_hash') and the chain's newest entry hash is '$mirror_hash'"
    fi

    # With redaction on, the stored record carries a fingerprint of the
    # text instead of the text itself.
    local stored
    stored=$(python3 -c "
import base64, csv, sys
rows = list(csv.reader(open(sys.argv[1], newline='')))
sys.stdout.write(base64.b64decode(rows[-1][2]).decode('utf-8', 'replace'))
" "$ledger_path.csv" 2>/dev/null)
    case "$stored" in
      *"a customer name"*)
        fail "35 enterprise_mock: with redaction on, the stored record still contains the question text" ;;
      *"sha256:"*)
        pass "35 enterprise_mock: with redaction on, the stored record holds a fingerprint of the question instead of the question" ;;
      *)
        fail "35 enterprise_mock: with redaction on, the stored record is '$stored' (expected a fingerprint)" ;;
    esac

    # A head file edited by hand does not match its own MAC.
    python3 -c "
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'(mac=)([0-9a-f])', lambda m: m.group(1) + ('0' if m.group(2) != '0' else '1'), s, count=1)
open(p, 'w').write(s)
" "$ledger_path.head" 2>/dev/null
    local vedit
    vedit=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    case "$vedit" in
      '{"ok":false,'*MAC*)
        pass "35 enterprise_mock: a head record edited by hand does not verify (its MAC no longer matches)" ;;
      *)
        fail "35 enterprise_mock: expected the edited head record to fail the verify, got: $vedit" ;;
    esac

    # The next append re-authenticates the head record, and the chain
    # verifies clean again.
    local anchor_before anchor_after
    anchor_before=$(grep -c '"event":"ledger_head"' "$main_log" 2>/dev/null || true)
    "${MARIADB[@]}" -e "SELECT fractal_audit_log('test.head_again', '{\"n\":2}');" >/dev/null 2>&1
    anchor_after=$(grep -c '"event":"ledger_head"' "$main_log" 2>/dev/null || true)
    local vagain
    vagain=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    if [ "$vagain" = '{"ok":true,"rows_verified":2}' ] && [ "$anchor_after" -eq $((anchor_before + 1)) ]; then
      pass "35 enterprise_mock: the next append re-authenticates the head record and publishes exactly one anchor line"
    else
      fail "35 enterprise_mock: after the edited head record, the chain answered '$vagain' and the anchor log grew by $((anchor_after - anchor_before)) line(s) (expected a 2-row ok verify and one line)"
    fi
  fi

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

# 8.3's MCP gate: builds on the harness's running scratch cluster
# (fractalsqld + the mock reasoning provider mdb_setup wired up) and
# starts the stdio fractalsql-mariadb-mcp C++ server subprocess against
# it, then drives a real client session through initialize / tools-list
# / per-tier tools/call round trips -- happy paths and clean error
# paths side by side, mirroring the SQL-level gates' own pairing style,
# plus the S-FT-004 partial-reasoning case through the admin tool. The
# client driver lives at mcp/tests/mcp_smoke_client.py so the .ps1 gate
# drives the same file. The server-side phase-0 lock checks (10.5/15.3/
# 15.5) make the regenerate-and-commit workflow mechanically enforced:
# a changed tool table without freshly generated committed locks fails
# here before any DB call runs.
gate_39_mcp_smoke() {
  # Self-skip until the MCP server code exists (spec 8.3's posture).
  # The server itself is the native C++17 binary; the only python3
  # dependency here is this gate's own JSON-RPC client driver.
  if [[ ! -f "$HERE/mcp/tests/mcp_smoke_client.py" \
        || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "39 mcp_smoke (mcp/ server code not present -- spec 8.3's self-skip)"
    return
  fi
  local mcp_py
  mcp_py="$(mcp_python)"
  if [[ -z "$mcp_py" ]]; then
    skip "39 mcp_smoke (no python3 on PATH -- the smoke client driver needs it)"
    return
  fi

  # The server binary. POSIX builds it from mcp/Makefile incrementally
  # (only when missing or stale against mcp/src); the gate needs
  # mariadb_config/pkg-config for the Connector/C + OpenSSL link lines,
  # which the engine gates' own fixture compiles already established
  # as present. On Windows the .sh harness uses the local
  # mcp/dist/windows-mcp build (built by mcp\scripts\windows\
  # build.bat) as-is.
  local mcp_exe mcp_why
  mcp_exe="$(mcp_resolve_exe 2>"$TMPROOT/fractalsql_bt_mcp_exe_why.txt")" \
    || { mcp_why="$(cat "$TMPROOT/fractalsql_bt_mcp_exe_why.txt" 2>/dev/null)";
         skip "39 mcp_smoke ($mcp_why)"; return; }

  # A per-run scratch CWD: the server's stderr JSON log (its own
  # per-call audit trail) lands there as mcp_server.log, and the
  # driver's fixture SQL must run against the SAME scratch cluster
  # every other mdb_setup gate serves from.
  local smoke_cwd="$TMPROOT/fractalsql_bt_mcp_smoke_${CUR_VER//./_}"
  rm -rf "$smoke_cwd"; mkdir -p "$smoke_cwd"
  local san_dir="$TMPROOT/fractalsql_bt_mcp_san_39_${CUR_VER//./_}"
  mcp_exe="$(mcp_san_wrap "$mcp_exe" "$san_dir")"

  MCP_HERE="$HERE/mcp" \
  MCP_SERVER_EXE="$mcp_exe" \
  MCP_TEST_DAEMON_EXE="$HERE/service/build/fractalsqld" \
  MCP_SERVER_CWD="$smoke_cwd" \
  MCP_MARIADB_BIN="$(command -v "${MARIADB[0]}")" \
  MCP_SLOW_REASONING_PLUGIN="$SLOW_SO" \
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
  FSQLCTL_SOCKET="$FSQD_SOCK" \
  FSQLCTL_KEY="$FSQD_KEY" \
  FSQLCTL_CONF="$FSQD_CONF" \
    "$mcp_py" -u "$HERE/mcp/tests/mcp_smoke_client.py"
  local rc=$?
  mcp_san_check "$san_dir" "39 mcp_smoke" || return
  if [[ $rc -ne 0 ]]; then
    fail "39 mcp_smoke: client driver exited $rc (server log: $smoke_cwd/mcp_server.log)"
  else
    pass "39 mcp_smoke: full MCP session (initialize, 93-tool catalog, discovery/cognition/agency round trips, enterprise clean-error path, \$ / cancel, resources+prompts, partial-reasoning S-FT-004 via the admin tools, shutdown drain)"
  fi
}

# The build mode the MCP server binary on disk was made in; mcp_resolve_exe
# rebuilds clean whenever it differs from the current run's.
mcp_mode_tag() { echo "a${ASAN}u${UBSAN}t${TSAN}c${COVERAGE}"; }

# Compiler/linker flags for the standalone MCP probes (space separated,
# no spaces inside a flag). UBSAN does not recover, as in mcp/Makefile.
mcp_san_flags() {
  local f=""
  [[ "$ASAN"  -eq 1 ]] && f+=" -fsanitize=address"
  [[ "$UBSAN" -eq 1 ]] && f+=" -fsanitize=undefined -fno-sanitize-recover=undefined"
  [[ "$TSAN"  -eq 1 ]] && f+=" -fsanitize=thread"
  [[ -n "$f" ]] && f+=" -fno-omit-frame-pointer"
  echo "$f"
}

# mcp_san_wrap <exe> <dir>: when the server is sanitized, prints a wrapper
# that execs it with each sanitizer's log_path pointing into <dir>, so a
# report is attributed to the server alone (not to the python driver or
# mariadbd that share the preloaded runtime) and survives however the
# server exits. Prints <exe> unchanged for a plain run.
mcp_san_wrap() {
  local exe="$1" dir="$2"
  if [[ "$ASAN$UBSAN$TSAN" = "000" ]]; then echo "$exe"; return; fi
  rm -rf "$dir"; mkdir -p "$dir"
  # A compiled wrapper, not a shell script: when libtsan is preloaded for
  # the extension gates, /bin/sh itself segfaults at start-up, and the
  # server would die before it ran.
  local w="$dir/mcp-san-wrapper" src="$dir/mcp-san-wrapper.c"
  cat >"$src" <<'WRAP_EOF'
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void add(const char *name, const char *extra, const char *log) {
  const char *old = getenv(name);
  char *v = malloc(strlen(old ? old : "") + strlen(extra) + strlen(log) + 4);
  sprintf(v, "%s%s%s%s", old ? old : "", old && *old ? ":" : "", extra, log);
  setenv(name, v, 1);
}
int main(int argc, char **argv) {
  (void)argc;
  add("ASAN_OPTIONS", "", "log_path=" WRAP_DIR "/mcp_asan");
  add("UBSAN_OPTIONS", "print_stacktrace=1:", "log_path=" WRAP_DIR "/mcp_ubsan");
  add("TSAN_OPTIONS", "", "log_path=" WRAP_DIR "/mcp_tsan");
#ifdef WRAP_UNSET_PRELOAD
  /* a TSan server links its own runtime; a second preloaded copy aborts it */
  unsetenv("LD_PRELOAD");
#endif
  argv[0] = WRAP_EXE;
  execv(WRAP_EXE, argv);
  perror("mcp-san-wrapper: exec");
  return 127;
}
WRAP_EOF
  local defs=(-DWRAP_DIR="\"$dir\"" -DWRAP_EXE="\"$exe\"")
  [[ "$TSAN" -eq 1 ]] && defs+=(-DWRAP_UNSET_PRELOAD)
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES cc -O1 "${defs[@]}" "$src" -o "$w" >"$dir/wrapper-build.log" 2>&1; then
    echo "$exe"; return
  fi
  echo "$w"
}

# mcp_san_check <dir> <label>: fails the gate when the sanitized server
# wrote a report. No-op for a plain run.
mcp_san_check() {
  local dir="$1" label="$2" f
  [[ "$ASAN$UBSAN$TSAN" = "000" ]] && return 0
  for f in "$dir"/mcp_asan* "$dir"/mcp_ubsan* "$dir"/mcp_tsan*; do
    [[ -f "$f" ]] || continue
    fail "$label: the sanitized MCP server reported errors ($f):"
    head -n 40 "$f" >&2
    return 1
  done
  return 0
}

# --- the MCP server binary, shared by gates 39/40/42/43/44 -----------------
# One resolver so every MCP-backed gate agrees on WHICH binary it drives
# and on how to build it. Deliberately factored out of gate 39 (rather
# than duplicated) because the new gates 40/42/43/44 all need the same
# binary, and a second copy of the Windows/POSIX build logic would be a
# second copy of the "which path is it on" question -- the question that
# has already bitten this harness once.
#
# Echoes the resolved path on stdout; returns 1 (with a skip message on
# stderr) when the binary cannot be produced here.
mcp_resolve_exe() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # The .sh harness uses the local mcp/dist/windows-mcp build (built by
      # mcp\scripts\windows\build.bat) as-is -- there is no make/compiler
      # toolchain the POSIX harness could use to rebuild it.
      local exe="$HERE/mcp/dist/windows-mcp/fractalsql-mariadb-mcp.exe"
      if [[ ! -f "$exe" ]]; then
        echo "no mcp/dist/windows-mcp build -- run mcp\\scripts\\windows\\build.bat" >&2
        return 1
      fi
      printf '%s' "$exe"
      ;;
    *)
      local exe="$HERE/mcp/fractalsql-mariadb-mcp"
      local stamp="$HERE/mcp/.mcp-build-mode"
      local tag; tag="$(mcp_mode_tag)"
      local needs_build=0
      # No stamp means the objects came from an unknown mode (for example an
      # earlier --coverage run, whose leftovers fail the final link with
      # undefined __gcov_*): treat that as a mismatch and clean once.
      local have; have="$(cat "$stamp" 2>/dev/null || echo unknown)"
      # --coverage: the first resolution in a run does a clean, instrumented
      # build (the marker lives under GCOV_PREFIX, so it is per run), so the
      # MCP gates exercise a binary whose counters the report can read.
      local cov_marker=""
      if [[ "$COVERAGE" -eq 1 ]]; then
        cov_marker="$GCOV_PREFIX/.mcp_cov_built"
        [[ -f "$cov_marker" ]] || needs_build=1
      fi
      if [[ ! -x "$exe" ]]; then
        needs_build=1
      elif [[ "$have" != "$tag" ]]; then
        needs_build=1
      elif [[ -n "$(find "$HERE/mcp/src" \( -name '*.cpp' -o -name '*.h' \) \
                    -newer "$exe" -print 2>/dev/null | head -n1)" ]]; then
        needs_build=1
      fi
      if [[ "$needs_build" = 1 ]]; then
        if ! command -v make >/dev/null 2>&1 || ! command -v g++ >/dev/null 2>&1; then
          echo "no make/g++ toolchain to build the MCP server binary" >&2
          return 1
        fi
        # Objects from another mode (or a coverage rerun) must not link into
        # this binary uninstrumented -- see mcp_mode_tag.
        if [[ "$have" != "$tag" || -n "$cov_marker" ]]; then
          [[ -n "$cov_marker" ]] && rm -f "$HERE/mcp"/*.gcda "$HERE/mcp/src"/*.gcda "$HERE/mcp/src/adapters"/*.gcda
          env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES make -C "$HERE/mcp" clean >&2
        fi
        local mcp_make_args=()
        [[ "$COVERAGE" -eq 1 ]] && mcp_make_args+=(COVERAGE=1)
        [[ "$ASAN"  -eq 1 ]] && mcp_make_args+=(ASAN=1)
        [[ "$UBSAN" -eq 1 ]] && mcp_make_args+=(UBSAN=1)
        [[ "$TSAN"  -eq 1 ]] && mcp_make_args+=(TSAN=1)
        if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES make -C "$HERE/mcp" ${mcp_make_args[@]+"${mcp_make_args[@]}"} >&2; then
          echo "MCP server build failed" >&2
          return 1
        fi
        [[ -n "$cov_marker" ]] && : > "$cov_marker"
        echo "$tag" >"$stamp"
      fi
      printf '%s' "$exe"
      ;;
  esac
}

# The python3 interpreter for the MCP client drivers, or empty when there
# is none. Honors the harness's own $PY override (the same one gate 39
# uses) so a machine with only "python" on PATH still runs the gates.
mcp_python() {
  local py
  py="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  [[ -n "${PY:-}" ]] && py="$PY"
  printf '%s' "$py"
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
gate_40_mcp_https() {
  if [[ ! -f "$HERE/mcp/tests/mcp_https_smoke_client.py" \
        || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "40 mcp_https (mcp/ server code not present)"
    return
  fi
  local mcp_py; mcp_py="$(mcp_python)"
  if [[ -z "$mcp_py" ]]; then
    skip "40 mcp_https (no python3 on PATH -- the TLS smoke client driver needs it)"
    return
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    skip "40 mcp_https (no openssl CLI on PATH to generate the throwaway TLS cert/key)"
    return
  fi
  local mcp_exe mcp_why
  mcp_exe="$(mcp_resolve_exe 2>"$TMPROOT/fractalsql_bt_mcp_exe_why.txt")" \
    || { mcp_why="$(cat "$TMPROOT/fractalsql_bt_mcp_exe_why.txt" 2>/dev/null)";
         skip "40 mcp_https ($mcp_why)"; return; }

  # Throwaway self-signed cert/key, 1-day validity, CN=127.0.0.1 (the only
  # host this gate ever connects to). Regenerated every run; never reused
  # across invocations and never committed anywhere.
  local tls_cert="$TMPROOT/fractalsql_bt_mcp_https_cert.pem"
  local tls_key="$TMPROOT/fractalsql_bt_mcp_https_key.pem"
  rm -f "$tls_cert" "$tls_key"
  # MSYS_NO_PATHCONV: under MSYS/git-bash an MSYS-built openssl otherwise
  # rewrites the leading "/" in -subj as a Windows path (the well-known
  # MSYS argv path-conversion gotcha).
  # -config pointing at a minimal synthesized [req]/distinguished_name
  # section, rather than OPENSSL_CONF=/dev/null (empty config): whichever
  # openssl resolves on PATH may carry a baked-in default config path from
  # an unrelated install (seen in practice on Windows: PostgreSQL's
  # psqlODBC ships its own openssl.exe pointing at its own
  # etc/openssl.cnf, which `openssl req` hard-fails loading if it doesn't
  # exist) -- but macOS's /usr/bin/openssl is Apple's LibreSSL, not
  # OpenSSL (Homebrew's real openssl@3 is keg-only and never reaches
  # PATH), and LibreSSL's `req`, unlike OpenSSL >= 1.1.1, has no built-in
  # fallback when the config has no distinguished_name section. An
  # explicit minimal config satisfies both implementations.
  local tls_cnf="$TMPROOT/fractalsql_bt_mcp_https_openssl.cnf"
  printf '[req]\ndistinguished_name = dn\nprompt = no\n[dn]\n' >"$tls_cnf"
  if ! MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
        -config "$tls_cnf" -keyout "$tls_key" -out "$tls_cert" >/tmp/fractalsql_bt_mcp_https_certgen.log 2>&1; then
    fail "40 mcp_https: openssl req failed to generate the throwaway cert/key (see /tmp/fractalsql_bt_mcp_https_certgen.log)"
    return
  fi

  # A per-run scratch CWD: the server's stderr JSON log lands there.
  local https_cwd="$TMPROOT/fractalsql_bt_mcp_https_${CUR_VER//./_}"
  rm -rf "$https_cwd"; mkdir -p "$https_cwd"

  # The TLS port must be a free port of its own, distinct from every
  # other gate's -- the harness's own 133xx range is already spoken for
  # by the cluster's own port, and a squatted port silently breaks the
  # user's next run.
  local tls_port=$(( 13400 + $(echo "$CUR_VER" | tr -d '.') % 90 ))

  local san_dir="$TMPROOT/fractalsql_bt_mcp_san_40_${CUR_VER//./_}"
  mcp_exe="$(mcp_san_wrap "$mcp_exe" "$san_dir")"
  MCP_SERVER_EXE="$mcp_exe" \
  MCP_SERVER_CWD="$https_cwd" \
  MCP_HTTPS_PORT="$tls_port" \
  MCP_HTTPS_CERT="$tls_cert" \
  MCP_HTTPS_KEY="$tls_key" \
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
    "$mcp_py" -u "$HERE/mcp/tests/mcp_https_smoke_client.py"
  local rc=$?
  mcp_san_check "$san_dir" "40 mcp_https" || return
  if [[ $rc -ne 0 ]]; then
    fail "40 mcp_https: client driver exited $rc (server log: $https_cwd/mcp_https_server.log)"
  else
    pass "40 mcp_https: TLS fail-fast misconfig, TLS-only listening, a full authenticated JSON-RPC round trip, one reply per connection, and a terminal 404"
  fi
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
gate_41_parse_probe() {
  if [[ ! -f "$HERE/tests/parse_csv_probe.c" ]]; then
    skip "41 parse_probe (tests/parse_csv_probe.c not present)"
    return
  fi
  local cc="${CC:-cc}"
  if ! command -v "$cc" >/dev/null 2>&1; then
    skip "41 parse_probe (no C compiler on PATH)"
    return
  fi
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  # A SEPARATELY-named support object (not src/fractalsql_parse.o, which
  # the real build already populated with this same file's hits from
  # earlier gates) so this probe's run only ADDS the parser's hits via
  # lcov's own same-source-path summation, rather than overwriting the
  # real build's object and risking its already-recorded hits.
  local mainobj="src/_parse_csv_probe_main.o"
  local supportobj="src/_parse_csv_probe_support.o"
  rm -f "$mainobj" "$supportobj"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" -std=c99 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc \
        -c tests/parse_csv_probe.c -o "$mainobj" \
        >/tmp/fractalsql_bt_parse_probe_build.log 2>&1 \
     || ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" -std=c99 -O1 -g \
        ${covflags[@]+"${covflags[@]}"} -Isrc \
        -c src/fractalsql_parse.c -o "$supportobj" \
        >>/tmp/fractalsql_bt_parse_probe_build.log 2>&1; then
    fail "41 parse_probe: probe failed to build (see /tmp/fractalsql_bt_parse_probe_build.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  local bin="/tmp/fractalsql_bt_parse_csv_probe"
  if ! env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cc" ${covflags[@]+"${covflags[@]}"} \
        "$mainobj" "$supportobj" src/fractalsql_interrupt.c -o "$bin" \
        >>/tmp/fractalsql_bt_parse_probe_build.log 2>&1; then
    fail "41 parse_probe: probe failed to link (see /tmp/fractalsql_bt_parse_probe_build.log)"
    rm -f "$mainobj" "$supportobj"
    return
  fi
  # No sanitizer instrumentation of its own -- same LD_PRELOAD-exclusion
  # the other standalone gates need under --asan/--ubsan/--tsan.
  local out; out=$(env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  printf '%s\n' "$out"
  if [[ $rc -eq 0 ]]; then
    pass "41 parse_probe: parse_vector_csv / parse_corpus / parse_index_csv happy paths and every malformed-input rejection"
  else
    fail "41 parse_probe: the parser probe reported a failure (see the OK/FAIL lines above)"
  fi
  rm -f "$mainobj" "$supportobj"
}

# Gates 42/43/44: the MCP's own standalone C++ probes.
#
# All three are DB-agnostic or skip cleanly when no cluster is reachable,
# and all three link the MCP's own sources directly rather than driving
# them through the JSON-RPC surface -- which is the only way to reach
# several of their internal branches at all (a malformed vector element
# would be rejected by the MCP's own inputSchema check before it ever
# reached the coercion code; a per-client concurrency limit is a
# mutex-guarded counter that only a direct call can saturate
# deterministically).
mcp_probe_gate() {
  local gate="$1" title="$2" src="$3" label="$4" extra_sources="$5"
  local probe="$HERE/mcp/tests/$src"
  if [[ ! -f "$probe" ]]; then
    skip "$gate $label ($src not present)"
    return
  fi
  local cxx="${FSQL_CXX:-}"
  if [[ -z "$cxx" ]]; then
    for c in g++ clang++ c++; do
      if command -v "$c" >/dev/null 2>&1; then cxx="$c"; break; fi
    done
  fi
  if [[ -z "$cxx" ]]; then
    skip "$gate $label (no C++ compiler on PATH -- set FSQL_CXX)"
    return
  fi
  local mcp_src="$HERE/mcp/src"
  local inc=()
  # The MariaDB connector headers (db_probe needs them); the OpenSSL
  # headers (logging.cpp needs them, and db_probe links logging.cpp).
  for d in "$HERE/deps/mariadb/root/include/mysql" \
           "/c/Program Files/MariaDB 11.4/include/mysql"; do
    [[ -d "$d" ]] && inc+=(-I"$d")
  done
  # The connector's own header path, as the MCP build asks for it: on
  # Linux the headers live under /usr/include/mariadb, and the vendored
  # tree above is not part of a fresh checkout.
  if command -v mariadb_config >/dev/null 2>&1; then
    local mcflags mcflag
    mcflags=$(mariadb_config --cflags 2>/dev/null)
    for mcflag in $mcflags; do
      [[ -n "$mcflag" ]] && inc+=("$mcflag")
    done
  fi
  for d in /usr/include /usr/local/include /opt/homebrew/opt/openssl@3/include; do
    [[ -d "$d/openssl" ]] && inc+=(-I"$d")
  done
  local libdirs=()
  for d in "$HERE/deps/mariadb/root/lib" "$HERE/deps/mariadb/root/lib/mariadb" \
           "/c/Program Files/MariaDB 11.4/lib"; do
    [[ -d "$d" ]] && libdirs+=(-L"$d")
  done
  # The connector's own library path, as the MCP build asks for it (mcp/Makefile uses
  # `mariadb_config --libs`): Homebrew's mariadb and openssl@3 are keg-only, so -lmariadb /
  # -lssl / -lcrypto do not resolve from a default search path there.
  if command -v mariadb_config >/dev/null 2>&1; then
    local mclib
    for mclib in $(mariadb_config --libs 2>/dev/null); do
      [[ "$mclib" == -L* ]] && libdirs+=("$mclib")
    done
  fi
  for d in /opt/homebrew/opt/openssl@3/lib /usr/local/opt/openssl@3/lib; do
    [[ -d "$d" ]] && libdirs+=(-L"$d")
  done
  local covflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  # shellcheck disable=SC2207
  covflags+=($(mcp_san_flags))
  # std::to_chars(double) in mcp/src/vectors.cpp needs macOS >= 13.3 (see mcp/Makefile)
  local minver=()
  [[ "$(uname -s)" = "Darwin" ]] && minver+=(-mmacosx-version-min=13.3)
  local bin="$TMPROOT/fractalsql_bt_${src%.cpp}"
  local buildlog="/tmp/fractalsql_bt_${src%.cpp}_build.log"
  # Built from mcp/ so the recorded source path for mcp/src/*.cpp matches
  # the main build's own, merging into its coverage rather than
  # duplicating it.
  if ! ( cd "$HERE/mcp" && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$cxx" \
          -std=c++17 -O1 -g ${covflags[@]+"${covflags[@]}"} ${minver[@]+"${minver[@]}"} \
          -Ivendor ${inc[@]+"${inc[@]}"} \
          "tests/$src" $extra_sources \
          -o "$bin" ${libdirs[@]+"${libdirs[@]}"} \
          ${MCP_PROBE_LIBS:-} ) >"$buildlog" 2>&1; then
    fail "$gate $label: the probe failed to build (see $buildlog)"
    return
  fi
  local out; out=$(cd "$HERE/mcp" && env -u LD_PRELOAD -u DYLD_INSERT_LIBRARIES "$bin" 2>&1)
  local rc=$?
  printf '%s\n' "$out"
  if [[ $rc -eq 0 ]]; then
    pass "$gate $label: the standalone probe's own checks all passed"
  else
    fail "$gate $label: the standalone probe reported a failure (see the OK/FAIL lines above)"
  fi
}

gate_42_vectors_probe() {
  # vectors.cpp is pure (JSON in, JSON/string/bytes out): no DB, no
  # transport, no cluster needed.
  mcp_probe_gate 42 vectors_probe vectors_probe.cpp vectors_probe \
    "src/vectors.cpp src/errors.cpp"
}

gate_43_db_probe() {
  # db.cpp talks to a LIVE MariaDB server through the C connector, so this
  # gate needs the harness's scratch cluster. The probe skips cleanly
  # (exit 0) when no server is reachable -- a missing cluster is not a
  # defect in db.h.
  if [[ ! -f "$HERE/mcp/tests/db_probe.cpp" ]]; then
    skip "43 db_probe (db_probe.cpp not present)"
    return
  fi
  local mcp_py; mcp_py="$(mcp_python)"
  export MCP_PROBE_LIBS="-lmariadb -lssl -lcrypto"
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
    mcp_probe_gate 43 db_probe db_probe.cpp db_probe \
      "src/db.cpp src/errors.cpp src/logging.cpp"
  unset MCP_PROBE_LIBS
}

gate_44_concurrency_probe() {
  # concurrency.h is header-only and DB-agnostic: no cluster needed.
  mcp_probe_gate 44 concurrency_probe concurrency_probe.cpp concurrency_probe ""
}

# =====================================================================
# Gate 45: the Agency-tier domain engines (A-P) and the five
# "Universal Agent" procedures, on MariaDB's own calling convention.
#
# This is the MariaDB-shaped counterpart of the upstream gate that
# covers the same sixteen engines. It is NOT a port of that gate's
# text: the two products have different call surfaces, and the
# assertions have to be written against the one this repo actually
# ships. The three differences that matter:
#
#   1. CALL, not SELECT. Every engine here is a stored PROCEDURE with
#      a trailing OUT p_result JSON, so the calling shape is
#      "CALL fractal_agent_x(args..., @r); SELECT @r;" -- one
#      connection, two statements. A scalar SELECT would raise
#      ERROR 1305 (PROCEDURE ... does not exist).
#   2. The engines' own SIGNAL messages, not upstream's. MariaDB's
#      procedures raise SQLSTATE 45000 with a per-engine message
#      ("no rows matching the filter", "no node rows found", ...);
#      each clean-error assertion below greps for the message this
#      repo's sql/install_agents.sql actually raises.
#   3. MariaDB's own result-JSON key names, which differ from
#      upstream's (threat_score, not anomaly_score; rationale, not
#      explanation; morph_dimension, not dimension; ...). The
#      assertions below match sql/install_agents.sql exactly.
#
# The reasoning canary: this repo's mock LLM (scripts/ci/mock_llm.py)
# answers every chat request with a fenced "```sql\nSELECT 1\n```"
# block, and fractal_reason returns the plugin's summary VERBATIM
# (fence markers and all). So "SELECT 1" appearing inside an
# engine's rationale/triage_summary/analysis field is the observable
# proof that the engine's reasoning step really ran against the
# live endpoint -- the same claim upstream proves with a file-based
# canary, expressed in this architecture's terms.
#
# Engines already covered by gate 24 (recall_hybrid/E,
# recommend_diverse/F, route_task/C, patient_deterioration_triage/H,
# outlier_intercept/D, detect_loop) are deliberately NOT re-tested
# here: gate 45 covers what gate 24 leaves uncovered, so the two
# gates together cover the whole tier without duplicating a single
# assertion.
# =====================================================================
gate_45_domain_agents() {
  local g45log="/tmp/fractalsql_bt_gate45.log"

  # g45_call <sql> : run one statement batch and return its STDOUT.
  # stderr is captured to its own file, not folded into the result:
  # a SIGNAL lands on stderr, but so does the client's own noise (the
  # Windows client's "insecure passwordless login" notice, for one),
  # and folding the two together makes a data assertion match a
  # warning line instead of the value it is looking for.
  G45_ERR="/tmp/fractalsql_bt_gate45.err"
  g45_call() {
    "${MARIADB[@]}" -N -e "$1" 2>"$G45_ERR"
  }

  # g45_expect_err <label> <expected-substring> <sql>
  # Asserts the statement FAILS with the expected clean error. The
  # client exits nonzero on a SIGNAL and the message lands on stderr.
  g45_expect_err() {
    local label="$1" want="$2" sql="$3" out rc err
    out="$(g45_call "$sql")"; rc=$?
    err="$(cat "$G45_ERR" 2>/dev/null)"
    if [ "$rc" -eq 0 ]; then
      fail "45 domain_agents: $label -- expected an error, but the call succeeded: $out"
      return
    fi
    if printf '%s' "$err$out" | grep -qF "$want"; then
      pass "45 domain_agents: $label"
    else
      fail "45 domain_agents: $label -- expected '$want', got: $err$out"
    fi
  }

  # --- fixtures ------------------------------------------------------
  # Every fixture is deterministic: no RAND() anywhere, so a rerun
  # of the gate produces byte-identical results and a numeric
  # assertion can be an exact comparison rather than a range.
  if ! "${MARIADB[@]}" -e "
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
  " >"$g45log" 2>&1; then
    fail "45 domain_agents: fixture setup failed (see $g45log)"
    cat "$g45log" >&2
    return
  fi

  # --- Engine A: fractal_agent_anomaly_triage -----------------------
  # drift + reason. The threat_score is a real computed float (not a
  # constant), and the triage_summary carries the reasoning canary.
  local a1
  a1="$(g45_call "
    CALL fractal_agent_anomaly_triage('g45_logs','metric','ts','host','host-1',32,@r);
    SELECT @r;")"
  printf '%s' "$a1" | grep -Eq '"threat_score" *: *"-?[0-9]+\.[0-9]+"' \
    && pass "45 domain_agents: anomaly_triage (A) threat_score is a real computed drift float" \
    || fail "45 domain_agents: anomaly_triage threat_score not a float: $a1"
  printf '%s' "$a1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: anomaly_triage (A) composes drift -> reason (the reasoning step really ran)" \
    || fail "45 domain_agents: expected the reasoning canary in triage_summary, got: $a1"
  printf '%s' "$a1" | grep -q '"anomaly_type" *: *"vector_drift"' \
    && pass "45 domain_agents: anomaly_triage (A) names the anomaly type" \
    || fail "45 domain_agents: anomaly_triage anomaly_type missing: $a1"
  g45_expect_err "anomaly_triage (A) raises a clean error when the filter matches no rows" \
    "no rows matching the filter" \
    "CALL fractal_agent_anomaly_triage('g45_logs','metric','ts','host','no-such-host',32,@r);"
  g45_expect_err "anomaly_triage (A) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
    "CALL fractal_agent_anomaly_triage(NULL,'metric','ts','host','host-1',32,@r);"

  # --- Engine B: fractal_agent_allocate -----------------------------
  # Community-tier cardinality-constrained optimizer + reason. The
  # 'allocation' key is a NESTED object ({"sharpe":..,"weights":[..]}),
  # so JSON_EXTRACT is the right tool, not JSON_VALUE.
  local b1
  b1="$(g45_call "
    CALL fractal_agent_allocate('[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1,
                                '{\"portfolio\": \"gate45\"}', @r);
    SELECT @r;")"
  printf '%s' "$b1" | grep -Eq '"weights" *: *\[[^]]*\]' \
    && pass "45 domain_agents: allocate (B) returns a real nested allocation with weights" \
    || fail "45 domain_agents: allocate allocation.weights missing: $b1"
  printf '%s' "$b1" | grep -Eq '"sharpe" *: *"?0\.1"?' \
    && pass "45 domain_agents: allocate (B) sharpe matches the hand-computed value (0.1)" \
    || fail "45 domain_agents: allocate sharpe was not 0.1: $b1"
  printf '%s' "$b1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: allocate (B) narrates the allocation through the reasoning tier" \
    || fail "45 domain_agents: allocate rationale missing the reasoning canary: $b1"

  # --- Engine G: fractal_agent_data_analyst -------------------------
  # The horizontal NL -> SQL -> execute -> reason engine. The mock
  # LLM's canned reply IS a valid SELECT, so the whole pipeline runs
  # for real: the generated_sql is the mock's own fenced block
  # ("SELECT 1") and result_json reports the execution.
  # p_auto_execute is the caller's EXPLICIT opt-in (the procedure has
  # no default -- MariaDB routines cannot carry DEFAULT values), so
  # the executing path passes TRUE explicitly.
  local g1
  g1="$(g45_call "
    CALL fractal_agent_data_analyst('total amount spent per category in g45_data',
                                    '[\"g45_data\"]', 2, NULL, TRUE, @r);
    SELECT @r;")"
  printf '%s' "$g1" | grep -q '"generated_sql" *: *"SELECT 1"' \
    && pass "45 domain_agents: data_analyst (G) generated real SQL from the LLM tier" \
    || fail "45 domain_agents: data_analyst generated_sql missing: $g1"
  printf '%s' "$g1" | grep -q '"status" *: *"executed"' \
    && pass "45 domain_agents: data_analyst (G) actually EXECUTED the generated SQL" \
    || fail "45 domain_agents: data_analyst result_json not executed: $g1"
  printf '%s' "$g1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: data_analyst (G) narrates the result through the reasoning tier" \
    || fail "45 domain_agents: data_analyst analysis missing the reasoning canary: $g1"
  # p_auto_execute => FALSE: the statement is generated and validated
  # but NOT run, so result_json carries no "executed" status and the
  # reasoning step never runs (analysis stays null).
  local g1b
  g1b="$(g45_call "
    CALL fractal_agent_data_analyst('total amount spent per category in g45_data',
                                    '[\"g45_data\"]', 2, NULL, FALSE, @r);
    SELECT @r;")"
  printf '%s' "$g1b" | grep -q '"generated_sql" *: *"SELECT 1"' \
    && pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE still returns the generated SQL" \
    || fail "45 domain_agents: data_analyst generated_sql missing with auto_execute=FALSE: $g1b"
  printf '%s' "$g1b" | grep -q '"status" *: *"executed"' \
    && fail "45 domain_agents: data_analyst (G) EXECUTED the generated SQL with auto_execute=FALSE" \
    || pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE does NOT execute the generated SQL"
  printf '%s' "$g1b" | grep -q '"analysis" *: *null' \
    && pass "45 domain_agents: data_analyst (G) with auto_execute=FALSE skips the reasoning step (analysis null)" \
    || fail "45 domain_agents: data_analyst analysis is not null with auto_execute=FALSE: $g1b"

  # --- Engine I: fractal_agent_feedback_audit -----------------------
  # Pure analytics, no LLM: it warms the D_q window with varied
  # searches and reports the diversity quotient. The explanation is a
  # NESTED object ({"dq":..,"diversify_enabled":..}).
  local i1
  i1="$(g45_call "
    CALL fractal_agent_feedback_audit('g45_fcatalog','emb','[0.5,0.5,0.5]',
                                      'g45_fwarmup','vc',8,3,@r);
    SELECT @r;")"
  printf '%s' "$i1" | grep -Eq '"diversity_quotient" *: *"?-?[0-9]' \
    && pass "45 domain_agents: feedback_audit (I) reports a real diversity quotient" \
    || fail "45 domain_agents: feedback_audit diversity_quotient missing: $i1"
  printf '%s' "$i1" | grep -q '"diversify_enabled" *: *true' \
    && pass "45 domain_agents: feedback_audit (I) reports the diversify state it ran under" \
    || fail "45 domain_agents: feedback_audit explanation lacks diversify_enabled: $i1"
  g45_expect_err "feedback_audit (I) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
    "CALL fractal_agent_feedback_audit(NULL,'emb','[0.5]','g45_fwarmup','vc',8,3,@r);"

  # --- Engine J: fractal_agent_schedule_workload --------------------
  # fractal_search refinement + telemetry + reason. The assignment is
  # the node table's own PRIMARY KEY (id 1, nearest to the refined
  # task vector), and the confidence is 1/(1+distance) -- a real
  # number in (0,1].
  local j1
  j1="$(g45_call "
    CALL fractal_agent_schedule_workload('[0.8, 0.1, 0.0, 0.0, 0.1]',
                                         'g45_nodes', 'capability', 30, 50, 5, NULL, @r);
    SELECT @r;")"
  printf '%s' "$j1" | grep -Eq '"assigned_node" *: *"1"' \
    && pass "45 domain_agents: schedule_workload (J) assigns the nearest node (1)" \
    || fail "45 domain_agents: schedule_workload assigned_node wrong: $j1"
  printf '%s' "$j1" | grep -Eq '"confidence" *: *"?0\.[0-9]' \
    && pass "45 domain_agents: schedule_workload (J) derives a real confidence from the distance" \
    || fail "45 domain_agents: schedule_workload confidence missing: $j1"
  printf '%s' "$j1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: schedule_workload (J) justifies the placement through the reasoning tier" \
    || fail "45 domain_agents: schedule_workload rationale missing the reasoning canary: $j1"
  g45_expect_err "schedule_workload (J) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
    "CALL fractal_agent_schedule_workload('[0.1]', NULL, 'capability', 30, 50, 5, NULL, @r);"
  # The engine's own "no node rows found" is likewise unreachable
  # behind the shared scanner's error, for the same reason as L and M
  # above.
  g45_expect_err "schedule_workload (J) raises a clean error when the node table has no rows" \
    "no non-NULL vector rows found" \
    "CALL fractal_agent_schedule_workload('[0.9,0.1,0.0,0.0,0.1]', 'g45_empty', 'emb', 30, 50, 5, NULL, @r);"

  # --- Engine K: fractal_agent_rebalance_sibling --------------------
  # Community optimizer + trajectory search + reason. The nearest
  # allocation is resolved by searching the DELTA (current minus
  # baseline) against the stored allocation vectors, so the winner is
  # a real distance computation, not a fixed id.
  local k1
  k1="$(g45_call "
    CALL fractal_agent_rebalance_sibling(
        '[0.05, 0.10, 0.15, 0.20]',
        '[0.04, 0.0, 0.0, 0.0, 0.0, 0.09, 0.0, 0.0, 0.0, 0.0, 0.16, 0.0, 0.0, 0.0, 0.0, 0.25]',
        4, 'g45_alloc', 'alloc', '[0.25, 0.25, 0.25, 0.25]', 42, NULL, @r);
    SELECT @r;")"
  printf '%s' "$k1" | grep -Eq '"nearest_alloc_id" *: *"[123]"' \
    && pass "45 domain_agents: rebalance_sibling (K) resolves a real nearest allocation" \
    || fail "45 domain_agents: rebalance_sibling nearest_alloc_id missing: $k1"
  printf '%s' "$k1" | grep -Eq '"weights" *: *\[[^]]*\]' \
    && pass "45 domain_agents: rebalance_sibling (K) returns the optimizer's weights" \
    || fail "45 domain_agents: rebalance_sibling weights missing: $k1"
  printf '%s' "$k1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: rebalance_sibling (K) narrates the rebalance through the reasoning tier" \
    || fail "45 domain_agents: rebalance_sibling rationale missing the reasoning canary: $k1"
  g45_expect_err "rebalance_sibling (K) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
    "CALL fractal_agent_rebalance_sibling('[0.1]','[1,0,0,1]',1,NULL,'alloc','[1]',42,NULL,@r);"

  # --- Engine L: fractal_agent_detour_classify ----------------------
  # Trajectory search + box-counting dimension of the GPS trace + reason.
  # The trace needs a few hundred points for the box count to be
  # meaningful; a deterministic sine walk supplies them.
  local l1
  l1="$(g45_call "
    CALL fractal_agent_detour_classify(
        'g45_vehicles', 'emb', '[0.9, 0.1, 0.0, 0.0]', '[0.0, 0.9, 0.0, 0.0]',
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 200)
            SELECT t, ROUND(SIN(t/9.0) + t/200.0, 6) AS v FROM seq) q),
        5, 2, @r);
    SELECT @r;")"
  printf '%s' "$l1" | grep -Eq '"nearest_fleet_id" *: *"[123]"' \
    && pass "45 domain_agents: detour_classify (L) resolves the nearest fleet peer" \
    || fail "45 domain_agents: detour_classify nearest_fleet_id missing: $l1"
  printf '%s' "$l1" | grep -Eq '"trace_complexity" *: *"?-?[0-9]' \
    && pass "45 domain_agents: detour_classify (L) computes a real box-counting dimension for the GPS trace" \
    || fail "45 domain_agents: detour_classify trace_complexity missing: $l1"
  printf '%s' "$l1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: detour_classify (L) classifies the detour through the reasoning tier" \
    || fail "45 domain_agents: detour_classify rationale missing the reasoning canary: $l1"
  g45_expect_err "detour_classify (L) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
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
  g45_expect_err "detour_classify (L) raises a clean error when the fleet table has no rows" \
    "no non-NULL vector rows found" \
    "CALL fractal_agent_detour_classify('g45_empty','emb','[1,0]','[0,1]','[1,2]',5,2,@r);"

  # --- Engine M: fractal_agent_track_anomaly -----------------------
  # Trajectory search + DFA over the heading series + reason.
  local m1
  m1="$(g45_call "
    CALL fractal_agent_track_anomaly(
        'g45_tracks', 'emb', '[0.9, 0.1, 0.0, 0.0]', '[0.0, 0.9, 0.0, 0.0]',
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 120)
            SELECT t, ROUND(0.1 + 0.02*SIN(t/7.0), 6) AS v FROM seq) q),
        5, @r);
    SELECT @r;")"
  printf '%s' "$m1" | grep -Eq '"nearest_fleet_id" *: *"[123]"' \
    && pass "45 domain_agents: track_anomaly (M) resolves the nearest tracked peer" \
    || fail "45 domain_agents: track_anomaly nearest_fleet_id missing: $m1"
  printf '%s' "$m1" | grep -Eq '"dfa_exponent" *: *"?-?[0-9]' \
    && pass "45 domain_agents: track_anomaly (M) computes a real DFA exponent over the heading series" \
    || fail "45 domain_agents: track_anomaly dfa_exponent missing: $m1"
  printf '%s' "$m1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: track_anomaly (M) triages the track through the reasoning tier" \
    || fail "45 domain_agents: track_anomaly rationale missing the reasoning canary: $m1"
  g45_expect_err "track_anomaly (M) rejects NULL identifier arguments" \
    "identifier arguments must not be NULL" \
    "CALL fractal_agent_track_anomaly(NULL,'emb','[1,0]','[0,1]','[1,2,3]',5,@r);"
  # Same shared-scanner-first ordering as detour_classify above: the
  # engine's own "no track rows found" is unreachable behind
  # _fractalsql_scan_corpus's error.
  g45_expect_err "track_anomaly (M) raises a clean error when the track table has no rows" \
    "no non-NULL vector rows found" \
    "CALL fractal_agent_track_anomaly('g45_empty','emb','[1,0]','[0,1]','[1,2,3]',5,@r);"

  # --- Engine N: fractal_agent_network_coverage_alert --------------
  # No table arguments: the point cloud and the drift series are
  # passed directly. The cloud is a flattened 20x20 grid (800 values,
  # 2 per point), which is what the box count needs to be meaningful.
  local n1
  n1="$(g45_call "
    CALL fractal_agent_network_coverage_alert(
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY id, ord SEPARATOR ','), ']') FROM (
            SELECT r0*20 + c0 AS id, 1 AS ord, r0 + MOD(c0,3)*0.01 AS v
              FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '\$[*]' COLUMNS (r0 INT PATH '\$')) AS rr
             CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '\$[*]' COLUMNS (c0 INT PATH '\$')) AS cc
            UNION ALL
            SELECT r0*20 + c0 AS id, 2 AS ord, c0 + MOD(r0,3)*0.01 AS v
              FROM JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '\$[*]' COLUMNS (r0 INT PATH '\$')) AS rr
             CROSS JOIN JSON_TABLE('[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19]', '\$[*]' COLUMNS (c0 INT PATH '\$')) AS cc
        ) g),
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
            SELECT t, ROUND(CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31)
                                 ELSE 4.0 + 3.0*SIN(t*1.4) END, 6) AS v FROM seq) q),
        2, 48, 0.5, NULL, @r);
    SELECT @r;")"
  printf '%s' "$n1" | grep -Eq '"morph_dimension" *: *"?-?[0-9]' \
    && pass "45 domain_agents: network_coverage_alert (N) computes a real morphological dimension" \
    || fail "45 domain_agents: network_coverage_alert morph_dimension missing: $n1"
  printf '%s' "$n1" | grep -Eq '"lacunarity" *: *"?-?[0-9]' \
    && pass "45 domain_agents: network_coverage_alert (N) computes a real lacunarity" \
    || fail "45 domain_agents: network_coverage_alert lacunarity missing: $n1"
  printf '%s' "$n1" | grep -Eq '"drift_detected" *: *"?1"?' \
    && pass "45 domain_agents: network_coverage_alert (N) detects the drift in the series" \
    || fail "45 domain_agents: network_coverage_alert drift_detected not set: $n1"
  printf '%s' "$n1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: network_coverage_alert (N) issues the alert through the reasoning tier" \
    || fail "45 domain_agents: network_coverage_alert rationale missing the reasoning canary: $n1"
  g45_expect_err "network_coverage_alert (N) requires both the point cloud and the drift series" \
    "point_cloud and drift_series are required" \
    "CALL fractal_agent_network_coverage_alert(NULL, '[1,2,3]', 2, 48, 0.5, NULL, @r);"

  # --- Engine O: fractal_agent_regime_triage -----------------------
  # The general-purpose engine: DFA + drift + reason, no table
  # arguments at all.
  local o1
  o1="$(g45_call "
    CALL fractal_agent_regime_triage(
        (SELECT CONCAT('[', GROUP_CONCAT(v ORDER BY t SEPARATOR ','), ']') FROM (
            WITH RECURSIVE seq(t) AS (SELECT 1 UNION ALL SELECT t+1 FROM seq WHERE t < 96)
            SELECT t, ROUND(CASE WHEN t < 48 THEN 4.0 + 1.5*SIN(t*0.31)
                                 ELSE 4.0 + 3.0*SIN(t*1.4) END, 6) AS v FROM seq) q),
        64, 0.5, NULL, @r);
    SELECT @r;")"
  printf '%s' "$o1" | grep -Eq '"dfa_exponent" *: *"?-?[0-9]' \
    && pass "45 domain_agents: regime_triage (O) computes a real DFA exponent" \
    || fail "45 domain_agents: regime_triage dfa_exponent missing: $o1"
  printf '%s' "$o1" | grep -Eq '"recent_alpha" *: *"?-?[0-9]' \
    && printf '%s' "$o1" | grep -Eq '"baseline_alpha" *: *"?-?[0-9]' \
    && pass "45 domain_agents: regime_triage (O) reports both the recent and the baseline alpha" \
    || fail "45 domain_agents: regime_triage alpha pair missing: $o1"
  printf '%s' "$o1" | grep -Eq '"drift_detected" *: *"?1"?' \
    && pass "45 domain_agents: regime_triage (O) detects the regime change" \
    || fail "45 domain_agents: regime_triage drift_detected not set: $o1"
  g45_expect_err "regime_triage (O) requires a series" \
    "series is required" \
    "CALL fractal_agent_regime_triage(NULL, 64, 0.5, NULL, @r);"

  # --- Engine P: fractal_agent_diverse_portfolios ------------------
  # Enterprise-tier: the backing fractal_optimize_portfolio_multimodal
  # returns NULL on a Community deployment, and the procedure SIGNALs
  # a clean error rather than passing that NULL through as if it were
  # real data. The objective_mode guard is checked FIRST, so it fires
  # even with no enterprise tier loaded.
  g45_expect_err "diverse_portfolios (P) rejects an unknown objective_mode" \
    "objective_mode must be 'sharpe' or 'pareto'" \
    "CALL fractal_agent_diverse_portfolios('[0.05,0.1]','[1,0,0,1]',1,4,0.3,0.8,NULL,'nonsense',NULL,@r);"
  g45_expect_err "diverse_portfolios (P) raises a clean error when the enterprise tier is not loaded" \
    "enterprise tier not loaded" \
    "CALL fractal_agent_diverse_portfolios('[0.05,0.1]','[1,0,0,1]',1,4,0.3,0.8,NULL,'sharpe',NULL,@r);"

  # --- the Universal Agent procedures ------------------------------
  # fractal_search_agent: embed -> scan -> Scout search -> refetch
  # the rows -> reason. The mock's canned embedding is a real
  # 3-element vector, so the whole pipeline runs.
  local u1
  u1="$(g45_call "
    CALL fractal_search_agent('alpha', 'g45_univ', 'emb', 20, 30, @r);
    SELECT @r;")"
  printf '%s' "$u1" | grep -Eq '"source_doc_ids" *: *\[[^]]*\]' \
    && pass "45 domain_agents: search_agent resolves real source doc_ids from the corpus" \
    || fail "45 domain_agents: search_agent source_doc_ids missing: $u1"
  printf '%s' "$u1" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: search_agent answers through the reasoning tier" \
    || fail "45 domain_agents: search_agent answer missing the reasoning canary: $u1"
  g45_expect_err "search_agent rejects NULL arguments" \
    "query, table_name and vector_col must not be NULL" \
    "CALL fractal_search_agent(NULL,'g45_univ','emb',20,30,@r);"

  # fractal_rag_agent: the same pipeline behind a thinner surface --
  # the OUT is the bare answer scalar, not a document.
  local u2
  u2="$(g45_call "
    CALL fractal_rag_agent('alpha', 'g45_univ', 'emb', JSON_OBJECT('x',1), @r);
    SELECT @r;")"
  printf '%s' "$u2" | grep -q 'SELECT 1' \
    && pass "45 domain_agents: rag_agent returns the reasoned answer as a bare scalar" \
    || fail "45 domain_agents: rag_agent answer missing the reasoning canary: $u2"

  # fractal_agent_plan_explore: each branch is a DISTINCT corpus row
  # with its OWN vector (the branch's plan_trajectory), not the query
  # vector repeated.
  local u3
  u3="$(g45_call "
    CALL fractal_agent_plan_explore('start', 'g45_univ', 'emb', 2, @r);
    SELECT @r;")"
  printf '%s' "$u3" | grep -q '"plan_trajectory"' \
    && pass "45 domain_agents: plan_explore returns a plan trajectory per branch" \
    || fail "45 domain_agents: plan_explore plan_trajectory missing: $u3"
  g45_expect_err "plan_explore rejects NULL arguments" \
    "initial_state, strategy_table and vector_col must not be NULL" \
    "CALL fractal_agent_plan_explore(NULL,'g45_univ','emb',2,@r);"

  # fractal_agent_trajectory_predict: reads the baseline row by PK,
  # computes the delta, and searches the whole table for the nearest
  # point to that delta.
  local u4
  u4="$(g45_call "
    CALL fractal_agent_trajectory_predict('g45_traj','emb',1,3,0.5,@r);
    SELECT @r;")"
  printf '%s' "$u4" | grep -Eq '"predicted_state_vector" *: *\[[^]]*\]' \
    && pass "45 domain_agents: trajectory_predict returns a predicted state vector" \
    || fail "45 domain_agents: trajectory_predict predicted_state_vector missing: $u4"
  printf '%s' "$u4" | grep -Eq '"projected_drift_delta" *: *"?-?[0-9]' \
    && pass "45 domain_agents: trajectory_predict computes a real projected drift delta" \
    || fail "45 domain_agents: trajectory_predict projected_drift_delta missing: $u4"
  g45_expect_err "trajectory_predict rejects NULL arguments" \
    "table, vector_col and baseline_id must not be NULL" \
    "CALL fractal_agent_trajectory_predict(NULL,'emb',1,3,0.5,@r);"
  g45_expect_err "trajectory_predict raises a clean error for a baseline_id that does not exist" \
    "no row with the given baseline_id" \
    "CALL fractal_agent_trajectory_predict('g45_traj','emb',999,3,0.5,@r);"

  # --- the whole tier, in one sweep --------------------------------
  # A single call that exercises every engine in turn, so a
  # regression that breaks one engine's registration (a dropped
  # procedure, a renamed OUT parameter) is caught as one clean
  # failure rather than as N independent ones that each fail for
  # their own reason.
  local all1
  all1="$(g45_call "
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
         'fractal_agent_detect_loop');" | tail -1)"
  [ "$all1" = "21" ] \
    && pass "45 domain_agents: all 16 lettered engines plus the 5 Universal Agent procedures are registered" \
    || fail "45 domain_agents: expected 21 registered agent procedures, got: $all1"

  # --- cleanup ------------------------------------------------------
  "${MARIADB[@]}" -e "
    DROP TABLE IF EXISTS g45_logs, g45_alloc, g45_nodes, g45_data,
                         g45_vehicles, g45_tracks, g45_empty,
                         g45_fcatalog, g45_fwarmup, g45_traj, g45_univ;" \
    >/dev/null 2>&1
}

# =====================================================================
# Gate 46: the concurrent-ledger-write runner under ThreadSanitizer.
#
# WHY A STANDALONE RUNNER:
#
# The ledger in this product is a FILE, not a database table. Every
# kind=2 append goes through
#
#     fractal_ledger_write_kind2()        (src/fractalsql_enterprise.c)
#       -> ledger_write_entry()
#            -> ent_lock()                (g_ent_lock, one per process)
#            -> read the chain head, link the new record to it, hash,
#               append, fsync
#            -> ent_unlock()
#
# so the race that matters is INTRA-PROCESS: N client connections
# become N worker threads inside ONE fractalsqld process, all appending
# to the same chain. The runner reproduces exactly that shape -- N
# threads, one process, one ledger file -- and it is the only shape
# ThreadSanitizer can actually observe, because TSan instruments a
# process, not a client/daemon pair.
#
# The runner links the SAME adapter objects the daemon links (there is
# no separate "ledger library" here), so the code under test is the
# shipped code and is instrumented by the same -fsanitize=thread the
# daemon got.
#
# --tsan-ONLY, and that is not a formality: TSan can only report a race
# in instrumented code. Run uninstrumented, the gate would report
# "no race" every time and mean nothing -- so it is not in
# DEFAULT_GATES, it is in TSAN_GATES, and it SKIPS (rather than
# passes) when the run is not instrumented.
#
# The gate ALSO fails on a TSan report even if the runner's own checks
# passed: a race is a race whether or not the chain happened to come
# out right.
# =====================================================================
gate_46_ledger_tsan_concurrent() {
  if [ "$TSAN" -ne 1 ]; then
    skip "46 ledger TSan concurrency: --tsan-only (an uninstrumented runner cannot observe a race)"
    return
  fi
  # MSVC and clang-cl have no ThreadSanitizer runtime at all, so a
  # --tsan build on Windows is not possible; the same skip the other
  # engine's TSan gate uses.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      skip "46 ledger TSan concurrency: no ThreadSanitizer runtime on this platform"
      return
      ;;
  esac
  if ! command -v make >/dev/null 2>&1; then
    skip "46 ledger TSan concurrency: 'make' is not on PATH"
    return
  fi
  local log="/tmp/fractalsql_bt_gate46.log"
  local runner="$HERE/service/build/ledger_concurrency_runner"
  local ledger="/tmp/fractalsql_bt_gate46_ledger.dat"
  local suppressions="$HERE/service/tests/tsan_suppressions.txt"

  # TSAN=1 makes the runner's own translation unit instrumented, and
  # (in a --tsan run) the adapter objects are already instrumented --
  # gate 01 built the whole service/ tree with the same flag set, from
  # a clean tree. The check further down confirms that directly rather
  # than taking it on trust.
  if ! make -C "$HERE/service" TSAN=1 build/ledger_concurrency_runner >"$log" 2>&1; then
    fail "46 ledger TSan concurrency: the runner failed to build (see $log)"
    grep -iE "error|undefined" "$log" | head -5 | sed 's/^/         /'
    return
  fi
  if [ ! -x "$runner" ]; then
    fail "46 ledger TSan concurrency: the runner was not produced (see $log)"
    return
  fi

  # THE ANTI-FALSE-PASS CHECK. ThreadSanitizer can only report a race
  # in code it instrumented. If the adapter objects were left over from
  # a NON-instrumented build, the runner would link uninstrumented
  # ledger code, TSan would find nothing (because there is nothing
  # instrumented to find a race in), and this gate would report a
  # clean PASS that means nothing at all.
  #
  # So check the translation unit that ACTUALLY HOLDS THE LEDGER
  # (src/fractalsql_enterprise.c) for the TSan runtime's own symbols.
  # The runner's own main() being instrumented would prove nothing --
  # it is the ledger's object that matters.
  local ledger_obj="$HERE/service/build/daemon/fractalsql_enterprise.o"
  if [ ! -f "$ledger_obj" ]; then
    fail "46 ledger TSan concurrency: the ledger object $ledger_obj is missing (see $log)"
    return
  fi
  local inspector=""
  if command -v nm >/dev/null 2>&1; then
    inspector="nm"
  elif command -v objdump >/dev/null 2>&1; then
    inspector="objdump -t"
  elif command -v strings >/dev/null 2>&1; then
    inspector="strings"
  else
    skip "46 ledger TSan concurrency: no nm/objdump/strings on PATH to verify the ledger object is TSan-instrumented"
    return
  fi
  if ! $inspector "$ledger_obj" 2>/dev/null | grep -q "__tsan"; then
    fail "46 ledger TSan concurrency: the ledger object is NOT TSan-instrumented (no __tsan symbols in $ledger_obj) -- the gate would pass vacuously. Re-run with a clean build."
    return
  fi

  rm -f "$ledger" "$ledger.csv"
  # halt_on_error=1: TSan reports the FIRST race and exits, so a run
  # that finds one cannot also print a misleading "all checks passed".
  # The suppressions file is wired in even though it currently holds no
  # active entries, so a benign finding has a documented home.
  local out rc
  out="$(TSAN_OPTIONS="halt_on_error=1:second_deadlock_stack=1:suppressions=$suppressions" \
        "$runner" "$ledger" 8 25 2>&1)"
  rc=$?
  printf '%s\n' "$out" | tee -a "$log"

  if printf '%s\n' "$out" | grep -qE "WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer|ERROR: ThreadSanitizer"; then
    fail "46 ledger TSan concurrency: ThreadSanitizer reported a race in the ledger write path (see $log)"
    printf '%s\n' "$out" | grep -A 12 "WARNING: ThreadSanitizer" | head -30 | sed 's/^/         /'
    rm -f "$ledger" "$ledger.csv"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    fail "46 ledger TSan concurrency: the runner reported a failure (exit $rc, see $log)"
    rm -f "$ledger" "$ledger.csv"
    return
  fi
  pass "46 ledger TSan concurrency: 8 threads x 25 concurrent appends, no race, the chain verified"
  rm -f "$ledger" "$ledger.csv"
}

# =====================================================================
# Gate 47 -- the ledger's FULL-CHAIN verification.
#
# WHAT THIS PROVES:
#   fractal_ledger_verify(session_id, kind) walks the WHOLE chain, not
#   just the tip. The tamper test in gate 26 flips a byte in the LAST
#   record, which a tip-only check would also catch -- so it cannot tell
#   the two apart. This gate builds a THREE-record chain, tampers the
#   MIDDLE record (leaving the tip intact), and requires the verifier to
#   name the middle record (first_failure_id = 2).
#
#   A tip-only implementation would report ok:true here, because the tip
#   itself is untouched and self-consistent. An implementation that
#   recomputes each record's hash but does not follow the chain would
#   name the tampered row too, so the pair of assertions (clean chain
#   first, then the mid-chain failure at row 2) is what pins the
#   behaviour down.
#
# WHY THE FIXTURE IS BUILT HERE AND NOT BY THE PRODUCT:
#   The only SQL-reachable writer for the kind=2 decision-audit chain is
#   fractal_audit_log, and that UDF is gated behind the licensed
#   enterprise library, which this public repo does not ship -- a gate
#   that used it would SKIP everywhere. The on-disk format is documented
#   in src/fractalsql_enterprise.c, and the WRITE side is already
#   covered by gate 26 (flush -> verify round trip against the product's
#   own writer). What is under test here is the verifier's chain walk.
#
#   tests/ledger_chain_tool.py builds and tampers the fixture, so both
#   harnesses (this one and build_test.ps1) share ONE definition of the
#   format.
# =====================================================================
gate_47_ledger_chain() {
  local ledger_path="$HERE/.gate47_ledger.dat"
  local tool="$HERE/tests/ledger_chain_tool.py"

  if ! command -v python3 >/dev/null 2>&1; then
    skip "47 ledger_chain: no python3 to build the fixture chain"
    return
  fi
  rm -f "$ledger_path" "$ledger_path.csv"

  # The ledger path is read by the DAEMON -- every UDF body runs there
  # -- and the enterprise code snapshots its environment ONCE per
  # process, so the variable has to be in place BEFORE the daemon
  # starts. Same restart-based env swap gate 26 uses.
  mdb_teardown
  export FRACTALSQL_ENTERPRISE_LEDGER_PATH="$ledger_path"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  local setup_rc=$?
  if [ "$setup_rc" -ne 0 ]; then
    unset FRACTALSQL_ENTERPRISE_LEDGER_PATH
    rm -f "$ledger_path" "$ledger_path.csv"
    fail "47 ledger_chain: restart with FRACTALSQL_ENTERPRISE_LEDGER_PATH set failed (rc=$setup_rc)"
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi

  # The chain is written AFTER the daemon started on purpose: the
  # verifier reads the file per call, so the content does not need a
  # second restart.
  if ! python3 "$tool" build "$ledger_path" 3 >/dev/null 2>&1 || [ ! -s "$ledger_path" ]; then
    fail "47 ledger_chain: the fixture chain was not written"
    unset FRACTALSQL_ENTERPRISE_LEDGER_PATH
    rm -f "$ledger_path" "$ledger_path.csv"
    mdb_teardown
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    return
  fi

  local v
  v="$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)"
  if [ "$v" = '{"ok":true,"rows_verified":3}' ]; then
    pass "47 ledger_chain: a three-record chain verifies clean (the walk reaches back to the genesis record)"
  else
    fail "47 ledger_chain: expected a clean 3-row verify report, got: $v"
  fi

  # Tamper the MIDDLE record; the tip stays intact.
  python3 "$tool" tamper "$ledger_path" 1 >/dev/null 2>&1
  v="$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)"
  case "$v" in
    '{"ok":false,"first_failure_id":2,'*)
      pass "47 ledger_chain: a tampered MIDDLE record is detected (first_failure_id=2 -- not the tip)" ;;
    *)
      fail "47 ledger_chain: expected the mid-chain tamper to be reported at row 2, got: $v" ;;
  esac

  unset FRACTALSQL_ENTERPRISE_LEDGER_PATH
  rm -f "$ledger_path" "$ledger_path.csv"
  mdb_teardown
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
}

# Gate 48: the text-to-SQL tier's REVIEW isolation.
#
# The engine's four reasoning tiers -- reason, embed, text-to-SQL
# generate and text-to-SQL review -- are four SEPARATE ctx slots
# (src/fractalsql_session.c's g_tier_ctx[]), and the reasoning VFS ABI
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
# tests/review_mode_reasoning_plugin.c captures the mode at INIT time
# -- the instant it is baked into that ctx's instance -- into a
# per-instance struct hung off vfs->user_ctx, and echoes it back from
# generate(). The core's loader calls fsql_reasoning_init once per ctx
# load (it hands the plugin a stack-local vfs), so each tier reports
# the mode that was in the environment at ITS OWN load.
#
# The three calls are made SEPARATELY, in this order, because the
# order is part of what is being proven: the reason tier is loaded
# first, so a review tier that had wrongly shared the reason ctx would
# report the reason tier's baked value instead of its own.
gate_48_t2s_review_isolation() {
  local r g v ri gi vi

  # The operator's own response mode. The reason tier must report it;
  # the review tier must NOT -- that is the whole point.
  export FSQL_REASONING_HTTP_RESPONSE_MODE=operator

  mdb_swap_reasoning_plugin "$REVIEW_MODE_SO" \
    || { fail "48 t2s_review_isolation: plugin swap did not take effect"; \
         unset FSQL_REASONING_HTTP_RESPONSE_MODE; mdb_restore_reasoning_plugin; return; }

  # (1) the reason tier: the operator's own mode, baked into the
  # reason ctx's plugin instance.
  r=$("${MARIADB[@]}" -N -e "SELECT fractal_reason(CONNECTION_ID(), 'q');" 2>&1)
  if echo "$r" | grep -q "FSQL_MODE=operator"; then
    pass "48 t2s_review_isolation: the reason tier keeps the operator's RESPONSE_MODE"
  else
    fail "48 t2s_review_isolation: the reason tier did not report the operator's RESPONSE_MODE: $r"
  fi

  # (2) the generate tier: its own ctx, RESPONSE_MODE=code
  # (apply_generate_env_locked forces it, whatever the operator set).
  g=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_generate(CONNECTION_ID(), 'q', '{}', 'gate48');" 2>&1)
  if echo "$g" | grep -q "FSQL_MODE=code"; then
    pass "48 t2s_review_isolation: the generate tier's own ctx carries RESPONSE_MODE=code"
  else
    fail "48 t2s_review_isolation: the generate tier did not report RESPONSE_MODE=code: $g"
  fi

  # (3) the review tier: its own ctx, RESPONSE_MODE unset -- NOT the
  # operator's value and NOT code. The verdict text is the fixture's
  # own "FSQL_MODE=..." line (a review response starting with "pass"
  # would be swallowed as a PASS verdict), so it is read back through
  # IFNULL.
  v=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(), 'q', 'SELECT 1'), '<NULL>');" 2>&1)
  if echo "$v" | grep -q "FSQL_MODE=(unset)"; then
    pass "48 t2s_review_isolation: the review tier's own ctx has RESPONSE_MODE unset (not the operator's, not code)"
  else
    fail "48 t2s_review_isolation: the review tier inherited a RESPONSE_MODE it must not have: $v"
  fi

  # (4) the three tiers really are three DIFFERENT plugin instances:
  # each ctx load calls fsql_reasoning_init once, so the ordinals must
  # differ. Identical ordinals would mean one instance is shared --
  # the very failure mode this gate exists to catch.
  ri=$(printf '%s\n' "$r" | grep -o 'FSQL_INSTANCE=[0-9-]*' | head -1 | cut -d= -f2)
  gi=$(printf '%s\n' "$g" | grep -o 'FSQL_INSTANCE=[0-9-]*' | head -1 | cut -d= -f2)
  vi=$(printf '%s\n' "$v" | grep -o 'FSQL_INSTANCE=[0-9-]*' | head -1 | cut -d= -f2)
  if [ -n "$ri" ] && [ -n "$gi" ] && [ -n "$vi" ] \
      && [ "$ri" != "$gi" ] && [ "$ri" != "$vi" ] && [ "$gi" != "$vi" ]; then
    pass "48 t2s_review_isolation: the three tiers run on three DISTINCT plugin instances (reason=$ri generate=$gi review=$vi)"
  else
    fail "48 t2s_review_isolation: the tiers are not on distinct plugin instances (reason=$ri generate=$gi review=$vi)"
  fi

  unset FSQL_REASONING_HTTP_RESPONSE_MODE
  mdb_restore_reasoning_plugin
}

# --- gate 49: the per-session configuration overlay, the canonical
# vector form, and the search's convergence view.
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
# statement in one mysql client run shares one connection id, so the
# set/get/list round trip below runs as ONE multi-statement call: a
# second client run would be a second connection, and a second
# connection id, and would see none of the first one's overrides.
gate_49_config_overlay() {
  local out l1 l2 l3 l4 l5 keys nkeys

  # --- fractal_config_keys(): the whole surface, discoverable, with
  # each key's type and whether a session may override it.
  keys=$("${MARIADB[@]}" -N -e "SELECT fractal_config_keys();" 2>&1)
  nkeys=$(echo "$keys" | grep -o '"name":' | wc -l | tr -d ' ')
  if [ "$nkeys" = "18" ]; then
    pass "49 config_overlay: keys() lists all 18 configuration keys"
  else
    fail "49 config_overlay: keys() listed $nkeys keys (expected 18): $keys"
  fi
  if echo "$keys" | grep -q '"name":"think","type":"string","session_overridable":true'; then
    pass "49 config_overlay: keys() marks the tuning keys session-overridable"
  else
    fail "49 config_overlay: keys() does not mark 'think' session-overridable: $keys"
  fi
  if echo "$keys" | grep -q '"name":"reasoning_plugin","type":"path","session_overridable":false'; then
    pass "49 config_overlay: keys() marks the daemon-wide keys operator-only"
  else
    fail "49 config_overlay: keys() does not mark 'reasoning_plugin' operator-only: $keys"
  fi

  # --- The round trip: set, get, list, in ONE session. The reset
  # first clears any override a recycled connection id might carry.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_set('think','high',CONNECTION_ID()); SELECT fractal_config_get('think',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID()); SELECT fractal_config_get('t2s_use_review',CONNECTION_ID());" 2>&1)
  l1=$(echo "$out" | sed -n 1p)
  l2=$(echo "$out" | sed -n 2p)
  l3=$(echo "$out" | sed -n 3p)
  l4=$(echo "$out" | sed -n 4p)
  l5=$(echo "$out" | sed -n 5p)
  if [ "$l2" = "ok" ]; then
    pass "49 config_overlay: set() accepts a tuning key and answers 'ok'"
  else
    fail "49 config_overlay: set('think','high') answered '$l2' (expected 'ok')"
  fi
  if [ "$l3" = "high" ]; then
    pass "49 config_overlay: get() returns the session's own override"
  else
    fail "49 config_overlay: get('think') answered '$l3' (expected 'high')"
  fi
  if [ "$l4" = '{"think":"high"}' ]; then
    pass "49 config_overlay: list() renders the session's overrides as a JSON object"
  else
    fail "49 config_overlay: list() answered '$l4' (expected {\"think\":\"high\"})"
  fi
  # A key the session never touched comes back as the daemon-wide
  # value (or NULL when there is none) -- the overlay is a layer, not
  # a replacement.
  if [ -n "$l5" ] && [ "$l5" != "high" ] && [ "$l5" != '{"think":"high"}' ]; then
    pass "49 config_overlay: an untouched key falls through to the daemon-wide value ($l5)"
  else
    fail "49 config_overlay: an untouched key answered '$l5' (expected the daemon-wide value, not the overlay)"
  fi

  # --- TWO keys in ONE session. A session may hold more than one
  # override at a time, and every one of them must be readable: the
  # overlay's entry table is indexed by session id, so a second
  # override used to land in a second entry for the same session, where
  # every read (and the reset) only ever saw the first one. The symptom
  # was a value that set() reported as accepted and then refused to read
  # back -- and a reset that reported "dropped 1" and left the session
  # still holding an override.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_set('think','high',CONNECTION_ID()); SELECT fractal_config_set('think_num_ctx','8192',CONNECTION_ID()); SELECT fractal_config_get('think',CONNECTION_ID()); SELECT fractal_config_get('think_num_ctx',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID()); SELECT fractal_config_reset(CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID());" 2>&1)
  l1=$(echo "$out" | sed -n 2p)
  l2=$(echo "$out" | sed -n 3p)
  l3=$(echo "$out" | sed -n 4p)
  l4=$(echo "$out" | sed -n 5p)
  l5=$(echo "$out" | sed -n 6p)
  l6=$(echo "$out" | sed -n 7p)
  l7=$(echo "$out" | sed -n 8p)
  if [ "$l1" = "ok" ] && [ "$l2" = "ok" ]; then
    pass "49 config_overlay: a session may hold TWO overrides at once"
  else
    fail "49 config_overlay: the two sets answered '$l1' / '$l2' (expected 'ok' / 'ok')"
  fi
  if [ "$l3" = "high" ] && [ "$l4" = "8192" ]; then
    pass "49 config_overlay: BOTH overrides read back, not just the first one"
  else
    fail "49 config_overlay: the two gets answered '$l3' / '$l4' (expected 'high' / '8192')"
  fi
  if echo "$l5" | grep -q '"think":"high"' && echo "$l5" | grep -q '"think_num_ctx":"8192"'; then
    pass "49 config_overlay: list() shows every override the session holds"
  else
    fail "49 config_overlay: list() answered '$l5' (expected both overrides)"
  fi
  if [ "$l6" = "2" ]; then
    pass "49 config_overlay: reset() drops every override the session holds"
  else
    fail "49 config_overlay: reset() answered '$l6' (expected 2 dropped overrides)"
  fi
  if [ "$l7" = "{}" ]; then
    pass "49 config_overlay: after the reset the session holds no overrides"
  else
    fail "49 config_overlay: after the reset the session still holds '$l7' (expected {})"
  fi

  # --- The refusal: a daemon-wide key is refused BY NAME, with the
  # reason, and it is a RETURNED string (the UDF ABI cannot carry a
  # reason on the error path). The set, the refusal and the list run
  # in ONE session, so the list shows exactly what this session holds.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('reasoning_model','m',CONNECTION_ID()); SELECT fractal_config_set('reasoning_plugin','/opt/evil.so',CONNECTION_ID()); SELECT fractal_config_list(CONNECTION_ID());" 2>&1)
  l1=$(echo "$out" | sed -n 1p)
  l2=$(echo "$out" | sed -n 2p)
  l3=$(echo "$out" | sed -n 3p)
  case "$l2" in
    *"'reasoning_plugin' is a daemon-wide setting and cannot be changed by a session"*)
      pass "49 config_overlay: a daemon-wide key is refused by name, with the reason" ;;
    *)
      fail "49 config_overlay: set('reasoning_plugin') answered '$l2' (expected the by-name refusal)" ;;
  esac
  if echo "$l3" | grep -q 'reasoning_plugin'; then
    fail "49 config_overlay: the refused key was stored anyway: $l3"
  elif [ "$l3" = '{"reasoning_model":"m"}' ]; then
    pass "49 config_overlay: the refused key is not in the session's overrides"
  else
    fail "49 config_overlay: list() answered '$l3' (expected {\"reasoning_model\":\"m\"})"
  fi

  # --- A secret's value is never returned: the caller learns whether
  # a credential is configured, and nothing more.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_get('reasoning_token',CONNECTION_ID());" 2>&1)
  if [ "$out" = "<redacted>" ] || [ "$out" = "<unset>" ]; then
    pass "49 config_overlay: a secret's value is never returned ($out)"
  else
    fail "49 config_overlay: get('reasoning_token') answered '$out' (expected <redacted> or <unset>)"
  fi

  # --- The renderer sizes the document ITSELF. A stored value with
  # control bytes escapes to six bytes each (\u00XX), so a value of
  # 8000 newlines is a 48 KB document: a buffer sized from a guess
  # about the escape factor truncates it (or returns NULL), and the
  # session's configuration silently stops being readable. The
  # document must be valid JSON and must round-trip the value.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('reasoning_model', REPEAT(CHAR(10), 8000), CONNECTION_ID()); SELECT JSON_VALID(fractal_config_list(CONNECTION_ID())); SELECT CHAR_LENGTH(JSON_UNQUOTE(JSON_EXTRACT(fractal_config_list(CONNECTION_ID()), '\$.reasoning_model')));" 2>&1)
  l1=$(echo "$out" | sed -n 1p)
  l2=$(echo "$out" | sed -n 2p)
  l3=$(echo "$out" | sed -n 3p)
  if [ "$l1" = "ok" ] && [ "$l2" = "1" ]; then
    pass "49 config_overlay: a heavily escaped value still renders as valid JSON"
  else
    fail "49 config_overlay: the escaped-value render answered '$l1' / JSON_VALID='$l2' (expected 'ok' / '1')"
  fi
  if [ "$l3" = "8000" ]; then
    pass "49 config_overlay: the escaped value round-trips through the JSON document"
  else
    fail "49 config_overlay: the escaped value came back $((l3)) bytes long (expected 8000)"
  fi
  # Clear the override again: the model name is published into the
  # daemon's environment on the next cognition dispatch, and a
  # 48 KB model name is not something to leave behind.
  "${MARIADB[@]}" -N -e "SELECT fractal_config_reset(CONNECTION_ID());" >/dev/null 2>&1

  # --- The value-length boundary. A value of exactly 8192 bytes was
  # ACCEPTED by set() and then came back TRUNCATED at 8191: the limit
  # was compared against the buffer's size rather than against the
  # space the value needs in it, terminator included. The value that
  # fits has to round-trip whole, the one that does not has to be
  # refused with a reason, and the refusal must not disturb the value
  # already stored.
  out=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('think', REPEAT('a', 8191), CONNECTION_ID()); SELECT CHAR_LENGTH(fractal_config_get('think', CONNECTION_ID())); SELECT fractal_config_set('think', REPEAT('a', 8192), CONNECTION_ID()); SELECT CHAR_LENGTH(fractal_config_get('think', CONNECTION_ID())); SELECT fractal_config_reset(CONNECTION_ID());" 2>&1)
  l1=$(echo "$out" | sed -n 1p)
  l2=$(echo "$out" | sed -n 2p)
  l3=$(echo "$out" | sed -n 3p)
  l4=$(echo "$out" | sed -n 4p)
  if [ "$l1" = "ok" ] && [ "$l2" = "8191" ]; then
    pass "49 config_overlay: a value that fits the buffer round-trips whole (8191 bytes)"
  else
    fail "49 config_overlay: the 8191-byte value answered '$l1' / '$l2' (expected 'ok' / '8191')"
  fi
  case "$l3" in
    *"too long"*)
      pass "49 config_overlay: a value one byte over the limit is refused, with the reason" ;;
    *)
      fail "49 config_overlay: the 8192-byte value answered '$l3' (expected a 'too long' refusal)" ;;
  esac
  if [ "$l4" = "8191" ]; then
    pass "49 config_overlay: the refused value did not disturb the stored one"
  else
    fail "49 config_overlay: after the refusal the stored value is '$l4' bytes long (expected 8191)"
  fi

  # --- The canonical vector form: a u16 dimension (LE), a u16
  # reserved field (zero), then the float32 values (LE), carried as
  # lowercase hex. fractal_vector(3) is the zero vector of dimension
  # 3: "0300" + "0000" + 24 zero digits.
  local z3; z3=$("${MARIADB[@]}" -N -e "SELECT fractal_vector(3);" 2>&1)
  if [ "$z3" = "03000000000000000000000000000000" ]; then
    pass "49 config_overlay: fractal_vector(3) is the canonical zero vector"
  else
    fail "49 config_overlay: fractal_vector(3) answered '$z3' (expected 03000000000000000000000000000000)"
  fi
  local c123; c123=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_from_text('[1,2,3]');" 2>&1)
  if [ "$c123" = "030000000000803f0000004000004040" ]; then
    pass "49 config_overlay: from_text() encodes [1,2,3] into the canonical form"
  else
    fail "49 config_overlay: from_text('[1,2,3]') answered '$c123' (expected 030000000000803f0000004000004040)"
  fi
  # The canonical form is a FIXED POINT: converting it again yields
  # the same bytes.
  local c2; c2=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_from_text(fractal_vector_from_text('[1,2,3]'));" 2>&1)
  if [ "$c2" = "$c123" ]; then
    pass "49 config_overlay: the canonical form is a fixed point"
  else
    fail "49 config_overlay: re-encoding the canonical form changed it ('$c123' -> '$c2')"
  fi
  local tj; tj=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_to_json(fractal_vector_from_text('[1,2,3]'));" 2>&1)
  if [ "$tj" = "[1,2,3]" ]; then
    pass "49 config_overlay: to_json() renders the canonical form back as a JSON array"
  else
    fail "49 config_overlay: to_json() answered '$tj' (expected [1,2,3])"
  fi
  local nd; nd=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_dims(fractal_vector_from_text('[1,2,3]'));" 2>&1)
  if [ "$nd" = "3" ]; then
    pass "49 config_overlay: dims() reads the dimension back out of the canonical form"
  else
    fail "49 config_overlay: dims() answered '$nd' (expected 3)"
  fi
  # Out-of-range dimensions are refused: the cap is the format's own
  # (1..32767), and a dimension of 0 has no canonical encoding.
  local bad; bad=$("${MARIADB[@]}" -N -e "SELECT fractal_vector(0);" 2>&1)
  if [ "$bad" = "NULL" ]; then
    pass "49 config_overlay: fractal_vector(0) is refused"
  else
    fail "49 config_overlay: fractal_vector(0) answered '$bad' (expected NULL)"
  fi
  bad=$("${MARIADB[@]}" -N -e "SELECT fractal_vector(32768);" 2>&1)
  if [ "$bad" = "NULL" ]; then
    pass "49 config_overlay: fractal_vector(32768) is refused (the format's dimension cap)"
  else
    fail "49 config_overlay: fractal_vector(32768) answered '$bad' (expected NULL)"
  fi
  bad=$("${MARIADB[@]}" -N -e "SELECT fractal_vector_to_json('not a vector');" 2>&1)
  if [ "$bad" = "NULL" ]; then
    pass "49 config_overlay: to_json() refuses text that is not a vector"
  else
    fail "49 config_overlay: to_json('not a vector') answered '$bad' (expected NULL)"
  fi

  # --- fractal_search_debug: the convergence view. A pinned seed makes
  # the trace byte-stable, which is the point of the seed argument.
  local sd; sd=$("${MARIADB[@]}" -N -e "SELECT fractal_search_debug('[1,2,3]', 20, 10, 2, 42);" 2>&1)
  if echo "$sd" | grep -q '"best_point"' && echo "$sd" | grep -q '"best_fit"' && echo "$sd" | grep -q '"trace"'; then
    pass "49 config_overlay: search_debug() returns the convergence view (best_point/best_fit/trace)"
  else
    fail "49 config_overlay: search_debug() did not return the convergence view: $sd"
  fi
  local sd2; sd2=$("${MARIADB[@]}" -N -e "SELECT fractal_search_debug('[1,2,3]', 20, 10, 2, 42);" 2>&1)
  if [ "$sd" = "$sd2" ]; then
    pass "49 config_overlay: search_debug() with a pinned seed is byte-stable"
  else
    fail "49 config_overlay: search_debug() with a pinned seed differed between calls"
  fi
  # The adapter refuses the same parameter range the CORE refuses, so
  # an out-of-range argument is turned away here rather than travelling
  # to the core to fail with a generic message.
  bad=$("${MARIADB[@]}" -N -e "SELECT fractal_search_debug('[1,2,3]', 0);" 2>&1)
  if [ "$bad" = "NULL" ]; then
    pass "49 config_overlay: search_debug() refuses iterations=0"
  else
    fail "49 config_overlay: search_debug(iterations=0) answered '$bad' (expected NULL)"
  fi
  bad=$("${MARIADB[@]}" -N -e "SELECT fractal_search_debug('[1,2,3]', 10, 20000);" 2>&1)
  if [ "$bad" = "NULL" ]; then
    pass "49 config_overlay: search_debug() refuses a population above the core's own cap"
  else
    fail "49 config_overlay: search_debug(population=20000) answered '$bad' (expected NULL)"
  fi

  # --- A caller-supplied output count that does not fit. The count is
  # multiplied by the element size to size the buffer the core writes
  # into: a count whose multiplication wrapped to 0 gave the core a
  # zero-length buffer to write real output into (a heap overflow inside
  # mariadbd). The count is now clamped to what the data can actually
  # produce, so the answer is the same as asking for that many -- and the
  # server stays up.
  local big alive
  big=$("${MARIADB[@]}" -N -e "SELECT fractal_periodogram('1,2,3,4,5,6,7,8', 2305843009213693952);" 2>&1)
  alive=$("${MARIADB[@]}" -N -e "SELECT 42;" 2>&1)
  if [ "$alive" = "42" ]; then
    pass "49 config_overlay: a periodogram count of 2^61 does not take the server down"
  else
    fail "49 config_overlay: the server did not answer after fractal_periodogram(2^61) (answered '$alive')"
  fi
  if [ "$big" = "NULL" ] || { [[ "$big" == *'"freqs"'* ]] && [[ "$big" == *'"power"'* ]]; }; then
    pass "49 config_overlay: a periodogram count of 2^61 is refused or clamped, never a short buffer"
  else
    fail "49 config_overlay: fractal_periodogram(2^61) answered '$big'"
  fi
  big=$("${MARIADB[@]}" -N -e "SELECT fractal_change_point_detect('1,2,3,4,5,6,7,8', 2, 0.5, 2305843009213693952);" 2>&1)
  alive=$("${MARIADB[@]}" -N -e "SELECT 42;" 2>&1)
  if [ "$alive" = "42" ] && { [ "$big" = "NULL" ] || [[ "$big" == *'['* ]]; }; then
    pass "49 config_overlay: a change-point count of 2^61 is refused or clamped, and the server stays up"
  else
    fail "49 config_overlay: fractal_change_point_detect(2^61) answered '$big' (server answered '$alive')"
  fi
  big=$("${MARIADB[@]}" -N -e "SELECT fractal_tda_persistence_diagram('1,2,3,4,5,6', 2, 0, 10.0, 2305843009213693952);" 2>&1)
  alive=$("${MARIADB[@]}" -N -e "SELECT 42;" 2>&1)
  if [ "$alive" = "42" ] && { [ "$big" = "NULL" ] || [[ "$big" == *'"h0_bars"'* ]]; }; then
    pass "49 config_overlay: a persistence-diagram bar count of 2^61 is refused or clamped, and the server stays up"
  else
    fail "49 config_overlay: fractal_tda_persistence_diagram(2^61) answered '$big' (server answered '$alive')"
  fi
}

# --- run ------------------------------------------------------------

# ----------------------------------------------------------------------
# gate 50: industry kits (demo/demo-vertical-*.sql, the twenty-nine newer
# automotive / aerospace / telecom / climate-tech / RF kits).  Each is
# piped end to end through the scratch cluster's client (with the agents
# installed and the mock LLM answering the reasoned steps) and must
# (a) exist, (b) raise no SQL error beyond the documented exception (the
# scenario-planning kit's plan_explore call needs an embedding endpoint
# the cluster may not have: at most one error), (c) print no NaN, and
# (d) reproduce its headline claim -- the fixtures are deterministic (no
# RAND()), so the claim is checked against fixed numbers.
# ----------------------------------------------------------------------
# kit_shape_ok <output> <min>: the 13 original kits print no HEADLINE line and seed RAND(), so
# their numbers are not pinned. What a regression does change is the SHAPE of the output: a step
# that silently returns no rows drops data lines. Count the lines that are neither errors nor
# blank and require <min> (three quarters of a clean run).
kit_shape_ok() {
  local n
  n=$(printf '%s\n' "$1" | grep -vc '^\(ERROR \|$\)')
  [ "$n" -ge "$2" ]
}

gate_50_kits() {
  if [ ! -d demo ]; then
    skip "50 kits (demo/ not present)"; return
  fi
  local kits="ev-battery-lifecycle adas-safety-validation v2x-warranty-triage
    critical-inventory-routing heavy-industry-predictive-maintenance
    climatech-grid-balancing hazmat-occupational-triage
    scenario-planning-simulation avionics-fault-prediction
    satellite-constellation-coverage telecom-account-anomaly-screening
    telecom-traffic-routing climatech-emissions-monitoring
    climatech-risk-exposure rf-spectrum-sensing
    event-stream-anomaly-triage outlier-interception-footprint agentic-budget-reallocation
    stalled-process-triage intent-matching-discovery
    agentic-next-action-ranking document-risk-drift
    coordinated-record-detection sensor-telemetry-allocation simulated-economy-drift
    multi-series-replenishment periodicity-portfolio-selection
    agentic-recall-recommendation spatial-footprint-portfolio-risk
    agentic-customer-support agentic-edge-swarm agentic-fintech-mcts
    agentic-ops-devops biotech-genomics cybersecurity-threat-detection
    fleet-logistics maritime-defense medtech-clinical quant-finance
    recommendation-search smart-cities-iot sovereign-edge-ai"
  local k f out nerr maxerr ok
  for k in $kits; do
    f="demo/demo-vertical-$k.sql"
    if [ ! -f "$f" ]; then
      fail "50 kits: $f is missing"; continue
    fi
    out=$("${MARIADB[@]}" -N --force < "$f" 2>&1 | tr '\t' '|')
    nerr=$(printf '%s\n' "$out" | grep -c '^ERROR ')
    maxerr=0; [ "$k" = "scenario-planning-simulation" ] && maxerr=1; [ "$k" = "periodicity-portfolio-selection" ] && maxerr=1
    case "$k" in agentic-fintech-mcts) maxerr=1 ;; agentic-ops-devops) maxerr=2 ;; esac   # fractal_embed with no embedding endpoint
    if [ "$nerr" -gt "$maxerr" ]; then
      fail "50 kits: $k raised $nerr SQL error(s), at most $maxerr expected: $(printf '%s\n' "$out" | grep '^ERROR ' | head -2 | tr '\n' ' ')"
      continue
    fi
    if printf '%s\n' "$out" | grep -qE '(^|\|)-?(nan|NaN|inf)(\||$)'; then
      fail "50 kits: $k printed a NaN/inf cell"; continue
    fi
    ok=0
    case "$k" in
      event-stream-anomaly-triage|outlier-interception-footprint|agentic-budget-reallocation|stalled-process-triage|intent-matching-discovery|agentic-next-action-ranking|document-risk-drift|coordinated-record-detection|sensor-telemetry-allocation|simulated-economy-drift|multi-series-replenishment|periodicity-portfolio-selection|agentic-recall-recommendation|spatial-footprint-portfolio-risk) printf '%s\n' "$out" | grep -q "HEADLINE kit=$k ok" && ok=1 ;;
      agentic-customer-support) kit_shape_ok "$out" 13 && ok=1 ;;
      agentic-edge-swarm) kit_shape_ok "$out" 12 && ok=1 ;;
      agentic-fintech-mcts) kit_shape_ok "$out" 5 && ok=1 ;;
      agentic-ops-devops) kit_shape_ok "$out" 6 && ok=1 ;;
      biotech-genomics) kit_shape_ok "$out" 6 && ok=1 ;;
      cybersecurity-threat-detection) kit_shape_ok "$out" 15 && ok=1 ;;
      fleet-logistics) kit_shape_ok "$out" 10 && ok=1 ;;
      maritime-defense) kit_shape_ok "$out" 11 && ok=1 ;;
      medtech-clinical) kit_shape_ok "$out" 3 && ok=1 ;;
      quant-finance) kit_shape_ok "$out" 3 && ok=1 ;;
      recommendation-search) kit_shape_ok "$out" 15 && ok=1 ;;
      smart-cities-iot) kit_shape_ok "$out" 8 && ok=1 ;;
      sovereign-edge-ai) kit_shape_ok "$out" 8 && ok=1 ;;
      ev-battery-lifecycle) printf '%s\n' "$out" | awk -F'|' '$1=="EV-203" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="EV-101" && $2+0<0 && $3+0<1 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      adas-safety-validation) printf '%s\n' "$out" | awk -F'|' '$1 ~ /^P1 firm/ && $4==1 {a=1} $1 ~ /^P2 steady/ && $4==0 {b=1} $1 ~ /^P3 gentle/ && $4==1 {c=1} END{exit !(a&&b&&c)}' && ok=1 ;;
      v2x-warranty-triage) printf '%s\n' "$out" | grep -q '^battery-thermal-service|0\.99' && ok=1 ;;
      critical-inventory-routing) printf '%s\n' "$out" | awk -F'|' '$1==4 && $2=="west" && $5+0>1.2 {a=1} END{exit !a}' && ok=1 ;;
      heavy-industry-predictive-maintenance) printf '%s\n' "$out" | awk -F'|' '$1=="PUMP-07" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="PUMP-03" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      climatech-grid-balancing) printf '%s\n' "$out" | awk -F'|' '$1=="AREA-C" && $2+0>0.5 && $3+0>1.2 {a=1} $1=="AREA-A" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      hazmat-occupational-triage) printf '%s\n' "$out" | awk -F'|' '($1==7||$1==15||$1==31) && $2=="reactor-bay" && $3=="night" && $4+0<0.001 {n++} END{exit !(n>=3)}' && ok=1 ;;
      scenario-planning-simulation) [ "$(printf '%s\n' "$out" | grep -c 'variant')" -ge 6 ] && ok=1 ;;
      avionics-fault-prediction) printf '%s\n' "$out" | grep -q '^AC-09|0\.2' && ok=1 ;;
      satellite-constellation-coverage) printf '%s\n' "$out" | awk -F'|' '$1=="healthy" && NF==3 {h=$3+0} $1=="degraded" && NF==3 {d=$3+0} END{exit !(h>0 && d>h)}' && ok=1 ;;
      telecom-account-anomaly-screening) printf '%s\n' "$out" | awk -F'|' '$1 ~ /^E1 swap/ && $4==1 {a=1} $1 ~ /^E2 routine/ && $4==0 {b=1} $1 ~ /^E4 faint/ && $4==1 {c=1} END{exit !(a&&b&&c)}' && ok=1 ;;
      telecom-traffic-routing) printf '%s\n' "$out" | grep -q '^R3 mobile handover burst|edge-mobile-hub|' && printf '%s\n' "$out" | grep -q '^R3 mobile handover burst|edge-backup-west$' && ok=1 ;;
      climatech-emissions-monitoring) printf '%s\n' "$out" | awk -F'|' '$1=="CH4-02" && $2+0>0.5 && $3+0>1.5 {a=1} $1=="CH4-01" && $2+0<0 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      climatech-risk-exposure) printf '%s\n' "$out" | awk -F'|' '$1=="dry season" && NF==3 {a=1} $1=="wet season" && NF==3 {b=1} END{exit !(a&&b)}' && ok=1 ;;
      rf-spectrum-sensing) printf '%s\n' "$out" | grep -q '^CH-A|\[9\]$' && printf '%s\n' "$out" | grep -q '^CH-B|\[\]$' && printf '%s\n' "$out" | grep -q '^CH-C|\[\]$' && ok=1 ;;
    esac
    if [ "$ok" -eq 1 ]; then
      pass "50 kits: demo-vertical-$k.sql runs clean and reproduces its headline result"
    else
      fail "50 kits: demo-vertical-$k.sql did not reproduce its headline result (non-error lines: $(printf '%s\n' "$out" | grep -vc '^\(ERROR \|$\)'), errors: $nerr; first lines: $(printf '%s\n' "$out" | head -16 | cut -c1-48 | tr '\n' '/'); headline: $(printf '%s\n' "$out" | grep -m1 HEADLINE | cut -c1-80); last: $(printf '%s\n' "$out" | tail -2 | cut -c1-100 | tr '\n' '/'); probe(population_size=3 returns n points): $("${MARIADB[@]}" -N -e "SELECT JSON_LENGTH(JSON_EXTRACT(fractal_search_explore('0,0;1,1;2,2;3,3;4,4;5,5;6,6;7,7', '0,0', '{\"population_size\": 3, \"iterations\": 2}'), '\$.population'))" 2>&1 | tr '\n' ' '))"
    fi
  done
  # The kits leave their tables behind for inspection; this gate does not.
  "${MARIADB[@]}" -e "DROP TABLE IF EXISTS ebl_telemetry, asv_known_bad, asv_proposed, asv_routes,
      v2x_capabilities, v2x_claims, cir_depots, cir_consumption, cir_profile, hpm_readings,
      cgb_freq, cgb_resources, hot_workers, sps_scenarios, afp_flights, scc_footprints, scc_slots,
      taa_known_anomalous, taa_proposed, ttr_nodes, ttr_requests, ttr_available, cem_readings,
      cre_grid, rfs_capture, rfs_entropy,
      esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj, oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim, abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed, spt_items, spt_traj, spt_triage, imd_entities, imd_picks, imd_content, imd_rec, anr_candidates, anr_recall, anr_actions, anr_rec, drd_risk, drd_prof, drd_clauses, drd_picks, drd_approved, drd_rec, crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim, sta_demand, sta_prof, sta_result, sed_price, sed_prof, sed_result, sed_loop, msr_units, msr_prof, msr_result, pps_sales, pps_prof, pps_result, pps_catalog, pps_rec, arr_offers, arr_picks, arr_sessions, arr_recall, sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks;" >/dev/null 2>&1
}

# ======================================================================
# Robustness gates 51-62
#
# The gates above prove what each function does with GOOD input. These
# prove what the engine does with BAD input, and that its input
# validators and integrity checks give the right verdict:
#
#   51 udf_sweeps       every UDF with malformed, extreme and oversize
#                       arguments, odd JSON parameter spellings, and the
#                       session configuration functions across every key
#   52 validators       the text-to-SQL allowlist and the audit-log JSON
#                       check against tables of statements and payloads
#                       with a known correct verdict
#   53 daemon_frames    authenticated but malformed protocol frames
#   54 daemon_conf_boot configuration files the daemon must accept or
#                       refuse at startup
#   55 ledger_forged    hand-built ledgers, valid and corrupted
#   56 ledger_files     unusable, read-only and missing ledger paths
#   57 fault_sweeps     (--fault) an injected allocation or file-system
#                       failure at every point of a long list of calls
#   58 enterprise_loading  enterprise_lib and signature combinations
#   59 provider_reload  live reloads of the provider settings
#   60 scripted_replies reasoning-plugin replies of every shape
#   61 daemon_limits    connection limits, idle timeout, reload rules
#   62 provider_env     provider settings taken from the environment
#
# Nothing here is judged on a sweep's own output: a sweep passes when
# the daemon is still running and still answers afterwards, and logged
# no FATAL. The tables in tests/robustness/ carry the expected verdicts.
# ======================================================================

# Bytes in the daemon's log so far, and everything logged after a mark.
rb_log_mark() { wc -c < "/tmp/fractalsql_bt_fsqd_${CUR_VER//./_}.log" 2>/dev/null | tr -d '[:space:]' || echo 0; }
rb_log_since() { tail -c +"$(( $1 + 1 ))" "/tmp/fractalsql_bt_fsqd_${CUR_VER//./_}.log" 2>/dev/null; }

# Succeeds when the log text on stdin records a crash. Under --coverage a
# SIGSEGV logged right after the daemon's own "process exiting" line is not
# the daemon: libgcov writes its counters from an exit handler, allocates while
# doing so, and does not survive an injected allocation failure there.
rb_log_has_crash() {
  awk -v cov="$COVERAGE" '
    /process exiting/ { after_exit = 1; next }
    /FATAL/           { if (!(cov == 1 && after_exit)) found = 1 }
                      { after_exit = 0 }
    END               { exit found ? 0 : 1 }'
}

# 0 when the daemon process is alive and a UDF round trip works.
rb_daemon_ok() {
  [ -n "$FSQD_PID" ] && kill -0 "$FSQD_PID" 2>/dev/null || return 1
  local v; v=$("${MARIADB[@]}" -N -e "SELECT fractal_version();" </dev/null 2>&1)
  case "$v" in [0-9]*.[0-9]*) return 0 ;; esac
  return 1
}

# Replaces (or, with an empty value, removes) one key of the daemon's
# configuration file.
rb_conf_set() {
  local key="$1" val="$2" tmp="$FSQD_CONF.rb"
  grep -v "^$key *=" "$FSQD_CONF" > "$tmp" || true
  [ -n "$val" ] && printf '%s = %s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$FSQD_CONF"
  chmod 600 "$FSQD_CONF"
}

# Restarts the daemon on the configuration file as it stands (daemon_start
# writes a fresh one). Anything exported to this call, such as LD_PRELOAD,
# reaches the new process, and NAME=value arguments are added to its
# environment.
rb_daemon_restart() {
  local tag="${CUR_VER//./_}" i
  daemon_stop
  rm -f "$FSQD_SOCK"
  env ${1+"$@"} "$HERE/service/build/fractalsqld" -c "$FSQD_CONF" </dev/null >>"/tmp/fractalsql_bt_fsqd_${tag}.log" 2>&1 &
  FSQD_PID=$!
  for i in $(seq 1 50); do
    [ -S "$FSQD_SOCK" ] && return 0
    sleep 0.1
  done
  return 1
}

# The mock enterprise core (the same fixture gate 35 uses), built once per run.
rb_mock_lib() {
  local so="$TMPROOT/fractalsql_bt_robust_mock_${CUR_VER//./_}.so"
  if [ ! -f "$so" ]; then
    cc -shared -fPIC -std=c99 -I"$HERE/include/$(fsql_ent_platform_dir)" -I"$HERE/include" \
       tests/mock_enterprise_core.c -o "$so" 2>/tmp/fractalsql_bt_robust_mock.log || return 1
  fi
  printf '%s' "$so"
}

# Points the daemon at the mock enterprise core and a ledger file, with an
# optional ledger key, and restarts it.
rb_enterprise_up() {
  local lib="$1" ledger="$2" key="$3"
  rb_conf_set enterprise_lib "$lib"
  rb_conf_set enterprise_ledger_path "$ledger"
  rb_conf_set enterprise_ledger_key "$key"
  rb_conf_set enterprise_require_signature 0
  rb_daemon_restart
}

# Back to a daemon with the stock configuration.
rb_reset_daemon() {
  daemon_stop
  daemon_start >/dev/null 2>&1
}

rb_fsq_reload() {
  FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$HERE/service/build/fsqlctl" reload 2>&1
}

# Runs one generated sweep through a mariadb client and judges the daemon.
# rb_sweep <label> <mode> [extra udf_sweep.py arguments...]
rb_sweep() {
  local label="$1" mode="$2" py L
  shift 2
  py="$(mcp_python)"
  L=$(rb_log_mark)
  "$py" tests/robustness/udf_sweep.py "$mode" --stride "${FSQL_ROBUST_STRIDE:-1}" "$@" \
    | "${MARIADB[@]}" --force -N >/dev/null 2>&1
  if ! rb_daemon_ok; then
    fail "51 udf_sweeps: $label -- the daemon stopped answering (see /tmp/fractalsql_bt_fsqd_${CUR_VER//./_}.log)"
  elif rb_log_since "$L" | rb_log_has_crash; then
    fail "51 udf_sweeps: $label -- the daemon logged a FATAL: $(rb_log_since "$L" | grep FATAL | head -1)"
  else
    pass "51 udf_sweeps: $label -- the daemon stayed up and answering"
  fi
}

gate_51_udf_sweeps() {
  if [ -z "$(mcp_python)" ]; then
    skip "51 udf_sweeps (no python3 on PATH)"; return
  fi
  rb_reset_daemon
  rb_sweep "every UDF called with 0-8 arguments of mixed types and NULL" arity
  rb_sweep "each seed call with one argument at a time set to an edge value" mutate
  rb_sweep "numeric series arguments of many lengths and shapes" shapes
  rb_sweep "JSON parameter objects in many spellings, and session ids" params
  rb_sweep "inputs just past the 4 MiB limit" oversize
  rb_sweep "the session configuration functions across every key and edge value" config

  # The enterprise functions refuse before doing anything while no core is
  # loaded, so repeat the argument sweeps with the mock core and a ledger.
  local lib; lib="$(rb_mock_lib)"
  if [ -z "$lib" ]; then
    fail "51 udf_sweeps: the mock enterprise core failed to build (see /tmp/fractalsql_bt_robust_mock.log)"
  else
    rm -f "$TMPROOT/fractalsql_bt_robust_ledger.bin"
    if rb_enterprise_up "$lib" "$TMPROOT/fractalsql_bt_robust_ledger.bin" "sweep-key"; then
      rb_sweep "the ledger, audit and multimodal functions with the enterprise core loaded (arity)" arity --only 'ledger|audit|multimodal'
      rb_sweep "the ledger, audit and multimodal functions with the enterprise core loaded (edge values)" mutate --only 'ledger|audit|multimodal'
    else
      fail "51 udf_sweeps: the daemon did not restart with the mock enterprise core"
    fi
    rm -f "$TMPROOT/fractalsql_bt_robust_ledger.bin" "$TMPROOT/fractalsql_bt_robust_ledger.bin.csv"
  fi
  # Sweeps leave session state (ids, latches, overrides) behind; start clean.
  rb_reset_daemon
}

# Compares the verdicts a table expects with what the engine answered.
# rb_table_diff <expected-file> <results-file>   (prints up to five mismatches)
# <expected-file> has one "N<TAB>expected<TAB>text" line per case: "PASS" (the
# allowlist let it through), "REJECT" (it refused), or the exact value ("0",
# "<NULL>"). <results-file> has one "N<TAB>answer" line per case.
rb_table_diff() {
  local exp="$1" got="$2"
  awk -F'\t' 'NR==FNR { want[$1] = $2; text[$1] = $3; next }
              { seen[$1] = 1; have[$1] = $2 }
              END { for (n in want) {
                      if (!(n in seen)) { printf "case %s (%s): no answer\n", n, text[n]; continue }
                      if (want[n] == "PASS") { if (have[n] != "<PASS>") printf "case %s (%s): expected a pass, got a refusal\n", n, text[n] }
                      else if (want[n] == "REJECT") { if (have[n] == "<PASS>") printf "case %s (%s): expected a refusal, got a pass\n", n, text[n] }
                      else if (have[n] != want[n]) printf "case %s (%s): expected %s, got %s\n", n, text[n], want[n], have[n]
                    } }' "$exp" "$got" | sort -t' ' -k2 -n | head -5
}

# 52: the two input validators that guard what reaches the model's output and
# the ledger, against tables of inputs with a known correct verdict.
gate_52_validators() {
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_validators_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  local n lit e2 e3 mode col
  local lib; lib="$(rb_mock_lib)"
  rb_reset_daemon

  # --- the allowlist, once per t2s_allowed_statements setting.
  for mode in select select_insert_update; do
    rb_conf_set t2s_allowed_statements "$mode"
    rb_fsq_reload >/dev/null
    col=2; [ "$mode" = "select_insert_update" ] && col=3
    : > "$W/exp.tsv"; : > "$W/sql.sql"
    n=0
    while IFS=$'\t' read -r lit e2 e3; do
      case "$lit" in ''|'#'*) continue ;; esac
      n=$((n + 1))
      if [ "$col" = 2 ]; then printf '%s\t%s\t%s\n' "$n" "$e2" "$lit" >> "$W/exp.tsv"
      else printf '%s\t%s\t%s\n' "$n" "$e3" "$lit" >> "$W/exp.tsv"; fi
      printf "SELECT %s, IFNULL(fractal_t2s_check_allowlist(%s), '<PASS>');\n" "$n" "$lit" >> "$W/sql.sql"
    done < tests/robustness/allowlist_cases.tsv
    "${MARIADB[@]}" --force -N < "$W/sql.sql" 2>/dev/null > "$W/got.tsv"
    local diff; diff=$(rb_table_diff "$W/exp.tsv" "$W/got.tsv")
    if [ -z "$diff" ]; then
      pass "52 validators: the allowlist gives the right verdict for all $n statements (t2s_allowed_statements = $mode)"
    else
      fail "52 validators: allowlist ($mode): $(printf '%s' "$diff" | head -3 | tr '\n' ';')"
    fi
  done
  rb_conf_set t2s_allowed_statements ""
  rb_fsq_reload >/dev/null

  # --- the audit-log payload check (needs the enterprise core and a ledger).
  if [ -z "$lib" ]; then
    fail "52 validators: the mock enterprise core failed to build"
  elif ! rb_enterprise_up "$lib" "$W/ledger.bin" "validator-key"; then
    fail "52 validators: the daemon did not restart with the mock enterprise core"
  else
    local verdict
    : > "$W/exp.tsv"; : > "$W/sql.sql"
    n=0
    while IFS=$'\t' read -r verdict lit; do
      case "$verdict" in ''|'#'*) continue ;; esac
      n=$((n + 1))
      if [ "$verdict" = OK ]; then printf '%s\t0\t%s\n' "$n" "$lit" >> "$W/exp.tsv"
      else printf '%s\t<NULL>\t%s\n' "$n" "$lit" >> "$W/exp.tsv"; fi
      printf "SELECT %s, IFNULL(fractal_audit_log('probe', %s), '<NULL>');\n" "$n" "$lit" >> "$W/sql.sql"
    done < tests/robustness/audit_json_cases.tsv
    "${MARIADB[@]}" --force -N < "$W/sql.sql" 2>/dev/null > "$W/got.tsv"
    local diff2; diff2=$(rb_table_diff "$W/exp.tsv" "$W/got.tsv")
    if [ -z "$diff2" ]; then
      pass "52 validators: fractal_audit_log accepts exactly the well-formed JSON payloads and refuses the malformed ones ($n cases)"
    else
      fail "52 validators: audit-log payload check: $(printf '%s' "$diff2" | head -3 | tr '\n' ';')"
    fi
    # What was accepted must still verify as an intact chain.
    local v; v=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)
    case "$v" in
      '{"ok":true,"rows_verified":'*) pass "52 validators: the chain built from the accepted payloads verifies clean" ;;
      *) fail "52 validators: the chain built from the accepted payloads did not verify: $v" ;;
    esac
  fi
  rb_reset_daemon
}

# 53: frames that carry a valid HMAC but a hostile payload.
gate_53_daemon_frames() {
  local py; py="$(mcp_python)"
  if [ -z "$py" ]; then skip "53 daemon_frames (no python3 on PATH)"; return; fi
  rb_reset_daemon
  local L out rc
  L=$(rb_log_mark)
  out=$("$py" tests/robustness/frame_fuzz.py "$FSQD_SOCK" "$(cat "$FSQD_KEY")" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "53 daemon_frames: the fuzzer ended with status $rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  elif ! rb_daemon_ok; then
    fail "53 daemon_frames: the daemon stopped answering after the malformed frames"
  elif rb_log_since "$L" | rb_log_has_crash; then
    fail "53 daemon_frames: the daemon logged a FATAL: $(rb_log_since "$L" | grep FATAL | head -1)"
  else
    pass "53 daemon_frames: malformed frames for every opcode were refused and the daemon kept serving"
  fi
  rb_reset_daemon
}

# Starts a throwaway daemon on a configuration file and reports "start"
# (it opened its socket) or "refuse" (it exited without listening). The
# socket path is cleared first unless a fourth argument asks to keep it.
rb_boot_result() {
  local conf="$1" sock="$2" log="$3" keep="${4:-}" pid i res=""
  [ -n "$keep" ] || rm -f "$sock"
  "$HERE/service/build/fractalsqld" -c "$conf" </dev/null >"$log" 2>&1 &
  pid=$!
  for i in $(seq 1 60); do
    if [ -S "$sock" ]; then res=start; break; fi
    if ! kill -0 "$pid" 2>/dev/null; then res=refuse; break; fi
    sleep 0.05
  done
  [ -z "$res" ] && res=timeout
  kill "$pid" 2>/dev/null
  { wait "$pid"; } 2>/dev/null
  printf '%s' "$res"
}

# 54: the daemon's startup validation, against configuration files with a known verdict.
# (The scratch directory name is short on purpose: a Unix socket path must fit in
# sun_path, 104 bytes on macOS, and TMPROOT is already long there.)
gate_54_daemon_conf_boot() {
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fsqlbt_cb_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  local sock="$W/s.sock" keyfile="$W/key" uid; uid=$(id -u)
  local long many uids80 longsock i
  long=$(head -c 20000 /dev/zero | tr '\0' x)
  many=""; for i in $(seq 1 300); do many="${many}unknown_key_$i = v"$'\n'; done
  uids80=""; for i in $(seq 1 80); do uids80="${uids80}$((1000 + i)),"; done; uids80="${uids80}${uid}"
  longsock="$W/$(head -c 200 /dev/zero | tr '\0' a).sock"

  local line name expect confmode keymode keycontent body ok=0 bad=0 first_bad="" res rest
  local in_case=0
  while IFS= read -r line; do
    if [ "$in_case" = 0 ]; then
      case "$line" in
        'case '*)
          set -- $line
          name="$2"; expect="$3"
          confmode=600; keymode=600; keycontent="@RAND@"
          rest="${line#case $name $expect}"
          case "$rest" in *' conf='*) confmode="${rest#* conf=}"; confmode="${confmode%% *}" ;; esac
          case "$rest" in *' keymode='*) keymode="${rest#* keymode=}"; keymode="${keymode%% *}" ;; esac
          case "$rest" in *' key='*) keycontent="${rest#* key=}" ;; esac
          body=""; in_case=1 ;;
      esac
      continue
    fi
    if [ "$line" = end ]; then
      in_case=0
      keycontent="${keycontent//@RAND@/$(openssl rand -hex 32)}"
      keycontent="${keycontent//@LONG@/$long}"
      printf '%b\n' "$keycontent" > "$keyfile"; chmod "$keymode" "$keyfile"
      printf '%s' "$body" > "$W/c.conf"; chmod "$confmode" "$W/c.conf"
      res="$(rb_boot_result "$W/c.conf" "$sock" "$W/c.log")"
      if [ "$res" = "$expect" ]; then ok=$((ok + 1))
      else bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name (expected $expect, got $res: $(head -c 120 "$W/c.log" | tr '\n' ' '))"
      fi
      continue
    fi
    case "$line" in
      '@MANYKEYS@') body="${body}${many}" ;;
      *)
        line="${line//@SOCK@/$sock}"; line="${line//@KEY@/$keyfile}"; line="${line//@UID@/$uid}"
        line="${line//@DIR@/$W}"; line="${line//@LONG@/$long}"; line="${line//@UIDS80@/$uids80}"
        line="${line//@LONGSOCK@/$longsock}"
        body="${body}${line}"$'\n' ;;
    esac
  done < tests/robustness/conf_boot_cases.txt
  # A socket file left behind by a previous run is replaced; any other file
  # at the socket path is left alone and the daemon refuses to start.
  printf 'socket_path = %s\nhmac_key_file = %s\n' "$sock" "$keyfile" > "$W/c.conf"; chmod 600 "$W/c.conf"
  openssl rand -hex 32 > "$keyfile"; chmod 600 "$keyfile"
  local py; py="$(mcp_python)"
  if [ -n "$py" ]; then
    rm -f "$sock"; "$py" -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$sock"
    res="$(rb_boot_result "$W/c.conf" "$sock" "$W/c.log" keep)"
    if [ "$res" = start ]; then ok=$((ok + 1)); else bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a stale socket file was not replaced (daemon: $res)"; fi
    rm -f "$sock"; : > "$sock"
    res="$(rb_boot_result "$W/c.conf" "$sock" "$W/c.log" keep)"
    if [ "$res" = refuse ]; then ok=$((ok + 1)); else bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a regular file at the socket path was not refused (daemon: $res)"; fi
    rm -f "$sock"
  fi

  # Command lines: each must exit at once with the documented status.
  local args want pid j status
  for args in "-c $W/does-not-exist:1" "-x:2" "--help:2" "-h:2" "-c:2"; do
    want="${args##*:}"; args="${args%:*}"
    "$HERE/service/build/fractalsqld" $args </dev/null >"$W/cli.out" 2>&1 &
    pid=$!
    for j in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null; { wait "$pid"; } 2>/dev/null
      bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="'fractalsqld $args' did not exit"
      continue
    fi
    { wait "$pid"; status=$?; } 2>/dev/null
    if [ "$status" = "$want" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="'fractalsqld $args' exited with $status, expected $want"; fi
  done
  if [ "$bad" -eq 0 ]; then
    pass "54 daemon_conf_boot: all $ok configuration files and command lines were accepted or refused as expected"
  else
    fail "54 daemon_conf_boot: $bad of $((ok + bad)) configuration files and command lines behaved unexpectedly, first: $first_bad"
  fi
  rm -rf "$W"
}

# Turns a verify() JSON report into "ok:ROWS" or "bad:FIRST_FAILURE:REASON".
rb_verdict() {
  printf '%s' "$1" | tr -d '\n' | sed -E \
    -e 's/^\{"ok":true,"rows_verified":([0-9]+)\}$/ok:\1/' \
    -e 's/^\{"ok":false,"first_failure_id":([0-9]+),"reason":"(.*)"\}$/bad:\1:\2/'
}

# 55: ledgers built by hand, valid and corrupted in every way the integrity
# check is meant to notice, under a matching key, no key and the wrong key.
gate_55_ledger_forged() {
  local py; py="$(mcp_python)"
  if [ -z "$py" ]; then skip "55 ledger_forged (no python3 on PATH)"; return; fi
  local lib; lib="$(rb_mock_lib)"
  if [ -z "$lib" ]; then fail "55 ledger_forged: the mock enterprise core failed to build"; return; fi
  rb_reset_daemon
  local tag="${CUR_VER//./_}"
  local ledger="$TMPROOT/fractalsql_bt_forged_${tag}.bin"
  local mode daemon_key record_key mode_ok mode_bad first_bad mode_cases
  local m scn want_load want_v1 want_v2 got_load got_v1 got_v2
  for mode in keyed unkeyed wrongkey; do
    case "$mode" in
      keyed)    daemon_key="forge-key"; record_key="forge-key" ;;
      unkeyed)  daemon_key="";          record_key="" ;;
      wrongkey) daemon_key="forge-key"; record_key="other-key" ;;
    esac
    rm -f "$ledger"
    if ! rb_enterprise_up "$lib" "$ledger" "$daemon_key"; then
      fail "55 ledger_forged: the daemon did not restart for the $mode cases"; continue
    fi
    mode_ok=0; mode_bad=0; first_bad=""
    while IFS=$'\t' read -r m scn want_load want_v1 want_v2; do
      case "$m" in ''|'#'*) continue ;; esac
      [ "$m" = "$mode" ] || continue
      "$py" tests/robustness/ledger_forge.py "$ledger" "$scn" "$record_key"
      got_load=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_load(CONNECTION_ID()), 'refused');" 2>&1)
      [ "$got_load" = 0 ] && got_load=ok
      got_v1=$(rb_verdict "$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 1);" 2>&1)")
      got_v2=$(rb_verdict "$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);" 2>&1)")
      if [ "$got_load" = "$want_load" ] && [ "$got_v1" = "$want_v1" ] && [ "$got_v2" = "$want_v2" ]; then
        mode_ok=$((mode_ok + 1))
      else
        mode_bad=$((mode_bad + 1))
        [ -z "$first_bad" ] && first_bad="$scn: load $got_load/$want_load, kind 1 '$got_v1'/'$want_v1', kind 2 '$got_v2'/'$want_v2'"
      fi
    done < tests/robustness/ledger_cases.tsv
    if [ "$mode_bad" -eq 0 ] && [ "$mode_ok" -gt 0 ]; then
      pass "55 ledger_forged: $mode_ok forged ledgers gave the right load and verify verdicts ($mode)"
    else
      fail "55 ledger_forged ($mode): $mode_bad of $((mode_ok + mode_bad)) forged ledgers were judged wrongly, first: $first_bad"
    fi
  done
  rm -f "$ledger" "$ledger.csv"
  rb_reset_daemon
}

# 56: ledger paths the daemon cannot use as intended.
gate_56_ledger_files() {
  local py; py="$(mcp_python)"
  if [ -z "$py" ]; then skip "56 ledger_files (no python3 on PATH)"; return; fi
  local lib; lib="$(rb_mock_lib)"
  if [ -z "$lib" ]; then fail "56 ledger_files: the mock enterprise core failed to build"; return; fi
  rb_reset_daemon
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_ledgerfiles_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  "$py" tests/robustness/ledger_forge.py "$W/good.bin" k2_two ledger-key
  local L; L=$(rb_log_mark)
  local key path name want_audit a v ld bad=0 first_bad="" cases=0
  for key in "" ledger-key; do
    for name in dev_full dev_null directory missing_directory read_only empty fresh; do
      rm -f "$W/ro.bin" "$W/empty.bin" "$W/fresh.bin" "$W/ro.bin.head" "$W/empty.bin.head" "$W/fresh.bin.head"   # each case starts a new ledger, head included
      cp "$W/good.bin" "$W/ro.bin"; chmod 400 "$W/ro.bin"; : > "$W/empty.bin"
      case "$name" in
        dev_full) path=/dev/full; want_audit=NULL ;;
        dev_null) path=/dev/null; want_audit=NULL ;;
        directory) path="$W"; want_audit=NULL ;;
        missing_directory) path="$W/no/such/dir/ledger.bin"; want_audit=NULL ;;
        read_only) path="$W/ro.bin"; want_audit=NULL
                   # Permissions do not bind the superuser, who can append anyway.
                   [ "$(id -u)" = 0 ] && want_audit=0 ;;
        empty) path="$W/empty.bin"; want_audit=0 ;;
        fresh) path="$W/fresh.bin"; want_audit=0 ;;
      esac
      cases=$((cases + 1))
      if ! rb_enterprise_up "$lib" "$path" "$key"; then
        bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: the daemon did not restart"; continue
      fi
      a=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_audit_log('probe', '{\"a\":1}'), 'NULL');" 2>&1)
      v=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), 'NULL');" 2>&1)
      ld=$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_load(CONNECTION_ID()), 'NULL');" 2>&1)
      if [ "$a" != "$want_audit" ]; then
        bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name (key '${key:-none}'): audit_log answered '$a', expected '$want_audit'"
      fi
      if [ "$name" = fresh ] || [ "$name" = empty ]; then
        [ "$(rb_verdict "$v")" = "ok:1" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: verify answered '$v' after one append"; }
      fi
      rb_daemon_ok || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: the daemon stopped answering"; }
    done
  done
  chmod 600 "$W/ro.bin" 2>/dev/null
  if rb_log_since "$L" | rb_log_has_crash; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "56 ledger_files: audit_log refuses cleanly on unusable ledger paths and appends on usable ones ($cases cases, with and without a key)"
  else
    fail "56 ledger_files: $bad problem(s), first: $first_bad"
  fi
  rm -rf "$W"
  rb_reset_daemon
}

# Coarse outcome of a client call: "error", "null" or "value". A fault sweep
# stops once the injected failure point lies past the end of the call, which
# shows as the same outcome class as the uninjected run several times over.
rb_outcome_class() {
  case "$1" in
    *ERROR*) printf error ;;
    NULL|*$'\n'NULL) printf null ;;
    *) printf value ;;
  esac
}

# 57 (--fault): one injected failure at every point of a long list of calls.
#
# Gate 37 restarts the daemon per trial, which limits it to a few calls. Here
# one long-lived daemon is armed over a control file and SIGUSR1 (see
# tests/oom_preload.c): "the Nth allocation from now fails", or "the Mth
# stdio/file call from now fails". Each call is repeated with N = 1, 2, 3 ...
# until the failure point is past the end of the call. A trial passes unless
# the daemon dies or logs a FATAL. A third sweep arms the failure during daemon
# startup, which reads the configuration and key files and builds its state.
gate_57_fault_sweeps() {
  case "$(uname -s)" in
    Linux) ;;
    *) skip "57 fault_sweeps (needs LD_PRELOAD and signals, Linux only)"; return ;;
  esac
  if [ "$ASAN" -eq 1 ] || [ "$UBSAN" -eq 1 ] || [ "$TSAN" -eq 1 ]; then
    skip "57 fault_sweeps (a sanitizer runtime and the fault shim cannot both interpose the allocator)"; return
  fi
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_faults_${tag}"
  local so="$W/oom_preload.so" ctl="$W/ctl" py; py="$(mcp_python)"
  rm -rf "$W"; mkdir -p "$W"
  if ! cc -O2 -fPIC -shared -o "$so" tests/oom_preload.c -ldl 2>"$W/build.log"; then
    cat "$W/build.log" >&2; fail "57 fault_sweeps: oom_preload.so failed to build"; return
  fi
  local lib; lib="$(rb_mock_lib)"
  if [ -z "$lib" ] || [ -z "$py" ]; then skip "57 fault_sweeps (needs the mock enterprise core and python3)"; return; fi
  local ledger="$W/ledger.bin" template="$W/ledger.template"
  "$py" tests/robustness/ledger_forge.py "$template" mixed fault-key
  rb_reset_daemon
  rb_conf_set enterprise_lib "$lib"; rb_conf_set enterprise_ledger_path "$ledger"
  rb_conf_set enterprise_ledger_key "fault-key"; rb_conf_set enterprise_require_signature 0
  local L; L=$(rb_log_mark)

  rb_arm()    { printf '%s %s %s %s\n' "$1" "$2" "${3:-0}" "${4:-0}" > "$ctl"; kill -USR1 "$FSQD_PID" 2>/dev/null; }
  rb_disarm() { kill -USR2 "$FSQD_PID" 2>/dev/null; }
  rb_restart_armed() { LD_PRELOAD="$so" FSQL_OOM_CTL="$ctl" rb_daemon_restart; }

  rb_restart_armed || { fail "57 fault_sweeps: the daemon did not start under the fault shim"; rb_reset_daemon; return; }
  "${MARIADB[@]}" --force < tests/robustness/oom_pre.sql >/dev/null 2>&1

  # Which calls: up to two per function from the seed corpus, then the larger ones.
  local calls="$W/calls.sql"
  awk '{ if (match($0, /fractal_[a-z0-9_]+/)) { n = substr($0, RSTART, RLENGTH); if (++c[n] <= 2) print } }' \
      tests/robustness/seed_calls.sql | grep -vE 'lock_destructive|ledger_(reset|compact|flush)' > "$calls"
  grep -v '^--' tests/robustness/oom_calls.sql | grep -v '^$' >> "$calls"

  local q base base_class out same n trials=0 crashes=0 first_crash="" maxn="${FSQL_OOM_MAX_N:-45}"
  while IFS= read -r q; do
    case "$q" in ''|'--'*) continue ;; esac
    base=$("${MARIADB[@]}" -N -e "$q" 2>&1); base_class=$(rb_outcome_class "$base"); same=0
    for n in $(seq 1 "$maxn"); do
      rb_arm "$n" 0
      out=$("${MARIADB[@]}" -N -e "$q" 2>&1); trials=$((trials + 1))
      rb_disarm
      if ! kill -0 "$FSQD_PID" 2>/dev/null; then
        crashes=$((crashes + 1)); [ -z "$first_crash" ] && first_crash="allocation #$n in: ${q:0:80}"
        rb_restart_armed; same=0; continue
      fi
      if [ "$(rb_outcome_class "$out")" = "$base_class" ]; then
        same=$((same + 1)); [ "$same" -ge 3 ] && [ "$n" -gt 10 ] && break
      else
        same=0
      fi
    done
  done < "$calls"
  if [ "$crashes" -eq 0 ]; then
    pass "57 fault_sweeps: no crash across $trials injected allocation failures over the UDF corpus"
  else
    fail "57 fault_sweeps: $crashes injected allocation failure(s) crashed the daemon, first at $first_crash"
  fi

  # File-system failures over the ledger paths, from a valid chain and from none.
  local io_queries=(
    "SELECT fractal_ledger_load(CONNECTION_ID());"
    "SELECT fractal_ledger_verify(CONNECTION_ID());"
    "SELECT fractal_ledger_verify(CONNECTION_ID(), 2);"
    "SELECT fractal_ledger_verify(CONNECTION_ID(), 1);"
    "SELECT fractal_audit_log('probe', '{\"a\":1}');"
    "SELECT fractal_audit_log('probe', '[1,2,3]');"
    "SELECT fractal_ledger_flush(CONNECTION_ID());"
    "SELECT fractal_ledger_compact(CONNECTION_ID());"
    "SELECT fractal_ledger_reset_soft(CONNECTION_ID());"
    "SELECT fractal_ledger_truth_count(CONNECTION_ID());"
    "SELECT fractal_optimize_portfolio_multimodal('1,2','1,0,0,1',1,2,0.5,0.5,42);")
  local start m maxm="${FSQL_IO_MAX_M:-400}"
  trials=0; crashes=0; first_crash=""
  for q in "${io_queries[@]}"; do
    for start in template none; do
      rm -f "$ledger" "$ledger.csv"; [ "$start" = template ] && cp "$template" "$ledger"
      base=$("${MARIADB[@]}" -N -e "$q" 2>&1); same=0
      for m in $(seq 1 "$maxm"); do
        rm -f "$ledger" "$ledger.csv"; [ "$start" = template ] && cp "$template" "$ledger"
        rb_arm 0 "$m"
        out=$("${MARIADB[@]}" -N -e "$q" 2>&1); trials=$((trials + 1))
        rb_disarm
        if ! kill -0 "$FSQD_PID" 2>/dev/null; then
          crashes=$((crashes + 1)); [ -z "$first_crash" ] && first_crash="file call #$m in: ${q:0:80}"
          rb_restart_armed; same=0; continue
        fi
        if [ "$out" = "$base" ]; then
          same=$((same + 1)); [ "$same" -ge 6 ] && [ "$m" -gt 15 ] && break
        else
          same=0
        fi
      done
    done
  done
  if [ "$crashes" -eq 0 ]; then
    pass "57 fault_sweeps: no crash across $trials injected file-system failures in the ledger paths"
  else
    fail "57 fault_sweeps: $crashes injected file-system failure(s) crashed the daemon, first at $first_crash"
  fi

  # Socket and thread failures while the daemon accepts, authenticates, reads
  # and answers: a client call and a reload under each errno, the Kth call
  # of the group failing.
  local k e maxk="${FSQL_SYS_MAX_K:-30}" probe_out
  trials=0; crashes=0; first_crash=""
  local clean_exits=0 smark
  for e in 5 4 103 24 12 11 32 104 22; do
    for k in $(seq 1 "$maxk"); do
      smark=$(rb_log_mark)
      rb_arm 0 0 "$k" "$e"
      probe_out=$("${MARIADB[@]}" -N -e "SELECT fractal_version(), fractal_vector_lp_distance('[1,0]', '[0,1]', 2.0);" 2>&1)
      rb_fsq_reload >/dev/null 2>&1
      rb_disarm
      trials=$((trials + 1))
      if ! kill -0 "$FSQD_PID" 2>/dev/null; then
        # An accept() error the daemon does not recognise stops it on purpose:
        # it logs the error and exits normally. That is not a crash.
        if rb_log_since "$smark" | rb_log_has_crash; then
          crashes=$((crashes + 1)); [ -z "$first_crash" ] && first_crash="socket/thread call #$k failing with errno $e"
        else
          clean_exits=$((clean_exits + 1))
        fi
        rb_restart_armed
      fi
    done
  done
  : "$probe_out"
  if [ "$crashes" -eq 0 ]; then
    pass "57 fault_sweeps: no crash across $trials injected socket and thread failures while serving ($clean_exits ended in a logged, normal exit)"
  else
    fail "57 fault_sweeps: $crashes injected socket or thread failure(s) crashed the daemon, first at $first_crash"
  fi

  # Failures during daemon startup.
  local conf="$W/boot.conf" bkey="$W/boot.key" sock="$W/boot.sock" kind res
  trials=0; crashes=0; first_crash=""
  openssl rand -hex 32 > "$bkey"; chmod 600 "$bkey"
  { printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\n' "$sock" "$bkey" "$(id -u)"
    printf 'log_file = %s/boot.log\nmax_connections = 4\nidle_timeout_secs = 9\n' "$W"
    printf 'enterprise_lib = %s\nenterprise_ledger_path = %s/boot-ledger.bin\nenterprise_ledger_key = k\n' "$lib" "$W"
    printf 't2s_max_attempts = 2\nthink = a\n'; } > "$conf"
  chmod 600 "$conf"
  daemon_stop
  for kind in io oom sys; do
    for n in $(seq 1 "$([ "$kind" = oom ] && echo 120 || { [ "$kind" = io ] && echo 60 || echo 14; })"); do
      rm -f "$sock"
      if [ "$kind" = io ]; then
        LD_PRELOAD="$so" FSQL_IO_FAIL_AT="$n" "$HERE/service/build/fractalsqld" -c "$conf" </dev/null >"$W/boot.out" 2>&1 &
      elif [ "$kind" = sys ]; then
        LD_PRELOAD="$so" FSQL_SYS_FAIL_AT="$n" FSQL_SYS_ERRNO=$((n % 3 == 0 ? 98 : 13)) "$HERE/service/build/fractalsqld" -c "$conf" </dev/null >"$W/boot.out" 2>&1 &
      else
        LD_PRELOAD="$so" FSQL_OOM_FAIL_AT="$n" "$HERE/service/build/fractalsqld" -c "$conf" </dev/null >"$W/boot.out" 2>&1 &
      fi
      local bpid=$! i
      for i in $(seq 1 10); do
        [ -S "$sock" ] && break
        kill -0 "$bpid" 2>/dev/null || break
        sleep 0.05
      done
      trials=$((trials + 1))
      if kill -0 "$bpid" 2>/dev/null; then kill "$bpid" 2>/dev/null; fi
      { wait "$bpid"; } 2>/dev/null
      if cat "$W/boot.out" "$W/boot.log" 2>/dev/null | rb_log_has_crash; then
        crashes=$((crashes + 1)); [ -z "$first_crash" ] && first_crash="$kind failure #$n during startup"
      fi
    done
  done
  if [ "$crashes" -eq 0 ]; then
    pass "57 fault_sweeps: no crash across $trials injected failures during daemon startup"
  else
    fail "57 fault_sweeps: $crashes injected failure(s) during startup crashed the daemon, first: $first_crash"
  fi

  if rb_log_since "$L" | rb_log_has_crash; then
    fail "57 fault_sweeps: the daemon logged a FATAL: $(rb_log_since "$L" | grep FATAL | head -1)"
  fi
  rm -rf "$W"
  rb_reset_daemon
}

# 58: enterprise_lib values the daemon must not load, and the signature rule.
#
# The enterprise core is a dlopen'd library. A path that is not a loadable
# library, a missing or wrong-sized signature, a signature that does not
# match, a library without the required symbols: none may load, and none may
# take the daemon down. An unsigned library does load while signatures are not
# required, and is refused once enterprise_require_signature is set.
gate_58_enterprise_loading() {
  local lib; lib="$(rb_mock_lib)"
  if [ -z "$lib" ]; then fail "58 enterprise_loading: the mock enterprise core failed to build"; return; fi
  rb_reset_daemon
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_entload_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  echo 'not a shared library' > "$W/not_elf.so"
  : > "$W/empty.so"
  cp "$lib" "$W/sig_16_bytes.so";  head -c 16 /dev/urandom > "$W/sig_16_bytes.so.sig"
  cp "$lib" "$W/sig_64_random.so"; head -c 64 /dev/urandom > "$W/sig_64_random.so.sig"
  cp "$lib" "$W/sig_65_bytes.so";  head -c 65 /dev/urandom > "$W/sig_65_bytes.so.sig"
  cp "$lib" "$W/sig_empty.so";     : > "$W/sig_empty.so.sig"
  cp "$lib" "$W/sig_is_dir.so";    mkdir -p "$W/sig_is_dir.so.sig"
  cp "$lib" "$W/unsigned.so"
  local bad=0 first_bad="" cases=0 name path req want got
  # name|path|require_signature|expected truth_count answer ("0" loaded, "NULL" refused)
  # A directory where the .sig should be opens on POSIX but cannot be read, which
  # counts as a wrong-sized (invalid) signature and is refused either way. On
  # Windows it cannot be opened at all, so it counts as a missing .sig and loads
  # unless signatures are required; build_test.ps1 expects that. The _required
  # case is refused on both.
  local table="not_elf|$W/not_elf.so|0|NULL
empty_file|$W/empty.so|0|NULL
sig_16_bytes|$W/sig_16_bytes.so|0|NULL
sig_64_random|$W/sig_64_random.so|0|NULL
sig_65_bytes|$W/sig_65_bytes.so|0|NULL
sig_empty|$W/sig_empty.so|0|NULL
sig_is_a_directory|$W/sig_is_dir.so|0|NULL
sig_is_a_directory_required|$W/sig_is_dir.so|1|NULL
sig_64_random_required|$W/sig_64_random.so|1|NULL
nonexistent|$W/nonexistent.so|0|NULL
directory|$W|0|NULL
no_required_symbols|/bin/true|0|NULL
libc|$(ls /lib/x86_64-linux-gnu/libc.so.6 /lib/aarch64-linux-gnu/libc.so.6 /usr/lib/libSystem.B.dylib 2>/dev/null | head -1)|0|NULL
unsigned_not_required|$W/unsigned.so|0|0
unsigned_but_required|$W/unsigned.so|1|NULL"
  local L; L=$(rb_log_mark)
  while IFS='|' read -r name path req want; do
    [ -n "$name" ] || continue
    cases=$((cases + 1))
    rb_conf_set enterprise_lib "$path"
    rb_conf_set enterprise_ledger_path "$W/ledger.bin"
    rb_conf_set enterprise_ledger_key "load-key"
    rb_conf_set enterprise_require_signature "$req"
    if ! rb_daemon_restart; then
      bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: the daemon did not start"; continue
    fi
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_ledger_truth_count(CONNECTION_ID());" </dev/null 2>&1)
    if [ "$got" != "$want" ]; then
      bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: truth_count answered '$got', expected '$want'"
    fi
    # Whatever happened to the load, the rest of the engine must still work.
    rb_daemon_ok || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$name: the daemon stopped answering"; }
  done <<< "$table"
  if rb_log_since "$L" | rb_log_has_crash; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "58 enterprise_loading: $cases enterprise_lib/signature combinations loaded or were refused as expected"
  else
    fail "58 enterprise_loading: $bad problem(s) across $cases combinations, first: $first_bad"
  fi
  rm -rf "$W"
  rb_reset_daemon
}

# 59: live reload of the provider settings.
#
# The provider keys (reasoning, embedding, thinking, text-to-SQL) are read at
# startup and again on every reload, and a reload that fails validation must
# leave the running settings alone. Every key is removed, changed and
# restored in turn, with a reasoning, embedding and text-to-SQL call after
# each step; fractal_t2s_config() shows what the daemon is actually using.
gate_59_provider_reload() {
  rb_reset_daemon
  local want_default='{"max_attempts":2,"allowed_statements":"select","use_review":false}'
  local got r i key bad=0 first_bad="" steps=0
  local calls="SELECT fractal_reason('q','c'); SELECT fractal_embed('hello'); SELECT fractal_t2s_generate(CONNECTION_ID(),'mariadb1011','schema','question'); SELECT fractal_t2s_review(CONNECTION_ID(),'q','SELECT 1');"
  local L; L=$(rb_log_mark)

  got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
  [ "$got" = "$want_default" ] || { bad=$((bad + 1)); first_bad="the default settings read '$got'"; }

  # name|value for each provider key that has no side effect on the plugin path
  local keys="reasoning_url|http://127.0.0.1:1/v1
reasoning_token|token
reasoning_model|model
reasoning_allow_plaintext|true
embed_url|http://127.0.0.1:1/v1
embed_model|embed
think|high
think_provider|ollama
think_native_url|http://127.0.0.1:1
think_num_ctx|4096
t2s_max_attempts|3
t2s_allowed_statements|select_insert_update
t2s_use_review|true"
  local name value
  # 1. every key set at once, then each removed in turn.
  while IFS='|' read -r name value; do rb_conf_set "$name" "$value"; done <<< "$keys"
  r=$(rb_fsq_reload)
  steps=$((steps + 1))
  [ "$r" = "reloaded: configuration swapped in" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reload with every key set answered '$r'"; }
  got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
  [ "$got" = '{"max_attempts":3,"allowed_statements":"select_insert_update","use_review":true}' ] \
    || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="with every key set fractal_t2s_config() read '$got'"; }
  "${MARIADB[@]}" --force -N -e "$calls" </dev/null >/dev/null 2>&1
  while IFS='|' read -r name value; do
    rb_conf_set "$name" ""
    r=$(rb_fsq_reload); steps=$((steps + 1))
    [ "$r" = "reloaded: configuration swapped in" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reload without $name answered '$r'"; }
    "${MARIADB[@]}" --force -N -e "$calls" </dev/null >/dev/null 2>&1
    rb_conf_set "$name" "$value"
  done <<< "$keys"
  # 2. each key changed to another valid value.
  while IFS='|' read -r name value; do
    case "$name" in
      t2s_max_attempts) rb_conf_set "$name" 4 ;;
      t2s_allowed_statements) rb_conf_set "$name" select ;;
      t2s_use_review) rb_conf_set "$name" false ;;
      think_num_ctx) rb_conf_set "$name" 8192 ;;
      reasoning_allow_plaintext) rb_conf_set "$name" false ;;
      *) rb_conf_set "$name" "changed-$name" ;;
    esac
    r=$(rb_fsq_reload); steps=$((steps + 1))
    [ "$r" = "reloaded: configuration swapped in" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reload with $name changed answered '$r'"; }
    "${MARIADB[@]}" --force -N -e "$calls" </dev/null >/dev/null 2>&1
    rb_conf_set "$name" "$value"
  done <<< "$keys"
  # 3. a reload that fails validation is refused and leaves the running settings in place.
  rb_fsq_reload >/dev/null
  rb_conf_set t2s_max_attempts 4
  r=$(rb_fsq_reload)
  got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
  case "$got" in *'"max_attempts":4'*) ;; *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a valid reload to max_attempts 4 read '$got'" ;; esac
  for key in "think_num_ctx|0" "t2s_max_attempts|99" "t2s_allowed_statements|delete" "reasoning_url|"; do
    name="${key%%|*}"; value="${key#*|}"
    rb_conf_set "$name" "$value"
    if [ -z "$value" ]; then printf '%s =\n' "$name" >> "$FSQD_CONF"; fi
    r=$(rb_fsq_reload); steps=$((steps + 1))
    [ "$r" = "reloaded: configuration swapped in" ] && { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="an invalid $name = '$value' was accepted"; }
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
    case "$got" in *'"max_attempts":4'*) ;; *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="after refusing $name = '$value' the settings read '$got'" ;; esac
    rb_conf_set "$name" ""
    rb_conf_set "t2s_max_attempts" 4
  done
  # 4. every provider key removed: back to the defaults.
  while IFS='|' read -r name value; do rb_conf_set "$name" ""; done <<< "$keys"
  r=$(rb_fsq_reload); steps=$((steps + 1))
  got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
  [ "$got" = "$want_default" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="with every key removed the settings read '$got'"; }

  # 5. A session may override the two text-to-SQL keys fractal_t2s_config() reports,
  # for its own connection only: accepted spellings take effect, others are refused.
  local pair spelling expect_review
  for pair in on:true yes:true 1:true true:true off:false no:false 0:false false:false; do
    spelling="${pair%%:*}"; expect_review="${pair##*:}"
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('t2s_use_review','$spelling',CONNECTION_ID()), fractal_t2s_config(CONNECTION_ID());" </dev/null 2>&1)
    steps=$((steps + 1))
    case "$got" in
      "ok"*'"use_review":'"$expect_review"'}') ;;
      *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a session setting t2s_use_review = $spelling read back '$got'" ;;
    esac
  done
  for spelling in TRUE maybe 2; do
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('t2s_use_review','$spelling',CONNECTION_ID()), fractal_t2s_config(CONNECTION_ID());" </dev/null 2>&1)
    steps=$((steps + 1))
    case "$got" in
      *"expects true/false/on/off/1/0"*'"use_review":false}') ;;
      *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="t2s_use_review = $spelling was not refused: '$got'" ;;
    esac
  done
  for pair in 5:5 1:1 10:10; do
    spelling="${pair%%:*}"; expect_review="${pair##*:}"
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('t2s_max_attempts','$spelling',CONNECTION_ID()), fractal_t2s_config(CONNECTION_ID());" </dev/null 2>&1)
    steps=$((steps + 1))
    case "$got" in
      "ok"*'"max_attempts":'"$expect_review"',"'*) ;;
      *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a session setting t2s_max_attempts = $spelling read back '$got'" ;;
    esac
  done
  for spelling in 0 11 abc; do
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_config_set('t2s_max_attempts','$spelling',CONNECTION_ID()), fractal_t2s_config(CONNECTION_ID());" </dev/null 2>&1)
    steps=$((steps + 1))
    case "$got" in
      *"'t2s_max_attempts'"*'"max_attempts":2,"'*) ;;
      *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="t2s_max_attempts = $spelling was not refused: '$got'" ;;
    esac
  done

  rb_daemon_ok || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon stopped answering"; }
  if rb_log_since "$L" | rb_log_has_crash; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "59 provider_reload: $steps live reloads of the provider settings behaved as expected"
  else
    fail "59 provider_reload: $bad problem(s), first: $first_bad"
  fi
  rb_reset_daemon
}

# 60: what the engine does with every kind of reply a reasoning plugin can give.
#
# tests/scripted_reasoning_plugin.c returns whatever the test has written to a
# file, or fails with a chosen code, or returns no summary at all, or a reply
# past the 16 MiB limit. fractal_reason, fractal_t2s_generate and
# fractal_t2s_review must pass a normal reply through, refuse the broken ones
# cleanly, and fractal_t2s_review must treat a reply that starts with "pass"
# as approval (NULL) and any other reply as the critique to return.
gate_60_scripted_replies() {
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_scripted_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  W="$(cd "$W" && pwd -P)"
  if ! cc -shared -fPIC -std=c99 -I"$HERE/include" tests/scripted_reasoning_plugin.c \
          -o "$W/scripted.so" 2>"$W/build.log"; then
    cat "$W/build.log" >&2; fail "60 scripted_replies: the scripted plugin failed to build"; return
  fi
  rb_reset_daemon
  rb_conf_set reasoning_plugin "$W/scripted.so"
  if ! FSQL_SCRIPTED_REPLY="$W/reply" rb_daemon_restart; then
    fail "60 scripted_replies: the daemon did not restart with the scripted plugin"; return
  fi
  local L; L=$(rb_log_mark)
  local reason_q="SELECT IFNULL(fractal_reason('q','c'),'<NULL>')"
  local review_q="SELECT IFNULL(fractal_t2s_review(CONNECTION_ID(),'q','SELECT 1'),'<NULL>')"
  local gen_q="SELECT IFNULL(fractal_t2s_generate(CONNECTION_ID(),'mariadb1011','schema','q'),'<NULL>')"
  # reply (printf format) | expected reason | expected review | expected generate
  local table='hello|hello|hello|hello
SELECT 1|SELECT 1|SELECT 1|SELECT 1
|||
PASS|PASS|<NULL>|PASS
pass|pass|<NULL>|pass
Pass: fine|Pass: fine|<NULL>|Pass: fine
 \t Pass|*|<NULL>|*
FAIL: bad|FAIL: bad|FAIL: bad|FAIL: bad
pas|pas|pas|pas
@null|<NULL>|<NULL>|<NULL>
@rc=-5|<NULL>|<NULL>|<NULL>
@rc=-1|<NULL>|<NULL>|<NULL>
@size=16777217|<NULL>|<NULL>|<NULL>'
  local reply e_reason e_review e_gen got bad=0 first_bad="" cases=0
  while IFS='|' read -r reply e_reason e_review e_gen; do
    printf "$reply" > "$W/reply"
    cases=$((cases + 1))
    got=$("${MARIADB[@]}" -N -e "$reason_q" </dev/null 2>&1)
    [ "$e_reason" = "*" ] || [ "$got" = "$e_reason" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reply '$reply': fractal_reason answered '$got', expected '$e_reason'"; }
    got=$("${MARIADB[@]}" -N -e "$review_q" </dev/null 2>&1)
    [ "$e_review" = "*" ] || [ "$got" = "$e_review" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reply '$reply': fractal_t2s_review answered '$got', expected '$e_review'"; }
    got=$("${MARIADB[@]}" -N -e "$gen_q" </dev/null 2>&1)
    [ "$e_gen" = "*" ] || [ "$got" = "$e_gen" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reply '$reply': fractal_t2s_generate answered '$got', expected '$e_gen'"; }
  done <<< "$table"
  # A large but legal reply comes back whole.
  printf '@size=5242880' > "$W/reply"
  got=$("${MARIADB[@]}" -N -e "SELECT LENGTH(fractal_reason('q','c'));" </dev/null 2>&1)
  [ "$got" = 5242880 ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a 5 MiB reply came back as '$got' bytes"; }
  rb_daemon_ok || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon stopped answering"; }
  if rb_log_since "$L" | rb_log_has_crash; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "60 scripted_replies: $cases scripted plugin replies were passed through, refused or judged as expected"
  else
    fail "60 scripted_replies: $bad problem(s) across $cases replies, first: $first_bad"
  fi
  rm -rf "$W"
  rb_reset_daemon
}

# 61: the connection limits and what a reload may and may not change.
#
# A throwaway daemon with max_connections = 3 and idle_timeout_secs = 1 must
# refuse the fourth connection, free a slot when a connection closes, close a
# connection that stays silent, and serve again afterwards. A reload applies a
# new limit to later connections, and refuses a configuration that moves the
# socket or the key file, which a running daemon cannot adopt.
gate_61_daemon_limits() {
  local py; py="$(mcp_python)"
  if [ -z "$py" ]; then skip "61 daemon_limits (no python3 on PATH)"; return; fi
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fsqlbt_lim_${tag}"
  rm -rf "$W"; mkdir -p "$W"
  local sock="$W/s.sock" keyfile="$W/key" conf="$W/c.conf" bad=0 first_bad="" checks=0
  openssl rand -hex 32 > "$keyfile"; chmod 600 "$keyfile"
  limits_conf() { # max_connections idle_timeout_secs [socket_path] [key_file]
    printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\nmax_connections = %s\nidle_timeout_secs = %s\n' \
      "${3:-$sock}" "${4:-$keyfile}" "$(id -u)" "$1" "$2" > "$conf"
    chmod 600 "$conf"
  }
  limits_reload() { FSQLCTL_SOCKET="$sock" FSQLCTL_KEY="$keyfile" "$HERE/service/build/fsqlctl" reload 2>&1; }
  limits_run() { # max idle
    "$py" tests/robustness/conn_limits.py "$sock" "$(cat "$keyfile")" "$1" "$2" 2>&1
  }

  limits_conf 3 1
  rm -f "$sock"
  "$HERE/service/build/fractalsqld" -c "$conf" </dev/null >"$W/daemon.log" 2>&1 &
  local pid=$! i out r
  for i in $(seq 1 60); do [ -S "$sock" ] && break; sleep 0.05; done
  if [ ! -S "$sock" ]; then
    fail "61 daemon_limits: the throwaway daemon did not start (see $W/daemon.log)"; kill "$pid" 2>/dev/null; return
  fi

  out=$(limits_run 3 1); checks=$((checks + 1))
  case "$out" in *FAIL*) bad=$((bad + 1)); first_bad="max_connections = 3: $(printf '%s' "$out" | grep FAIL | head -1)" ;; esac

  # A reload lowers the limit; the next connections obey it.
  limits_conf 1 1
  r=$(limits_reload); checks=$((checks + 1))
  [ "$r" = "reloaded: configuration swapped in" ] || { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="reload to max_connections = 1 answered '$r'"; }
  out=$(limits_run 1 1); checks=$((checks + 1))
  case "$out" in *FAIL*) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="after the reload to 1: $(printf '%s' "$out" | grep FAIL | head -1)" ;; esac

  # A reload that moves the socket or the key file is refused and the old settings stay.
  limits_conf 1 1 "$W/other.sock"
  r=$(limits_reload); checks=$((checks + 1))
  [ "$r" = "reloaded: configuration swapped in" ] && { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a reload that moved socket_path was accepted"; }
  openssl rand -hex 32 > "$W/key2"; chmod 600 "$W/key2"
  limits_conf 1 1 "$sock" "$W/key2"
  r=$(limits_reload); checks=$((checks + 1))
  [ "$r" = "reloaded: configuration swapped in" ] && { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a reload that moved hmac_key_file was accepted"; }
  # An invalid limit is refused too.
  limits_conf 0 1
  r=$(limits_reload); checks=$((checks + 1))
  [ "$r" = "reloaded: configuration swapped in" ] && { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a reload to max_connections = 0 was accepted"; }
  # A missing configuration file is refused.
  mv "$conf" "$conf.away"
  r=$(limits_reload); checks=$((checks + 1))
  [ "$r" = "reloaded: configuration swapped in" ] && { bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="a reload with the configuration file gone was accepted"; }
  mv "$conf.away" "$conf"
  # The daemon kept the limit of 1 through all of that.
  out=$(limits_run 1 1); checks=$((checks + 1))
  case "$out" in *FAIL*) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="after the refused reloads: $(printf '%s' "$out" | grep FAIL | head -1)" ;; esac

  kill "$pid" 2>/dev/null; { wait "$pid"; } 2>/dev/null
  if grep -q "FATAL" "$W/daemon.log" 2>/dev/null; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "61 daemon_limits: connection limit, slot release, idle timeout and reload rules held ($checks checks)"
  else
    fail "61 daemon_limits: $bad problem(s) across $checks checks, first: $first_bad"
  fi
  rm -rf "$W"
}

# 62: provider settings that come from the daemon's environment.
#
# A provider key missing from the configuration file falls back to the
# environment the daemon was started with. Out-of-range or unrecognised
# values fall back to the defaults, and a key that is in the file wins over
# the environment.
gate_62_provider_env() {
  rb_reset_daemon
  local def='{"max_attempts":2,"allowed_statements":"select","use_review":false}'
  local q="SELECT fractal_t2s_config(), fractal_config_get('reasoning_allow_plaintext', 1), IFNULL(fractal_config_get('think', 1),'-'), IFNULL(fractal_config_get('think_num_ctx', 1),'-'), IFNULL(fractal_config_get('reasoning_model', 1),'-')"
  # label | environment | expected answer with ~ between columns
  local table="defaults|FSQL_BT_UNUSED=1|$def~*~*~*~*
max_attempts_4|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=4|{\"max_attempts\":4,\"allowed_statements\":\"select\",\"use_review\":false}~*~*~*~*
max_attempts_1|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=1|{\"max_attempts\":1,\"allowed_statements\":\"select\",\"use_review\":false}~*~*~*~*
max_attempts_10|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=10|{\"max_attempts\":10,\"allowed_statements\":\"select\",\"use_review\":false}~*~*~*~*
max_attempts_0_ignored|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=0|$def~*~*~*~*
max_attempts_11_ignored|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=11|$def~*~*~*~*
max_attempts_text_ignored|FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=abc|$def~*~*~*~*
allowed_select_insert_update|FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update|{\"max_attempts\":2,\"allowed_statements\":\"select_insert_update\",\"use_review\":false}~*~*~*~*
allowed_other_is_select|FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=delete|$def~*~*~*~*
review_1|FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=1|{\"max_attempts\":2,\"allowed_statements\":\"select\",\"use_review\":true}~*~*~*~*
review_0|FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=0|$def~*~*~*~*
review_any_other_value|FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=x|{\"max_attempts\":2,\"allowed_statements\":\"select\",\"use_review\":true}~*~*~*~*
plaintext_generic_on|FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1|*~1~*~*~*
plaintext_generic_off|FRACTALSQL_HTTP_ALLOW_PLAINTEXT=0|*~0~*~*~*
plaintext_specific_wins|FSQL_REASONING_HTTP_ALLOW_PLAINTEXT=1 FRACTALSQL_HTTP_ALLOW_PLAINTEXT=0|*~1~*~*~*
think_ctx_model|FSQL_REASONING_HTTP_THINK=high FSQL_REASONING_HTTP_NUM_CTX=2048 FSQL_REASONING_HTTP_MODEL=m1|*~*~high~2048~m1"
  local label envs want got bad=0 first_bad="" cases=0 L
  L=$(rb_log_mark)
  while IFS='|' read -r label envs want; do
    [ -n "$label" ] || continue
    cases=$((cases + 1))
    if ! rb_daemon_restart $envs; then
      bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$label: the daemon did not restart"; continue
    fi
    got=$("${MARIADB[@]}" -N -e "$q" </dev/null 2>&1 | tr '\t' '~')
    # "*" in the expected answer means "whatever the harness environment gives".
    local IFS_SAVE="$IFS" g_cols w_cols col_ok=1 c
    IFS='~' read -ra g_cols <<< "$got"; IFS='~' read -ra w_cols <<< "$want"; IFS="$IFS_SAVE"
    for c in 0 1 2 3 4; do
      [ "${w_cols[$c]:-}" = "*" ] || [ "${g_cols[$c]:-}" = "${w_cols[$c]:-}" ] || col_ok=0
    done
    if [ "$col_ok" -ne 1 ]; then
      bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="$label: read '$got', expected '$want'"
    fi
  done <<< "$table"
  # A key in the configuration file wins over the environment.
  rb_conf_set t2s_max_attempts 3
  cases=$((cases + 1))
  if rb_daemon_restart FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS=4; then
    got=$("${MARIADB[@]}" -N -e "SELECT fractal_t2s_config();" </dev/null 2>&1)
    case "$got" in *'"max_attempts":3,'*) ;; *) bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the file said 3 and the environment 4; the daemon used '$got'" ;; esac
  else
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon did not restart for the precedence case"
  fi
  if rb_log_since "$L" | rb_log_has_crash; then
    bad=$((bad + 1)); [ -z "$first_bad" ] && first_bad="the daemon logged a FATAL"
  fi
  if [ "$bad" -eq 0 ]; then
    pass "62 provider_env: $cases environment settings were applied, ignored or overridden as expected"
  else
    fail "62 provider_env: $bad problem(s) across $cases settings, first: $first_bad"
  fi
  rb_reset_daemon
}

# ======================================================================
# Direct-call gates 63 and 64
#
# The robustness gates above reach the engine through a database and a daemon.
# These two call the UDF entry points, the configuration library, the session
# registry and the provider settings directly from one process
# (service/tests/udf_direct.c, linked against the same adapter objects the
# daemon links), so thousands of calls run in seconds and a single allocation or
# file call inside each can be made to fail:
#
#   63 direct_calls   every call of the seed corpus, with each argument set to
#                     edge values, with an interruption requested at each poll,
#                     the configuration library, the session registry, the
#                     provider settings and scripted reasoning replies; then
#                     the calls again with the enterprise mock core loaded
#   64 direct_faults  (--fault) the same, with a failure injected at every
#                     allocation and file call of each
#
# A run passes when the process exits normally. The harness judges no result.
# ======================================================================

# Builds service/build/udf_direct with the same instrumentation as the daemon.
rb_build_direct() {
  local san_arg=""
  [ "$COVERAGE" -eq 1 ] && san_arg="COVERAGE=1"
  [ "$ASAN" -eq 1 ]     && san_arg="ASAN=1"
  [ "$UBSAN" -eq 1 ]    && san_arg="UBSAN=1"
  [ "$TSAN" -eq 1 ]     && san_arg="TSAN=1"
  make -C "$HERE/service" $san_arg build/udf_direct >/tmp/fractalsql_bt_direct_build.log 2>&1
}

# Runs udf_direct for the given phases in the community configuration and
# again with the enterprise mock core loaded. Environment NAME=value arguments
# before the phases (for example LD_PRELOAD) reach both runs.
# rb_direct_runs <label-prefix> <stride> <phase>...  (PRELOAD in $RB_DIRECT_PRELOAD)
rb_direct_runs() {
  local gate="$1" stride="$2"; shift 2
  CUR_VER="${CUR_VER:-$MDB_MAJOR}"   # these gates run without a cluster
  local tag="${CUR_VER//./_}"
  local W="$TMPROOT/fractalsql_bt_direct_${tag}"
  local lib scr rc mode out phase bad=0 first_bad="" runs=0
  rm -rf "$W"; mkdir -p "$W"
  lib="$(rb_mock_lib)"
  scr="$W/scripted.so"
  if ! cc -shared -fPIC -std=c99 -I"$HERE/include" tests/scripted_reasoning_plugin.c -o "$scr" 2>"$W/scr.log"; then
    cat "$W/scr.log" >&2; fail "$gate direct: the scripted plugin failed to build"; return
  fi
  for mode in community enterprise; do
    [ "$mode" = enterprise ] && [ -z "$lib" ] && continue
    for phase in "$@"; do
      # The enterprise pass covers the functions that need the core; the
      # configuration, session, provider and reply phases do not depend on it.
      if [ "$mode" = enterprise ]; then
        case "$phase" in config|session|provider|replies) continue ;; esac
      fi
      runs=$((runs + 1))
      if [ "$mode" = enterprise ]; then
        rm -f "$W/ledger.bin" "$W/ledger.bin.csv"
        out=$(env ${RB_DIRECT_PRELOAD:+LD_PRELOAD="$RB_DIRECT_PRELOAD"} \
                  FSQL_SCRIPTED_PLUGIN="$scr" FSQL_SCRIPTED_REPLY="$W/reply" \
                  FSQL_DIRECT_ONLY="ledger,audit,multimodal,truth,portfolio" \
                  FSQL_DIRECT_OOM_CAP=40 FSQL_DIRECT_NO_VARIANTS=1 \
                  FRACTALSQL_ENTERPRISE_LIB="$lib" FRACTALSQL_ENTERPRISE_LEDGER_PATH="$W/ledger.bin" \
                  FRACTALSQL_ENTERPRISE_LEDGER_KEY="direct-key" \
                  ${BT_TIMEOUT_BIN:+$BT_TIMEOUT_BIN ${BT_DIRECT_TIMEOUT:-1200}} "$HERE/service/build/udf_direct" "$phase" tests/robustness/seed_calls.sql "$stride" 2>&1 </dev/null)
      else
        out=$(env ${RB_DIRECT_PRELOAD:+LD_PRELOAD="$RB_DIRECT_PRELOAD"} \
                  FSQL_SCRIPTED_PLUGIN="$scr" FSQL_SCRIPTED_REPLY="$W/reply" \
                  ${BT_TIMEOUT_BIN:+$BT_TIMEOUT_BIN ${BT_DIRECT_TIMEOUT:-1200}} "$HERE/service/build/udf_direct" "$phase" tests/robustness/seed_calls.sql "$stride" 2>&1 </dev/null)
      fi
      rc=$?
      if [ "$rc" -ne 0 ]; then
        bad=$((bad + 1))
        [ -z "$first_bad" ] && first_bad="$phase ($mode): exit status $rc: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
        # The one-line summary keeps only the last two lines; the run's own tail goes to the log.
        { printf '    direct %s (%s) ended with status %s; last output:\n' "$phase" "$mode" "$rc"
          printf '%s\n' "$out" | tail -25 | sed 's/^/    | /'; } >&2
      fi
    done
  done
  if [ "$bad" -eq 0 ]; then
    pass "$gate direct: $runs runs of the direct driver finished normally ($*)"
  else
    fail "$gate direct: $bad of $runs runs ended abnormally, first: $first_bad"
  fi
  rm -rf "$W"
}

gate_63_direct_calls() {
  if ! rb_build_direct; then
    fail "63 direct_calls: udf_direct failed to build (see /tmp/fractalsql_bt_direct_build.log)"; return
  fi
  # ThreadSanitizer slows every call several-fold; a shorter ledger chain and a tighter per-run limit keep the
  # gate inside the job's time budget (a run that still overruns fails by name instead of eating the job).
  if [ "$TSAN" -eq 1 ]; then
    export FSQL_DIRECT_LEDGER_RESET="${FSQL_DIRECT_LEDGER_RESET:-25}"
    export BT_DIRECT_TIMEOUT="${BT_DIRECT_TIMEOUT:-1200}"
  fi
  RB_DIRECT_PRELOAD="" rb_direct_runs 63 "${FSQL_DIRECT_STRIDE:-3}" seed mutate cancel config session provider replies
}

gate_64_direct_faults() {
  case "$(uname -s)" in
    Linux) ;;
    *) skip "64 direct_faults (needs LD_PRELOAD, Linux only)"; return ;;
  esac
  if [ "$ASAN" -eq 1 ] || [ "$UBSAN" -eq 1 ] || [ "$TSAN" -eq 1 ]; then
    skip "64 direct_faults (a sanitizer runtime and the fault shim cannot both interpose the allocator)"; return
  fi
  local W="$TMPROOT/fractalsql_bt_direct_so"
  rm -rf "$W"; mkdir -p "$W"
  if ! cc -O2 -fPIC -shared -o "$W/oom_preload.so" tests/oom_preload.c -ldl 2>"$W/build.log"; then
    cat "$W/build.log" >&2; fail "64 direct_faults: oom_preload.so failed to build"; return
  fi
  if ! rb_build_direct; then
    fail "64 direct_faults: udf_direct failed to build (see /tmp/fractalsql_bt_direct_build.log)"; return
  fi
  RB_DIRECT_PRELOAD="$W/oom_preload.so" rb_direct_runs 64 "${FSQL_DIRECT_STRIDE:-3}" oom config session provider replies
  rm -rf "$W"
}

# 65 mcp_faults (--fault, Linux): the MCP server under tests/oom_preload.c with one
# allocation, file call or socket call failing inside each tool call. The server
# may answer any way it likes; it must still be running and answering afterwards.
gate_65_mcp_faults() {
  case "$(uname -s)" in
    Linux) ;;
    *) skip "65 mcp_faults (needs LD_PRELOAD and signals, Linux only)"; return ;;
  esac
  if [ "$ASAN" -eq 1 ] || [ "$UBSAN" -eq 1 ] || [ "$TSAN" -eq 1 ]; then
    skip "65 mcp_faults (a sanitizer runtime and the fault shim cannot both interpose the allocator)"; return
  fi
  local mcp_py; mcp_py="$(mcp_python)"
  if [[ -z "$mcp_py" ]]; then skip "65 mcp_faults (no python3 on PATH)"; return; fi
  local mcp_exe mcp_why
  mcp_exe="$(mcp_resolve_exe 2>"$TMPROOT/fractalsql_bt_mcp_exe_why.txt")" \
    || { mcp_why="$(cat "$TMPROOT/fractalsql_bt_mcp_exe_why.txt" 2>/dev/null)"; skip "65 mcp_faults ($mcp_why)"; return; }
  local W="$TMPROOT/fractalsql_bt_mcp_faults_${CUR_VER//./_}"
  rm -rf "$W"; mkdir -p "$W"
  if ! cc -O2 -fPIC -shared -o "$W/oom_preload.so" tests/oom_preload.c -ldl 2>"$W/build.log"; then
    cat "$W/build.log" >&2; fail "65 mcp_faults: oom_preload.so failed to build"; return
  fi
  MCP_OOM_PRELOAD="$W/oom_preload.so" \
  MCP_SERVER_EXE="$mcp_exe" \
  MCP_SERVER_CWD="$W" \
  MCP_MARIADB_BIN="$(command -v "${MARIADB[0]}")" \
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
  FSQLCTL_SOCKET="$FSQD_SOCK" \
  FSQLCTL_KEY="$FSQD_KEY" \
  FSQLCTL_CONF="$FSQD_CONF" \
    ${BT_TIMEOUT_BIN:+$BT_TIMEOUT_BIN 420} "$mcp_py" -u "$HERE/mcp/tests/mcp_faults.py" 2>&1 | sed -u 's/^/    /'
  local rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    fail "65 mcp_faults: the fault driver reported failures (see its output above)"
  else
    pass "65 mcp_faults: the MCP server survived injected allocation, file and socket failures in every tool call"
  fi
  rm -rf "$W"
}

# 66 mcp_cli: the MCP server started every way its command line, environment and
# database connection allow (tests/mcp_cli.py), including a connection killed under
# a running server. Each run must end in an orderly way.
gate_66_mcp_cli() {
  local mcp_py; mcp_py="$(mcp_python)"
  if [[ -z "$mcp_py" ]]; then skip "66 mcp_cli (no python3 on PATH)"; return; fi
  local mcp_exe mcp_why
  mcp_exe="$(mcp_resolve_exe 2>"$TMPROOT/fractalsql_bt_mcp_exe_why.txt")" \
    || { mcp_why="$(cat "$TMPROOT/fractalsql_bt_mcp_exe_why.txt" 2>/dev/null)"; skip "66 mcp_cli ($mcp_why)"; return; }
  local W="$TMPROOT/fractalsql_bt_mcp_cli_${CUR_VER//./_}"
  rm -rf "$W"; mkdir -p "$W"
  local san_dir="$TMPROOT/fractalsql_bt_mcp_san_66_${CUR_VER//./_}"
  mcp_exe="$(mcp_san_wrap "$mcp_exe" "$san_dir")"
  MCP_SERVER_EXE="$mcp_exe" \
  MCP_SERVER_CWD="$W" \
  MCP_MARIADB_BIN="$(command -v "${MARIADB[0]}")" \
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
  FSQLCTL_SOCKET="$FSQD_SOCK" \
  FSQLCTL_KEY="$FSQD_KEY" \
  FSQLCTL_CONF="$FSQD_CONF" \
    "$mcp_py" -u "$HERE/mcp/tests/mcp_cli.py" 2>&1 | sed -u 's/^/    /'
  local rc=${PIPESTATUS[0]}
  mcp_san_check "$san_dir" "66 mcp_cli" || { rm -rf "$W"; return; }
  if [[ $rc -ne 0 ]]; then
    fail "66 mcp_cli: a start-up case ended badly (see the output above)"
  else
    pass "66 mcp_cli: the MCP server ended in order for every command line, setting, database and killed connection tried"
  fi
  rm -rf "$W"
}

# 67 mcp_fuzz (--fuzz): libFuzzer targets over what the MCP server accepts
# from a client. Standalone like gate 30 (no cluster, no daemon): the
# JSON-RPC target drives JsonRpcServer::handleLine with two stub tools, and
# the vectors target drives argument coercion and error-text redaction.
# A ToolError is the documented rejection; a crash, hang or sanitizer
# report is the finding.
gate_67_mcp_fuzz() {
  if [[ ! -f "$HERE/tests/fuzz/fuzz_mcp_jsonrpc.cpp" || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "67 mcp_fuzz (mcp/ server code or fuzz targets not present)"; return
  fi
  local cc="${FSQL_FUZZ_CC:-}" candidate
  if [ -z "$cc" ]; then
    for candidate in clang-19 clang-18 clang-17 clang-16 clang-15 clang; do
      if command -v "$candidate" >/dev/null 2>&1; then cc="$candidate"; break; fi
    done
  fi
  if [ -z "$cc" ] || ! command -v "$cc" >/dev/null 2>&1; then
    skip "67 mcp_fuzz (no clang found -- set FSQL_FUZZ_CC to a libFuzzer-capable clang)"; return
  fi
  local cxx="${cc/clang/clang++}"
  if ! command -v "$cxx" >/dev/null 2>&1; then
    skip "67 mcp_fuzz (no $cxx next to $cc)"; return
  fi
  local W="$TMPROOT/fractalsql_bt_mcp_fuzz"
  rm -rf "$W"; mkdir -p "$W"
  local probe="$W/probe.c"
  printf 'int LLVMFuzzerTestOneInput(const unsigned char*d,unsigned long n){(void)d;(void)n;return 0;}\n' > "$probe"
  if ! "$cc" -fsanitize=fuzzer "$probe" -o "$W/probe" >/dev/null 2>&1; then
    skip "67 mcp_fuzz ($cc lacks -fsanitize=fuzzer support -- set FSQL_FUZZ_CC)"; return
  fi
  # shellcheck disable=SC2207
  local mflags=(-std=c++17 -O1 -g -fsanitize=fuzzer,address -Imcp/src -Imcp/vendor -Itests/fuzz $(mariadb_config --cflags 2>/dev/null))
  # std::to_chars(double) in mcp/src/vectors.cpp needs macOS >= 13.3 (see mcp/Makefile)
  [[ "$(uname -s)" = "Darwin" ]] && mflags+=(-mmacosx-version-min=13.3)
  # No Connector/C at link time: only its headers are compiled against, and
  # tests/fuzz/mcp_db_stub.cpp stands in for db.cpp.
  local libs=(-lssl -lcrypto -lpthread)
  if [[ "$(uname -s)" = "Darwin" ]]; then
    local openssl_prefix; openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    [[ -n "$openssl_prefix" ]] && mflags+=(-I"${openssl_prefix}/include") && libs=(-L"${openssl_prefix}/lib" "${libs[@]}")
  fi
  local t rc fuzz_time="${FSQL_FUZZ_TIME:-30}"
  for t in fuzz_mcp_vectors fuzz_mcp_jsonrpc; do
    local srcs=(mcp/src/errors.cpp)
    if [[ "$t" = fuzz_mcp_vectors ]]; then
      srcs+=(mcp/src/vectors.cpp)
    else
      srcs+=(mcp/src/jsonrpc_server.cpp mcp/src/logging.cpp mcp/src/prompts.cpp
             mcp/src/resources.cpp mcp/src/conf_file.cpp mcp/src/fsqlctl.cpp
             tests/fuzz/mcp_db_stub.cpp)
    fi
    if ! "$cxx" "${mflags[@]}" "tests/fuzz/$t.cpp" "${srcs[@]}" "${libs[@]}" \
          -o "$W/$t" >"$W/$t.log" 2>&1; then
      fail "67 mcp_fuzz: $t failed to build; see $W/$t.log"
      continue
    fi
    mkdir -p "$W/${t}_seed"
    rc=0
    ASAN_OPTIONS="detect_leaks=0:symbolize=0:abort_on_error=1" \
      "$W/$t" "$W/${t}_seed" "tests/fuzz/corpus_${t#fuzz_}" \
      -max_total_time="$fuzz_time" -print_final_stats=1 \
      >"$W/$t.run.log" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
      pass "67 mcp_fuzz: $t (${fuzz_time}s, corpus-seeded)"
    else
      fail "67 mcp_fuzz: $t exited rc=$rc; see $W/$t.run.log"
      tail -5 "$W/$t.run.log" 2>/dev/null | sed 's/^/         /'
    fi
  done
}

# 68 mcp_conformance: the MCP server against the protocol conformance driver
# (mcp/tests/mcp_conformance.py). The driver starts real servers on both
# transports and checks the two protocol eras, the authentication and framing
# rules, the tool catalog's shape, the operator switches and the
# session-state handles.
#
# It needs a live cluster (the read tool is an engine call) and the daemon
# (the config-write checks edit the daemon's own configuration file).
# Gate 69: every vendored reasoning plugin carries its detached signature. The host loads the
# plugin only when <plugin>.sig (exactly 64 raw Ed25519 bytes) sits beside it, so a plugin vendored
# without one (or with a truncated one) would ship a package whose reasoning tier refuses to start.
# Needs no database: it is a static check of include/<platform>/.
gate_69_plugin_sig_vendored() {
  local n=0 bad=0 f
  for f in "$HERE"/include/*/fractalsql-reasoning-http.so "$HERE"/include/*/fractalsql-reasoning-http.dll; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    if [ ! -f "${f}.sig" ] || [ "$(wc -c < "${f}.sig" | tr -d ' ')" -ne 64 ]; then
      printf '      missing or not 64 bytes: %s.sig\n' "${f#"$HERE"/}"; bad=$((bad + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then skip "69 plugin_sig_vendored (no vendored plugins under include/)"; return; fi
  if [ "$bad" -ne 0 ]; then fail "69 plugin_sig_vendored: $bad of $n vendored plugin(s) lack a valid .sig"; return; fi
  pass "69 plugin_sig_vendored: all $n vendored plugins have a 64-byte .sig beside them"
}

# 70 redact_unit: tests/redact_unit.c, the header-level unit test of src/fsql_audit_redact.h (hash and truncate modes, buffer limits, every JSON
# shape the walker handles, malformed documents, escapes with surrogate pairs, allocation failure in the walker). The SQL gates reach that
# code only through the enterprise audit path, so without this its branches are dead in a --coverage run. Built with the sanitizers under
# --asan/--ubsan, and with gcov under --coverage (an object named src/_redact_unit.o, so its counters ADD to the build's).
gate_70_redact_unit() {
  local cc="${FSQL_CC:-cc}"
  command -v "$cc" >/dev/null 2>&1 || { skip "70 redact_unit (no C compiler on PATH)"; return; }
  [[ -f "$HERE/tests/redact_unit.c" ]] || { skip "70 redact_unit (tests/redact_unit.c not present)"; return; }
  local obj="$HERE/src/_redact_unit.o" covflags=() sanflags=()
  [[ "$COVERAGE" -eq 1 ]] && covflags+=(--coverage)
  [[ "$ASAN" -eq 1 ]] && sanflags+=(-fsanitize=address -fno-omit-frame-pointer)
  [[ "$UBSAN" -eq 1 ]] && sanflags+=(-fsanitize=undefined -fno-sanitize-recover=undefined)
  local log="$TMPROOT/fractalsql_bt_redact_unit_build.log" bin="$TMPROOT/fractalsql_bt_redact_unit"
  rm -f "$obj"
  if ! env -u LD_PRELOAD "$cc" -std=c11 -O1 -g -Wno-unused-function ${covflags[@]+"${covflags[@]}"} ${sanflags[@]+"${sanflags[@]}"} \
        -I"$HERE/src" -c "$HERE/tests/redact_unit.c" -o "$obj" >"$log" 2>&1 \
     || ! env -u LD_PRELOAD "$cc" ${covflags[@]+"${covflags[@]}"} ${sanflags[@]+"${sanflags[@]}"} "$obj" -o "$bin" >>"$log" 2>&1; then
    tail -5 "$log" | sed 's/^/         /'; fail "70 redact_unit: the unit test did not build (see $log)"; rm -f "$obj"; return
  fi
  local out rc
  # LeakSanitizer does not exist on macOS: asking for it there makes the ASan runtime itself refuse to start.
  local leaks=1; [[ "$(uname -s)" == Darwin ]] && leaks=0
  out="$(env -u LD_PRELOAD ASAN_OPTIONS=detect_leaks=$leaks "$bin" 2>&1)"; rc=$?
  rm -f "$obj" "$bin"
  if [[ "$COVERAGE" -ne 1 ]]; then rm -f "${obj%.o}.gcno" "${obj%.o}.gcda"; fi
  if [[ $rc -eq 0 ]]; then pass "70 redact_unit: $(tail -1 <<< "$out")"
  else printf '%s\n' "$out" | tail -12 | sed 's/^/         /'; fail "70 redact_unit: see the output above"; fi
}

# 71 ledger_env: the audit-ledger settings read from the SERVER's environment once per process -- the ledger size cap (FRACTALSQL_LEDGER_MAX_BYTES), the
# head anchor log (FSQL_LEDGER_ANCHOR_LOG), audit redaction (FSQL_AUDIT_REDACT), the signature policy (FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE) and the
# temp directory (TMPDIR). Each round restarts the server with a different set and drives the audit and ledger functions with the mock enterprise core
# loaded. Asserts the server survives every round, the chain that was kept verifies, a cap that is hit refuses an append, and an unsigned library is
# refused when a signature is required and loaded when the operator opts out.
gate_71_ledger_env() {
  local tag="${CUR_VER//./_}"
  local mock_so="$TMPROOT/fractalsql_bt_ledger_env_${tag}.so" ledger_path="$HERE/.gate71_ledger.dat" round out out2 alive
  rm -f "$ledger_path" "$mock_so"
  cc -shared -fPIC -std=c99 -I"$HERE/include/$(fsql_ent_platform_dir)" -I"$HERE/include" tests/mock_enterprise_core.c -o "$mock_so" 2>/tmp/fractalsql_bt_gate71_build.log \
    || { cat /tmp/fractalsql_bt_gate71_build.log >&2; fail "71 ledger_env: mock .so failed to build"; return; }
  for round in "FRACTALSQL_LEDGER_MAX_BYTES=300 FSQL_LEDGER_ANCHOR_LOG=stderr FSQL_AUDIT_REDACT=hash FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0" \
               "FRACTALSQL_LEDGER_MAX_BYTES=abc FSQL_LEDGER_ANCHOR_LOG=syslog FSQL_AUDIT_REDACT=truncate FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=1" \
               "FRACTALSQL_LEDGER_MAX_BYTES=0 FSQL_LEDGER_ANCHOR_LOG=bogus FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 TMPDIR=" \
               "FSQL_LEDGER_ANCHOR_LOG=STDERR FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 FRACTALSQL_ENTERPRISE_LEDGER_KEY=gate71-ledger-key" \
               "FSQL_LEDGER_ANCHOR_LOG=Syslog FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 FSQL_AUDIT_REDACT=truncate" \
               "FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 FRACTALSQL_AUDIT_REQUIRE_ACTOR=1"; do
    mdb_teardown >/dev/null 2>&1
    rm -f "$ledger_path"
    export FRACTALSQL_ENTERPRISE_LIB="$mock_so" FRACTALSQL_ENTERPRISE_LEDGER_PATH="$ledger_path"
    local kv; for kv in $round; do export "$kv"; done
    mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
    if [ $? -ne 0 ]; then fail "71 ledger_env [$round]: the server did not start"; for kv in $round; do unset "${kv%%=*}"; done; continue; fi
    out=$("${MARIADB[@]}" 2>&1 <<'SQL'
SELECT IFNULL(fractal_audit_log('env.test', '{"q":"customer secret text","n":1}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('env.test', '{"n":2}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('env.test', '[1,2,3]'), '<NULL>');
SELECT IFNULL(fractal_audit_log('env.test', '{"n":4}', CONNECTION_ID(), 'alice'), '<NULL>');
SELECT IFNULL(fractal_audit_log('env.test', '{"n":5}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('env.test', '{"n":6}'), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), '<NULL>');
SELECT IFNULL(fractal_ledger_flush(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_truth_count(CONNECTION_ID()), '<NULL>');
SQL
)
    case "$round" in
      *AUDIT_REQUIRE_ACTOR=1*)
        # with an actor required, an append that names no session is refused; with one it goes through; and a session under the destructive latch
        # is refused whatever it names
        out2=$("${MARIADB[@]}" 2>&1 <<'SQL'
SELECT IFNULL(fractal_audit_log('a', '{"n":1}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('a', '{"n":2}', CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_audit_log('a', '{"n":3}', CONNECTION_ID(), 'carol'), '<NULL>');
SELECT IFNULL(fractal_audit_log('a', '{"n":4}', NULL, 'carol'), '<NULL>');
SELECT IFNULL(fractal_lock_destructive(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_audit_log('a', '{"n":5}', CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), '<NULL>');
SQL
)
        grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out2" \
          && fail "71 ledger_env: the audit actor requirement or the destructive latch killed the connection -- $out2" \
          || pass "71 ledger_env: an audit append without a session is refused when an actor is required, and a latched session is refused" ;;
      *LEDGER_KEY=*)
        # audit entries of every awkward shape: padded and scalar payloads, a payload that forges the reserved actor key, one past the blob limit,
        # actor labels that are long, quoted, non-ASCII or need escaping past the stack buffer
        out2=$("${MARIADB[@]}" 2>&1 <<'SQL'
SELECT IFNULL(fractal_audit_log('e', '   {"a":1}   '), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '  {}  '), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '"scalar"'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '42'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"_actor":"forged"}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"x":{"_actor":1}}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT('{"p":"', REPEAT('x', 67108900), '"}')), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":1}', CONNECTION_ID(), REPEAT('a', 300)), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":2}', CONNECTION_ID(), 'a"b\\c'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":3}', CONNECTION_ID(), REPEAT('"', 200)), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":4}', CONNECTION_ID(), REPEAT(CHAR(1), 100)), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":5}', CONNECTION_ID(), REPEAT('é', 100)), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":6}', CONNECTION_ID(), ''), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"n":7}', 999999, 'alice'), '<NULL>');
SELECT IFNULL(fractal_audit_log(REPEAT('t', 5000), '{"n":8}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{bad'), '<NULL>');
SELECT IFNULL(fractal_audit_log(CONCAT('t', CHAR(8), CHAR(12), CHAR(10), CHAR(13), CHAR(9), CHAR(1), CHAR(31), '"\\/'), '{}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT(CHAR(9), CHAR(10), '{"a":1}', CHAR(13), CHAR(10))), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT('{', CHAR(9), CHAR(10), CHAR(13), ' }')), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT(' ', CHAR(9), '[1]', CHAR(10))), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1e5}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":-0.5E+3}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":0}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1.}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":01}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":-}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1e}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1e+}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '[1,2,]'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":tru}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":true,"b":false,"c":null}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":"\\u00e9\\n\\t\\"\\\\\\/"}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":"\\u00zz"}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":"\\x"}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '"abc'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '['), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', ']'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":[1,{"b":[2,3]},"x"]}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1}{"b":2}'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', '{"a":1} x'), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', REPEAT('[', 2000)), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT(REPEAT('[', 500), REPEAT(']', 500))), '<NULL>');
SELECT IFNULL(fractal_audit_log('e', CONCAT('{"s":"', CHAR(1), '"}')), '<NULL>');
SELECT LENGTH(IFNULL(fractal_audit_unpack('abc'), '<NULL>'));
SELECT LENGTH(IFNULL(fractal_audit_unpack(REPEAT('x', 30000)), '<NULL>'));
SELECT LENGTH(IFNULL(fractal_audit_unpack(REPEAT('x', 3000000)), '<NULL>'));
SELECT IFNULL(fractal_audit_unpack(''), '<NULL>');
SELECT IFNULL(fractal_audit_unpack(NULL), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 0), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 17), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), -1), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 99), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), NULL), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(NULL), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(999999), '<NULL>');
SELECT IFNULL(fractal_ledger_load(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_load(NULL), '<NULL>');
SELECT IFNULL(fractal_ledger_flush(NULL), '<NULL>');
SELECT IFNULL(fractal_ledger_compact(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_reset_soft(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_truth_count(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_shadow_count(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_reset_hard(CONNECTION_ID()), '<NULL>');
SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), '<NULL>');
SQL
)
        grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out2" \
          && fail "71 ledger_env: an awkward audit payload or actor killed the connection -- $out2" \
          || pass "71 ledger_env: padded, scalar, forged-actor, oversized and awkward-actor audit entries are handled"
        # the head file records how many rows each chain held; every shape of damaged or old-format record must be read without harm
        local hv headf="$ledger_path.head"
        for hv in "2 6" "  2   6  " "2" "2 x" "2 6 junk" "kind=2 rows=6" "kind=2 rows=6 mac=00" "kind=2 rows=6 mac=zz" "kind=x rows=1" "rows=" "kind=" "mac=" "kind=2 rows=6 extra=1" "garbage" "" "kind=2 rows=999999999999"; do
          printf '%s\n' "$hv" > "$headf" 2>/dev/null
          "${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), '<NULL>'); SELECT IFNULL(fractal_audit_log('h', '{\"n\":1}'), '<NULL>');" >/dev/null 2>&1
        done
        # the ledger file itself, damaged in every way a crash or a bad disk can: cut at many lengths (inside the magic, a header, a blob, between
        # records), a bad magic, garbage and zeros appended, unreadable, replaced by a directory. Each damage is followed by every ledger call.
        local dmg fresh_ledger
        fresh_ledger() {
          rm -rf "$ledger_path" "$ledger_path.head" "$ledger_path.head.tmp"
          "${MARIADB[@]}" -N -e "SELECT fractal_audit_log('d','{\"n\":1}'); SELECT fractal_audit_log('d','{\"n\":2}'); SELECT fractal_audit_log('d','{\"n\":3}');" >/dev/null 2>&1
        }
        for dmg in "cut:0" "cut:1" "cut:4" "cut:8" "cut:12" "cut:16" "cut:24" "cut:33" "cut:40" "cut:64" "cut:-1" "cut:-3" "cut:-9" "cut:-40" "magic" "garbage" "zeros" "unreadable" "directory" "magic_only"; do
          fresh_ledger
          case "$dmg" in
            cut:-*) truncate -s "$dmg" "$ledger_path" 2>/dev/null; truncate -s "$(( $(wc -c < "$ledger_path") ))" "$ledger_path" 2>/dev/null ;;
            cut:*)  truncate -s "${dmg#cut:}" "$ledger_path" 2>/dev/null ;;
            magic)  printf 'XXXXXXXXXXXXXXXX' | dd of="$ledger_path" bs=1 conv=notrunc 2>/dev/null ;;
            garbage) printf '\001\002\003\004\005\006\007' >> "$ledger_path" ;;
            zeros)  head -c 200 /dev/zero >> "$ledger_path" ;;
            unreadable) chmod 000 "$ledger_path" ;;
            directory) rm -f "$ledger_path"; mkdir "$ledger_path" ;;
            magic_only) head -c 8 "$ledger_path" > "$ledger_path.keep"; mv "$ledger_path.keep" "$ledger_path" ;;
          esac
          "${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID(), 2), '<NULL>'); SELECT IFNULL(fractal_audit_log('d','{\"n\":9}'), '<NULL>'); SELECT IFNULL(fractal_ledger_flush(CONNECTION_ID()), '<NULL>'); SELECT IFNULL(fractal_ledger_load(CONNECTION_ID()), '<NULL>'); SELECT IFNULL(fractal_ledger_verify(CONNECTION_ID()), '<NULL>'); SELECT IFNULL(fractal_ledger_truth_count(CONNECTION_ID()), '<NULL>');" >/dev/null 2>&1
          [ "$dmg" = "unreadable" ] && chmod 600 "$ledger_path" 2>/dev/null
          [ "$dmg" = "directory" ] && rm -rf "$ledger_path"
        done
        alive=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
        [ "$alive" = "1" ] && pass "71 ledger_env: twenty ways of damaging the ledger file are survived by every ledger call" \
                           || fail "71 ledger_env: the server did not survive the ledger file damage"
        alive=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
        [ "$alive" = "1" ] && pass "71 ledger_env: sixteen shapes of head-file record are read without harm" \
                           || fail "71 ledger_env: the server did not survive the head-file variants" ;;
    esac
    alive=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
    if [ "$alive" != "1" ] || grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out"; then
      fail "71 ledger_env [$round]: the server did not survive -- $out"
    else
      pass "71 ledger_env [$round]: the server survives the audit and ledger calls"
    fi
    case "$round" in
      *REQUIRE_SIGNATURE=1*)
        # verify is community-side, so it still answers; the audit appends are what the enterprise gate refuses (NULL)
        [ "$(grep -c '<NULL>' <<< "$out")" -ge 6 ] \
          && pass "71 ledger_env: an unsigned enterprise library is refused when a signature is required (every audit append is refused)" \
          || fail "71 ledger_env: an unsigned library was used although a signature is required: $out" ;;
      *)
        grep -q '"ok":true' <<< "$out" && pass "71 ledger_env: the chain that was kept verifies" \
          || fail "71 ledger_env [$round]: expected an ok verify, got: $out" ;;
    esac
    for kv in $round; do unset "${kv%%=*}"; done
  done
  unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_LEDGER_PATH
  rm -rf "$ledger_path" "$ledger_path.head" "$ledger_path.head.tmp" "$ledger_path.csv" "$mock_so"
  mdb_teardown >/dev/null 2>&1
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  return 0
}

# 72 allowlist_matrix: fractal_t2s_check_allowlist() against 96 candidate statements (src/fractalsql_textsql.c). The check is deterministic and needs no
# model, so every shape the allowlist has to judge is asserted by category: P pass, E empty, X versioned or optimizer-hint comment, M more than one
# statement, O INTO OUTFILE/DUMPFILE, F a state-changing or outside-reaching function, T a statement type that is not permitted. Covers comments of all
# three kinds (closed, unclosed, trailing), quoting of all three kinds with semicolons inside, case, look-alike keywords, CTEs that write, and statement
# types in select-only mode. Runs in one client session.
# 75 multimodal_edge: the three enterprise portfolio optimizers (fractal_optimize_portfolio_multimodal, _ex and _pareto; src/fractalsql_enterprise.c) with the
# mock enterprise core loaded: ordinary calls, every argument the validation looks at (NULL, empty, malformed or mismatched arrays, a restart count
# below what the core returns, zero and negative counts, unknown diffusion modes), the core failing (the mock's fail sentinel) and the core finding
# nothing (its zero-found file). The server must answer every one; a call the core fails or the arguments refuse returns NULL.
gate_75_multimodal_edge() {
  local tag="${CUR_VER//./_}"
  local mock_so="$TMPROOT/fractalsql_bt_mmedge_${tag}.so" sentinel="$TMPROOT/fractalsql_bt_mmedge_fail_${tag}" zero="$TMPROOT/fractalsql_bt_mmedge_zero_${tag}"
  local sqlf="$TMPROOT/fractalsql_bt_mmedge.sql" out n alive
  rm -f "$mock_so" "$sentinel" "$zero"
  cc -shared -fPIC -std=c99 -I"$HERE/include/$(fsql_ent_platform_dir)" -I"$HERE/include" tests/mock_enterprise_core.c -o "$mock_so" 2>/tmp/fractalsql_bt_gate75_build.log \
    || { cat /tmp/fractalsql_bt_gate75_build.log >&2; fail "75 multimodal_edge: mock .so failed to build"; return; }
  mdb_teardown >/dev/null 2>&1
  export FRACTALSQL_ENTERPRISE_LIB="$mock_so" FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE=0 FSQL_MOCK_ENT_FAIL="$sentinel" FSQL_MOCK_ENT_ZERO_FOUND="$zero"
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1 || { fail "75 multimodal_edge: the server did not start"; unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE FSQL_MOCK_ENT_FAIL FSQL_MOCK_ENT_ZERO_FOUND; mdb_setup "$MDB_MAJOR" >/dev/null 2>&1; return; }
  cat > "$sqlf" <<'SQL'
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 1, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2,3', '1,0,0,0,1,0,0,0,1', 2, 5, 0.9, 0.9, 7);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 0, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', -1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 0, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 99999999, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, -1, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, 0.5, 2, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2,3', '1,0,0,1', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('', '', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('x,y', 'a,b,c,d', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,nan', '1,0,0,1', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal(NULL, '1,0,0,1', 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', NULL, 1, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', NULL, 2, 0.5, 0.5, 42);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1', 1, 2, 0.5, 0.5);
SELECT fractal_optimize_portfolio_multimodal('1,2', '1,0,0,1');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 1, 'levy');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 1, 0.5, 0.5, 42, 1, 'levy');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 0, 'bogus');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 2, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, -1, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, NULL, NULL);
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1', 1, 2, 0.5, 0.5, 42, 0, '');
SELECT fractal_optimize_portfolio_multimodal_ex('1,2', '1,0,0,1');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 1, 1, 1, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 5, 1, 3, 0, 'levy');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2,3', '1,0,0,0,1,0,0,0,1', 2, 5, 0.5, 100, 1, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 1, 1, 0, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 1, 1, -5, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1', 1, 1, 1, 1, 0, 'nope');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0', 1, 1, 1, 1, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto(NULL, NULL, 1, 1, 1, 1, 0, 'gaussian');
SELECT fractal_optimize_portfolio_multimodal_pareto('1,2', '1,0,0,1');
SQL
  n=$(grep -c '^SELECT' "$sqlf")
  out=$("${MARIADB[@]}" --force < "$sqlf" 2>&1)
  grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out" && { fail "75 multimodal_edge: the server dropped the connection on ordinary calls -- $out"; }
  touch "$sentinel"     # the core now fails every call
  out=$("${MARIADB[@]}" --force < "$sqlf" 2>&1)
  grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out" && { fail "75 multimodal_edge: the server dropped the connection while the core was failing -- $out"; }
  rm -f "$sentinel"; touch "$zero"      # the core now finds nothing
  out=$("${MARIADB[@]}" --force < "$sqlf" 2>&1)
  grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out" && { fail "75 multimodal_edge: the server dropped the connection while the core found nothing -- $out"; }
  rm -f "$zero"
  alive=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  [ "$alive" = "1" ] && pass "75 multimodal_edge: the server answered $n optimizer calls three times over (core working, core failing, core finding nothing)" \
                     || fail "75 multimodal_edge: the server did not survive (alive=$alive)"
  unset FRACTALSQL_ENTERPRISE_LIB FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE FSQL_MOCK_ENT_FAIL FSQL_MOCK_ENT_ZERO_FOUND
  rm -f "$sqlf" "$mock_so" "$sentinel" "$zero"
  mdb_teardown >/dev/null 2>&1
  mdb_setup "$MDB_MAJOR" >/dev/null 2>&1
  return 0
}

# 76 enterprise_refusals: every way the enterprise library can be refused, through the daemon's conf file and a reload (src/fractalsql_enterprise.c): a .sig of
# the wrong size (empty, short, long) or that does not verify, a missing .sig with a signature required, a library that cannot be read, one that is a
# directory, a path too long to name its .sig, a library without the core's symbols, a path that does not exist, and the unsigned load the operator
# can opt into. Each is a fresh library path (a failed attempt is cached per path), applied with a reload and followed by a ledger call; the server
# must survive every one and the refused ones must leave the ledger calls answering NULL.
gate_76_enterprise_refusals() {
  local tag="${CUR_VER//./_}" ctl_bin="$HERE/service/build/fsqlctl"
  local d="$TMPROOT/fractalsql_bt_entref_${tag}" mock good nosym i=0 n_ok=0 n_bad=0 got label sigsize req rd conf_keep="$TMPROOT/fractalsql_bt_entref_conf_${tag}"
  rm -rf "$d"; mkdir -p "$d"
  cc -shared -fPIC -std=c99 -I"$HERE/include/$(fsql_ent_platform_dir)" -I"$HERE/include" tests/mock_enterprise_core.c -o "$d/mock.so" 2>/tmp/fractalsql_bt_gate76_build.log \
    || { cat /tmp/fractalsql_bt_gate76_build.log >&2; fail "76 enterprise_refusals: mock .so failed to build"; return; }
  printf 'int fsql_nothing(void){return 0;}\n' > "$d/nosym.c"
  cc -shared -fPIC "$d/nosym.c" -o "$d/nosym.so" 2>/dev/null
  cp "$FSQD_CONF" "$conf_keep"
  # each variant: label|library setup (a shell snippet run with $L as the library path)|signature requirement
  local variants=(
    "sig64zero|cp $d/mock.so \$L; head -c 64 /dev/zero > \$L.sig|0"
    "sig64zero_req|cp $d/mock.so \$L; head -c 64 /dev/zero > \$L.sig|1"
    "sig10|cp $d/mock.so \$L; head -c 10 /dev/zero > \$L.sig|0"
    "sig65|cp $d/mock.so \$L; head -c 65 /dev/zero > \$L.sig|0"
    "sig0|cp $d/mock.so \$L; : > \$L.sig|0"
    "nosig_req|cp $d/mock.so \$L|1"
    "nosig_optout|cp $d/mock.so \$L|0"
    "unreadable_req|cp $d/mock.so \$L; head -c 64 /dev/zero > \$L.sig; chmod 000 \$L|1"
    "unreadable_optout|cp $d/mock.so \$L; head -c 64 /dev/zero > \$L.sig; chmod 000 \$L|0"
    "directory_req|mkdir \$L; head -c 64 /dev/zero > \$L.sig|1"
    "directory_optout|mkdir \$L|0"
    "nosym_optout|cp $d/nosym.so \$L|0"
    "missing_optout|true|0"
    "missing_sig_only|head -c 64 /dev/zero > \$L.sig|1"
  )
  local v
  for v in "${variants[@]}"; do
    i=$((i + 1)); label="${v%%|*}"; v="${v#*|}"; local setup="${v%|*}" req="${v##*|}"
    local L="$d/lib_${i}_${label}.so"
    eval "$setup" 2>/dev/null
    cp "$conf_keep" "$FSQD_CONF"
    printf 'enterprise_lib = %s\nenterprise_require_signature = %s\n' "$L" "$req" >> "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
    rd="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)"
    got="$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_truth_count(CONNECTION_ID()), '<NULL>');" 2>&1)"
    case "$got" in *"ERROR 2013"*|*"ERROR 2006"*|*"gone away"*|*"Lost connection"*) n_bad=$((n_bad + 1)); printf '         %s: the connection dropped (%s)\n' "$label" "${got:0:80}" ;; *) n_ok=$((n_ok + 1)) ;; esac
    chmod 600 "$L" 2>/dev/null; rm -rf "$L" "$L.sig"
  done
  # a path too long to name its .sig
  local longp="$d/$(printf 'q%.0s' $(seq 1 1100)).so"
  cp "$conf_keep" "$FSQD_CONF"; printf 'enterprise_lib = %s\nenterprise_require_signature = 1\n' "$longp" >> "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload >/dev/null 2>&1
  got="$("${MARIADB[@]}" -N -e "SELECT IFNULL(fractal_ledger_truth_count(CONNECTION_ID()), '<NULL>');" 2>&1)"
  case "$got" in *"ERROR 2013"*|*"ERROR 2006"*|*"gone away"*|*"Lost connection"*) n_bad=$((n_bad + 1)) ;; *) n_ok=$((n_ok + 1)) ;; esac
  cp "$conf_keep" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload >/dev/null 2>&1
  got="$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)"
  if [ "$n_bad" -eq 0 ] && [ "$got" = "1" ]; then pass "76 enterprise_refusals: the server survived $n_ok ways of presenting a bad or unusual enterprise library"
  else fail "76 enterprise_refusals: $n_bad of $((n_ok + n_bad)) variants dropped the connection (final probe: $got)"; fi
  rm -rf "$d" "$conf_keep"
}

# 74 udf_inputs: the vector and search UDFs with the inputs their parsers and limit checks have to judge (src/fractalsql.c, fractalsql_cognition.c): number
# tokens in every notation (exponents with and without signs, bare dots, nan/inf, out-of-range exponents, 70-digit tokens), a corpus whose dimension does not
# match the query, a zero-dimension query, option documents with wrong types and out-of-range values, a search whose work limit is exceeded, session ids
# (none, unknown, the connection's own), the diversify and explain calls before and after a search, the partial-failure switch in every spelling, and
# reasoning calls with NULL and over-limit arguments. Statements may succeed or return an error; the assertion is that the server answers every one.
gate_74_udf_inputs() {
  local sqlf="$TMPROOT/fractalsql_bt_udf_inputs.sql" out alive n
  cat > "$sqlf" <<'SQL'
SELECT fractal_search('', '1e5,2E-3,3e+2');
SELECT fractal_search('', '.5,5.,1e,1e+');
SELECT fractal_search('', '-.5e-2,+1');
SELECT fractal_search('', 'nan,inf,-inf');
SELECT fractal_search('', '1e999,1');
SELECT fractal_search('', CONCAT(REPEAT('9', 70), ',1'));
SELECT fractal_search('', CONCAT('1e', REPEAT('9', 70), ',1'));
SELECT fractal_search('', CONCAT('1.', REPEAT('0', 70), '1,1'));
SELECT fractal_search('[[1,2],[3,4]]', '1,2,3', 1, '{}');
SELECT fractal_search('[[1,2],[3,4]]', '1,2', 1, '{}');
SELECT fractal_search('[[1,2],[3]]', '1,2', 1, '{}');
SELECT fractal_search('', '', 1, '{}');
SELECT fractal_search('', ',', 1, '{}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"iterations":10000,"population_size":10000,"diffusion_factor":32}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"iterations":"x"}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"iterations":-1}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"population_size":1e10}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"diffusion_factor":0}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"walk":"a","debug":1}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"debug":true,"iterations":3,"population_size":5}');
SELECT fractal_search('[[1,2]]', '1,2', 1, 'not json');
SELECT fractal_search('[[1,2]]', '1,2', 1, '[1]');
SELECT fractal_search('[[1,2]]', '1,2', 1, NULL);
SELECT fractal_search('[[1,2]]', '1,2', 0, '{}');
SELECT fractal_search('[[1,2]]', '1,2', -1, '{}');
SELECT fractal_search('[[1,2]]', '1,2', 1000000, '{}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"session_id":0,"iterations":3,"population_size":5}');
SELECT fractal_search('[[1,2]]', '1,2', 1, '{"session_id":99999999,"iterations":3,"population_size":5}');
SELECT fractal_explain_result(CONNECTION_ID());
SELECT fractal_diversify_enable(CONNECTION_ID());
SELECT fractal_explain_result(CONNECTION_ID());
SELECT fractal_search('[[1,2],[2,3]]', '1,2', 1, CONCAT('{"session_id":', CONNECTION_ID(), ',"iterations":3,"population_size":5}'));
SELECT fractal_search('[[1,2],[2,3]]', '1,2', 1, CONCAT('{"session_id":', CONNECTION_ID(), ',"iterations":3,"population_size":5}'));
SELECT fractal_explain_result(CONNECTION_ID());
SELECT fractal_detect_collapse(CONNECTION_ID());
SELECT fractal_diversify_disable(CONNECTION_ID());
SELECT fractal_explain_result(CONNECTION_ID());
SELECT fractal_explain_result(NULL);
SELECT fractal_explain_result(99999999);
SELECT fractal_search_debug('');
SELECT fractal_search_debug(',');
SELECT fractal_search_debug('1e5,2E-3');
SELECT fractal_search_debug('1,2', 0, 0, 0, 0);
SELECT fractal_search_debug('1,2', 100000, 100000, 32, 1);
SELECT fractal_search_explore('', '', '{}');
SELECT fractal_search_explore('[[1,2],[3,4]]', '1,2,3', '{}');
SELECT fractal_search_explore('[[1,2],[3,4]]', '1,2', '{"population_size":10000,"iterations":10000}');
SELECT fractal_search_explore('[[1,2],[3,4]]', '1,2', '{"population_size":1}');
SELECT fractal_search_explore('[[1,2],[3,4]]', '1,2', 'x');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'on');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'off');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'ON');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'Off');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), 'x');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), '');
SELECT fractal_agent_partial_fail(NULL, 'on');
SELECT fractal_agent_partial_fail(CONNECTION_ID(), NULL);
SELECT fractal_reason(CONNECTION_ID(), 'q', NULL);
SELECT fractal_reason(CONNECTION_ID(), 'q', '{}');
SELECT fractal_reason(CONNECTION_ID(), 'q', REPEAT('x', 5242880));
SELECT fractal_reason(CONNECTION_ID(), REPEAT('x', 5242880));
SELECT fractal_reason(NULL, 'q');
SELECT fractal_reason(CONNECTION_ID(), NULL);
SELECT fractal_reason(CONNECTION_ID(), '');
SELECT fractal_session_close(CONNECTION_ID());
SELECT fractal_session_close(CONNECTION_ID());
SELECT fractal_session_close(NULL);
SELECT fractal_version(), fractal_edition();
SQL
  n=$(grep -c '^SELECT' "$sqlf")
  out=$("${MARIADB[@]}" --force < "$sqlf" 2>&1)
  alive=$("${MARIADB[@]}" -N -e "SELECT 1;" 2>&1)
  if [ "$alive" = "1" ] && ! grep -qE "ERROR 2013|ERROR 2006|server has gone away|Lost connection" <<< "$out"; then
    pass "74 udf_inputs: the server answered all $n awkward vector, search, diversify and reasoning statements"
  else
    printf '%s\n' "$out" | tail -5 | sed 's/^/         /'; fail "74 udf_inputs: the server did not survive (alive=$alive)"
  fi
  rm -f "$sqlf"
}

# 73 config_matrix: every configuration key through both ways of setting it (src/fractalsql_config.c). Part 1: the SQL functions fractal_config_set / _get
# for all 18 keys with 189 values (accepted, wrong type, out of range, too long, empty, prefixed and upper-cased names, unknown keys), asserted by verdict:
# OK stored, D daemon-wide setting a session may not change, L too long, U unknown key, I not an integer, R out of range, B not a boolean; a stored
# value reads back as it was set. Part 2: the daemon's own conf file, where the daemon-wide keys DO get set -- the path rules (relative, "..", drive
# letter, UNC, root, spaces, empty), the integer, boolean, enum and string keys, unknown keys and malformed lines -- each applied with a reload; the
# daemon must keep answering and the conf is put back.
gate_73_config_matrix() {
  local sqlf="$TMPROOT/fractalsql_bt_cfg_matrix.sql" outf="$TMPROOT/fractalsql_bt_cfg_matrix.out" kind name val i=0 bad=0 n=0 got want rowsv
  # The heredoc is read straight into the variable: wrapped in $(...), bash 3.2 (macOS) mis-tracks the quotes in rows like SELECT 'unterminated.
  IFS= read -r -d '' rowsv <<'ROWS' || true
D	reasoning_plugin	/opt/fsql/x.so
D	reasoning_plugin	rel/x.so
D	reasoning_plugin	/a/../b.so
D	reasoning_plugin	C:\\x\\y.so
D	reasoning_plugin	\\\\srv\\sh\\f.dll
D	reasoning_plugin	/
D	reasoning_plugin	@P5000@
D	reasoning_plugin	
D	fractalsql.reasoning_plugin	/opt/fsql/x.so
U	REASONING_PLUGIN	/opt/fsql/x.so
D	reasoning_url	value-1
D	reasoning_url	
L	reasoning_url	@X9000@
D	reasoning_url	with space
D	reasoning_url	ünï
D	reasoning_url	a\nb
D	fractalsql.reasoning_url	value-1
U	REASONING_URL	value-1
D	reasoning_token	value-1
D	reasoning_token	
L	reasoning_token	@X9000@
D	reasoning_token	with space
D	reasoning_token	ünï
D	reasoning_token	a\nb
D	fractalsql.reasoning_token	value-1
U	REASONING_TOKEN	value-1
OK	reasoning_model	value-1
OK	reasoning_model	
L	reasoning_model	@X9000@
OK	reasoning_model	with space
OK	reasoning_model	ünï
OK	reasoning_model	a\nb
OK	fractalsql.reasoning_model	value-1
U	REASONING_MODEL	value-1
D	reasoning_allow_plaintext	1
D	reasoning_allow_plaintext	true
D	reasoning_allow_plaintext	on
D	reasoning_allow_plaintext	yes
D	reasoning_allow_plaintext	0
D	reasoning_allow_plaintext	false
D	reasoning_allow_plaintext	off
D	reasoning_allow_plaintext	no
D	reasoning_allow_plaintext	
D	reasoning_allow_plaintext	maybe
D	reasoning_allow_plaintext	TRUE
D	reasoning_allow_plaintext	2
D	fractalsql.reasoning_allow_plaintext	1
U	REASONING_ALLOW_PLAINTEXT	1
D	embed_url	value-1
D	embed_url	
L	embed_url	@X9000@
D	embed_url	with space
D	embed_url	ünï
D	embed_url	a\nb
D	fractalsql.embed_url	value-1
U	EMBED_URL	value-1
OK	embed_model	value-1
OK	embed_model	
L	embed_model	@X9000@
OK	embed_model	with space
OK	embed_model	ünï
OK	embed_model	a\nb
OK	fractalsql.embed_model	value-1
U	EMBED_MODEL	value-1
OK	think	value-1
OK	think	
L	think	@X9000@
OK	think	with space
OK	think	ünï
OK	think	a\nb
OK	fractalsql.think	value-1
U	THINK	value-1
D	think_provider	value-1
D	think_provider	
L	think_provider	@X9000@
D	think_provider	with space
D	think_provider	ünï
D	think_provider	a\nb
D	fractalsql.think_provider	value-1
U	THINK_PROVIDER	value-1
D	think_native_url	value-1
D	think_native_url	
L	think_native_url	@X9000@
D	think_native_url	with space
D	think_native_url	ünï
D	think_native_url	a\nb
D	fractalsql.think_native_url	value-1
U	THINK_NATIVE_URL	value-1
OK	think_num_ctx	5
OK	think_num_ctx	1
OK	think_num_ctx	10
R	think_num_ctx	0
OK	think_num_ctx	11
R	think_num_ctx	-1
I	think_num_ctx	abc
I	think_num_ctx	12x
R	think_num_ctx	99999999999
OK	think_num_ctx	
I	think_num_ctx	3.5
OK	think_num_ctx	10000000
R	think_num_ctx	10000001
OK	fractalsql.think_num_ctx	5
U	THINK_NUM_CTX	5
OK	t2s_max_attempts	5
OK	t2s_max_attempts	1
OK	t2s_max_attempts	10
R	t2s_max_attempts	0
R	t2s_max_attempts	11
R	t2s_max_attempts	-1
I	t2s_max_attempts	abc
I	t2s_max_attempts	12x
R	t2s_max_attempts	99999999999
OK	t2s_max_attempts	
I	t2s_max_attempts	3.5
R	t2s_max_attempts	10000000
R	t2s_max_attempts	10000001
OK	fractalsql.t2s_max_attempts	5
U	T2S_MAX_ATTEMPTS	5
D	t2s_allowed_statements	select
D	t2s_allowed_statements	select_insert_update
D	t2s_allowed_statements	delete
D	t2s_allowed_statements	SELECT
D	t2s_allowed_statements	
D	t2s_allowed_statements	
D	fractalsql.t2s_allowed_statements	select
U	T2S_ALLOWED_STATEMENTS	select
OK	t2s_use_review	1
OK	t2s_use_review	true
OK	t2s_use_review	on
OK	t2s_use_review	yes
OK	t2s_use_review	0
OK	t2s_use_review	false
OK	t2s_use_review	off
OK	t2s_use_review	no
OK	t2s_use_review	
B	t2s_use_review	maybe
B	t2s_use_review	TRUE
B	t2s_use_review	2
OK	fractalsql.t2s_use_review	1
U	T2S_USE_REVIEW	1
D	enterprise_lib	/opt/fsql/x.so
D	enterprise_lib	rel/x.so
D	enterprise_lib	/a/../b.so
D	enterprise_lib	C:\\x\\y.so
D	enterprise_lib	\\\\srv\\sh\\f.dll
D	enterprise_lib	/
D	enterprise_lib	@P5000@
D	enterprise_lib	
D	fractalsql.enterprise_lib	/opt/fsql/x.so
U	ENTERPRISE_LIB	/opt/fsql/x.so
D	enterprise_ledger_path	/opt/fsql/x.so
D	enterprise_ledger_path	rel/x.so
D	enterprise_ledger_path	/a/../b.so
D	enterprise_ledger_path	C:\\x\\y.so
D	enterprise_ledger_path	\\\\srv\\sh\\f.dll
D	enterprise_ledger_path	/
D	enterprise_ledger_path	@P5000@
D	enterprise_ledger_path	
D	fractalsql.enterprise_ledger_path	/opt/fsql/x.so
U	ENTERPRISE_LEDGER_PATH	/opt/fsql/x.so
D	enterprise_ledger_key	value-1
D	enterprise_ledger_key	
L	enterprise_ledger_key	@X9000@
D	enterprise_ledger_key	with space
D	enterprise_ledger_key	ünï
D	enterprise_ledger_key	a\nb
D	fractalsql.enterprise_ledger_key	value-1
U	ENTERPRISE_LEDGER_KEY	value-1
D	enterprise_require_signature	1
D	enterprise_require_signature	true
D	enterprise_require_signature	on
D	enterprise_require_signature	yes
D	enterprise_require_signature	0
D	enterprise_require_signature	false
D	enterprise_require_signature	off
D	enterprise_require_signature	no
D	enterprise_require_signature	
D	enterprise_require_signature	maybe
D	enterprise_require_signature	TRUE
D	enterprise_require_signature	2
D	fractalsql.enterprise_require_signature	1
U	ENTERPRISE_REQUIRE_SIGNATURE	1
U	nope	1
U		1
L	@X300@	1
U	fractalsql.	1
U	fractalsql.nope	1
U	reasoning_plugin 	1
U	a;b	1
ROWS
  rowsv="${rowsv%$'\n'}"
  _cfg_expand() { case "$1" in @X9000@) printf 'x%.0s' $(seq 1 9000) ;; @P5000@) printf '/'; printf 'p%.0s' $(seq 1 5000) ;; @X300@) printf 'x%.0s' $(seq 1 300) ;; *) printf '%s' "$1" ;; esac; }
  : > "$sqlf"
  while IFS=$'\t' read -r kind name val; do
    i=$((i + 1)); name="$(_cfg_expand "$name")"; val="$(_cfg_expand "$val")"
    printf "SELECT %d, IFNULL(fractal_config_set('%s', '%s', CONNECTION_ID()), '<NULL>'), IFNULL(fractal_config_get('%s', CONNECTION_ID()), '<NULL>');\n" \
      "$i" "$(printf '%s' "$name" | sed "s/'/''/g")" "$(printf '%s' "$val" | sed "s/'/''/g")" "$(printf '%s' "$name" | sed "s/'/''/g")" >> "$sqlf"
  done <<< "$rowsv"
  "${MARIADB[@]}" -N < "$sqlf" > "$outf" 2>&1
  i=0
  while IFS=$'\t' read -r kind name val; do
    i=$((i + 1)); n=$((n + 1))
    got="$(awk -F'\t' -v id="$i" '$1 == id { print $2 "\t" $3 }' "$outf" | head -1)"
    case "$kind" in
      OK) want="ok" ;; D) want="daemon-wide setting" ;; L) want="too long" ;; U) want="unknown configuration key" ;;
      I) want="expects an integer" ;; R) want="must be" ;; B) want="expects true/false" ;;
    esac
    case "$got" in *"$want"*) ;; *) bad=$((bad + 1)); [ "$bad" -le 6 ] && printf '         %s %s=%s -> %s\n' "$kind" "$name" "${val:0:30}" "${got:0:80}" ;; esac
    if [ "$kind" = "OK" ] && [ -n "$val" ] && [ "${val#*\\}" = "$val" ] && [ "${val#*é}" = "$val" ]; then
      case "$got" in *$'\t'"$val") ;; *) bad=$((bad + 1)); [ "$bad" -le 6 ] && printf '         read-back %s=%s -> %s\n' "$name" "$val" "${got:0:80}" ;; esac
    fi
  done <<< "$rowsv"
  if [ "$bad" -eq 0 ]; then pass "73 config_matrix: all $n session-side settings got the verdict the key table specifies, and stored values read back"
  else fail "73 config_matrix: $bad of $n settings did not (first ones above)"; fi

  # Part 2: the conf file
  local ctl_bin="$HERE/service/build/fsqlctl" conf_keep="$TMPROOT/fractalsql_bt_cfg_matrix.conf.keep" line alive rd cb=0 cn=0
  cp "$FSQD_CONF" "$conf_keep"
  while IFS= read -r line; do
    cn=$((cn + 1))
    cp "$conf_keep" "$FSQD_CONF"
    printf '%b\n' "$line" >> "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
    rd="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)"
    alive="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" ping 2>&1)"
    case "$alive" in *pong*|*ok*|*alive*) ;; *) cb=$((cb + 1)); [ "$cb" -le 4 ] && printf '         daemon stopped answering after: %s (reload said: %s; ping said: %s)\n' "$line" "${rd:0:60}" "${alive:0:60}" ;; esac
  done <<'CONFS'
reasoning_plugin = /abs/ok.so
reasoning_plugin = rel/x.so
reasoning_plugin = /a/../b.so
reasoning_plugin = C:\\x\\y.so
reasoning_plugin = C:/x/y.so
reasoning_plugin = \\\\srv\\sh\\f.dll
reasoning_plugin = \\rooted\\path.dll
reasoning_plugin = /
reasoning_plugin = /with space/x.so
reasoning_plugin =
enterprise_lib = /abs/missing.so
enterprise_lib = rel/x.so
enterprise_lib = /a/../b.so
enterprise_lib = C:\\x\\y.dll
enterprise_ledger_path = /tmp/fsql_cfg_matrix_ledger.dat
enterprise_ledger_path = rel/ledger
enterprise_ledger_path = /a/../ledger
enterprise_ledger_key = k
enterprise_ledger_key =
enterprise_require_signature = 1
enterprise_require_signature = maybe
enterprise_require_signature = 0
reasoning_allow_plaintext = true
reasoning_allow_plaintext = maybe
reasoning_url = https://example.test/v1
reasoning_url = http://example.test/v1
embed_url = https://example.test/v1/embeddings
think_native_url = http://127.0.0.1:11434
think_provider = ollama
think_provider = bogus
think_num_ctx = 4096
think_num_ctx = 0
think_num_ctx = abc
think_num_ctx = 99999999999
t2s_max_attempts = 5
t2s_max_attempts = 0
t2s_max_attempts = 11
t2s_max_attempts = x
t2s_allowed_statements = select_insert_update
t2s_allowed_statements = select
t2s_allowed_statements = delete
t2s_use_review = 1
t2s_use_review = maybe
reasoning_model = m
reasoning_token = t
embed_model = e
think = high
bogus_key = 1
no equals sign here
= novalue
reasoning_model = a\nreasoning_model = b
# a comment line
   reasoning_model   =   spaced   
reasoning_model=nospace
reasoning_plugin = /a/one.so\nreasoning_plugin = /a/two.so\nreasoning_url = https://a.test/1\nreasoning_url = https://a.test/2\nreasoning_token = t1\nreasoning_token = t2\nembed_url = https://e.test/1\nembed_url = https://e.test/2\nembed_model = m1\nembed_model = m2\nthink_provider = ollama\nthink_provider = openai\nthink_native_url = http://127.0.0.1:1\nthink_native_url = http://127.0.0.1:2\nt2s_allowed_statements = select\nt2s_allowed_statements = select_insert_update\nenterprise_lib = /a/e1.so\nenterprise_lib = /a/e2.so\nenterprise_ledger_path = /tmp/l1\nenterprise_ledger_path = /tmp/l2\nenterprise_ledger_key = k1\nenterprise_ledger_key = k2\nsocket_path = /tmp/fsql_cfg_matrix_other.sock\nlog_path = /tmp/fsql_cfg_matrix.log
CONFS
  # a conf file or a key file that other users can read is refused (the daemon holds a secret): both modes, then put back
  chmod 644 "$FSQD_CONF"
  rd="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)"
  alive="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" ping 2>&1)"
  case "$alive" in *pong*|*ok*|*alive*) ;; *) cb=$((cb + 1)); printf '         the daemon stopped answering with a world-readable conf (reload said: %s)\n' "${rd:0:80}" ;; esac
  cp "$conf_keep" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  chmod 644 "$FSQD_KEY"
  rd="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload 2>&1)"
  alive="$(FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" ping 2>&1)"
  case "$alive" in *pong*|*ok*|*alive*) ;; *) cb=$((cb + 1)); printf '         the daemon stopped answering with a world-readable key file (reload said: %s)\n' "${rd:0:80}" ;; esac
  chmod 600 "$FSQD_KEY"
  cn=$((cn + 2))
  cp "$conf_keep" "$FSQD_CONF"; chmod 600 "$FSQD_CONF"
  FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$FSQD_KEY" "$ctl_bin" reload >/dev/null 2>&1
  rm -f "$sqlf" "$outf" "$conf_keep"
  if [ "$cb" -eq 0 ]; then pass "73 config_matrix: the daemon kept answering through $cn conf-file variants (paths of every shape, every key type, unknown keys, malformed lines)"
  else fail "73 config_matrix: the daemon stopped answering after $cb of $cn conf-file variants"; fi
}

gate_72_allowlist_matrix() {
  local sqlf="$TMPROOT/fractalsql_bt_allowlist_matrix.sql" outf="$TMPROOT/fractalsql_bt_allowlist_matrix.out" kind cand i=0 bad=0 got want n=0
  : > "$sqlf"
  # The heredoc is read straight into the variable: wrapped in $(...), bash 3.2 (macOS) mis-tracks the quotes in rows like SELECT 'unterminated.
  local rows; IFS= read -r -d '' rows <<'ROWS' || true
P	SELECT 1
P	select * from bt_customers where id = 1
P	WITH x AS (SELECT 1) SELECT * FROM x
P	SELECT 1;
P	SELECT 1; 
P	-- c\nSELECT 1
P	# c\nSELECT 1
P	/* c */ SELECT 1
P	SELECT /* c */ 1
E	/* never closed SELECT 1
E	-- only a comment
P	SELECT 1 -- trailing
P	SELECT 1 # trailing
X	/*! SELECT 1 */
X	/*!50000 SELECT 1 */
X	/*+ HINT */ SELECT 1
X	SELECT /*! 1 */ 1
X	SELECT /*+ MAX_EXECUTION_TIME(1) */ 1
M	SELECT 1; SELECT 2
M	SELECT 1; DROP TABLE bt_customers
P	SELECT 'a;b'
P	SELECT "a;b"
P	SELECT `a;b` FROM bt_customers
P	SELECT 'it''s'
M	SELECT 'a\\'' ; DROP TABLE x; -- '
O	SELECT 1 INTO OUTFILE '/tmp/x'
O	SELECT 1 INTO DUMPFILE '/tmp/x'
P	SELECT 1 INTO @v
O	select * from bt_customers into outfile '/tmp/y'
P	SELECT 'into outfile' AS s
F	SELECT LOAD_FILE('/etc/passwd')
F	SELECT SLEEP(5)
F	SELECT BENCHMARK(1000000, MD5('a'))
T	DO SLEEP(1)
T	SET @a = 1
T	CALL some_proc()
T	INSERT INTO bt_customers (name) VALUES ('x')
T	UPDATE bt_customers SET name = 'x'
T	DELETE FROM bt_customers
T	REPLACE INTO bt_customers (id) VALUES (1)
T	DROP TABLE bt_customers
T	TRUNCATE TABLE bt_customers
T	CREATE TABLE t (a INT)
T	ALTER TABLE bt_customers ADD COLUMN z INT
T	SHOW TABLES
T	EXPLAIN SELECT 1
T	DESCRIBE bt_customers
T	USE mysql
T	GRANT ALL ON *.* TO 'x'@'%'
T	LOCK TABLES bt_customers READ
T	HANDLER bt_customers OPEN
T	LOAD DATA INFILE '/etc/passwd' INTO TABLE bt_customers
T	PREPARE s FROM 'SELECT 1'
T	EXECUTE s
T	BEGIN
T	COMMIT
T	KILL 1
T	FLUSH TABLES
T	`SELECT` 1
T	"SELECT" 1
P	(SELECT 1)
P	(SELECT 1) UNION (SELECT 2)
P	SELECT 1 UNION SELECT 2
P	SELECT * FROM bt_customers FOR UPDATE
P	SELECT * FROM bt_customers LOCK IN SHARE MODE
F	SELECT GET_LOCK('x', 1)
P	SELECT @@version
P	SELECT user()
P	SELECT * FROM information_schema.tables
P	SELECT * FROM mysql.user
P	  \n\t SELECT 1
P	SELECT\n1
P	sElEcT 1
T	SELECTED 1
T	SELECT1
T	123 not a keyword
E	;
E	;;
P	SELECT 1;;
P	SELECT 1 ; -- x
P	SELECT '\0'
P	SELECT 0x41
P	SELECT * FROM (SELECT 1) t
P	WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<3) SELECT * FROM n
T	WITH x AS (SELECT 1) DELETE FROM bt_customers
T	WITH x AS (SELECT 1) INSERT INTO bt_customers SELECT * FROM x
P	SELECT 1 FROM DUAL
P	SELECT SQL_NO_CACHE 1
P	SELECT 'unterminated
P	SELECT "unterminated
P	SELECT `unterminated
P	SELECT 1 /* x */ ; /* y */
P	SELECT 1; /* only a comment after */
P	SELECT 1; -- comment after
P	SELECT 1; # comment after
M	SELECT 1;\nSELECT 2
ROWS
  rows="${rows%$'\n'}"
  while IFS=$'\t' read -r kind cand; do
    i=$((i + 1))
    printf "SELECT %d, IFNULL(fractal_t2s_check_allowlist('%s'), '<PASS>');\n" "$i" "$(printf '%s' "$cand" | sed "s/'/''/g")" >> "$sqlf"
  done <<< "$rows"
  "${MARIADB[@]}" -N < "$sqlf" > "$outf" 2>&1
  i=0
  while IFS=$'\t' read -r kind cand; do
    i=$((i + 1)); n=$((n + 1))
    got="$(awk -F'\t' -v id="$i" '$1 == id { print $2 }' "$outf" | head -1)"
    case "$kind" in
      P) want="<PASS>" ;;
      E) want="SQL is empty" ;;
      X) want="versioned (slash-star-bang)" ;;
      M) want="expected exactly one SQL statement" ;;
      O) want="INTO OUTFILE/DUMPFILE" ;;
      F) want="a function that changes state" ;;
      T) want="is not permitted" ;;
    esac
    case "$got" in
      *"$want"*) ;;
      *) bad=$((bad + 1)); [ "$bad" -le 6 ] && printf '         %s: %q -> %s\n' "$kind" "$cand" "${got:-<no answer>}" ;;
    esac
  done <<< "$rows"
  if [ "$bad" -eq 0 ]; then pass "72 allowlist_matrix: all $n candidate statements got the verdict the allowlist is specified to give"
  else fail "72 allowlist_matrix: $bad of $n candidates got a different verdict (first ones above)"; fi
  rm -f "$sqlf" "$outf"
}

gate_68_mcp_conformance() {
  if [[ ! -f "$HERE/mcp/tests/mcp_conformance.py" || ! -f "$HERE/mcp/src/main.cpp" ]]; then
    skip "68 mcp_conformance (mcp/ server code not present)"; return
  fi
  local mcp_py; mcp_py="$(mcp_python)"
  if [[ -z "$mcp_py" ]]; then
    skip "68 mcp_conformance (no python3 on PATH -- the conformance driver needs it)"; return
  fi
  # The server refuses to start without its two lock files, so a tree
  # without them cannot run this gate at all.
  local missing=""
  for lock_name in .mcp-schema-lock .mcp-safety-annotations-lock; do
    [[ -f "$HERE/mcp/$lock_name" ]] || missing="$missing $lock_name"
  done
  if [[ -n "$missing" ]]; then
    skip "68 mcp_conformance (missing lock file(s):$missing)"; return
  fi
  local mcp_exe mcp_why
  mcp_exe="$(mcp_resolve_exe 2>"$TMPROOT/fractalsql_bt_mcp_exe_why.txt")" \
    || { mcp_why="$(cat "$TMPROOT/fractalsql_bt_mcp_exe_why.txt" 2>/dev/null)"; skip "68 mcp_conformance ($mcp_why)"; return; }
  local W="$TMPROOT/fractalsql_bt_mcp_conformance_${CUR_VER//./_}"
  rm -rf "$W"; mkdir -p "$W"

  # The server looks for its two lock files beside the executable when no
  # path is configured, and that is what lets it start from any working
  # directory. The POSIX build's exe already sits in mcp/, where the locks
  # live, so that copy is skipped rather than made onto itself.
  local exe_dir; exe_dir="$(dirname "$mcp_exe")"
  for lock_name in .mcp-schema-lock .mcp-safety-annotations-lock; do
    if [[ -f "$HERE/mcp/$lock_name" && "$HERE/mcp/$lock_name" != "$exe_dir/$lock_name" ]]; then
      cp -f "$HERE/mcp/$lock_name" "$exe_dir/$lock_name" 2>/dev/null || true
    fi
  done

  # The config-write checks edit the daemon's configuration file and ask the
  # daemon to reload it. The driver gets a COPY of that file, so a test
  # never edits the configuration the running daemon was started with.
  local conf_copy="$W/fractalsqld.conf"
  if [[ -f "$FSQD_CONF" ]]; then cp -f "$FSQD_CONF" "$conf_copy" 2>/dev/null || true; fi
  [[ -f "$conf_copy" ]] || : > "$conf_copy"

  local out="$W/conformance.log"
  local runner=("$mcp_py" -u "$HERE/mcp/tests/mcp_conformance.py")
  if [ -n "$BT_TIMEOUT_BIN" ]; then runner=("$BT_TIMEOUT_BIN" 600 "${runner[@]}"); fi
  MCP_SERVER_EXE="$mcp_exe" \
  MCP_SERVER_CWD="$W" \
  MCPC_TOKEN="conformance-token" \
  MCPC_GATE=68 \
  MCPC_LOCK_DIR="$HERE/mcp" \
  MCPC_PASSTHROUGH_ENV="MARIADB_HOST,MARIADB_PORT,MARIADB_DATABASE,MARIADB_USER,MARIADB_PASSWORD,FSQLCTL_SOCKET,FSQLCTL_KEY,FSQLCTL_CONF" \
  MCPC_READ_TOOL="fractal_version" \
  MCPC_READ_ARGS='{}' \
  MCPC_STATE_TOOL="fractal_diversify_enable" \
  MCPC_STATE_ARGS='{}' \
  MCPC_STATE_READER="fractal_explain_result" \
  MCPC_DESTRUCTIVE_TOOL="fractal_diversify_enable" \
  MCPC_DESTRUCTIVE_ARGS='{}' \
  MCPC_SAFE_KEY="reasoning_model" \
  MCPC_UNSAFE_KEY="reasoning_url" \
  MARIADB_HOST="127.0.0.1" \
  MARIADB_PORT="$PORT" \
  MARIADB_DATABASE="fractalsql_bt" \
  MARIADB_USER="root" \
  MARIADB_PASSWORD="" \
  FSQLCTL_SOCKET="$FSQD_SOCK" \
  FSQLCTL_KEY="$FSQD_KEY" \
  FSQLCTL_CONF="$conf_copy" \
    "${runner[@]}" >"$out" 2>&1
  local rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q "ALL GREEN" "$out"; then
    pass "68 mcp_conformance: protocol eras, authentication, framing, operator switches and catalog conformance"
  else
    # The driver's own failure lines, not the server's log: they say which
    # rule was broken and what was seen instead.
    grep -E '^(FAIL|SKIP) ' "$out" | sed 's/^/         /' || true
    fail "68 mcp_conformance: the conformance driver reported failures (see $out)"
  fi
  rm -rf "$W"
}

run_major() {
  local v="$1"; shift
  local gates=("$@")
  printf "== MariaDB %s ==\n" "$v"

  for g in "${gates[@]}"; do [ "$g" = "01" ] && gate_01_build; done
  # No gate 01 in this run, so service/ is whatever an earlier run left: make sure it is the flavor asked for.
  case " ${gates[*]} " in *" 01 "*) ;; *) ensure_service_flavor ;; esac
  # Gate 30 (fuzz smoke) is standalone like gate 01 -- links
  # src/fractalsql_parse.c + src/fractalsql_interrupt.c directly, no
  # extension .so, no mariadbd, no cluster at all. Gate 41 (the parser
  # probe) is standalone for the same reason: it links the same
  # parser TU with its own test driver and needs nothing but a C
  # compiler.
  for g in "${gates[@]}"; do
    [ "$g" = "30" ] && gate_30_fuzz_smoke
    [ "$g" = "67" ] && gate_67_mcp_fuzz
    [ "$g" = "41" ] && gate_41_parse_probe
    # Gate 46 (the TSan ledger-concurrency runner) is standalone like
    # gates 30 and 41: it links its own binary and needs no cluster,
    # no daemon and no MariaDB -- only the instrumented adapter
    # objects, which gate 01 has already built.
    [ "$g" = "46" ] && gate_46_ledger_tsan_concurrent
    [ "$g" = "63" ] && gate_63_direct_calls
    [ "$g" = "64" ] && gate_64_direct_faults
    [ "$g" = "69" ] && gate_69_plugin_sig_vendored
    [ "$g" = "70" ] && gate_70_redact_unit
  done

  local need_db=0
  for g in "${gates[@]}"; do
    case "$g" in 02|03|04|05|06|07|08|10|11|12|13|14|15|16|17|18|19|20|21|22|23|24|25|26|27|28|29|31|32|33|34|35|36|37|38|39|40|42|43|44|45|47|48|49|50|51|52|53|54|55|56|57|58|59|60|61|62|65|66|68|71|72|73|74|75|76) need_db=1 ;; esac
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
        71) gate_71_ledger_env ;;
        72) gate_72_allowlist_matrix ;;
        73) gate_73_config_matrix ;;
        74) gate_74_udf_inputs ;;
        75) gate_75_multimodal_edge ;;
        76) gate_76_enterprise_refusals ;;
        36) gate_36_morphology_metrics ;;
        37) gate_37_oom_injection ;;
        38) gate_38_fatal_signal ;;
        39) gate_39_mcp_smoke ;;
        40) gate_40_mcp_https ;;
        42) gate_42_vectors_probe ;;
        43) gate_43_db_probe ;;
        44) gate_44_concurrency_probe ;;
        45) gate_45_domain_agents ;;
        47) gate_47_ledger_chain ;;
        48) gate_48_t2s_review_isolation ;;
        49) gate_49_config_overlay ;;
        50) gate_50_kits ;;
        51) gate_51_udf_sweeps ;;
        52) gate_52_validators ;;
        53) gate_53_daemon_frames ;;
        54) gate_54_daemon_conf_boot ;;
        55) gate_55_ledger_forged ;;
        56) gate_56_ledger_files ;;
        57) gate_57_fault_sweeps ;;
        58) gate_58_enterprise_loading ;;
        59) gate_59_provider_reload ;;
        60) gate_60_scripted_replies ;;
        61) gate_61_daemon_limits ;;
        62) gate_62_provider_env ;;
        65) gate_65_mcp_faults ;;
        66) gate_66_mcp_cli ;;
        68) gate_68_mcp_conformance ;;
      esac
    done
    mdb_teardown
  fi
}

# The --tsan-only gates are appended to the run when the run is
# instrumented. They are deliberately NOT in DEFAULT_GATES: an
# uninstrumented build cannot observe a race, so running them anyway
# would report a meaningless "no race found" every time. The
# ${arr[@]+"${arr[@]}"} form is the safe expansion of a possibly-empty
# array under `set -u` on bash 3.2 (macOS's system bash), where a bare
# "${arr[@]}" on an empty array is an "unbound variable" error.
TSAN_EXTRA=()
if [ "$TSAN" -eq 1 ]; then TSAN_EXTRA=("${TSAN_GATES[@]}"); fi

if [ "$ONE_GATE" = "mcp" ]; then
  # Only the MCP server gates. Gate 01 first: they drive the freshly built
  # daemon, and a sanitized or coverage run needs it rebuilt in that mode.
  MCP_GATES=(01 39 40 42 43 44 66 68)
  [ "$MODE" = "fault" ] && MCP_GATES+=(65)
  run_major "$MDB_MAJOR" "${MCP_GATES[@]}"
elif [ -n "$ONE_GATE" ]; then
  run_major "$MDB_MAJOR" "$ONE_GATE"
elif [ "$MODE" = "quick" ]; then
  run_major "$MDB_MAJOR" "${QUICK_GATES[@]}" ${TSAN_EXTRA[@]+"${TSAN_EXTRA[@]}"}
elif [ "$MODE" = "cross" ]; then
  for v in 10.6 10.11 11.4 12.3; do run_major "$v" "${DEFAULT_GATES[@]}"; done
elif [ "$MODE" = "fuzz" ]; then
  run_major "$MDB_MAJOR" "${FUZZ_GATES[@]}" ${TSAN_EXTRA[@]+"${TSAN_EXTRA[@]}"}
elif [ "$MODE" = "fault" ]; then
  run_major "$MDB_MAJOR" "${DEFAULT_GATES[@]}" "${FAULT_GATES[@]}"
else
  run_major "$MDB_MAJOR" "${DEFAULT_GATES[@]}" ${TSAN_EXTRA[@]+"${TSAN_EXTRA[@]}"}
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
