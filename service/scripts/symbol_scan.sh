#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Symbol scan (spec 12.3, A2): the shim binary imports no OpenSSL symbols and
# no core symbols. Only UDF ABI and libc imports are allowed.
#
# GNU nm (Linux) needs -D (dynamic symbol table) to see anything in a
# stripped .so; Apple/BSD nm has no -D and lists a dylib's undefined
# imports with plain -gu, each name carrying the C symbol prefix ("_"),
# e.g. "_EVP_DigestVerify" -- the forbidden-prefix match below allows an
# optional leading underscore so one pattern covers both platforms.
set -u
so="$1"
[ -f "$so" ] || { echo "symbol scan: missing $so"; exit 2; }
if [ "$(uname -s)" = "Darwin" ]; then
    imports=$(nm -gu "$so" 2>/dev/null | awk '{print $NF}')
else
    imports=$(nm -D --undefined-only "$so" | awk '{print $NF}')
fi
bad=$(printf '%s\n' "$imports" | grep -E '^_?(EVP_|OPENSSL_|CRYPTO_|HMAC_|SHA256_|fsql_|sfs_|fractal_|fsq_core)' || true)
if [ -n "$bad" ]; then
    printf 'symbol scan: forbidden imports in %s:\n%s\n' "$so" "$bad"
    exit 1
fi
if strings "$so" | grep -qE 'libcrypto|libssl|EVP_DigestVerify'; then
    echo "symbol scan: forbidden string (libcrypto/libssl/EVP) in $so"
    exit 1
fi
echo "symbol scan: PASS ($(printf '%s\n' "$imports" | grep -c .) undefined symbols, none forbidden)"
