#!/usr/bin/env bash
# tests/valgrind_run.sh -- build_test.sh --profile: valgrind memcheck over the UDF shim, the fractalsqld daemon and the MCP server
# (Linux only).
#
# What it adds to the sanitizer cells: uninitialised reads and leaks (the sanitizer runs set detect_leaks=0) on the unmodified
# builds. The engine runs in the daemon (fractalsqld); the server-side shim (fractalsql.so, loaded as a UDF library into mariadbd)
# talks to it over a Unix socket, so both are put under valgrind.
#
# (mariadbd runs with --innodb-use-native-aio=0: InnoDB's io_uring path hangs under valgrind.)
#
# Targets:
#   units    tests/parse_csv_probe.c and the three pure-C fuzz corpora (parse_vector_csv, parse_index_csv, parse_corpus) replayed
#            with mutations; -O0 -g
#   engine   a throwaway MariaDB datadir; mariadbd under valgrind with the shim in its plugin dir, fractalsqld under valgrind with
#            the vendored HTTP reasoning plugin and the mock LLM; sql/install_udf.sql and install_agents.sql; every
#            demo/demo-vertical-*.sql kit through the mariadb client
#   mcp      the MCP server's own code (mcp/src, C++): vectors_probe, concurrency_probe, db_probe (DB-less)
#   server   the running MCP server under valgrind (a wrapper script starts it), driven by mcp/tests/mcp_smoke_client.py against
#            the valgrind'd mariadbd and daemon
#
# Verdict (tests/valgrind_check.py): FAIL on any memcheck error or definite/indirect leak whose stack has a frame in our code (the
# shim, the daemon, the vendored plugin, a probe, the MCP server binary); mariadbd's own reports and possible leaks are counted,
# not failed. SKIP (exit 0) when not on Linux or valgrind / mariadbd / the built shim and daemon are missing.
#
# Env: MDB_BINDIR (default: mariadbd on PATH), PROFILE_KEEP=1 keeps the logs directory, PROFILE_ONLY=units|engine|mcp|server.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"
say() { printf '\n== profile: %s\n' "$*"; }
[ "$(uname -s)" = Linux ] || { echo "  SKIP profile: valgrind runs on Linux only"; exit 0; }
command -v valgrind >/dev/null 2>&1 || { echo "  SKIP profile: valgrind is not installed"; exit 0; }
pick() { local n; for n in "$@"; do if [ -n "${MDB_BINDIR:-}" ] && [ -x "$MDB_BINDIR/$n" ]; then echo "$MDB_BINDIR/$n"; return; fi; command -v "$n" && return; done; }
MARIADBD="$(pick mariadbd mysqld)"; CLIENT="$(pick mariadb mysql)"; ADMIN="$(pick mariadb-admin mysqladmin)"; INSTALLDB="$(pick mariadb-install-db mysql_install_db)"
{ [ -n "$MARIADBD" ] && [ -n "$CLIENT" ] && [ -n "$ADMIN" ] && [ -n "$INSTALLDB" ]; } || { echo "  SKIP profile: MariaDB server/client binaries not found (set MDB_BINDIR)"; exit 0; }
PY="$(command -v python3)"
PLAT="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
ONLY="${PROFILE_ONLY:-}"
W="$(mktemp -d "${TMPDIR:-/tmp}/fsql_profile_XXXXXX")"
PIDS=()
cleanup() {
  [ -n "${SOCK:-}" ] && "$ADMIN" --socket="$SOCK" -uroot shutdown >/dev/null 2>&1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && { kill -9 "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done
  [ "${PROFILE_KEEP:-0}" = 1 ] || rm -rf "$W"
}
trap cleanup EXIT
FAILS=0
VG=(valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes
    --num-callers=40 --fair-sched=yes --xml=yes)
cc_clean() { env -u LD_PRELOAD "$@"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; }
free_port() { "$PY" -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
export FSQL_REASONING_REQUIRE_SIGNATURE=0

verdict() {   # verdict LABEL ours... -- xml...
  local label="$1"; shift
  local args=() xmls=() seen=0 a
  for a in "$@"; do
    if [ "$a" = -- ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then args+=(--ours "$a"); else xmls+=("$a"); fi
  done
  local x ok=1; for x in "${xmls[@]}"; do [ -s "$x" ] || { echo "  FAIL $label: no valgrind report at $x"; ok=0; }; done
  [ "$ok" = 1 ] || { FAILS=$((FAILS + 1)); PROFILE_KEEP=1; return; }
  if "$PY" -I "$HERE/valgrind_check.py" verdict "${args[@]}" "${xmls[@]}"; then echo "  PASS $label"
  else echo "  FAIL $label (logs in $W)"; FAILS=$((FAILS + 1)); PROFILE_KEEP=1; fi
}

SHIM="$ROOT/service/build/fractalsql.so"; FSQLD="$ROOT/service/build/fractalsqld"
need_build() {
  [ -n "${BUILT:-}" ] && return 0
  if [ ! -x "$FSQLD" ] || [ ! -f "$SHIM" ]; then nice make -C "$ROOT" >"$W/make.log" 2>&1; fi
  { [ -x "$FSQLD" ] && [ -f "$SHIM" ]; } || { fail "no fractalsqld / shim built (make: see $W/make.log)"; return 1; }
  BUILT=1
}

# the whole stack, mariadbd and fractalsqld under valgrind; sets SOCK, PORT, MARIADB[], DPID, MPID; logs in $W/slogs
start_stack() {
  need_build || return 1
  local plug="$ROOT/include/$PLAT"
  { [ -f "$plug/fractalsql-reasoning-http.so" ] && [ -f "$plug/fractalsql-reasoning-http.so.sig" ]; } || { fail "no vendored reasoning plugin for $PLAT"; return 1; }
  PLUGDIR="$W/plugins"; DATADIR="$W/data"; SOCK="$W/sock/mysql.sock"; PORT="$(free_port)"
  rm -rf "$PLUGDIR" "$DATADIR" "$W/sock" "$W/d" "$W/slogs/daemon.xml" "$W/slogs/mariadbd.xml"   # a fresh stack for every target
  mkdir -p "$PLUGDIR" "$W/sock" "$W/slogs" "$W/d"
  cp "$SHIM" "$PLUGDIR/fractalsql.so"
  install -m 0755 "$plug/fractalsql-reasoning-http.so" "$PLUGDIR/"; install -m 0644 "$plug/fractalsql-reasoning-http.so.sig" "$PLUGDIR/"
  MOCKP="$(free_port)"; "$PY" "$ROOT/scripts/ci/mock_llm.py" "$MOCKP" >"$W/mock_llm.log" 2>&1 & PIDS+=("$!")
  : > "$W/my.cnf"
  "$INSTALLDB" --defaults-file="$W/my.cnf" --datadir="$DATADIR" --auth-root-authentication-method=normal >"$W/installdb.log" 2>&1 \
    || { fail "mariadb-install-db failed (see $W/installdb.log)"; tail -5 "$W/installdb.log"; return 1; }
  # the daemon: a private socket and key, the vendored HTTP plugin pointed at the mock LLM
  openssl rand -hex 32 > "$W/d/key" 2>/dev/null || "$PY" -c 'import secrets; print(secrets.token_hex(32))' > "$W/d/key"; chmod 600 "$W/d/key"
  FSQD_SOCK="$W/d/fsqld.sock"
  printf 'socket_path = %s\nhmac_key_file = %s\nallowed_uids = %s\nreasoning_plugin = %s\n' "$FSQD_SOCK" "$W/d/key" "$(id -u)" "$PLUGDIR/fractalsql-reasoning-http.so" > "$W/d/fsqld.conf"
  chmod 600 "$W/d/fsqld.conf"
  export FRACTALSQL_CONFIG="$W/d/fsqld.conf" FRACTALSQL_REASONING_PLUGIN="$PLUGDIR/fractalsql-reasoning-http.so" \
         FRACTALSQL_HTTP_URL="http://127.0.0.1:$MOCKP/v1/chat/completions" FRACTALSQL_HTTP_EMBED_URL="http://127.0.0.1:$MOCKP/v1/embeddings" FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1
  sleep 1
  ( cd "$W/d" && exec nice "${VG[@]}" --xml-file="$W/slogs/daemon.xml" "$FSQLD" -c "$W/d/fsqld.conf" </dev/null ) >"$W/daemon.log" 2>&1 &
  DPID=$!; PIDS+=("$DPID")
  local i; for i in $(seq 1 240); do [ -S "$FSQD_SOCK" ] && break; kill -0 "$DPID" 2>/dev/null || break; sleep 0.5; done
  [ -S "$FSQD_SOCK" ] || { fail "fractalsqld did not open its socket"; tail -5 "$W/daemon.log"; return 1; }
  ( cd "$W" && exec nice "${VG[@]}" --xml-file="$W/slogs/mariadbd.xml" "$MARIADBD" --defaults-file="$W/my.cnf" --datadir="$DATADIR" --socket="$SOCK" --port="$PORT" \
      --plugin-dir="$PLUGDIR" --pid-file="$W/mariadbd.pid" --skip-networking=0 --bind-address=127.0.0.1 --innodb-use-native-aio=0 ) >"$W/mariadbd.log" 2>&1 &
  MPID=$!; PIDS+=("$MPID")
  for i in $(seq 1 480); do "$CLIENT" --socket="$SOCK" -uroot -e "SELECT 1;" >/dev/null 2>&1 && break; kill -0 "$MPID" 2>/dev/null || break; sleep 0.5; done
  "$CLIENT" --socket="$SOCK" -uroot -e "SELECT 1;" >/dev/null 2>&1 || { fail "mariadbd did not come up under valgrind"; tail -8 "$W/mariadbd.log"; return 1; }
  "$CLIENT" --socket="$SOCK" -uroot -e "CREATE DATABASE IF NOT EXISTS fractalsql_bt;" >"$W/setup.log" 2>&1
  MARIADB=("$CLIENT" --socket="$SOCK" -uroot -D fractalsql_bt)
  "${MARIADB[@]}" < sql/install_udf.sql >>"$W/setup.log" 2>&1 && "${MARIADB[@]}" < sql/install_agents.sql >>"$W/setup.log" 2>&1 \
    || { echo "  the extension's SQL did not install:"; tail -3 "$W/setup.log"; return 1; }
  return 0
}
stop_stack() {   # mariadbd first (it holds the shim), then the daemon; a clean exit is what makes valgrind write the report
  "$ADMIN" --socket="$SOCK" -uroot shutdown >"$W/stop.log" 2>&1
  local i; for i in $(seq 1 600); do kill -0 "${MPID:-0}" 2>/dev/null || break; sleep 0.5; done
  kill -0 "${MPID:-0}" 2>/dev/null && { fail "mariadbd did not exit after shutdown"; kill -9 "$MPID" 2>/dev/null; }
  kill -TERM "${DPID:-0}" 2>/dev/null
  for i in $(seq 1 600); do kill -0 "${DPID:-0}" 2>/dev/null || break; sleep 0.5; done
  kill -0 "${DPID:-0}" 2>/dev/null && { fail "fractalsqld did not exit after SIGTERM"; kill -9 "$DPID" 2>/dev/null; }
  SOCK=""
}

if [ -z "$ONLY" ] || [ "$ONLY" = units ]; then
  say "units"
  mkdir -p "$W/u"
  build() { cc_clean cc -std=c11 -O0 -g -Wno-unused-function -Iinclude -Isrc "$@" src/fractalsql_interrupt.c -lm 2>"$W/u/cc.log" \
              || { fail "a unit binary did not build"; tail -3 "$W/u/cc.log"; return 1; }; }
  run_u() { local n="$1"; shift; timeout 600 nice "${VG[@]}" --xml-file="$W/u/$n.xml" "$W/u/$n" "$@" >"$W/u/$n.log" 2>&1; verdict "$n" "$W/u/" -- "$W/u/$n.xml"; }
  build tests/parse_csv_probe.c src/fractalsql_parse.c -o "$W/u/parse_csv_probe" && run_u parse_csv_probe
  for t in parse_vector_csv parse_index_csv parse_corpus; do
    build "$HERE/fuzz_replay.c" "tests/fuzz/fuzz_$t.c" src/fractalsql_parse.c -o "$W/u/fuzz_$t" && run_u "fuzz_$t" "tests/fuzz/corpus_$t" 3
  done
fi

if [ -z "$ONLY" ] || [ "$ONLY" = engine ]; then
  say "engine (mariadbd + fractalsqld under valgrind, the demo kits through the mariadb client)"
  if start_stack; then
    n=0; bad=0
    for kit in "$ROOT"/demo/demo-vertical-*.sql; do
      [ -f "$kit" ] || continue
      n=$((n + 1))
      "${MARIADB[@]}" -N --force < "$kit" >"$W/kit_$n.out" 2>&1 || true
      grep -q 'Lost connection\|server has gone away' "$W/kit_$n.out" && { bad=$((bad + 1)); echo "  the server died during $(basename "$kit")"; }
    done
    echo "  $n kits ($(cat "$W"/kit_*.out | grep -c '^ERROR ') SQL errors, expected: a few for the unconfigured embedding endpoint)"
    [ "$bad" -eq 0 ] || { FAILS=$((FAILS + 1)); PROFILE_KEEP=1; }
    stop_stack
    verdict engine "$PLUGDIR/fractalsql.so" "$FSQLD" "fractalsql-reasoning-http" -- "$W/slogs/mariadbd.xml" "$W/slogs/daemon.xml"
  else fail "engine: could not start the stack under valgrind"; stop_stack; fi
fi

mcp_ready() {
  [ -n "${MCP_READY:-}" ] && return 0
  CXX="$(command -v g++ || command -v c++ || command -v clang++ || true)"
  if [ -z "$CXX" ] || ! command -v mariadb_config >/dev/null 2>&1; then echo "  SKIP mcp: no C++ compiler or no mariadb_config (libmariadb-dev)"; return 1; fi
  mkdir -p "$W/mcp"; MCP_READY=1
}

if [ -z "$ONLY" ] || [ "$ONLY" = mcp ]; then
  say "mcp (the MCP server's probes, C++)"
  if mcp_ready; then
    M="$ROOT/mcp"; CXXF=(-std=c++17 -O1 -g -pthread -I"$M/vendor" -I"$M/src" $(mariadb_config --cflags) $(pkg-config --cflags openssl 2>/dev/null))
    LIBS=($(mariadb_config --libs) $(pkg-config --libs openssl 2>/dev/null || echo -lssl -lcrypto) -lpthread)
    bm() { cc_clean "$CXX" "${CXXF[@]}" "$@" 2>>"$W/mcp/cc.log" || { fail "an MCP probe did not build (see $W/mcp/cc.log)"; return 1; }; }
    run_m() { local n="$1"; shift; timeout 1500 nice "${VG[@]}" --xml-file="$W/mcp/$n.xml" "$W/mcp/$n" "$@" >"$W/mcp/$n.log" 2>&1; verdict "mcp_$n" "$W/mcp/" -- "$W/mcp/$n.xml"; }
    bm "$M/tests/vectors_probe.cpp" "$M/src/vectors.cpp" "$M/src/errors.cpp" -o "$W/mcp/vectors_probe" && run_m vectors_probe
    bm "$M/tests/concurrency_probe.cpp" -o "$W/mcp/concurrency_probe" && run_m concurrency_probe
    bm "$M/tests/db_probe.cpp" "$M/src/db.cpp" "$M/src/errors.cpp" "$M/src/logging.cpp" -o "$W/mcp/db_probe" "${LIBS[@]}" \
      && { unset MARIADB_HOST MARIADB_PORT MARIADB_USER MARIADB_PASSWORD MARIADB_DATABASE; run_m db_probe; }
  fi
fi

if [ -z "$ONLY" ] || [ "$ONLY" = server ]; then
  say "server (the running MCP server under valgrind, driven by mcp/tests/mcp_smoke_client.py)"
  if mcp_ready && need_build; then
    # the server's Makefile builds in its own directory: build a copy, so the repo's own objects and binary are left alone
    mkdir -p "$W/mcpsrc" && cp -r "$ROOT/mcp/Makefile" "$ROOT/mcp/src" "$ROOT/mcp/vendor" "$W/mcpsrc/" 2>/dev/null
    if ! cc_clean nice make -C "$W/mcpsrc" CXXFLAGS="-std=c++17 -O1 -g $(mariadb_config --cflags) $(pkg-config --cflags openssl 2>/dev/null)" >"$W/mcp/smake.log" 2>&1 \
         || ! cp "$W/mcpsrc/fractalsql-mariadb-mcp" "$W/mcp/fractalsql-mariadb-mcp"; then
      fail "the MCP server did not build (see $W/mcp/smake.log)"; tail -5 "$W/mcp/smake.log"
    elif start_stack; then
      cp "$ROOT/mcp/.mcp-schema-lock" "$ROOT/mcp/.mcp-safety-annotations-lock" "$W/mcp/" 2>/dev/null
      mkdir -p "$W/mcp/slogs" "$W/mcp/cwd"
      cat > "$W/mcp/srv-valgrind.sh" <<EOF
#!/bin/bash
# (bash, not dash: only bash keeps the client's stdin on a backgrounded command; valgrind runs as a child so a client that kills
# this wrapper after giving up waiting for the slow leak-checking exit does not cut the report short)
nice valgrind --tool=memcheck --leak-check=full --show-leak-kinds=definite,indirect,possible --track-origins=yes --num-callers=40 --fair-sched=yes --xml=yes --xml-file='$W/mcp/slogs/server.%p.xml' '$W/mcp/fractalsql-mariadb-mcp' "\$@" <&0 &
VP=\$!
# a client that terminates the wrapper (HTTP servers are stopped that way) must stop the server, not orphan it
trap 'kill -TERM \$VP 2>/dev/null' TERM INT
while kill -0 \$VP 2>/dev/null; do wait \$VP; rc=\$?; done
exit \${rc:-0}
EOF
      chmod +x "$W/mcp/srv-valgrind.sh"
      # the slow reasoning fixture the shutdown-drain checks need (as the harness builds it)
      cc_clean cc -shared -fPIC -std=c99 -Iinclude tests/slow_reasoning_plugin.c -o "$W/mcp/slow_reasoning_plugin.so" 2>"$W/mcp/slow.log" || fail "the slow reasoning plugin did not build"
      out="$(cd "$W/mcp/cwd" && env MCP_HERE="$ROOT/mcp" MCP_SERVER_EXE="$W/mcp/srv-valgrind.sh" MCP_TEST_DAEMON_EXE="$FSQLD" MCP_SERVER_CWD="$W/mcp/cwd" \
             MCP_MARIADB_BIN="$CLIENT" MCP_SLOW_REASONING_PLUGIN="$W/mcp/slow_reasoning_plugin.so" MARIADB_HOST=127.0.0.1 MARIADB_PORT="$PORT" MARIADB_DATABASE=fractalsql_bt MARIADB_USER=root MARIADB_PASSWORD= \
             FSQLCTL_SOCKET="$FSQD_SOCK" FSQLCTL_KEY="$W/d/key" FSQLCTL_CONF="$W/d/fsqld.conf" MCP_SMOKE_SKIP_SWEEPS=1 \
             timeout 3000 "$PY" -u "$ROOT/mcp/tests/mcp_smoke_client.py" 2>&1)"
      rc=$?
      printf '%s\n' "$out" > "$W/mcp/smoke.log"
      echo "  smoke client: $(grep -c '^ *PASS' <<< "$out") checks passed, $(grep -c '^ *FAIL' <<< "$out") failed (exit $rc)"
      real_fails="$(grep -E '^ *FAIL' <<< "$out" | grep -vc 'graceful shutdown')"
      if [ "$rc" -ne 0 ] && { [ "$real_fails" -ne 0 ] || ! grep -q 'graceful shutdown' <<< "$out"; }; then
        echo "  (a failure here may be a client timeout under valgrind's slowdown, see $W/mcp/smoke.log)"
        grep -E 'FAIL|Traceback|Error' <<< "$out" | head -5 | cut -c1-200
        FAILS=$((FAILS + 1)); PROFILE_KEEP=1
      elif [ "$rc" -ne 0 ]; then echo "  note: only the shutdown-timing checks failed (the driver kills a server that is still writing its valgrind report)"; fi
      for i in $(seq 1 120); do pgrep -f "$W/mcp/slogs/" >/dev/null 2>&1 || break; sleep 1; done
      pkill -TERM -f "$W/mcp/slogs/" 2>/dev/null   # a server the client left running: stop it so it writes its report
      for i in $(seq 1 600); do pgrep -f "$W/mcp/slogs/" >/dev/null 2>&1 || break; sleep 1; done
      stop_stack
      # shellcheck disable=SC2206
      logs=("$W"/mcp/slogs/server.*.xml "$W/slogs/mariadbd.xml" "$W/slogs/daemon.xml")
      verdict server "$W/mcp/fractalsql-mariadb-mcp" "$PLUGDIR/fractalsql.so" "$FSQLD" "fractalsql-reasoning-http" -- "${logs[@]}"
    else fail "server: could not start the stack under valgrind"; stop_stack; fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then echo "profile: all targets clean"; else echo "profile: $FAILS target(s) failed"; fi
[ "${PROFILE_KEEP:-0}" = 1 ] && echo "  logs kept in $W"
exit "$FAILS"
