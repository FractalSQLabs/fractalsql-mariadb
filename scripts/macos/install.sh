#!/bin/bash
#
# install.sh - installer bundled inside the fractalsql-mariadb macOS zip.
# Run it from the extracted zip directory, against an already running
# MariaDB server (this only installs the plugin and the daemon, not
# MariaDB itself):
#
#     unzip fractalsql-mariadb-osx_arm64.zip -d fractalsql-mariadb-darwin
#     cd fractalsql-mariadb-darwin
#     ./install.sh                                  # mariadb -uroot on PATH
#     MARIADB_BIN=/path/to/mariadb ./install.sh      # or a specific client
#
# fractalsql.so (the shim) runs inside mariadbd. Every UDF body runs in
# a separate process, fractalsqld, that this script installs and loads
# as a per-user LaunchAgent (the same user mariadbd runs as under the
# common `brew services start mariadb` case -- see the plist's own
# comment for the system-wide/multi-user case, which this script does
# not set up).
#
# One shim binary works across MariaDB 10.6, 10.11, 11.4 LTS, and 12.3
# LTS, since the UDF ABI is stable across those majors (see
# docs/getting-started.md). There's no per-major build-vs-target check
# here because there's nothing to check.
#
# macOS has no package manager for MariaDB UDF plugins the way
# Debian/RHEL have .deb/.rpm, so this zip plus installer script is the
# delivery vehicle here, matching the self-contained artifacts shipped
# for Linux and Windows.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_DIR=/usr/local/libexec/fractalsql
CONF_DIR=/etc/fractalsql
LOG_DIR=/usr/local/var/log/fractalsql
SOCK_DIR=/usr/local/var/run/fractalsql
PLIST_DST="${HOME}/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"

MARIADB_BIN="${MARIADB_BIN:-mariadb}"
if ! command -v "${MARIADB_BIN}" >/dev/null 2>&1; then
    MARIADB_BIN="mysql"
fi
if ! command -v "${MARIADB_BIN}" >/dev/null 2>&1; then
    echo "error: neither mariadb nor mysql client found." >&2
    echo "  Put one on PATH, or run: MARIADB_BIN=/path/to/mariadb ./install.sh" >&2
    echo "  Homebrew example: MARIADB_BIN=\$(brew --prefix mariadb)/bin/mariadb ./install.sh" >&2
    exit 1
fi
# Connection account. Fresh Homebrew MariaDB (12.x) creates root@localhost
# with unix_socket auth only -- connecting as root is denied to everyone
# but the OS root user -- plus a same-named, all-privilege account for
# the invoking user (e.g. runner@localhost, or your own username). So
# try the invoking user first (the common case: a per-user `brew
# services` server), then fall back to -u root (older installs, or
# running this script under sudo).
MDB_AUTH=""
if "${MARIADB_BIN}" -Nse 'SELECT 1;' >/dev/null 2>&1; then
    :
elif "${MARIADB_BIN}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
    MDB_AUTH="-u root"
else
    echo "error: can't connect to a running MariaDB server via ${MARIADB_BIN}." >&2
    echo "  This installs the plugin into an already-running server -- it doesn't start one." >&2
    echo "  Tried your own account (unix_socket auth) and root." >&2
    exit 1
fi

PLUGIN_DIR="$("${MARIADB_BIN}" ${MDB_AUTH} -Nse 'SELECT @@plugin_dir;' 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR%/}"
# Canonical (realpath-equal) form, not just slash-trimmed: the reasoning
# core rejects symlinked plugin paths ("reasoning plugin path is not
# canonical"), and @@plugin_dir under Homebrew is a symlink to the
# versioned Cellar dir -- the load instructions below must hand users a
# path that actually loads.
if [[ -n "${PLUGIN_DIR}" ]]; then
    PLUGIN_DIR="$(cd "${PLUGIN_DIR}" && pwd -P)" || {
        echo "error: can't resolve plugin dir to a physical path" >&2
        exit 1
    }
fi
if [[ -z "${PLUGIN_DIR}" ]]; then
    echo "error: SELECT @@plugin_dir returned nothing." >&2
    exit 1
fi

# macOS's dynamic loader is happy to load a .dylib under a name ending
# in .so, so it's staged here as fractalsql.so: every install_udf.sql
# CREATE FUNCTION ... SONAME 'fractalsql.so' reference expects that
# exact on-disk name, on every platform.
for f in fractalsql.dylib fractalsql-reasoning-http.so fractalsqld \
         com.fractalsqlabs.fractalsqld.plist; do
    if [[ ! -f "${HERE}/${f}" ]]; then
        echo "error: ${f} not found in ${HERE}" >&2
        exit 1
    fi
done

echo "plugin_dir : ${PLUGIN_DIR}"
echo

PLUGIN_INSTALL="install"
if [[ ! -w "${PLUGIN_DIR}" ]]; then
    echo "note: ${PLUGIN_DIR} is not writable -- re-running the copy under sudo"
    echo "      (you may be prompted for your password)."
    PLUGIN_INSTALL="sudo install"
fi

