#!/usr/bin/env bash
#
# scripts/package.sh: fractalsql-mariadb packaging.
#
# Assumes ./build.sh ${ARCH} --target export has produced:
#   dist/${ARCH}/fractalsql.so    GPL-2.0-only shim, loaded by mariadbd
#   dist/${ARCH}/fractalsqld      Apache-2.0 daemon, holds the core
#
# Emits one .deb and one .rpm per arch into dist/packages/, each containing
# both binaries -- separately licensed (GPL-2.0-only shim, Apache-2.0
# daemon), one package by design:
#   dist/packages/fractalsql-mariadb-amd64.deb
#   dist/packages/fractalsql-mariadb-amd64.rpm
#   dist/packages/fractalsql-mariadb-arm64.deb
#   dist/packages/fractalsql-mariadb-arm64.rpm
#
# One binary covers MariaDB 10.6 / 10.11 / 11.4 LTS and 12.3 LTS:
# the UDF ABI is stable across those majors, so the package depends on
# mariadb-server generically rather than pinning a specific major.
#
# One glibc profile, matching build.sh: modern glibc-2.34 only (built
# inside rockylinux:9).
#
# Usage:
#   scripts/package.sh [amd64|arm64]

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${FSQL_PKG_VERSION:-$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' src/fractalsql.c)}"
[[ -n "${VERSION}" ]] || { echo "could not determine VERSION (FSQL_VERSION not found in src/fractalsql.c)" >&2; exit 1; }
ITERATION="1"
DIST_DIR="dist/packages"

# GLIBC_DEP matches the build target in build.sh: both binaries compile
# inside rockylinux:9 (glibc 2.34).
GLIBC_DEP="2.34"
PKG_NAME="fractalsql-mariadb"
PKG_LICENSE="GPL-2.0-only AND Apache-2.0"
mkdir -p "${DIST_DIR}"

# Absolute repo root, captured before any -C chdir'd fpm invocation.
REPO_ROOT="$(pwd)"
for f in LICENSE THIRD-PARTY-NOTICES.md GPL-SOURCE-OFFER.txt \
         LICENSES/Apache-2.0.txt LICENSES/GPL-2.0-only.txt LICENSES/MIT.txt \
         packaging/systemd/fractalsqld.service packaging/scripts/postinst.sh \
         packaging/scripts/postrm.sh packaging/debian-copyright; do
    if [[ ! -f "${REPO_ROOT}/${f}" ]]; then
        echo "missing ${REPO_ROOT}/${f}: refusing to package without it" >&2
        exit 1
    fi
done

PKG_ARCH="${1:-amd64}"
case "${PKG_ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${PKG_ARCH}': expected amd64 or arm64" >&2
        exit 2
        ;;
esac

case "${PKG_ARCH}" in
    amd64) RPM_ARCH="x86_64"  ; FSQL_PLATFORM="linux-x86_64"  ;;
    arm64) RPM_ARCH="aarch64" ; FSQL_PLATFORM="linux-aarch64" ;;
    # The arch was validated above, so reaching this arm is an internal
    # dispatch gap, not a user typo: fail loudly rather than let a
    # half-populated RPM_ARCH/FSQL_PLATFORM reach the staging below.
    *)     echo "internal error: unhandled arch '${PKG_ARCH}' (validated above)" >&2; exit 2 ;;
esac

SHIM="dist/${PKG_ARCH}/fractalsql.so"
DAEMON="dist/${PKG_ARCH}/fractalsqld"
MCP_BIN="dist/${PKG_ARCH}/fractalsql-mariadb-mcp"
HAVE_MCP=0
if [[ -f "${MCP_BIN}" ]]; then
    HAVE_MCP=1
else
    echo "warning: ${MCP_BIN} not found: packaging without the MCP server (run ./build.sh ${PKG_ARCH})" >&2
fi
for f in "${SHIM}" "${DAEMON}"; do
    if [[ ! -f "${f}" ]]; then
        echo "missing ${f}: run ./build.sh ${PKG_ARCH} first" >&2
        exit 1
    fi
done

# The reasoning plugin (fractalsql-reasoning-http.so) is a standalone
# dlopen'd .so, not linked into fractalsql.so itself. Cognition
# (fractal_reason/fractal_embed), Text-to-SQL, the Vectorizer, and the
# Agency tier are all unusable without it landing in plugin_dir
# alongside fractalsql.so. It's vendored per-arch under include/, same
# artifact the demo Dockerfile and the darwin release .zip already
# ship. Links libcurl at runtime; the libcurl dependency is declared on
# the package below rather than statically linked.
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
REASONING_SIG="${REASONING_SO}.sig"
if [[ ! -f "${REASONING_SO}" ]]; then
    echo "missing ${REASONING_SO}: re-run the vendored-artifact deploy step" >&2
    exit 1
