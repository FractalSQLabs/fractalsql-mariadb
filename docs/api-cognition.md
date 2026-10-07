<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the provider bridge that connects the SFS core to Large Language Models (LLMs) and embedding providers, plus the Text-to-SQL orchestration built on top of it. See [`reasoning-setup.md`](reasoning-setup.md) for how to wire up a provider, and [`text-to-sql-setup.md`](text-to-sql-setup.md) for a full Text-to-SQL walkthrough. This page covers the core dispatch/orchestration surface itself.

## Configuration: `fractalsqld.conf` preferred, environment fallback

Every reasoning/embedding/text-to-sql knob here is set for `fractalsqld` (the daemon), never `mariadbd` -- MariaDB has no config-registration mechanism reachable from a plain C UDF, so none of these can be a server system variable and there is no SQL statement that changes them. The **preferred source is the daemon's own conf file** (`fractalsqld.conf`, whatever the daemon was started with via `-c`; `/etc/fractalsql/fractalsqld.conf` by default on Linux/macOS, `C:\ProgramData\FractalSQL\fractalsqld.conf` on Windows), one `key = value` per line with `#` comments. The table below gives both spellings per setting; `fsqlctl reload` applies a conf edit live -- the pushed value reaches the tier on its **next** call, including a changed plugin path (the reload itself never attempts a load, so a bad or changed path surfaces at that next call, with the path named in the daemon log), and removing a key from the conf takes the setting back to the environment fallback. The **process environment** remains the fallback for keys the conf leaves out, read **once**, at daemon startup. `mariadbd` and the shim it loads read neither source:

| `fractalsqld.conf` key (preferred) | Environment fallback | Purpose |
| --- | --- | --- |
| `reasoning_plugin` | `FRACTALSQL_REASONING_PLUGIN` | Absolute path to a `fsql_reasoning_vfs_t`-implementing `.so` (e.g. `fractalsql-reasoning-http.so`, bundled with this repo). |
| `reasoning_url` | `FSQL_REASONING_HTTP_URL` | Chat-completions endpoint URL, for `fractal_reason`/`fractal_t2s_generate`/`fractal_t2s_review`. |
| `reasoning_token` | `FSQL_REASONING_HTTP_TOKEN` | Bearer/API-key token. Plaintext in the conf, which is therefore permission-gated like the HMAC key file (`chmod 600` on Linux/macOS). |
| `reasoning_model` | `FSQL_REASONING_HTTP_MODEL` | Chat model name. |
| `embed_url` | `FRACTALSQL_HTTP_EMBED_URL` | Embeddings endpoint URL, for `fractal_embed()`. No fallback to the chat URL; it's a different endpoint shape. |
| `embed_model` | `FRACTALSQL_HTTP_EMBED_MODEL` | Embedding model name. |
| `reasoning_allow_plaintext` | `FSQL_REASONING_HTTP_ALLOW_PLAINTEXT` | Non-empty value except `0` to allow a non-TLS URL. |
| `think` | `FSQL_REASONING_HTTP_THINK` | Reasoning effort: `none` (default) \| `low` \| `medium` \| `high`. Chat tiers only (`fractal_reason`/`fractal_t2s_generate`/`fractal_t2s_review`), never `fractal_embed`. |
| `think_provider` | `FSQL_REASONING_HTTP_THINK_PROVIDER` | Which field/shape carries it: `openai` (default) \| `ollama` \| `anthropic` \| `vllm`. `openai` also covers Azure/Bedrock/Vertex's OpenAI-compatible surfaces. |
| `think_native_url` | `FSQL_REASONING_HTTP_NATIVE_URL` | Optional: routes the ollama-native/anthropic-native request elsewhere without touching the chat URL. |
| `think_num_ctx` | `FSQL_REASONING_HTTP_NUM_CTX` | Optional: Ollama-native context window cap (integer in [1,10000000]). |
| `t2s_max_attempts` | `FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` | GENERATE retry budget for `fractal_text_to_sql` (1–10, default 2). |
| `t2s_allowed_statements` | `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` | `"select"` (default) or `"select_insert_update"`. |
| `t2s_use_review` | `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW` | Non-empty value except `0` to add a REVIEW pass (default off). |

Conf-file edits are validated loudly, by name: an out-of-range, unparseable, or empty value refuses startup and reload with the key and the expected range in the daemon log (e.g. `t2s_max_attempts` outside `[1,10]`, `t2s_allowed_statements` not exactly one of the two spellings above, `think_num_ctx` below 1); an unknown conf key is WARN-logged and ignored, so a typo never silently orphans its value. The environment fallback keeps its legacy silent-clamping behavior, read at startup. Two related settings are outside this table: the enterprise-tier keys (`enterprise_lib` and friends, see [`docs/enterprise.md`](enterprise.md) -- `enterprise_lib` specifically cannot be swapped while its library is loaded, restart instead) and the reasoning plugin's own lower-level knobs, which deliberately stay environment-only (`FSQL_REASONING_HTTP_RESPONSE_MODE` and the rest, see [`docs/reasoning-setup.md`](reasoning-setup.md)).

---

## `fractal_reason`
**LLM Dispatch**

