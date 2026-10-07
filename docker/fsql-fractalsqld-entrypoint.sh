#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Demo entrypoint for fractalsqld. Writes the daemon config and the shared
# HMAC key from FSQL_HMAC_KEY into /run/fractalsql, then runs the daemon as
# the mysql user, so the peer-uid check admits mariadbd. The container runs
# as mysql (user: 999:999 in compose), so no capabilities are needed; if it
# is started as root, the daemon is dropped to mysql with gosu.
set -eu
: "${FSQL_HMAC_KEY:?set FSQL_HMAC_KEY (hex, e.g. openssl rand -hex 32); the mariadb service needs the same value}"
RUN_DIR=/run/fractalsql
MYSQL_UID=$(id -u mysql)
umask 077
mkdir -p "$RUN_DIR"
chmod 0750 "$RUN_DIR"
rm -f "$RUN_DIR/fractalsqld.sock"
printf '%s\n' "$FSQL_HMAC_KEY" > "$RUN_DIR/hmac.key"
cat > "$RUN_DIR/fractalsqld.conf" <<CONF
socket_path = $RUN_DIR/fractalsqld.sock
hmac_key_file = $RUN_DIR/hmac.key
allowed_uids = $MYSQL_UID
max_connections = 64
idle_timeout_secs = 300
CONF
if [ "$(id -u)" -eq 0 ]; then
  chown -R mysql:mysql "$RUN_DIR"
  exec gosu mysql /usr/local/bin/fractalsqld -c "$RUN_DIR/fractalsqld.conf"
fi
exec /usr/local/bin/fractalsqld -c "$RUN_DIR/fractalsqld.conf"