fi
# The plugin loads only when its detached Ed25519 signature (exactly 64 bytes) sits beside it,
# so a package must never carry the plugin without the signature.
if [[ ! -f "${REASONING_SIG}" || "$(wc -c < "${REASONING_SIG}")" -ne 64 ]]; then
    echo "missing or invalid ${REASONING_SIG} (needs 64 bytes): re-run the vendored-artifact deploy step" >&2
    exit 1
fi

DEB_OUT="${DIST_DIR}/${PKG_NAME}-${PKG_ARCH}.deb"
RPM_OUT="${DIST_DIR}/${PKG_NAME}-${PKG_ARCH}.rpm"

# Build per-format staging roots. mariadbd's plugin_dir differs across
# distros and we must match each one or CREATE FUNCTION will fail to
# find the .so at runtime:
#
#   Debian/Ubuntu mariadb-server (apt):
#       plugin_dir = /usr/lib/mysql/plugin/
#   RHEL/CentOS/Rocky Linux MariaDB-server (MariaDB Foundation's own
#   repo, via mariadb_repo_setup -- what install-test.yml actually
#   installs):
#       plugin_dir = /usr/lib64/mysql/plugin/  (confirmed live via
#                                               SELECT @@plugin_dir on
#                                               rockylinux:9, majors
#                                               10.6/10.11/11.4/12.3)
#
# The daemon fractalsqld is architecture-dependent but not plugin_dir-
# dependent: it is a standalone executable, not dlopen'd by mariadbd, so
# both layouts stage it at the same /usr/libexec/fractalsql/fractalsqld.
#
# LICENSE ledger: staged into /usr/share/doc/<pkg>/ via install -Dm0644
# BEFORE running fpm. Explicit fpm src=dst mappings break here: fpm's
# -C chroots absolute source paths too, so ${REPO_ROOT}/LICENSE gets
# resolved as ${STAGE}${REPO_ROOT}/LICENSE and fpm bails with
# "Cannot chdir to ...".
STAGE_DEB="$(mktemp -d)"
STAGE_RPM="$(mktemp -d)"
trap 'rm -rf "${STAGE_DEB}" "${STAGE_RPM}"' EXIT

# Per-binary license placement: the shim is GPL-2.0-only and the daemon
# (and the vendored core it links) is Apache-2.0. One license text per
# component, plus the GPL source offer and the third-party notices,
# staged once under /usr/share/doc/<pkg>/ and referenced from the
# Debian copyright file (packaging/debian-copyright) and the RPM's
# compound License: tag below.
stage_common() {
    local stage="$1"
    install -Dm0644 sql/install_udf.sql \
        "${stage}/usr/share/${PKG_NAME}/install_udf.sql"
    install -Dm0644 "${REPO_ROOT}/LICENSES/Apache-2.0.txt" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-Apache-2.0"
    install -Dm0644 "${REPO_ROOT}/LICENSES/GPL-2.0-only.txt" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-GPL-2.0-only"
    install -Dm0644 "${REPO_ROOT}/LICENSES/MIT.txt" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-MIT"
    install -Dm0644 "${REPO_ROOT}/GPL-SOURCE-OFFER.txt" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-GPL-SOURCE-OFFER"
    install -Dm0644 "${REPO_ROOT}/THIRD-PARTY-NOTICES.md" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-THIRD-PARTY"
    install -Dm0755 "${DAEMON}" \
        "${stage}/usr/libexec/fractalsql/fractalsqld"
    install -Dm0644 "${REPO_ROOT}/packaging/systemd/fractalsqld.service" \
        "${stage}/usr/lib/systemd/system/fractalsqld.service"
}

# The MCP server (a client of the database, Apache-2.0). The binary and its two lock files go to /usr/bin together:
# the server looks for the locks beside its own executable, so nothing depends on /usr/share/doc (some images strip
# it). The README and the manifest are documentation and travel with the other docs.
stage_mcp() {
    local stage="$1"
    [[ "${HAVE_MCP}" = "1" ]] || return 0
    install -Dm0755 "${REPO_ROOT}/${MCP_BIN}" "${stage}/usr/bin/fractalsql-mariadb-mcp"
    for f in .mcp-schema-lock .mcp-safety-annotations-lock; do
        install -Dm0644 "${REPO_ROOT}/mcp/${f}" "${stage}/usr/bin/${f}"
    done
    for f in README.md manifest.json; do
        install -Dm0644 "${REPO_ROOT}/mcp/${f}" "${stage}/usr/share/doc/${PKG_NAME}/mcp/${f}"
    done
}

# Debian layout. debian/copyright (DEP-5): the one Debian-specific path
# dpkg tooling actually looks for, so it ships at the exact conventional
# name and location rather than alongside the other LICENSE-* files.
install -Dm0755 "${SHIM}" \
    "${STAGE_DEB}/usr/lib/mysql/plugin/fractalsql.so"
