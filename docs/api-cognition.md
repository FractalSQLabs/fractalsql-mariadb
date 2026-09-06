<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Cognition API Reference

The Cognition tier provides the provider bridge that connects the SFS core to Large Language Models (LLMs) and embedding providers, plus the Text-to-SQL orchestration built on top of it. See [`reasoning-setup.md`](reasoning-setup.md) for how to wire up a provider, and [`text-to-sql-setup.md`](text-to-sql-setup.md) for a full Text-to-SQL walkthrough. This page covers the core dispatch/orchestration surface itself.

## Configuration is process environment variables, not SQL

Unlike fractalsql-postgresql, where `fractalsql.reasoning_plugin`/`fractalsql.http_url`/etc. are GUCs settable with `ALTER SYSTEM SET`, MariaDB has no equivalent config-registration mechanism reachable from a plain C UDF. Every reasoning/embedding/text-to-sql knob here is a **process environment variable**, read **once** by `mariadbd` at first use and cached for that process's entire lifetime. There is no SQL statement that changes it. Set these **before mariadbd starts** (`docker run -e ...`, a systemd `EnvironmentFile`, or equivalent):

| Variable | Purpose |
| --- | --- |
| `FRACTALSQL_REASONING_PLUGIN` | Absolute path to a `fsql_reasoning_vfs_t`-implementing `.so` (e.g. `fractalsql-reasoning-http.so`, bundled with this repo). |
| `FRACTALSQL_HTTP_URL` | Chat-completions endpoint URL, for `fractal_reason`/`fractal_t2s_generate`/`fractal_t2s_review`. |
| `FRACTALSQL_HTTP_TOKEN` | Bearer/API-key token. |
| `FRACTALSQL_HTTP_MODEL` | Chat model name. |
| `FRACTALSQL_HTTP_EMBED_URL` | Embeddings endpoint URL, for `fractal_embed()`. No fallback to `HTTP_URL`; it's a different endpoint shape. |
| `FRACTALSQL_HTTP_EMBED_MODEL` | Embedding model name. |
| `FRACTALSQL_HTTP_ALLOW_PLAINTEXT` | `"1"` to allow a non-TLS URL. |
| `FRACTALSQL_HTTP_THINK` | Reasoning effort: `none` (default) \| `low` \| `medium` \| `high`. Chat tiers only (`fractal_reason`/`fractal_t2s_generate`/`fractal_t2s_review`), never `fractal_embed`. |
| `FRACTALSQL_HTTP_THINK_PROVIDER` | Which field/shape carries it: `openai` (default) \| `ollama` \| `anthropic` \| `vllm`. `openai` also covers Azure/Bedrock/Vertex's OpenAI-compatible surfaces. |
| `FRACTALSQL_HTTP_NATIVE_URL` | Optional: routes the ollama-native/anthropic-native request elsewhere without touching `HTTP_URL`. |
| `FRACTALSQL_HTTP_NUM_CTX` | Optional: Ollama-native context window cap. |
| `FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` | GENERATE retry budget for `fractal_text_to_sql` (1–10, default 2). |
| `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` | `"select"` (default) or `"select_insert_update"`. |
| `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW` | `"1"` to add a REVIEW pass (default off). |

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
2 or 3 arguments; `context` may be omitted. `session_id` is required and first: every reasoning-tier function in this repo takes it, because MariaDB is one shared multithreaded process for every connection (unlike postgres's one-process-per-connection), so the dispatch ctx has to be per-session rather than a single file-static (see `src/fractalsql_session.c`).

```sql
SELECT fractal_reason(CONNECTION_ID(), 'reply with a one-word confirmation');
SELECT fractal_reason(CONNECTION_ID(), 'summarize this', '{"rows": [...]}');
```

### Reasoning Effort
Hybrid-thinker models' internal reasoning trace is throttled via `FRACTALSQL_HTTP_THINK` and related environment variables. See [Reasoning Setup: Reasoning Effort (THINK)](reasoning-setup.md#reasoning-effort-think).

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

Returns the same JSON-array-string grammar every `fractal_vector_*` function and MariaDB's own `VEC_FROMTEXT()` accept, feeding straight into either with no conversion step (no `float8[]` here; MariaDB has no native array type across the 10.6-12.2 compat floor this repo targets, see the Vector tier docs). Requires `FRACTALSQL_HTTP_EMBED_URL` and `FRACTALSQL_HTTP_EMBED_MODEL` to be configured.

---

## `fractal_schema_context`
**Schema Introspection**

Builds a plain-text description of the database schema (columns, PK/NOT NULL, comments, foreign keys) for use as `fractal_reason()`/text-to-sql prompt context.

Plain UDFs have no SPI equivalent in MariaDB: a C UDF cannot run SQL against the calling session at all, so this is a **stored procedure**, not a function, unlike postgres's `fractal_schema_context()`.

### Signature
```sql
CALL fractal_schema_context(
    IN  table_names_json JSON,     -- e.g. '["orders","customers"]', or NULL for all visible tables
    OUT out_context      LONGTEXT
);
SELECT out_context;
```

Two arguments, not postgres's three: this repo has no `query_hint` parameter. Postgres accepts one for forward compatibility with a future ranking pass that doesn't exist there yet either; it was left out here rather than added unused.

`SQL SECURITY INVOKER`: `information_schema` rows are already filtered to what the calling user can see, so no separate privilege check is needed the way postgres's `has_table_privilege()` joins require.

```sql
CALL fractal_schema_context(NULL, @ctx);
SELECT @ctx;
```

---

## `fractal_text_to_sql`
**Safe SQL Generation**

Turns a natural-language question into a single, validated SQL statement. Same SPI limitation as `fractal_schema_context` above: a **stored procedure**, orchestrating the GENERATE -> ALLOWLIST -> EXPLAIN-equivalent (+ optional REVIEW) pipeline internally by calling `fractal_t2s_generate`/`fractal_t2s_check_allowlist`/`fractal_t2s_review` (see [`text-to-sql-setup.md`](text-to-sql-setup.md) for those and the full pipeline walkthrough).

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

Exactly one of `out_sql`/`out_error` is set on return (both NULL is not a possible outcome). A hard failure like a missing reasoning plugin raises a real SQL error instead of setting `out_error`. Never auto-executed. Retries up to `FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` times, feeding each rejection back into the next GENERATE attempt as feedback.

The EXPLAIN-equivalent check is `PREPARE`-only (immediately `DEALLOCATE`d on success, never `EXECUTE`d). `PREPARE` already performs the same parse and catalog-resolution postgres's plain `EXPLAIN` relies on (unknown table/column, basic type mismatches all surface as a `PREPARE`-time error), while sidestepping a dynamic `EXPLAIN`'s own result set leaking out of this procedure's `CALL` as a spurious extra result set. This is a best-effort quality gate, not a complete semantic validator; real security still rests on the execution role's own grants, not on this check.

```sql
CALL fractal_text_to_sql('How many orders does customer ''acme'' have?', '["orders"]', @sql, @err);
SELECT @sql, @err;
```