${PLUGIN_INSTALL} -d "${PLUGIN_DIR}"
${PLUGIN_INSTALL} -m 0755 "${HERE}/fractalsql.dylib" "${PLUGIN_DIR}/fractalsql.so"
${PLUGIN_INSTALL} -m 0755 "${HERE}/fractalsql-reasoning-http.so" "${PLUGIN_DIR}/fractalsql-reasoning-http.so"

# /etc and /usr/local/{libexec,var} are root-owned on a stock system on
# both Intel and Apple Silicon (unlike plugin_dir, which Homebrew's own
# installer already made writable by the invoking user on Intel --
# but not reliably on Apple Silicon, where Homebrew lives under
# /opt/homebrew and never touches /usr/local at all). Always sudo these,
# rather than guessing writability per path.
echo "note: installing the daemon under /usr/local and /etc needs sudo"
echo "      (you may be prompted for your password)."
SYS_INSTALL="sudo install"

${SYS_INSTALL} -d "${DAEMON_DIR}"
${SYS_INSTALL} -m 0755 "${HERE}/fractalsqld" "${DAEMON_DIR}/fractalsqld"

# The daemon runs as the invoking user (a per-user LaunchAgent -- see
# the plist's own comment), the same user mariadbd runs as under the
# common `brew services start mariadb` case, so the config, key,
# socket, and log directories are owned by that user even though
# creating them needs root once.
${SYS_INSTALL} -d -o "$(id -un)" -m 0750 "${CONF_DIR}"
${SYS_INSTALL} -d -o "$(id -un)" "${LOG_DIR}" "${SOCK_DIR}"

KEY="${CONF_DIR}/hmac.key"
if [[ ! -f "${KEY}" ]]; then
    TMP_KEY="$(mktemp)"
    ( umask 077 && openssl rand -hex 32 > "${TMP_KEY}" )
    ${SYS_INSTALL} -m 0600 -o "$(id -un)" "${TMP_KEY}" "${KEY}"
    rm -f "${TMP_KEY}"
fi

TMP_CONF="$(mktemp)"
cat > "${TMP_CONF}" <<CONF
socket_path = ${SOCK_DIR}/fractalsqld.sock
hmac_key_file = ${KEY}
allowed_uids = $(id -u)
CONF
${SYS_INSTALL} -m 0640 -o "$(id -un)" "${TMP_CONF}" "${CONF_DIR}/fractalsqld.conf"

cat > "${TMP_CONF}" <<CONF
socket_path = ${SOCK_DIR}/fractalsqld.sock
hmac_key_file = ${KEY}
CONF
${SYS_INSTALL} -m 0640 -o "$(id -un)" "${TMP_CONF}" "${CONF_DIR}/fractalsql.conf"
rm -f "${TMP_CONF}"

mkdir -p "$(dirname "${PLIST_DST}")"
install -m 0644 "${HERE}/com.fractalsqlabs.fractalsqld.plist" "${PLIST_DST}"

echo
echo "Installed:"
echo "  ${PLUGIN_DIR}/fractalsql.so (shim, from fractalsql.dylib)"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo "  ${DAEMON_DIR}/fractalsqld (daemon)"
echo "  ${CONF_DIR}/fractalsqld.conf, ${CONF_DIR}/fractalsql.conf, ${CONF_DIR}/hmac.key"
echo "  ${PLIST_DST} (not yet loaded)"
echo

if launchctl bootstrap "gui/$(id -u)" "${PLIST_DST}" 2>/dev/null \
    || launchctl load -w "${PLIST_DST}" 2>/dev/null; then
    echo "fractalsqld is running (LaunchAgent loaded)."
else
    echo "note: could not load the LaunchAgent automatically. Load it yourself:"
    echo "  launchctl load -w ${PLIST_DST}"
fi
echo

echo "Next: restart mariadbd (so the freshly installed shim is (re)loaded"
echo "if an older fractalsql.so was already in plugin_dir), then register"
echo "the UDFs + procedures with the same account this script connected"
echo "as (mydb below must already exist -- the FUNCTION definitions are"
echo "server-global, but install_udf.sql also creates the"
echo "fractal_schema_context stored procedure, and CREATE PROCEDURE needs"
echo "a database selected):"
echo "  ${MARIADB_BIN} ${MDB_AUTH} mydb < ${HERE}/install_udf.sql"
echo "  ${MARIADB_BIN} ${MDB_AUTH} mydb < ${HERE}/install_agents.sql"
echo "  ${MARIADB_BIN} ${MDB_AUTH} -e 'SELECT fractal_edition(), fractal_version();'"
echo
echo "Reasoning is opt-in and set via a process environment variable, not"
echo "a SQL statement -- MariaDB has no GUC/sysvar surface for this (see"
echo "docs/reasoning-setup.md). FRACTALSQL_REASONING_PLUGIN is read by"
echo "fractalsqld now (not by mariadbd): add it to"
echo "  ~/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist"
echo "'s EnvironmentVariables dict, pointing at:"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo "then: launchctl kickstart -k gui/\$(id -u)/com.fractalsqlabs.fractalsqld"