install -Dm0755 "${REASONING_SO}" \
    "${STAGE_DEB}/usr/lib/mysql/plugin/fractalsql-reasoning-http.so"
install -Dm0644 "${REASONING_SIG}" \
    "${STAGE_DEB}/usr/lib/mysql/plugin/fractalsql-reasoning-http.so.sig"
stage_common "${STAGE_DEB}"
stage_mcp "${STAGE_DEB}"
install -Dm0644 "${REPO_ROOT}/packaging/debian-copyright" \
    "${STAGE_DEB}/usr/share/doc/${PKG_NAME}/copyright"

# RHEL layout. rockylinux:9 + MariaDB Foundation's own MariaDB-server
# package (mariadb_repo_setup, what install-test.yml installs) reports
# @@plugin_dir = /usr/lib64/mysql/plugin/, not /usr/lib64/mariadb/plugin/
# -- confirmed live across majors 10.6/10.11/11.4/12.3. A distro-stock
# mariadb-server package may differ; this targets the Foundation repo
# since that's what the install-test CI (and this script's own users
# following docs/getting-started.md) actually installs.
install -Dm0755 "${SHIM}" \
    "${STAGE_RPM}/usr/lib64/mysql/plugin/fractalsql.so"
install -Dm0755 "${REASONING_SO}" \
    "${STAGE_RPM}/usr/lib64/mysql/plugin/fractalsql-reasoning-http.so"
install -Dm0644 "${REASONING_SIG}" \
    "${STAGE_RPM}/usr/lib64/mysql/plugin/fractalsql-reasoning-http.so.sig"
stage_common "${STAGE_RPM}"
stage_mcp "${STAGE_RPM}"
# RPM has no equivalent single conventional copyright path; the same
# per-component LICENSE-* files staged by stage_common cover it, under
# the common /usr/share/licenses/<pkg>/ convention too.
install -Dm0644 "${REPO_ROOT}/LICENSES/Apache-2.0.txt" \
    "${STAGE_RPM}/usr/share/licenses/${PKG_NAME}/LICENSE-Apache-2.0"
install -Dm0644 "${REPO_ROOT}/LICENSES/GPL-2.0-only.txt" \
    "${STAGE_RPM}/usr/share/licenses/${PKG_NAME}/LICENSE-GPL-2.0-only"

echo "------------------------------------------"
echo "Packaging ${PKG_NAME} (${PKG_ARCH})"
echo "------------------------------------------"

# No LuaJIT anywhere in this build (pure-C vendored core, statically
# linked): no libluajit-5.1-2 (Debian) or luajit (RPM) runtime
# dependency. libcurl IS a real runtime dependency of the bundled
# fractalsql-reasoning-http.so (dlopen-linked, not statically linked).
# libssl/libcrypto IS a real runtime dependency of fractalsqld (dynamic
# link against the system OpenSSL, for the enterprise .so's Ed25519
# signature check -- not statically linked, unlike the Windows build).
fpm -s dir -t deb \
    -n "${PKG_NAME}" \
    -v "${VERSION}" \
    -a "${PKG_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL: Stochastic Fractal Search UDF for MariaDB (10.6 / 10.11 / 11.4 LTS, 12.3 LTS)" \
    --license "${PKG_LICENSE}" \
    --depends "libc6 (>= ${GLIBC_DEP})" \
    --depends "libcurl4" \
    --depends "libssl3" \
    --depends "libmariadb3" \
    --depends "mariadb-server" \
    --after-install "${REPO_ROOT}/packaging/scripts/postinst.sh" \
    --before-remove "${REPO_ROOT}/packaging/scripts/postrm.sh" \
    -C "${STAGE_DEB}" \
    -p "${DEB_OUT}" \
    usr

fpm -s dir -t rpm \
    -n "${PKG_NAME}" \
    -v "${VERSION}" \
    -a "${RPM_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL: Stochastic Fractal Search UDF for MariaDB (10.6 / 10.11 / 11.4 LTS, 12.3 LTS)" \
    --license "${PKG_LICENSE}" \
    --depends "libcurl.so.4()(64bit)" \
    --depends "libcrypto.so.3()(64bit)" \
    --depends "libmariadb.so.3()(64bit)" \
    --depends "mariadb-server" \
    --after-install "${REPO_ROOT}/packaging/scripts/postinst.sh" \
    --before-remove "${REPO_ROOT}/packaging/scripts/postrm.sh" \
    -C "${STAGE_RPM}" \
    -p "${RPM_OUT}" \
    usr

rm -rf "${STAGE_DEB}" "${STAGE_RPM}"
trap - EXIT

echo
echo "Done. Packages in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
