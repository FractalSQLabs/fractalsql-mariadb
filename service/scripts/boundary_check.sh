#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Checks the process boundary between the GPL-2.0-only shim and the
# Apache-2.0 daemon. The shim may include only the host database header, the
# C standard and system socket/pipe headers, and the two protocol headers
# under protocol/ and common/. It must not reference the core, the adapter
# sources, or the vendored include/ tree. The protocol and common headers
# must not include any core header either. Exits non-zero on any violation.

cd "$(dirname "$0")/.." || exit 2
fail=0

ok_shim_includes='
mysql.h
errno.h
fcntl.h
pthread.h
stdint.h
stdio.h
stdlib.h
string.h
sys/socket.h
sys/un.h
unistd.h
windows.h
../common/fsq_sha256.h
../protocol/fsq_protocol.h
shim_udfs.h
'

tmp=$(mktemp) || exit 2
trap 'rm -f "$tmp"' EXIT

f=shim/fractalsql_shim.c
grep -n '^[[:space:]]*#[[:space:]]*include' "$f" > "$tmp"
while IFS= read -r line; do
    hdr=$(printf '%s\n' "$line" | sed -n 's/.*#[[:space:]]*include[[:space:]]*[<"]\([^>"]*\)[>"].*/\1/p')
    if ! printf '%s\n' "$ok_shim_includes" | grep -qx "$hdr"; then
        echo "boundary: $f includes '$hdr', which is not on the shim allow-list"
        fail=1
    fi
done < "$tmp"

if grep -n -e '\.\./include' -e '\.\./src' -e 'fractalsql\.h' -e 'fractalsql_sql\.h' \
        -e 'fractalsql_[a-z]*\.h' -e '\bfsql_[a-z_]*(' "$f" > "$tmp"; [ -s "$tmp" ]; then
    echo "boundary: $f references core or vendored code:"
    cat "$tmp"
    fail=1
fi

for f in protocol/fsq_protocol.h common/fsq_sha256.h; do
    grep -n '^[[:space:]]*#[[:space:]]*include' "$f" |
        grep -v -e '<stddef.h>' -e '<stdint.h>' -e '<string.h>' -e '<stdbool.h>' -e '"opcodes.def"' > "$tmp"
    if [ -s "$tmp" ]; then
        echo "boundary: $f includes something outside the standard C headers and its own registry:"
        cat "$tmp"
        fail=1
    fi
done

if grep -n -e '\.\./include' -e '\.\./src' Makefile | grep -i 'shim' >/dev/null; then
    echo "boundary: the shim build rule in Makefile names a core or adapter path"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "boundary: ok (shim includes limited to the allow-list; no core or vendored references)"
fi
exit "$fail"