Dispatches a natural language query and an optional context payload to the configured LLM reasoning plugin.

### Signature
```sql
fractal_reason(
    session_id BIGINT UNSIGNED,   -- pass CONNECTION_ID()
    query      TEXT,
    context    TEXT               -- optional, JSON payload, defaults to '{}'
) RETURNS TEXT
```
2 or 3 arguments; `context` may be omitted. `session_id` is required and first: every reasoning-tier function in this repo takes it, because `fractalsqld` (the daemon every UDF body runs in) is one shared multithreaded process for every connection's forwarded calls, so the dispatch ctx has to be per-session rather than a single file-static (see `src/fractalsql_session.c`).

```sql
SELECT fractal_reason(CONNECTION_ID(), 'reply with a one-word confirmation');
SELECT fractal_reason(CONNECTION_ID(), 'summarize this', '{"rows": [...]}');
```

### Reasoning Effort
Hybrid-thinker models' internal reasoning trace is throttled via `think`/`think_provider` in `fractalsqld.conf` (reloadable live) or the `FSQL_REASONING_HTTP_THINK`/`FSQL_REASONING_HTTP_THINK_PROVIDER` environment fallback. See [Reasoning Setup: Reasoning Effort (THINK)](reasoning-setup.md#reasoning-effort-think).

---

## `fractal_embed`
**Semantic Vector Generation**

Generates a high-dimensional vector from text using the configured embedding model.

### Signature
```sql
fractal_embed(
    session_id BIGINT UNSIGNED,
    input      TEXT
) RETURNS TEXT   -- fractal_vector JSON-array-string, e.g. "[0.1,0.2,0.3]"
```

Returns the same JSON-array-string grammar every `fractal_vector_*` function and MariaDB's own `VEC_FROMTEXT()` accept, feeding straight into either with no conversion step (MariaDB has no native array type across the 10.6-12.3 compat floor this repo targets, see the Vector tier docs). Requires the embeddings endpoint and model to be configured: `embed_url`/`embed_model` in `fractalsqld.conf` or the `FRACTALSQL_HTTP_EMBED_URL`/`FRACTALSQL_HTTP_EMBED_MODEL` environment fallback (without them the error names `embed_url`/`FRACTALSQL_HTTP_EMBED_URL`, the same way the reasoning tier's error names its plugin).

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema (columns, PK/NOT NULL, comments, foreign keys) for use as `fractal_reason()`/text-to-sql prompt context.

Plain UDFs cannot run SQL against the calling session at all in MariaDB: a C UDF has no path back to the caller's tables, so this is a **stored procedure**, not a function.

### Signature
```sql
CALL fractal_schema_context(
    IN  table_names_json JSON,     -- e.g. '["orders","customers"]', or NULL for all visible tables
    OUT out_context      LONGTEXT
);
SELECT out_context;
```

Two arguments: there is no `query_hint` parameter — it was left out rather than added unused, ahead of a future ranking pass that doesn't exist yet.

`SQL SECURITY INVOKER`: `information_schema` rows are already filtered to what the calling user can see, so no separate privilege check is needed.

```sql
CALL fractal_schema_context(NULL, @ctx);
SELECT @ctx;
```

---

## `fractal_text_to_sql`
**Safe SQL Generation**

Turns a natural-language question into a single, validated SQL statement. Same limitation as `fractal_schema_context` above (a C UDF cannot run SQL against the calling session): a **stored procedure**, orchestrating the GENERATE -> ALLOWLIST -> EXPLAIN-equivalent (+ optional REVIEW) pipeline internally by calling `fractal_t2s_generate`/`fractal_t2s_check_allowlist`/`fractal_t2s_review` (see [`text-to-sql-setup.md`](text-to-sql-setup.md) for those and the full pipeline walkthrough).

### Signature
```sql
CALL fractal_text_to_sql(
    IN  p_question    TEXT,
    IN  p_table_names JSON,   -- e.g. '["orders"]', or NULL to auto-discover all visible tables
    OUT out_sql       TEXT,
    OUT out_error     TEXT
);
SELECT out_sql, out_error;
```

Exactly one of `out_sql`/`out_error` is set on return (both NULL is not a possible outcome). A hard failure like a missing reasoning plugin raises a real SQL error instead of setting `out_error`. Never auto-executed. Retries up to `t2s_max_attempts` in `fractalsqld.conf` (`FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` in the environment) times, feeding each rejection back into the next GENERATE attempt as feedback.

The EXPLAIN-equivalent check is `PREPARE`-only (immediately `DEALLOCATE`d on success, never `EXECUTE`d). `PREPARE` already performs the same parse and catalog-resolution a plain `EXPLAIN` relies on (unknown table/column, basic type mismatches all surface as a `PREPARE`-time error), while sidestepping a dynamic `EXPLAIN`'s own result set leaking out of this procedure's `CALL` as a spurious extra result set. This is a best-effort quality gate, not a complete semantic validator; real security still rests on the execution role's own grants, not on this check.

```sql
CALL fractal_text_to_sql('How many orders does customer ''acme'' have?', '["orders"]', @sql, @err);
SELECT @sql, @err;
```
