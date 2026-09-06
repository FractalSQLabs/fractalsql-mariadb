#!/bin/sh
# shellcheck shell=sh  # Intentionally POSIX: runs in minimal builder stages where bash may be absent.
# docker/assert_so.sh: zero-dependency posture check for fractalsql.so.
#
# Usage: assert_so.sh <path/to/fractalsql.so> <size_ceiling_bytes>
#
# Fails the build if:
#   * ldd reports any dynamic library outside the glibc shortlist
#   * nm reports __cxx11::basic_string symbols (cxx11 ABI leak)
#   * the .so exceeds the size ceiling
#   * expected UDF entry points are missing from .dynsym
#
# Run inside the builder stage so problems are caught before the .so
# is emitted to the export stage.

set -eu

SO="${1:?usage: assert_so.sh <so> <ceiling>}"
CEILING="${2:?usage: assert_so.sh <so> <ceiling>}"

echo "=== assert_so.sh ${SO} (ceiling ${CEILING} bytes) ==="

echo "--- file ---"
file "${SO}"

echo "--- ldd ---"
ldd "${SO}" || true

# Assertion 1: no dynamic libluajit / libstdc++ dependency.
if ldd "${SO}" | grep -E 'libluajit|libstdc\+\+' >/dev/null; then
    echo "FAIL: ${SO} links dynamic libluajit or libstdc++" >&2
    exit 1
fi

# Assertion 2: every library listed by ldd is on the glibc shortlist.
#   linux-vdso.so.1       (kernel-provided, no file)
#   libc.so.6
#   libm.so.6
#   libdl.so.2            (merged into libc on glibc 2.34+, may still appear)
#   libpthread.so.0       (merged into libc on glibc 2.34+, may still appear)
#   /lib*/ld-linux-*.so.* (dynamic loader)
BAD=$(ldd "${SO}" \
        | awk '{print $1}' \
        | grep -vE '^(linux-vdso\.so\.1|libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|/.*/ld-linux.*\.so\.[0-9]+)$' \
        | grep -v '^$' || true)
if [ -n "${BAD}" ]; then
    echo "FAIL: ${SO} has disallowed dynamic deps:" >&2
    echo "${BAD}" >&2
    exit 1
fi

# Assertion 3: no __cxx11::basic_string symbols (ABI hygiene).
echo "--- nm -D -C | grep __cxx11::basic_string ---"
if nm -D -C "${SO}" 2>/dev/null | grep -F '__cxx11::basic_string' >/dev/null; then
    echo "FAIL: ${SO} exposes __cxx11::basic_string symbols" >&2
    nm -D -C "${SO}" | grep -F '__cxx11::basic_string' >&2 || true
    exit 1
fi

# Assertion 4: size ceiling.
SZ=$(stat -c '%s' "${SO}")
echo "size: ${SZ} bytes (ceiling ${CEILING})"
if [ "${SZ}" -gt "${CEILING}" ]; then
    echo "FAIL: ${SO} exceeds size ceiling ${CEILING}" >&2
    exit 1
fi

# Assertion 5: UDF entry points are in .dynsym. Without these, MariaDB's
# dlsym(fractal_search) fails at CREATE FUNCTION time.
echo "--- dynsym UDF entry points ---"
for sym in fractal_search fractal_search_init fractal_search_deinit \
           fractal_explore fractal_explore_init fractal_explore_deinit \
           fractalsql_edition fractalsql_edition_init fractalsql_edition_deinit \
           fractalsql_version fractalsql_version_init fractalsql_version_deinit; do
    if ! nm -D "${SO}" 2>/dev/null | awk '{print $NF}' | grep -Fx "${sym}" >/dev/null; then
        echo "FAIL: ${sym} missing from .dynsym" >&2
        exit 1
    fi
done
echo "ok: all UDF entry points exported"

echo "OK: ${SO}"
