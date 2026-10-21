#!/bin/sh
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# The demo container's one-liner MCP tool call:
#
#   docker compose exec mariadb /demo/mcp/call-tool.sh fractal_search \
#       '{"query":[0.6,0.8,0.0],"corpus":[[0.1,0.9,0.0]],"k":1}'
#
# Runs the PRODUCTION MCP server binary (the same one mcp/ builds) with
# its tool table --tool-filtered to exactly the four pinned demo tools
# rather than a second, drifting demo implementation (the demo owns
# only this wrapper, not its own server).
#
# The MCP server is a CLIENT of the database, not an in-process
# extension: it opens its own MariaDB connection (MARIADB_* env) and
# calls the engine's stored procedures and UDFs over that connection,
# while the UDF bodies themselves run in the separate fractalsqld
# daemon. So the demo's own credentials/posture are reused here
# deliberately -- this is NOT a production posture.
#
set -eu

# The demo directory, resolved from this script's own location, so the
# same wrapper works both in the container (staged at /demo/mcp/) and
# from a checkout (demo/mcp/).
DEMO="$(cd "$(dirname "$0")" && pwd)"
DEMO_TOOLS=fractal_search,fractal_reason,fractal_agent_data_analyst,fractal_agent_diverse_portfolios

# Resolve the server binary. The in-container path comes first (that is
# where the image stages it), then the repo-checkout build, so the same
# wrapper works outside the container against a locally built server.
#
# The Windows build lands in mcp/dist/windows-mcp/ as an .exe and the
# POSIX build lands in mcp/ as an extensionless binary; only one of the
# two can actually run on the host, so the platform's own candidate is
# tried first.
case "$(uname -s 2>/dev/null || echo Windows)" in
    MINGW*|MSYS*|CYGWIN*|Windows*)
        CANDIDATES="
/usr/local/bin/fractalsql-mariadb-mcp.exe
$(dirname "$0")/../../mcp/dist/windows-mcp/fractalsql-mariadb-mcp.exe
$(dirname "$0")/../../mcp/fractalsql-mariadb-mcp.exe
" ;;
    *)
        CANDIDATES="
/usr/local/bin/fractalsql-mariadb-mcp
$(dirname "$0")/../../mcp/fractalsql-mariadb-mcp
" ;;
esac

SERVER=""
for CAND in $CANDIDATES; do
    if [ -f "$CAND" ]; then
        SERVER="$CAND"
        break
    fi
done
if [ -z "$SERVER" ]; then
    echo "ERROR: no fractalsql-mariadb-mcp binary found." >&2
    echo "The demo image stages the MCP server at" >&2
    echo "    /usr/local/bin/fractalsql-mariadb-mcp" >&2
    echo "so this wrapper needs no host build. Outside the container, build" >&2
    echo "it with:" >&2
    echo "    make -C mcp                          (Linux/macOS)" >&2
    echo "    mcp\\scripts\\windows\\build.bat      (Windows)" >&2
    echo "then re-run this wrapper." >&2
    exit 1
fi

# Demo-process connection config (the env contract), same database the
# demo image already stages. The server connects as an ordinary
# MariaDB client; the UDF bodies run in the fractalsqld daemon, which
# the server reaches through the shim the database has loaded.
if [ -z "${MARIADB_HOST:-}" ]; then
    MARIADB_HOST=127.0.0.1
    export MARIADB_HOST
fi
if [ -z "${MARIADB_PORT:-}" ]; then
    MARIADB_PORT=3306
    export MARIADB_PORT
fi
if [ -z "${MARIADB_USER:-}" ]; then
    MARIADB_USER=root
    export MARIADB_USER
fi
if [ -z "${MARIADB_PASSWORD:-}" ]; then
    MARIADB_PASSWORD=fractalsql
    export MARIADB_PASSWORD
fi
if [ -z "${MARIADB_DATABASE:-}" ]; then
    MARIADB_DATABASE=fractalsql_demo
    export MARIADB_DATABASE
fi

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <tool-name> ['{json args}']" >&2
    echo "demo tools: fractal_search, fractal_reason, fractal_agent_data_analyst," >&2
    echo "            fractal_agent_diverse_portfolios" >&2
    exit 2
fi
TOOL="$1"; shift
TOOL_ARGS="${1:-{\}}"

# Server argv = [binary, --tool, <four demo tools>]; the named tool and
# its JSON arguments travel only inside the JSON-RPC tools/call payload
# (call-tool.py splits the server command at the first '--').
exec python3 "$DEMO/call-tool.py" \
    "$SERVER" --tool "$DEMO_TOOLS" \
    -- "$TOOL" "$TOOL_ARGS"
