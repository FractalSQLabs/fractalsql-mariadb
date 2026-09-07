<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Vectorizer Setup Guide

The Vectorizer is the Cognition tier's automation engine. It keeps raw text and semantic embeddings in sync automatically, so your data is always "search-ready" without external middleware or a separate ETL pipeline.

By running the embedding sync as MariaDB stored procedures + triggers inside the server itself, FractalSQL eliminates the "data shuffle" and ensures that your semantic index is a real-time reflection of your data.

---

## Prerequisites

To enable automated embeddings, the following configuration is required (Community edition, no separate tier or license needed). These are **process environment variables**, read once by `mariadbd` at startup and cached for that process's lifetime (`src/fractalsql_cognition.c`'s `ensure_env_config`); there is no sysvar or `SET GLOBAL` equivalent. To change one, export a new value and restart `mariadbd`.

1. **Reasoning Plugin**: `FRACTALSQL_REASONING_PLUGIN` must point at a compiled `fractalsql-reasoning-http.so` (see the reasoning-setup guide).
2. **Embeddings Endpoint**: `FRACTALSQL_HTTP_EMBED_URL` must be set to your provider's **embeddings** endpoint, a distinct path from the chat endpoint (e.g. `/v1/embeddings` vs `/v1/chat/completions`).
3. **Embedding Model**: `FRACTALSQL_HTTP_EMBED_MODEL` specifies the purpose-trained model. **Important**: never reuse a chat model for embeddings; they are mathematically distinct tasks.
4. `FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1` if your endpoint is plain `http://` rather than `https://` (e.g. a local Ollama instance).

**Connectivity Check**:
Confirm the embed path is active before creating a vectorizer:
```sql
SELECT fractal_embed(CONNECTION_ID(), 'hello world');
--  [0.0023064255,-0.009327292,...]
```
(`fractal_embed` takes `session_id` as its first argument, pass `CONNECTION_ID()`. Every reasoning-tier function follows the same convention, backed by the connection-scoped context registry in `src/fractalsql_session.c`.)

---

## Quick Start: Automated Sync

### 1. Define your table
A plain `TEXT` column storing a JSON-array-string works on every supported MariaDB major (10.6-12.3). On MariaDB 11.7+, you can instead declare a native `VECTOR(n)` column, see **Native VECTOR(n) support** below.

```sql
CREATE TABLE docs (
    id        BIGINT PRIMARY KEY AUTO_INCREMENT,
    body      TEXT NOT NULL,
    embedding TEXT
);

INSERT INTO docs (body) VALUES ('first doc'), ('second doc');
```

### 2. Create the Vectorizer
This installs `AFTER INSERT` and `AFTER UPDATE` triggers on `docs` and immediately queues existing rows missing an embedding.

```sql
CALL fractal_vectorizer_create('docs', 'body', 'embedding', NULL, @vectorizer_id);
SELECT @vectorizer_id;
```

Requires a single-column primary key on the source table.

### 3. Process the Queue
FractalSQL runs no background worker (`mariadbd` has no built-in equivalent of a background-scheduler extension, and this repo deliberately avoids adding one, keeping the extension portable). You trigger the embedding process on your own schedule: a `cron` entry, a systemd timer, an application-level scheduler.

```sql
CALL fractal_vectorizer_process_queue(100, 600);
-- a plain SELECT result, not an OUT param:
-- n_processed
-- 2
```
`batch_size` (default 100 if `NULL`) caps rows attempted per call; `stale_after_secs` (default 600) reclaims rows stuck `processing` past that many seconds, e.g. from a crashed prior call.

### 4. Monitor Progress
```sql
SELECT * FROM fractal_vectorizer_status WHERE vectorizer_id = @vectorizer_id;
-- vectorizer_id | source_table | text_col | embedding_col | enabled | status | n | last_failure_at | last_error
```
`fractal_vectorizer_status` is a `VIEW` (not a function): one row per `(vectorizer_id, status)` pair, with the count of rows currently in that status and the most recent failure detail.

---

## Storage: TEXT/JSON vs. native `VECTOR(n)`

FractalSQL stores and searches embeddings as a **JSON-array-string** (`'[0.1,0.2,0.3]'`), the same convention `fractal_search`/`fractal_vector_*` use everywhere. There is no native array type across the 10.6-12.3 compat floor this repo targets, so this is the portable baseline on every supported major.

### Native `VECTOR(n)` support (MariaDB 11.7+, GA in 11.8 LTS)

From MariaDB 11.7, `VECTOR(n)` is a real, built-in column type with its own `VEC_FROMTEXT()`/`VEC_TOTEXT()`/`VEC_DISTANCE_COSINE()`/`VEC_DISTANCE_EUCLIDEAN()` functions and index-accelerated ANN search (`VECTOR INDEX`). Verified (not assumed) to use the **same** bracket-comma text grammar this repo's `fractal_vector_*` functions emit/accept, so no conversion UDF is needed.

