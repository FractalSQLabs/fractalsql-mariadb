<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# fractalsql-mariadb-mcp

An MCP (Model Context Protocol) server for **FractalSQL for MariaDB** —
one clean tool per documented FractalSQL SQL symbol, so an external agent
(Claude Desktop, Cursor, Windsurf, Claude Code, LangChain, LlamaIndex, CrewAI, …) can call a primitive or one of the
sixteen installable agents without ever speaking `CALL
fractal_agent(…, @out) / SELECT @out`, the vector-string grammar, or
`CONNECTION_ID()` session plumbing.

Public-facing documentation (quickstart, per-tier tool catalog,
resources/prompts, operational caveats, troubleshooting) lives in
**[docs/mcp-plugin.md](../docs/mcp-plugin.md)**.
This README covers running the server and the deployment guidance the
docs assume.

This server is a **caller, not an installer**: it never runs DDL on the
target database. Run `sql/install_udf.sql` and `sql/install_agents.sql`
against the target database first (see docs/getting-started.md), and
keep `fractalsqld` running — it is a separate process that holds every
UDF body, the reasoning plugin and the enterprise ledger (see
docs/fractalsql-daemon.md). A call that reaches a stopped daemon fails
immediately with a clear error, never a hang.

## Layout (spec section 13.2's shape)

    mcp/
      Makefile                   POSIX build (no CMake, no package manager)
      scripts/windows/
        build.bat                MSVC 2022 + vcpkg OpenSSL static build
                                 -> dist\windows-mcp
      .mcp-schema-lock           committed tool-surface integrity hash (10.5)
      .mcp-safety-annotations-lock  committed safety-annotation hash (15.3)
      manifest.json              distribution manifest (15.5)
      src/                       C++17 sources
        main.cpp                 CLI flags, config from env, lock paths
        jsonrpc_server.cpp       MCP JSON-RPC dispatch, $/cancel, shutdown
        db.h / db.cpp            session connections, CALL/(OUT var) plumbing,
                                 KILL QUERY cancellation, bootstrap, skew guard
        fsqlctl.h / fsqlctl.cpp  the fractalsqld wire client (admin tools)
        tool_registry.cpp        tool table + the 11.1 error taxonomy
        adapters/                discovery | cognition | agency | analytics |
                                 enterprise | vectorizer | admin
        resources.cpp            fractalsql://schema|config|ledger/1|ledger/2|
                                 vectorizer/status|agents
        prompts.cpp              the eleven starter-kit prompts
        transport_stdio.cpp      default transport
        transport_http.cpp       optional HTTP transport (Bearer + probes)
        schema_lock.cpp          --write-schema-lock / startup check (10.5)
        safety_lock.cpp          --write-safety-annotations-lock / check (15.3)
        vectors.cpp              vector-argument normalization (1.4)
        rows.h                   row ceiling/truncation annotation (1.5)
      vendor/json.hpp            nlohmann::json v3.11.3, vendored
      tests/mcp_smoke_client.py  the mcp_smoke gate's client driver

The binary links MariaDB Connector/C and OpenSSL; it connects to a real
MariaDB server (unlike the engine's own shim, it never embeds a
database), and talks to the `fractalsqld` daemon only for the four
admin/config tools, over the daemon's own socket/named pipe and its own
HMAC key — that is the suite's one deliberate two-credential realm
(docs/mcp-plugin.md, "Admin").

## Building & running

```bash
# Linux/macOS: g++ or clang >= 11, OpenSSL dev headers,
# libmariadb-dev (for mariadb_config), make
make -C mcp                                   # -> mcp/fractalsql-mariadb-mcp

# Windows: VS 2022 + vcpkg's openssl:x64-windows-static (VCPKG_ROOT or
# ..\vcpkg), the repo's own MSVC posture; MARIADB_DIR names the MariaDB
# Windows tree whose Connector/C binaries the link uses
mcp\scripts\windows\build.bat                 # -> mcp\dist\windows-mcp\
```

Stdout is the MCP wire (stdio transport); **all logging goes to stderr**
as structured JSON lines — stdout must never be polluted.

