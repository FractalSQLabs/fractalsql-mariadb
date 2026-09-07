#!/bin/bash
#
# install.sh - installer bundled inside the fractalsql-mariadb macOS zip.
# Run it from the extracted zip directory, against an already running
# MariaDB server (this only installs the plugin, not MariaDB itself):
#
#     unzip fractalsql-mariadb-osx_arm64.zip -d fractalsql-mariadb-darwin
#     cd fractalsql-mariadb-darwin
#     ./install.sh                                  # mariadb -uroot on PATH
#     MARIADB_BIN=/path/to/mariadb ./install.sh      # or a specific client
#
# Copies the UDF library and reasoning plugin into the server's
# plugin_dir, then registers the UDFs and procedures by running the two
# bundled SQL scripts against that same server.
#
# plugin_dir is read live with `SELECT @@plugin_dir` against the running
# server rather than from `mariadb_config`/`mysql_config --plugindir`,
# which reports the client connector library's own plugin path, not the
# server's. Using it would copy the plugin somewhere the server never
# looks.
#
# One binary works across MariaDB 10.6, 10.11, 11.4 LTS, and 12.3
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
if ! "${MARIADB_BIN}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
    echo "error: can't connect to a running MariaDB server as root via ${MARIADB_BIN}." >&2
    echo "  This installs the plugin into an already-running server -- it doesn't start one." >&2
    exit 1
fi

PLUGIN_DIR="$("${MARIADB_BIN}" -u root -Nse 'SELECT @@plugin_dir;' 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR%/}"
if [[ -z "${PLUGIN_DIR}" ]]; then
    echo "error: SELECT @@plugin_dir returned nothing." >&2
    exit 1
fi

# macOS's dynamic loader is happy to load a .dylib under a name ending
# in .so, so it's staged here as fractalsql.so: every install_udf.sql
# CREATE FUNCTION ... SONAME 'fractalsql.so' reference expects that
# exact on-disk name, on every platform.
if [[ ! -f "${HERE}/fractalsql.dylib" ]]; then
    echo "error: fractalsql.dylib not found in ${HERE}" >&2
    exit 1
fi
if [[ ! -f "${HERE}/fractalsql-reasoning-http.so" ]]; then
    echo "error: fractalsql-reasoning-http.so not found in ${HERE}" >&2
    exit 1
fi

echo "plugin_dir : ${PLUGIN_DIR}"
echo

INSTALL="install"
if [[ ! -w "${PLUGIN_DIR}" ]]; then
    echo "note: ${PLUGIN_DIR} is not writable -- re-running the copy under sudo"
    echo "      (you may be prompted for your password)."
    INSTALL="sudo install"
fi

${INSTALL} -d "${PLUGIN_DIR}"
${INSTALL} -m 0755 "${HERE}/fractalsql.dylib" "${PLUGIN_DIR}/fractalsql.so"
${INSTALL} -m 0755 "${HERE}/fractalsql-reasoning-http.so" "${PLUGIN_DIR}/fractalsql-reasoning-http.so"

echo "Installed:"
echo "  ${PLUGIN_DIR}/fractalsql.so (from fractalsql.dylib)"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo

echo "Next: register the UDFs (server-global, no database needed):"
echo "  ${MARIADB_BIN} -u root -p < ${HERE}/install_udf.sql"
echo "  ${MARIADB_BIN} -u root -p -e 'SELECT fractalsql_edition(), fractalsql_version();'"
echo "...then the agent procedures into a specific database (mydb below"
echo "must already exist -- CREATE PROCEDURE needs one, UDFs don't):"
echo "  ${MARIADB_BIN} -u root -p mydb < ${HERE}/install_agents.sql"
echo
echo "Reasoning is opt-in and set via a process environment variable, not"
echo "a SQL statement -- MariaDB has no GUC/sysvar surface for this (see"
echo "docs/reasoning-setup.md). Set FRACTALSQL_REASONING_PLUGIN to:"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo "in mariadbd's environment (e.g. via 'brew services' launchd plist"
echo "overrides) before configuring an endpoint, then restart mariadbd."
