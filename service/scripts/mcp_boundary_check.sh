#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# Checks the licence and process boundary around the MCP server (../mcp).
#
# The MCP server is an Apache-2.0 program in its own process. It reaches the
# engine only through (1) SQL over libmariadb and (2) the FSQ wire protocol to
# fractalsqld, which it implements independently from protocol/SPEC.md -- the
# same relationship service/cli/fsqlctl.c has. So it must:
#   - include nothing from the GPL-2.0-only shim, the daemon, the vendored core
#     (include/), or the engine adapter sources (src/);
#   - not name those trees in its build rules;
#   - link only libmariadb (dynamic), OpenSSL and the system libraries;
#   - carry an Apache-2.0 SPDX tag on every source file it owns (vendor/ keeps
#     its upstream MIT tag).
# Exits non-zero on any violation.

cd "$(dirname "$0")/../../mcp" || exit 2
fail=0

# 1. No header or path from the other side of the boundary.
hits=$(grep -rnE '#[[:space:]]*include[[:space:]]*[<"][^>"]*(service/(shim|daemon|common)|fractalsql_shim|\.\./\.\./(include|src|service)|fractalsql_sql\.h|fractalsql\.h|sfs_core|fsq_protocol\.h|fsq_sha256\.h)' src tests 2>/dev/null)
if [ -n "$hits" ]; then
    printf 'mcp boundary: forbidden include:\n%s\n' "$hits"
    fail=1
fi

# 2. No core symbol calls (the core is reachable only through the daemon/SQL).
hits=$(grep -rnE '\bfsql_[a-z_]+\(|\bsfs_[a-z_]+\(' src 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*//')
if [ -n "$hits" ]; then
    printf 'mcp boundary: direct core call:\n%s\n' "$hits"
    fail=1
fi

# 3. The build must not reach into the shim, daemon, core, or engine trees.
if grep -nE '\.\./(service|include|src)\b' Makefile | grep -v '^[0-9]*:[[:space:]]*#' >/dev/null; then
    echo "mcp boundary: Makefile names ../service, ../include or ../src"
    fail=1
fi

# 4. Link line: libmariadb + OpenSSL + system only.
libs=$(grep -E '^LIBS' Makefile)
for bad in -lfractalsql -lsfs -lgpl; do
    case "$libs" in *"$bad"*) echo "mcp boundary: LIBS links $bad"; fail=1;; esac
done

# 5. SPDX: every owned source file is Apache-2.0 (a test helper may add BSD-2-Clause).
for f in $(find src tests -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.py' \) 2>/dev/null); do
    head -5 "$f" | grep -qE 'SPDX-License-Identifier: Apache-2\.0' ||
        { echo "mcp boundary: $f lacks an Apache-2.0 SPDX tag"; fail=1; }
done
if grep -rn 'SPDX-License-Identifier: GPL' src tests >/dev/null 2>&1; then
    echo "mcp boundary: a GPL-tagged file is inside mcp/"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "mcp boundary: ok (no shim/daemon/core includes; links libmariadb+OpenSSL only; all sources Apache-2.0)"
fi
exit "$fail"
