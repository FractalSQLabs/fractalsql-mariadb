#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Demo entrypoint for the mariadb container. Writes the shim's config and
# the shared HMAC key (same FSQL_HMAC_KEY as the fractalsqld container),
# then hands off to the stock image entrypoint.
set -eu
: "${FSQL_HMAC_KEY:?set FSQL_HMAC_KEY (hex, e.g. openssl rand -hex 32); the fractalsqld service needs the same value}"
CONF_DIR=/etc/fractalsql
install -d -m 0750 -o root -g mysql "$CONF_DIR"
printf '%s\n' "$FSQL_HMAC_KEY" > "$CONF_DIR/hmac.key"
chown root:mysql "$CONF_DIR/hmac.key"
chmod 0640 "$CONF_DIR/hmac.key"
cat > "$CONF_DIR/fractalsql.conf" <<CONF
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = $CONF_DIR/hmac.key
CONF
chown root:mysql "$CONF_DIR/fractalsql.conf"
chmod 0640 "$CONF_DIR/fractalsql.conf"
exec docker-entrypoint.sh "$@"
