#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Protocol self-test: real mariadbd + fractalsqld + the shim
# (fractalsql.so). Checks SQL results, server survival when the daemon
# dies (A5), lazy reconnect, and frame-level auth.
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
work=${SPIKE_WORK:-/tmp/fractalsql_spike_test}
user=$(id -un)
uid=$(id -u)
pass=0; fail=0

ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }

# Resolve mariadbd/mariadb-install-db/mariadb/mariadb-admin against
# $MDB_BINDIR (same env var build_test.sh's mdb_bindir() honors) rather
# than bare PATH lookups. Homebrew keeps a *versioned* formula
# (mariadb@10.6) keg-only -- its binaries are never symlinked onto
# PATH -- so on Darwin CI, where build-test.yml's darwin-gate-matrix
# job exports MDB_BINDIR to a specific major's keg, a bare `command -v
# mariadbd` either finds nothing (10.6) or silently finds a *different*
# major's binary left on PATH by an earlier matrix cell / the runner
# image (caught live: 12.3's SQL-value check failed only here, while
# the exact same checks via build_test.sh's own properly-resolved
# mdb_setup() passed for every later gate in the same run).
mdb_find() {
    name="$1"; fallback="${2:-}"
    if [ -n "${MDB_BINDIR:-}" ]; then
        for d in "$MDB_BINDIR" "${MDB_BINDIR%/sbin}/bin" "${MDB_BINDIR%/bin}/sbin"; do
            [ -x "$d/$name" ] && { echo "$d/$name"; return; }
            [ -n "$fallback" ] && [ -x "$d/$fallback" ] && { echo "$d/$fallback"; return; }
        done
    fi
    command -v "$name" 2>/dev/null && return
    [ -n "$fallback" ] && command -v "$fallback" 2>/dev/null && return
    echo "$name"
}

# MariaDB 10.6 is the tool-rename transition major (Homebrew's
# mariadb@10.6 bottle ships only the pre-rename name) -- same fallback
# build_test.sh's mdb_setup() already applies.
INSTALLDB_BIN=$(mdb_find mariadb-install-db mysql_install_db)
MARIADBD_BIN=$(mdb_find mariadbd)
MARIADB_BIN=$(mdb_find mariadb mysql)
MARIADB_ADMIN_BIN=$(mdb_find mariadb-admin mysqladmin)

rm -rf "$work"; mkdir -p "$work/plugins" "$work/data"
openssl rand -hex 32 > "$work/hmac.key" && chmod 600 "$work/hmac.key"
cat > "$work/fractalsqld.conf" <<CONF
socket_path = $work/fsqld.sock
hmac_key_file = $work/hmac.key
allowed_uids = $uid
CONF
chmod 600 "$work/fractalsqld.conf"
cp "$here/build/fractalsql.so" "$work/plugins/fractalsql.so"

start_daemon() {
    "$here/build/fractalsqld" -c "$work/fractalsqld.conf" </dev/null >"$work/fsqld.log" 2>&1 &
    daemon_pid=$!
    i=0
    while [ ! -S "$work/fsqld.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}

mdb() { "$MARIADB_BIN" --no-defaults -uroot -S "$work/mdb.sock" "$@"; }

queries() {
    mdb -e "SELECT fractal_version();" 2>&1
    mdb -e "SELECT fractal_vector_dims('[1,2,3]') AS a, fractal_vector_dims('1,2') AS b, fractal_vector_dims('[]') AS c, fractal_vector_dims(NULL) AS d;" 2>&1
    mdb -e "SELECT fractal_vector_dims('[1,2') AS bad;" 2>&1
    mdb -e "SELECT fractal_vector_dims() AS arity;" 2>&1
}

echo "== starting fractalsqld and mariadbd"
start_daemon
"$INSTALLDB_BIN" --no-defaults --datadir="$work/data" --user="$user" \
    --auth-root-authentication-method=normal >"$work/install.log" 2>&1 || { bad "mariadb-install-db"; exit 1; }
FRACTALSQL_CONFIG="$work/fractalsqld.conf" "$MARIADBD_BIN" --no-defaults --datadir="$work/data" \
    --socket="$work/mdb.sock" --skip-networking --plugin-dir="$work/plugins" \
    --pid-file="$work/mdb.pid" --log-error="$work/mdb.err" --user="$user" </dev/null >/dev/null 2>&1 &
i=0
while ! "$MARIADB_ADMIN_BIN" --no-defaults -uroot -S "$work/mdb.sock" ping >/dev/null 2>&1 && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
mdb < "$here/sql/install_spike.sql" >"$work/install_sql.log" 2>&1 || { bad "install_spike.sql"; exit 1; }
ok "server up and spike UDFs installed"

queries > "$work/out.log"
# grep -F (fixed string), not -P: macOS ships BSD grep, which has no
# -P (Perl regex) support at all -- that combined check silently never
# matched on Darwin, failing this line on every mdb major regardless
# of the real SQL output (caught live on darwin-gate-matrix: "SQL
# values" failed identically on 10.6 and 12.3). The tab-separated
# expected row has no regex metacharacters, so a literal match is both
# portable and simpler.
dims_row=$(printf '3\t2\tNULL\tNULL')
if grep -qx "2.0.9" "$work/out.log" && grep -qxF "$dims_row" "$work/out.log" && grep -q "expected 1 argument, got 0" "$work/out.log"; then ok "SQL values correct (version, dims, NULL handling, arity error)"; else bad "SQL values (see $work/out.log)"; fi

echo "== A5: kill fractalsqld, server must survive"
kill "$daemon_pid" 2>/dev/null; wait "$daemon_pid" 2>/dev/null
out=$(mdb -e "SELECT fractal_version();" 2>&1)
case "$out" in *fractalsqld*) ok "call fails with a clear message when the daemon is down";; *) bad "unexpected: $out";; esac
mdb -e "SELECT 1;" >/dev/null 2>&1 && ok "server still answers after daemon death (A5)" || bad "server died with the daemon"

echo "== lazy reconnect"
start_daemon
out=$(mdb -e "SELECT fractal_version();" 2>&1)
case "$out" in *2.0.9*) ok "shim reconnects to a restarted daemon";; *) bad "no reconnect: $out";; esac

echo "== frame-level auth"
if "$here/build/frame_test" "$work/fsqld.sock" "$(cat "$work/hmac.key")"; then ok "frame_test: valid PING, bad tag, oversize length"; else bad "frame_test"; fi

echo "== cooperative-cancel seam (no daemon needed)"
if "$here/build/interrupt_test"; then ok "interrupt_test: hook semantics and parser cancel seams"; else bad "interrupt_test"; fi

"$MARIADB_ADMIN_BIN" --no-defaults -uroot -S "$work/mdb.sock" shutdown >/dev/null 2>&1
kill "$daemon_pid" 2>/dev/null
echo "== spike: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
