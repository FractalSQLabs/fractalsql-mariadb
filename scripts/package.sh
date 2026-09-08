#!/usr/bin/env bash
#
# scripts/package.sh: fractalsql-mariadb packaging.
#
# Assumes ./build.sh ${ARCH} has produced:
#   dist/${ARCH}/fractalsql.so
#
# Emits one .deb and one .rpm per arch into dist/packages/:
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
[ -n "${VERSION}" ] || { echo "could not determine VERSION (FSQL_VERSION not found in src/fractalsql.c)" >&2; exit 1; }
ITERATION="1"
DIST_DIR="dist/packages"

# GLIBC_DEP matches the build target in build.sh: the .so compiles
# inside rockylinux:9 (glibc 2.34).
GLIBC_DEP="2.34"
PKG_NAME="fractalsql-mariadb"
mkdir -p "${DIST_DIR}"

# Absolute repo root, captured before any -C chdir'd fpm invocation.
REPO_ROOT="$(pwd)"
for f in LICENSE THIRD-PARTY-NOTICES.md; do
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
esac

SO="dist/${PKG_ARCH}/fractalsql.so"
if [[ ! -f "${SO}" ]]; then
    echo "missing ${SO}: run ./build.sh ${PKG_ARCH} first" >&2
    exit 1
fi

# The reasoning plugin (fractalsql-reasoning-http.so) is a standalone
# dlopen'd .so, not linked into fractalsql.so itself. Cognition
# (fractal_reason/fractal_embed), Text-to-SQL, the Vectorizer, and the
# Agency tier are all unusable without it landing in plugin_dir
# alongside fractalsql.so. It's vendored per-arch under include/, same
# artifact the demo Dockerfile and the darwin release .zip already
# ship. Links libcurl at runtime; the libcurl dependency is declared on
# the package below rather than statically linked.
REASONING_SO="include/${FSQL_PLATFORM}/fractalsql-reasoning-http.so"
if [[ ! -f "${REASONING_SO}" ]]; then
    echo "missing ${REASONING_SO}: re-run the vendored-artifact deploy step" >&2
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
#   RHEL/CentOS/Rocky Linux mariadb-server (yum):
#       plugin_dir = /usr/lib64/mariadb/plugin/  (MariaDB 10.4+ on EL9
#                                                 uses its OWN tree,
#                                                 not /usr/lib64/mysql/)
#
# LICENSE ledger: staged into /usr/share/doc/<pkg>/ via install -Dm0644
# BEFORE running fpm. Explicit fpm src=dst mappings break here: fpm's
# -C chroots absolute source paths too, so ${REPO_ROOT}/LICENSE gets
# resolved as ${STAGE}${REPO_ROOT}/LICENSE and fpm bails with
# "Cannot chdir to ...".
STAGE_DEB="$(mktemp -d)"
STAGE_RPM="$(mktemp -d)"
trap 'rm -rf "${STAGE_DEB}" "${STAGE_RPM}"' EXIT

stage_common() {
    local stage="$1"
    install -Dm0644 sql/install_udf.sql \
        "${stage}/usr/share/${PKG_NAME}/install_udf.sql"
    install -Dm0644 "${REPO_ROOT}/LICENSE" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE"
    install -Dm0644 "${REPO_ROOT}/THIRD-PARTY-NOTICES.md" \
        "${stage}/usr/share/doc/${PKG_NAME}/LICENSE-THIRD-PARTY"
}

# Debian layout.
install -Dm0755 "${SO}" \
    "${STAGE_DEB}/usr/lib/mysql/plugin/fractalsql.so"
install -Dm0755 "${REASONING_SO}" \
    "${STAGE_DEB}/usr/lib/mysql/plugin/fractalsql-reasoning-http.so"
stage_common "${STAGE_DEB}"

# RHEL layout. MariaDB 10.4+ on EL9 reports
# @@plugin_dir = /usr/lib64/mariadb/plugin/, its own tree, not
# /usr/lib64/mysql/plugin/. Earlier docs and other UDF projects
# sometimes claim /usr/lib64/mysql/plugin/; that path is wrong on
# current MariaDB. Verified against rockylinux:9 + stock
# mariadb-server (10.5) + 11.4.
install -Dm0755 "${SO}" \
    "${STAGE_RPM}/usr/lib64/mariadb/plugin/fractalsql.so"
install -Dm0755 "${REASONING_SO}" \
    "${STAGE_RPM}/usr/lib64/mariadb/plugin/fractalsql-reasoning-http.so"
stage_common "${STAGE_RPM}"

echo "------------------------------------------"
echo "Packaging ${PKG_NAME} (${PKG_ARCH})"
echo "------------------------------------------"

# No LuaJIT anywhere in this build (pure-C vendored core, statically
# linked): no libluajit-5.1-2 (Debian) or luajit (RPM) runtime
# dependency. libcurl IS a real runtime dependency of the bundled
# fractalsql-reasoning-http.so (dlopen-linked, not statically linked).
fpm -s dir -t deb \
    -n "${PKG_NAME}" \
    -v "${VERSION}" \
    -a "${PKG_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL: Stochastic Fractal Search UDF for MariaDB (10.6 / 10.11 / 11.4 LTS, 12.3 LTS)" \
    --license "Apache-2.0" \
    --depends "libc6 (>= ${GLIBC_DEP})" \
    --depends "libcurl4" \
    --depends "mariadb-server" \
    -C "${STAGE_DEB}" \
    -p "${DEB_OUT}" \
    usr

fpm -s dir -t rpm \
    -n "${PKG_NAME}" \
    -v "${VERSION}" \
    -a "${RPM_ARCH}" \
    --iteration "${ITERATION}" \
    --description "FractalSQL: Stochastic Fractal Search UDF for MariaDB (10.6 / 10.11 / 11.4 LTS, 12.3 LTS)" \
    --license "Apache-2.0" \
    --depends "libcurl.so.4()(64bit)" \
    --depends "mariadb-server" \
    -C "${STAGE_RPM}" \
    -p "${RPM_OUT}" \
    usr

rm -rf "${STAGE_DEB}" "${STAGE_RPM}"
trap - EXIT

echo
echo "Done. Packages in ${DIST_DIR}:"
ls -l "${DIST_DIR}"