```sql
CREATE TABLE docs (
    id        BIGINT PRIMARY KEY AUTO_INCREMENT,
    body      TEXT NOT NULL,
    embedding VECTOR(768) NOT NULL,
    VECTOR INDEX (embedding)
);
INSERT INTO docs (body) VALUES ('first doc');

CALL fractal_vectorizer_create('docs', 'body', 'embedding', NULL, @vectorizer_id);
CALL fractal_vectorizer_process_queue(100, 600);
```

`fractal_vectorizer_create()` **auto-detects** whether `embedding_col` is a native `VECTOR(n)` column via `INFORMATION_SCHEMA` and records it on `fractal_vectorizers.embedding_is_vector_type`, with no separate flag to set. `fractal_vectorizer_process_queue()` then wraps the write-back in `VEC_FROMTEXT()` automatically. Live-verified against a real `mariadb:12.2` container: MariaDB itself rejects an insert whose dimension doesn't match the column's declared `VECTOR(n)` width, genuine dimension-drift protection with zero code in this repo needed to enforce it, unlike the portable TEXT path, which is unchecked.

```sql
-- Cross-path distance agreement (both read the same underlying float32 storage):
SELECT VEC_DISTANCE_COSINE(embedding, VEC_FROMTEXT('[1,0,0]')) FROM docs;
SELECT fractal_vector_cosine_distance(VEC_TOTEXT(embedding), '[1,0,0]') FROM docs;
```

Below 11.7, use the plain `TEXT`/`JSON` path. Every `fractal_vector_*` function and the vectorizer's queue/status mechanics work identically either way.

### Operators & helpers (portable path)
```sql
SELECT fractal_vector_l2_distance(a, b);          -- L2 (Euclidean) distance
SELECT fractal_vector_cosine_distance(a, b);       -- cosine distance
SELECT fractal_vector_negative_inner_product(a, b);-- for max-inner-product ranking
SELECT fractal_vector_l2_squared(a, b);            -- squared L2 (no sqrt, cheaper for ordering)
SELECT fractal_vector_cosine_similarity(a, b);     -- cosine similarity (1 - cosine distance)
SELECT fractal_vector_norm(a), fractal_vector_normalize(a);
SELECT fractal_vector_add(a, b), fractal_vector_sub(a, b), fractal_vector_scale(a, s);
SELECT fractal_vector_dims(a);
```

---

## Endpoint Providers

The Vectorizer shares the same auth-bridge as the Cognition tier's reasoning endpoint. Credentials and region settings are shared; only the URL and model change.

### Ollama (Local or Private Network)
Ideal for fully air-gapped deployments where data never leaves your network.

```bash
# chat / text-to-sql
export FRACTALSQL_HTTP_URL='http://127.0.0.1:11434/v1/chat/completions'
export FRACTALSQL_HTTP_MODEL='gpt-oss:20b'
export FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1

# embeddings
export FRACTALSQL_HTTP_EMBED_URL='http://127.0.0.1:11434/v1/embeddings'
export FRACTALSQL_HTTP_EMBED_MODEL='nomic-embed-text'
```
*Note: `ollama pull nomic-embed-text` (or your chosen embedding model) is a separate step. `FRACTALSQL_HTTP_EMBED_MODEL` is a distinct variable from `FRACTALSQL_HTTP_MODEL`, with no fallback between them: if it's unset, embed calls go out with no model field at all, so set it explicitly whenever your embedding model differs from your chat model (it almost always does).*

### OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```bash
export FRACTALSQL_HTTP_URL='https://api.openai.com/v1/chat/completions'
export FRACTALSQL_HTTP_TOKEN='sk-...'
export FRACTALSQL_HTTP_MODEL='gpt-4o-mini'
export FRACTALSQL_HTTP_EMBED_URL='https://api.openai.com/v1/embeddings'
export FRACTALSQL_HTTP_EMBED_MODEL='text-embedding-3-small'
```

### AWS Bedrock
Same SigV4 auth as the reasoning endpoint (see [reasoning-setup.md](reasoning-setup.md#aws-bedrock)); only the URL and model change for the embed path.

```bash
export FRACTALSQL_HTTP_URL='https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions'
export FRACTALSQL_HTTP_MODEL='amazon.nova-lite-v1:0'
export FRACTALSQL_HTTP_EMBED_URL='https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/embeddings'
export FRACTALSQL_HTTP_EMBED_MODEL='amazon.titan-embed-text-v2:0'
```

### Azure OpenAI
Requires a separate deployment resource for the embedding model.

```bash
export FRACTALSQL_HTTP_URL='https://<resource>.openai.azure.com/openai/deployments/<chat-deploy>/chat/completions?api-version=2024-02-01'
export FRACTALSQL_HTTP_TOKEN='<azure-api-key>'
export FRACTALSQL_HTTP_MODEL='gpt-4o'
export FRACTALSQL_HTTP_EMBED_URL='https://<resource>.openai.azure.com/openai/deployments/<embed-deploy>/embeddings?api-version=2024-02-01'
```

### Google Vertex AI
Uses the same OAuth access token as the reasoning endpoint (see [reasoning-setup.md](reasoning-setup.md#google-vertex-ai)); only the URL and model change. Point the embed path at the `openapi/v1/embeddings` surface of your project's region endpoint.

```bash
export FRACTALSQL_HTTP_TOKEN='<gcp-oauth-access-token>'
export FRACTALSQL_HTTP_EMBED_URL='https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/embeddings'
export FRACTALSQL_HTTP_EMBED_MODEL='text-embedding-005'
```

Export these into `mariadbd`'s environment before it starts: via `docker run -e ...` (see `docker/Dockerfile` and `build_test.sh`'s `mdb_setup` for this repo's own real wiring), a systemd unit's `EnvironmentFile`, or an equivalent process-manager mechanism. There is no server config file for this; it's always the process environment.

---

## SQL API Reference

### `fractal_vectorizer_create(source_table, text_col, embedding_col, options, out_id)`
`options` is a JSON object or `NULL`. Sets up the automation triggers and backfills the queue with existing unembedded rows. Requires a single-column primary key on `source_table`.

### `fractal_vectorizer_pause(id)` / `fractal_vectorizer_resume(id)`
Toggles the `enabled` state. When paused, new writes are not queued (the trigger no-ops) and `process_queue` skips existing pending rows for that vectorizer. `SIGNAL`s a clean error on a nonexistent id. Idempotent: pausing an already-paused vectorizer is a no-op.

### `fractal_vectorizer_drop(id)`
Permanently deregisters the vectorizer: drops its `_fsql_vec_<id>_ins`/`_fsql_vec_<id>_upd` triggers (if the source table still exists) and deletes its row from `fractal_vectorizers` (the `queue`/`rate_window` rows cascade via the existing foreign key). Irreversible: for a temporary stop, use `fractal_vectorizer_pause()` instead. `SIGNAL`s a clean error on a nonexistent id. Needed before re-creating a vectorizer on the same `(source_table, text_col, embedding_col)`, since that triple is unique.

### `fractal_vectorizer_process_queue(batch_size, stale_after_secs)`
The engine that drives synchronization. Ends in a plain `SELECT n_processed` result set: call it and fetch the result like any other query, there is no `OUT` parameter here. Concurrency-safe against another simultaneous call via an atomic claim-`UPDATE` (MariaDB has no `SKIP LOCKED` semantics that persist correctly across the statement boundaries this repo needs under autocommit; see `sql/install_udf.sql`'s own comment on the chosen concurrency mechanism).

### Rate Capping
To prevent provider throttling, set `options.max_embeds_per_window` (int) and `options.rate_window_secs` (default `3600`) during creation:
```sql
CALL fractal_vectorizer_create(
    'documents', 'body', 'embedding',
    '{"max_embeds_per_window": 500, "rate_window_secs": 3600}',
    @vectorizer_id
);
```
Tracked per-vectorizer in `fractal_vectorizer_rate_window`. Live-verified: the cap holds ATTEMPTS (not just successes) within a window, and correctly rolls over once `rate_window_secs` elapses.

---

## Design & Safety

### The "No-Worker" Architecture
FractalSQL uses a pull-based queue rather than a background worker thread. You control exactly when and how often the embedder runs, avoiding the extra process-management surface a worker thread would add inside `mariadbd`.

### Crash Safety & Authorization
- **Atomic recovery**: rows claimed by a `process_queue` call that never completes (a crashed connection, a killed session) are reclaimed automatically once `stale_after_secs` elapses on the next call; they don't stay stuck `processing` forever.
- **`SQL SECURITY INVOKER`**: the vectorizer procedures run with the calling session's own privileges. If that session lacks `SELECT`/`UPDATE` on the source table, the affected row is marked `failed` with a clear reason, not silently skipped or leaking data.
- **Identifier safety**: table/column names are handled via `_fractalsql_quote_ident()` (backtick-quoting, doubling embedded backticks) before being spliced into dynamically-built `PREPARE`d DDL/DML. Live-verified with a table name, text column, and embedding column all containing an embedded backtick, a `DROP TABLE`, and a SQL comment marker; the payload round-tripped safely with zero side effects on `fractal_vectorizers`.

---

## Known Constraints & Roadmap

- **Text chunking**: the current version sends the full text of the column to the provider. For documents exceeding model context limits, pre-chunk into a separate table first.
- **Spend caps**: rate capping is based on call count, not dollar cost.
- **Automatic retries**: failed rows are not retried automatically; reset them to `pending` (e.g. `UPDATE fractal_vectorizer_queue SET status = 'pending' WHERE status = 'failed' AND vectorizer_id = ?`) to have the next `process_queue` call pick them up again.
- **Backfill batching**: the initial backfill for very large tables happens as one `INSERT ... SELECT`. For millions of rows, consider seeding the source table in batches instead of one giant bulk load before calling `fractal_vectorizer_create`.

---

## When to use the Vectorizer

The Vectorizer is the right choice when you need seamless semantic synchronization without standing up a separate Python/Node.js worker. If you already have a robust external ETL pipeline, skip it and call `fractal_embed()` directly to populate your embedding column on your own schedule.