```bash
MARIADB_HOST=127.0.0.1 MARIADB_PORT=3306 MARIADB_DATABASE=mydb \
MARIADB_USER=fractal_analyst MARIADB_PASSWORD=… \
  ./fractalsql-mariadb-mcp                    # stdio (default)

./fractalsql-mariadb-mcp --version             # release banner
./fractalsql-mariadb-mcp --list-tools          # the (filtered) tool table
./fractalsql-mariadb-mcp --http 8765           # optional HTTP transport
```

Configuration is environment-only (`MARIADB_HOST/PORT/DATABASE/USER/
PASSWORD`, the admin realm `FSQLCTL_SOCKET`/`FSQLCTL_KEY`/`FSQLCTL_CONF`,
and the `FSQL_MCP_*` family) plus the narrow flag set `--help` prints —
see the [settings reference](../docs/mcp-plugin.md#settings-reference) for
every setting and its default.

## Authentication

The **stdio** transport needs no credential: the client spawns the server
as a trusted subprocess and owns its lifetime.

The **HTTP** transport requires a bearer token, and refuses to serve
without one. There are two ways to hold it:

- `FSQL_MCP_AUTH_TOKEN` — one secret for the whole deployment — or
  `FSQL_MCP_AUTH_TOKEN_FILE`, which is re-read whenever its modification
  time changes, so a secrets manager can rotate it in place without a
  restart.
- `FSQL_MCP_TOKEN_POLICY_FILE` — a JSON file naming clients, so each
  caller can be revoked on its own, can expire, and can be given its own
  tool allowlist:

  ```json
  { "tokens": [ { "name": "analyst", "sha256": "<hex sha256 of the token>",
                  "tools": ["fractal_search"], "expires": "2027-01-31" } ] }
  ```

  The file holds the SHA-256 of each token, never the token itself. A
  policy file that cannot be read or parsed is a **startup failure** (the
  server exits with status 2); a *replacement* file that turns malformed
  later keeps the last good policy in force.

The credential is read from the `Authorization` header only — a token in
the query string is not a credential, because a query string lands in
proxy logs and access logs. A wrong or expired token is answered `401`
with `WWW-Authenticate: Bearer realm="fractalsql-mcp"`; an unapproved
browser `Origin` is answered `403` before the credential is even checked.
Repeated failures are slowed down, the comparison is constant-time, and
no token is ever written to a log line.

**TLS.** The HTTP transport can terminate TLS itself — set
`FSQL_MCP_HTTP_TLS=true` with `FSQL_MCP_TLS_CERT` and `FSQL_MCP_TLS_KEY`
(PEM, TLS 1.2 or newer) — or sit behind a reverse proxy that terminates
it in front while the server stays on loopback. A certificate that will
not load, a key that will not parse, and a certificate and key that do not
belong together are all hard startup failures: the server never falls
back to plaintext.

## Protocol versions

The server speaks both protocol eras at once, and the era a call arrived
in is on the operator's log line for that call.

The **legacy era** is the handshake-based one: `initialize` first, an
`Mcp-Session-Id` for the calls that follow. The server speaks five
revisions — `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` and
`2026-07-28` — and the handshake echoes back the revision the client
asked for, defaulting to `2025-06-18`.

The **modern era** is the stateless one. Every request carries
`MCP-Protocol-Version`, `Mcp-Method`, and, for the methods that address
something by name (`tools/call`, `prompts/get`, `resources/read`),
`Mcp-Name`; the headers must agree with the body's
`_meta.io.modelcontextprotocol/protocolVersion`. A missing or
disagreeing header is answered `-32020` (HTTP `400`), a revision the
modern era does not serve is `-32022` (HTTP `400`, with the supported
and requested revisions), and a method this server does not have is
`-32601` (HTTP `404`). The modern era also adds `server/discover`, which
returns every revision the server speaks.

`FSQL_MCP_PROTOCOL_ERA` chooses: `dual` (the default) serves both,
`modern` serves the modern era only and refuses the legacy handshake
outright.

## Session state

A **protocol session** (the legacy era's `Mcp-Session-Id`) owns one
MariaDB connection for its lifetime, so one client's session state cannot
contaminate another's.

A **context handle** (the modern era's `context_id`) is an opaque hex
string the server mints. It is bound to the credential that created it: a
handle owned by another token is reported as not existing, so a client can
neither use nor probe for a handle it does not own.

Both are bounded: `FSQL_MCP_SESSION_TTL_SECS` (default 3600) is how long
an idle one survives, and `FSQL_MCP_MAX_SESSIONS` (default 64) is how
many exist at once — a request past the cap is answered `503` rather
than queued.

## Data at rest

The audit chain is a **file** the enterprise tier owns, not a database
table: `enterprise_ledger_path` in `fractalsqld.conf` names it. The chain
file, its CSV mirror (`<ledger>.csv`) and the head file (`<ledger>.head`)
are all created `0600` and tightened again on every open.

`<ledger>.head` holds, per chain kind, how many records that chain was
ever appended — a hash chain cannot show that its newest records were cut
off the end, so the counter lives outside the chain. Each head record
carries an HMAC-SHA256 MAC keyed with the enterprise ledger key, and the
file is replaced atomically.

`fractal_ledger_verify` names what it found: a head record with no MAC
(written before the ledger key was set), a MAC that does not match its
contents (the head was edited by hand), a head file that will not parse
(corrupt, or edited by hand), or a chain holding fewer rows than the head
recorded (rows removed, or the ledger replaced).

`FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog`) publishes the head on every
append as one JSON line — `{"event":"ledger_head","kind":N,"rows":N,"hash":"…"}` —
so a truncation is visible from a store the database administrator cannot
rewrite. `FSQL_AUDIT_REDACT` chooses what the chain keeps of an entry's
free text: `none` (the default), `hash` (a `sha256:<hex> len=<bytes>`
fingerprint), or `truncate` (the first 64 characters).

## Least-privilege account guidance (spec 1.8)

The MCP server inherits whatever its connection is opened as and adds
**no second auth layer**. MariaDB's privilege model decides what every
tool can touch, and the account you configure is the boundary:

- Point `MARIADB_USER` at a least-privilege account and bake tenant
  filtering into **views**: MariaDB has no Row-Level Security, so grant
  `SELECT` on the tenant-filtered views instead of the base tables.
  Never trust the MCP boundary to restrict anything.
- Run the admin/config tools (`fractalsql_set_config`,
  `fractalsql_configure_reasoning`) against a separately-scoped server
  instance, or at least a separately-privileged MariaDB account, from
  ordinary tool traffic — the server logs a one-time warning when one
  connection looks like it would serve both.
- Point `fractal_sql_agent`/`fractal_agent_data_analyst`'s auto-execute
  behavior at the above: `auto_execute` defaults to false everywhere
  and requires an explicit client-set parameter to enable. Generated
  SQL executes under whatever account this server's MariaDB connection
  is opened as.
- `FSQL_MCP_READ_ONLY=true` is the deployment-wide stop switch (15.4)
  when you want every destructive call refused outright.
- The admin tools additionally need the daemon realm: an
  `FSQLCTL_SOCKET` + `FSQLCTL_KEY` (that key file's mode and custody
  are operator matters; the MCP layer only ever reads the key, never
  rotates it).

## Regenerating the locks/manifest

After any reviewed change to a tool's name/description/schema, safety
annotations, or catalog membership, rebuild and:

```bash
fractalsql-mariadb-mcp --write-schema-lock             # (10.5)
fractalsql-mariadb-mcp --write-safety-annotations-lock # (15.3)
fractalsql-mariadb-mcp --write-manifest                # (15.5)
git add .mcp-schema-lock .mcp-safety-annotations-lock manifest.json
                                                       # commit in the same PR as the change
```

A stale-lock startup is a hard failure by default;
`FSQL_MCP_STRICT_SCHEMA_HASH=false` downgrades it to a warning. The safety-annotation check is
always strict: any annotation drift is a hard startup failure (15.3),
and the smoke gate regenerates both locks into temp files and compares —
a forgotten lock regeneration fails the gate mechanically.

## Hardening switches

| Variable | Effect |
|---|---|
| `FSQL_MCP_READ_ONLY` | `true` / `1` / `on` / `yes` (any case). Refuses every tool that writes state, and applies the engine-side backstop where the engine has one. |
| `FSQL_MCP_ALLOW_MISSING_LOCKS` | Off by default. A missing schema or safety-annotation lock file stops startup; set `true` to run without the drift check (development only). An explicit `FSQL_MCP_REQUIRE_LOCKS=false` has the same effect. Lock files are looked up in the working directory first, then next to the executable. |
| `FSQL_MCP_STRICT_SCHEMA_HASH` | `true` by default. A tool-surface mismatch against the committed lock stops startup; `false` downgrades it to a warning. The safety-annotation check is always strict. |
| `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` | Off by default. The HTTP transport refuses to bind a non-loopback address without TLS (enable TLS with `FSQL_MCP_HTTP_TLS=true` and a certificate/key); set this to `true` to accept a plaintext bind on a network you control. |
| `FSQL_MCP_HTTP_TLS` | Off by default. Serve HTTPS instead of HTTP. Both `FSQL_MCP_TLS_CERT` and `FSQL_MCP_TLS_KEY` are required, and a certificate that will not load is a startup failure — there is no silent plaintext fallback. |
| `FSQL_MCP_ALLOWED_ORIGINS` | Off by default, in the sense that only loopback origins are allowed. A comma-separated list adds the browser origins a deployment permits. |
| `FSQL_MCP_TOKEN_POLICY_FILE` | Off by default. Names clients, so each can be revoked on its own, given an expiry, and given its own tool allowlist. A malformed policy file stops startup; a malformed replacement keeps the last good policy. |
| `FSQL_MCP_PROTOCOL_ERA` | `dual` by default. `modern` serves the modern protocol era only and refuses the legacy handshake. |
| `FSQL_MCP_ALLOW_AUTO_EXECUTE` | Off by default. Whether a model may pass `auto_execute=true` to the tools that take it. |
| `FSQL_MCP_CONFIG_WRITES` | `safe` by default. `off` refuses every configuration write, `safe` allows only the model names and the think mode, `all` allows any key the operator has not reserved. An unrecognised value is treated as `safe`. |
| `FSQL_MCP_ENABLED_CATEGORIES` / `FSQL_MCP_TOOL_WHITELIST` | Both empty by default, meaning every category and every tool is published. Set either to a comma-separated list to publish less. |
| `FSQL_MCP_MAX_SESSIONS` / `FSQL_MCP_SESSION_TTL_SECS` | 64 and 3600 by default. How many sessions and context handles exist at once, and how long an idle one survives. |
| `FSQL_MCP_MAX_ROWS_CEILING` | 1000 by default. The hard cap on the rows a result may carry. |
| `FSQL_MCP_MAX_CONCURRENT_CHEAP` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE` / `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT` | 50, 5 and 2 by default. The concurrency budget, and the share of the expensive calls one client may take. |
| `FSQL_MCP_MAX_QUEUE_WAIT_MS` | 900000 by default. How long a call waits for a slot before it is refused. |
| `FSQL_MCP_MAX_CONNECTIONS` | 256 by default. The most connections served at once; on POSIX the effective value never exceeds half the process's descriptor limit. |
| `FSQL_MCP_CONNECT_TIMEOUT` | 10 seconds by default. How long the server waits for the database connection and its handshake. |
| `FSQL_MCP_SHUTDOWN_DRAIN_MS` | 5000 by default. How long a shutdown waits for in-flight work before letting go of it. |
| `FSQL_MCP_LOG_LEVEL` | `normal` by default; `verbose` adds per-call detail. |

Every state-changing tool is reported with `destructiveHint: true`, so a client that honours the annotation asks before calling it and read-only mode refuses it. Each `tool_call` log line carries a short `client` digest identifying the session or token that made the call.
