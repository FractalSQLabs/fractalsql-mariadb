# Cookbook: fractalsql-mariadb + reasoning-http

Wiring a reasoning plugin into a MariaDB server so SQL can call out
to a hosted LLM and have the response folded back into a result row.
Pattern is the same as the canonical [postgres cookbook], adjusted
for two real MariaDB constraints (both explained below, not just
asserted): MariaDB UDFs have no ambient per-connection identity, and
MariaDB's plugin ABI can't host a portable prebuilt config surface
the way postgres's GUCs can.

[postgres cookbook]: https://github.com/FractalSQLabs/fractalsql-postgresql/blob/main/docs/COOKBOOK.md

> **Why this looks the way it does.** The 40 KB libfractalsql-core
> never touches `dlopen`, libcurl, or sockets. Network I/O lives
> behind a VTable the host populates. The host here is
> `fractalsql.so`'s Cognition tier (`src/fractalsql_cognition.c`).
> The reasoning plugin is the same `fractalsql-reasoning-http.so`
> every other DB extension loads.

---

## Prerequisites

- MariaDB 10.6+ (LTS) or 11.x/12.x. One `fractalsql.so` covers the
  whole 10.6-12.2 compat matrix. See the note on plugin ABI below
  for why that's specifically true of the UDF surface.
- `fractalsql.so` on disk under `@@plugin_dir`, typically
  `/usr/lib/mysql/plugin/` or `/usr/lib/mariadb/plugin/` depending on
  the distro.
- `fractalsql-reasoning-http.so` somewhere readable by mariadbd,
  for example `/usr/lib/fractalsql/fractalsql-reasoning-http.so`.
- An OpenAI-compatible chat-completions endpoint and a bearer token.

