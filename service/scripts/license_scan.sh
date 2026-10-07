#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# License scan (spec 12.3, A1): the shim tree must hold no core files,
# no core headers, and no OpenSSL includes.
set -u
cd "$(dirname "$0")/.." || exit 2
fail=0
for dir in shim common protocol; do
    hits=$(grep -rnE 'fractalsql_sql\.h|fractalsql\.h|sfs_core|fsql_|openssl|libcrypto|\.\./include/|\.\./\.\./include|src/fractalsql' "$dir" 2>/dev/null)
    if [ -n "$hits" ]; then
        printf 'license scan: forbidden reference in %s:\n%s\n' "$dir" "$hits"
        fail=1
    fi
done
for f in shim/fractalsql_shim.c; do
# REUSE-IgnoreStart: the grep pattern below is a string, not a license tag
    grep -q 'SPDX-License-Identifier: GPL-2.0-only' "$f" || { echo "license scan: $f lacks GPL-2.0-only SPDX"; fail=1; }
# REUSE-IgnoreEnd
done
[ "$fail" -eq 0 ] && echo "license scan: PASS"
exit "$fail"
