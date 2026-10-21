#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# scripts/macos/build-mcp.sh -- build fractalsql-mariadb-mcp for macOS, for either architecture, from any runner.
#
#   build-mcp.sh <arm64|x86_64> <openssl-prefix> <output-binary>
#
# Native build (the target is the host's own architecture): the Homebrew MariaDB Connector/C and OpenSSL, through
# the Makefile's own mariadb_config / pkg-config lookup -- the same build build_test.sh exercises on macOS.
#
# Cross build (Intel on an Apple Silicon runner): Homebrew libraries exist for the host architecture only, and
# Homebrew no longer ships Intel bottles, so Connector/C is built from source for the target architecture and
# linked statically with the target-architecture OpenSSL below. The result needs no Homebrew at run time.
#
# <openssl-prefix> is used by the cross build only: include/ and lib/libssl.a + lib/libcrypto.a for the target arch.
set -euo pipefail

ARCH="${1:?arch (arm64|x86_64)}"
SSL="${2:?openssl prefix}"
OUT="${3:?output binary path}"
case "${ARCH}" in arm64|x86_64) ;; *) echo "unknown arch '${ARCH}'" >&2; exit 2 ;; esac

CC_VERSION=3.4.11
CC_SHA256=7cdb35c571dd0c187f806f569285829d31b4aba4feb93957a034b0b1e887e276
# -mmacosx-version-min=13.3: src/vectors.cpp uses std::to_chars on a double, which Apple's libc++ marks
# unavailable before 13.3. The server is a separate binary from the extension and carries its own minimum.
MIN=13.3

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

build_native() {
    local prefix_cc; prefix_cc="$(brew --prefix mariadb-connector-c)"
    export PATH="${prefix_cc}/bin:${PATH}"
    export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    make -C "${HERE}/mcp" clean
    make -C "${HERE}/mcp" -j"$(sysctl -n hw.ncpu)"
}

build_cross() {
curl -fsSL --proto '=https' -o "${WORK}/cc.tar.gz" \
    "https://github.com/mariadb-corporation/mariadb-connector-c/archive/refs/tags/v${CC_VERSION}.tar.gz"
echo "${CC_SHA256}  ${WORK}/cc.tar.gz" | shasum -a 256 -c -
mkdir -p "${WORK}/src"
tar -xzf "${WORK}/cc.tar.gz" -C "${WORK}/src" --strip-components=1

cmake -S "${WORK}/src" -B "${WORK}/build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="${ARCH}" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MIN}" \
    -DCMAKE_INSTALL_PREFIX="${WORK}/prefix" \
    -DWITH_SSL=OPENSSL -DOPENSSL_ROOT_DIR="${SSL}" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_EXTERNAL_ZLIB=ON -DWITH_UNIT_TESTS=OFF -DWITH_CURL=OFF \
    -DCLIENT_PLUGIN_DIALOG=STATIC -DCLIENT_PLUGIN_MYSQL_CLEAR_PASSWORD=STATIC \
    -DCLIENT_PLUGIN_SHA256_PASSWORD=STATIC -DCLIENT_PLUGIN_CACHING_SHA2_PASSWORD=STATIC \
    -DCLIENT_PLUGIN_CLIENT_ED25519=STATIC \
    -DCLIENT_PLUGIN_ZSTD=OFF -DCLIENT_PLUGIN_PARSEC=OFF -DCLIENT_PLUGIN_AUTH_GSSAPI_CLIENT=OFF \
    -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew:/usr/local
cmake --build "${WORK}/build" -j"$(sysctl -n hw.ncpu)"
cmake --install "${WORK}/build"

LIBMARIADB="$(find "${WORK}/prefix" -name 'libmariadbclient.a' -print -quit)"
INCDIR="$(find "${WORK}/prefix/include" -name mysql.h -print -quit | xargs dirname)"
[[ -f "${LIBMARIADB}" && -d "${INCDIR}" ]] || { echo "Connector/C install is missing its library or headers" >&2; exit 1; }
for f in "${SSL}/lib/libssl.a" "${SSL}/lib/libcrypto.a"; do
    [[ -f "${f}" ]] || { echo "missing ${f}: the OpenSSL prefix has no static libraries" >&2; exit 1; }
done

make -C "${HERE}/mcp" clean
make -C "${HERE}/mcp" -j"$(sysctl -n hw.ncpu)" \
    CXXFLAGS="-std=c++17 -O2 -Wall -Wextra -arch ${ARCH} -mmacosx-version-min=${MIN} -I${INCDIR} -I${SSL}/include" \
    LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${MIN}" \
    LIBS="${LIBMARIADB} ${SSL}/lib/libssl.a ${SSL}/lib/libcrypto.a -lz -lpthread -lm"

}

HOST="$(uname -m)"
if [[ "${ARCH}" = "${HOST}" ]]; then build_native; else build_cross; fi

BIN="${HERE}/mcp/fractalsql-mariadb-mcp"
lipo -info "${BIN}" | grep -q "${ARCH}" || { echo "not a ${ARCH} binary: $(lipo -info "${BIN}")" >&2; exit 1; }
if [[ "${ARCH}" != "${HOST}" ]] && otool -L "${BIN}" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' | grep -q .; then
    echo "the binary depends on a library outside the system:" >&2
    otool -L "${BIN}" >&2
    exit 1
fi
mkdir -p "$(dirname "${OUT}")"
cp "${BIN}" "${OUT}"
echo "built ${OUT} ($(lipo -info "${OUT}"))"