If you haven't installed `fractalsql-mariadb` yet, see
[Getting Started](../README.md#getting-started). The rest of this
cookbook assumes `sql/install_udf.sql` already ran on your target
server (`CREATE FUNCTION ... SONAME 'fractalsql.so'` for every
function; there is no separate `INSTALL SONAME`/`INSTALL PLUGIN`
step, see the note below on why).

> **Why not a real MariaDB plugin with `fractalsql_*` system
> variables?** That was the original design here, and it was
> rejected after checking (not assuming) MariaDB's own plugin loader
> (`sql/sql_plugin.cc`): a `MYSQL_DAEMON_PLUGIN` (the type needed to
> host system variables) declares its interface version as the
> running server's own `MYSQL_VERSION_ID`, and the loader requires an
> **exact** match, down to the patch release, before `INSTALL
> SONAME` accepts the library. A single prebuilt `fractalsql.so`
> could never satisfy that across 10.6-12.2, or even across patch
> releases of one major, unlike the plain UDF ABI (`CREATE FUNCTION
> ... SONAME`) every function in this library actually uses, which
> the server has kept stable across that whole range.

---

## Step 1: configure mysqld's environment

`fractal_reason()` and `fractal_embed()` read their config once, on
first call, from mysqld's own process environment, not from
`my.cnf`, since there's no portable plugin/sysvar surface to put it
in (see above). Set these before starting mysqld:

```ini
# /etc/systemd/system/mariadb.service.d/fractalsql.conf
[Service]
Environment="FRACTALSQL_REASONING_PLUGIN=/usr/lib/fractalsql/fractalsql-reasoning-http.so"
Environment="FRACTALSQL_HTTP_URL=https://api.openai.com/v1/chat/completions"
Environment="FRACTALSQL_HTTP_MODEL=gpt-4o-mini"
# Prefer EnvironmentFile= for the token so it never lands in a
# world-readable unit file:
EnvironmentFile=/etc/fractalsql/http-token.env
# (that file contains one line: FRACTALSQL_HTTP_TOKEN=sk-proj-...)

# fractal_embed() only, no fallback to HTTP_URL, different endpoint
# shape:
Environment="FRACTALSQL_HTTP_EMBED_URL=https://api.openai.com/v1/embeddings"
Environment="FRACTALSQL_HTTP_EMBED_MODEL=text-embedding-3-small"
```

Restart mariadbd (`systemctl daemon-reload && systemctl restart
mariadb`) for a systemd deployment; under Docker, set the same names
via `environment:` (see this repo's own `docker-compose.yml`, which
wires these at the `ollama` service for the turnkey demo).

The safety-guard variables in the table below (timeouts, response-size
caps, ...) live on `fractalsql-reasoning-http.so` itself, as
`FSQL_REASONING_HTTP_*`, set them the same way, alongside the
`FRACTALSQL_*` names above.

> **Changing config later.** These are read exactly once per mysqld
> process (the first `fractal_reason()`/`fractal_embed()` call in
> that process's lifetime). Changing an env var requires restarting
> mysqld; there is no reload-without-restart path, unlike
> postgres's GUCs + `SIGHUP`.

---

## Step 2: call from SQL

```sql
SELECT fractal_reason(CONNECTION_ID(),
                       'Summarize the alerts table for the last hour');
```

The first argument is `session_id`, pass `CONNECTION_ID()` by
convention (same as `fractal_search`'s optional session key and
`fractal_diversify_enable`'s required one). MariaDB UDFs have no
ambient way to ask "what connection am I on," and each session needs
its own reasoning-dispatch state, since the underlying `fsql_ctx` is not
safe to share across MariaDB's concurrently-executing connection
threads.

`fractal_search()` is also available for vector ranking, and returns
a `fractal_vector`-shaped result compatible with `fractal_embed()`'s
own output. See [reasoning-setup.md](reasoning-setup.md) for the full
LLM provider configuration reference (Ollama, OpenAI, Bedrock, Azure,
Vertex), and [text-to-sql-setup.md](text-to-sql-setup.md) for how
reasoning composes with the Text-to-SQL pipeline.

---

## Safety guards

Identical to the postgres / mysql cookbooks, since the guards live inside
`fractalsql-reasoning-http.so`, not the host extension:

| Guard | Default | Why it matters |
|---|---|---|
| `CURLOPT_TIMEOUT_MS` | 60 000 | Total wall-clock cap. |
| `CURLOPT_CONNECTTIMEOUT_MS` | 10 000 | Catches dead/blackholed endpoints. |
| `CURLOPT_LOW_SPEED_LIMIT` + `_TIME` | 32 B/s for 20 s | Slowloris guard. |
| `CURLOPT_MAXFILESIZE` | 8 MiB | Caps response body. |
| `CURLOPT_FOLLOWLOCATION` / `MAXREDIRS` | 0 / 0 | Bearer-token redirect protection. |
| `CURLOPT_SSL_VERIFY{PEER,HOST}` | on | TLS verification mandatory. |
| `CURLOPT_ERRORBUFFER` | 256 B | Diagnostics surface in mariadbd error log. |

Bad, zero, or negative values fall back to defaults; misconfig keeps
guards on.

---

## Architectural purity

Same three-layer separation as the rest of the fleet (engine → host
extension → reasoning plugin). Swap the plugin for a cleanroom
alternative; nothing else needs to change.

---

## Troubleshooting

- **`Can't find symbol 'fractal_reason' in library`**: check
  `@@plugin_dir` and that `fractalsql.so` is readable by the
  mariadbd user; re-run `sql/install_udf.sql` if the functions were
  never registered.
- **`fractal_reason: no reasoning plugin configured`**:
  `FRACTALSQL_REASONING_PLUGIN` isn't set in mysqld's environment (or
  wasn't set before the LAST restart, see Step 1's note on when
  config is actually read).
- **MariaDB Galera Cluster**: the `FRACTALSQL_*`/`FSQL_REASONING_
  HTTP_*` environment must be identical on every node's mysqld unit
  or you'll see asymmetric reasoning behavior. Use
  `wsrep_sst_method=mariabackup` and keep the systemd unit override
  (or Docker `environment:` block) synced across nodes.
- **`HTTP 401`**: bearer token not reaching the plugin.
- **`curl error 28`**: timeout.

---

## Where to go next

- Plugin source:
  [src/reasoning_http.c](https://github.com/FractalSQLabs/fractalsql-reasoning-http/blob/main/src/reasoning_http.c).
- Other DB hosts: cookbooks in postgres, mysql, sqlite, duckdb, redis,
  valkey, couchdb repos.
- Custom reasoning plugin: export `fsql_reasoning_init`, populate the
  VTable, point `FRACTALSQL_REASONING_PLUGIN` at its absolute path.
