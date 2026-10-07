#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# fpm --after-install hook, shared by the .deb and the .rpm. Creates the
# fractalsql system user, a shared HMAC key and config for the shim and the
# daemon if neither exists yet, and enables fractalsqld.
#
# The shim runs inside mariadbd (as the mysql user) and the daemon runs as
# its own fractalsql user (spec S4: the daemon has no database credentials).
# mariadbd reaches the daemon's socket under /run/fractalsql by mysql's
# membership in the fractalsql group, not by running as the same user.
set -e

getent group fractalsql >/dev/null 2>&1 || groupadd --system fractalsql
getent passwd fractalsql >/dev/null 2>&1 || \
    useradd --system --gid fractalsql --no-create-home \
        --shell /usr/sbin/nologin --comment "FractalSQL daemon" fractalsql

if getent passwd mysql >/dev/null 2>&1; then
    usermod -aG fractalsql mysql || true
fi

install -d -m 0750 -o fractalsql -g fractalsql /etc/fractalsql

KEY=/etc/fractalsql/hmac.key
if [ ! -f "${KEY}" ]; then
    oldumask=$(umask)
    umask 077
    openssl rand -hex 32 > "${KEY}"
    umask "${oldumask}"
    chown fractalsql:fractalsql "${KEY}"
    chmod 0640 "${KEY}"
fi

MYSQL_UID="$(id -u mysql 2>/dev/null || echo 0)"

# The daemon's own config: socket, key, and the shim's peer uid.
if [ ! -f /etc/fractalsql/fractalsqld.conf ]; then
    cat > /etc/fractalsql/fractalsqld.conf <<CONF
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = /etc/fractalsql/hmac.key
allowed_uids = ${MYSQL_UID}
CONF
    chown fractalsql:fractalsql /etc/fractalsql/fractalsqld.conf
    chmod 0640 /etc/fractalsql/fractalsqld.conf
fi

# The shim's config: same socket and key, read by mariadbd as mysql.
if [ ! -f /etc/fractalsql/fractalsql.conf ]; then
    cat > /etc/fractalsql/fractalsql.conf <<CONF
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = /etc/fractalsql/hmac.key
CONF
    chown root:mysql /etc/fractalsql/fractalsql.conf 2>/dev/null || \
        chown root:root /etc/fractalsql/fractalsql.conf
    chmod 0640 /etc/fractalsql/fractalsql.conf
fi

systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable fractalsqld.service >/dev/null 2>&1 || true
systemctl restart fractalsqld.service >/dev/null 2>&1 || true

# mysql was just added to the fractalsql group above, but a mariadbd
# already running at this point started with its OLD supplementary
# group list -- Linux resolves a process's groups at exec time, not on
# every file access -- so it can't traverse /etc/fractalsql (mode
# 0750, group fractalsql) until restarted. Best-effort under systemd;
# a host without it (or without mariadb-server installed at all) falls
# through to the printed instruction below.
if systemctl is-active --quiet mariadb.service 2>/dev/null; then
    systemctl restart mariadb.service >/dev/null 2>&1 || true
fi

cat <<EOF2

fractalsql-mariadb: fractalsqld is enabled and (re)started.
mysql was just added to the fractalsql group; if mariadbd was already
running, this just restarted it under systemd so the new group
membership takes effect. On a host without systemd, do it yourself:
    systemctl restart mariadb
Then: mysql -u root -p < /usr/share/fractalsql-mariadb/install_udf.sql
EOF2
