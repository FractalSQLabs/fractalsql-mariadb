#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Parity runner: runs one SQL file against the shim + fractalsqld and
# checks for a crash or a missing/not-yet-available function. Installs
# the full sql/install_udf.sql first. Run for every file in tests/parity/
# by docker/Dockerfile.test (Linux CI), after build_test.sh's own gates.
# Usage:
#   tests/parity.sh tests/parity/<file>.sql
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
sqlfile=$1
work=${PARITY_WORK:-/tmp/fractalsql_parity_test}
user=$(id -un); uid=$(id -u)
rm -rf "$work"; mkdir -p "$work/data" "$work/service"
[ -x "$here/build/fractalsqld" ] || { echo "parity: build the service tree first (make -C $here)"; exit 2; }
cp "$here/build/fractalsql.so" "$work/service/"
openssl rand -hex 32 > "$work/hmac.key" && chmod 600 "$work/hmac.key"
cat > "$work/fractalsqld.conf" <<CONF
socket_path = $work/fsqld.sock
hmac_key_file = $work/hmac.key
allowed_uids = $uid
CONF
mariadb-install-db --no-defaults --datadir="$work/data" --user="$user" \
    --auth-root-authentication-method=normal >"$work/install.log" 2>&1 || { echo "parity: install-db failed"; exit 1; }

run_variant() {  # name plugindir use_daemon
  name=$1; plug=$2; daemon=$3
  sock="$work/$name.sock"
  pid=""
  if [ "$daemon" = 1 ]; then
    "$here/build/fractalsqld" -c "$work/fractalsqld.conf" </dev/null >"$work/fsqld.log" 2>&1 &
    dpid=$!
    i=0; while [ ! -S "$work/fsqld.sock" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  fi
  FRACTALSQL_CONFIG="$work/fractalsqld.conf" mariadbd --no-defaults --datadir="$work/data" \
      --socket="$sock" --skip-networking --plugin-dir="$plug" --pid-file="$work/$name.pid" \
      --log-error="$work/$name.err" --user="$user" </dev/null >/dev/null 2>&1 &
  i=0; while ! mariadb-admin --no-defaults -uroot -S "$sock" ping >/dev/null 2>&1 && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  mariadb --no-defaults -uroot -S "$sock" -e "CREATE DATABASE IF NOT EXISTS fsql" >"$work/$name.install.log" 2>&1
  mariadb --no-defaults -uroot -S "$sock" -D fsql < "$repo/sql/install_udf.sql" >>"$work/$name.install.log" 2>&1 \
      || { echo "parity: $name install_udf.sql failed (see $work/$name.install.log)"; FAILED=1; }
  mariadb --no-defaults -uroot -S "$sock" -D fsql --force --batch < "$sqlfile" >"$work/$name.out" 2>&1
  mariadb-admin --no-defaults -uroot -S "$sock" shutdown >/dev/null 2>&1
  [ "$daemon" = 1 ] && kill "$dpid" 2>/dev/null && wait "$dpid" 2>/dev/null
  sleep 1
}

FAILED=0
run_variant service "$work/service" 1
lines=$(wc -l < "$work/service.out")
if grep -q "does not exist\|not yet available" "$work/service.out"; then
  echo "parity: missing functions (see $work/service.out)"
  grep "does not exist\|not yet available" "$work/service.out" | head -5
  FAILED=1
fi
if [ "$FAILED" -eq 0 ]; then
  echo "parity: PASS ($lines lines, no crash, no missing function) $sqlfile"
  exit 0
else
  echo "parity: FAIL $sqlfile"
  exit 1
fi
