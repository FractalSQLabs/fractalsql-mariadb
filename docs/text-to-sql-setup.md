<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Production-Safe Text-to-SQL

`fractal_text_to_sql` is a stored procedure built on the **Cognition Tier**. It transforms natural-language questions into mechanically validated SQL statements, providing a safe bridge between intent and execution.

Unlike naive LLM-to-SQL wrappers, FractalSQL treats SQL generation as a **hard-constrained engineering problem**, not a probabilistic one. It employs a multi-stage validation pipeline to ensure that every returned statement is syntactically correct and policy-compliant before it ever reaches your application.

**MariaDB note for anyone coming from the PostgreSQL edition**: this is a `CALL`-able stored procedure with `OUT` parameters here, not a function you `SELECT`. MariaDB's C UDF ABI has no SPI (no way for C code to run SQL against the calling session), so the orchestration (GENERATE, then ALLOWLIST, then EXPLAIN-equivalent, then RETURN) lives in SQL/PSM (`sql/install_udf.sql`) calling out to a handful of C primitives, not in one C function the way PostgreSQL's binding does it.

---

## Quick Start

By default, `fractal_text_to_sql` auto-discovers every table visible to the calling session (pass `NULL` for the table list). That's the simplest, most effective default for most use cases.

```sql
CALL fractal_text_to_sql('How many orders does customer ''acme'' have?', NULL, @sql, @err);
SELECT @sql, @err;
--  @sql: SELECT COUNT(*) FROM orders WHERE customer_id =
--          (SELECT id FROM customers WHERE name = 'acme')
--  @err: NULL
```

### Scoping the Context
For large schemas, narrow the schema context sent to the LLM by passing an explicit JSON array of table names. This reduces token cost, minimizes noise, and keeps unrelated metadata out of the prompt entirely.

```sql
CALL fractal_text_to_sql(
    'How many orders does customer ''acme'' have?',
    '["orders", "customers"]',
    @sql, @err
);
SELECT @sql, @err;
```

`out_sql` is `NULL` when the pipeline could not produce an approved statement. Always check `out_err` in that case, it carries the specific rejection reason from whichever stage failed on the last attempt.

---

## The Safety Pipeline: How it Works

```
GENERATE ──▶ ALLOWLIST ──▶ [REVIEW, optional] ──▶ EXPLAIN-equivalent ──▶ RETURN
   ▲                                                      │
   └──────────────── retry, with the specific failure fed back ────────┘
```

1. **GENERATE**: `fractal_t2s_generate(session_id, prompt, schema_context, system_tag)` sends the question plus a schema description (from `fractal_schema_context()`) to the configured LLM. Sets the reasoning plugin's response mode to fenced-code extraction internally, so the model's ```` ```sql ... ``` ```` block is pulled out automatically, with no separate config step.
2. **ALLOWLIST**: `fractal_t2s_check_allowlist(sql)` runs a hand-written lexical scanner (`src/fractalsql_textsql.c`) over the candidate. It rejects multiple statements, disallowed statement types (anything but `SELECT`, or `SELECT`/`INSERT`/`UPDATE` if `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select_insert_update`), and `INTO OUTFILE`/`INTO DUMPFILE` (a MariaDB-dialect filesystem-write hazard with no PostgreSQL equivalent). **MariaDB-specific note**: MariaDB's `WITH` clause is SELECT-only at the CTE-body level (`WITH d AS (DELETE FROM t ...) SELECT ...` is not even valid MariaDB syntax), so PostgreSQL's "data-modifying CTE hidden behind a top-level SELECT" attack class is structurally impossible here. A CTE feeding a top-level DML statement (`WITH cte AS (SELECT ...) DELETE FROM t WHERE id IN (SELECT id FROM cte)`) is still caught, the same as PostgreSQL, just via a shallower mechanism: the scanner classifies the statement by its actual leading keyword *after* skipping past the CTE definitions, not by a real parse tree. See `fractalsql_textsql.c`'s own header comment for the full account.
3. **REVIEW** *(optional, default off)*: `fractal_t2s_review(session_id, question, candidate_sql)`, a second LLM call that critiques the candidate against the original question. Enable with `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW=1`. Returns `NULL` on PASS, or the model's rejection text on FAIL, the same NULL-means-pass convention as the allowlist.
4. **EXPLAIN-equivalent**: the candidate is `PREPARE`d (not executed) inside the procedure. MariaDB's `PREPARE` mechanically catches malformed SQL and unknown-column errors the same way EXPLAIN would, without running the statement, caught via a `DECLARE CONTINUE HANDLER FOR SQLEXCEPTION` so a bad candidate never aborts the caller's session.
5. **RETURN or RETRY**: on success, `out_sql` is set and the loop ends. On failure at any stage, the rejection reason is fed back into the next attempt's prompt as explicit correction feedback, up to `FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` (default 2).

### Building on `PREPARE`, not a subtransaction
The PostgreSQL binding wraps its EXPLAIN check in an internal subtransaction so a late-stage constraint failure only rolls back that one attempt. MariaDB's `PREPARE`/`DEALLOCATE PREPARE` never executes the candidate at all, so there is nothing to roll back. This repo gets the same "never touches your session's transaction state" guarantee through a structurally different, arguably simpler mechanism.

---

## `fractal_schema_context(table_names, out_context)`

Builds the plain-text schema description used as the LLM's context. Call it directly to audit exactly what the model sees.

```sql
CALL fractal_schema_context('["orders", "customers"]', @ctx);
SELECT @ctx;
-- Table: customers
--   Columns: id BIGINT PK, name VARCHAR(100) NOT NULL  -- Customer full name
-- Table: orders
--   Columns: id BIGINT PK, customer_id BIGINT NOT NULL
--   Foreign keys: orders.customer_id -> customers.id
```

Table and column `COMMENT`s (if set) are included in the description, a cheap way to give the model real semantic hints without touching the prompt text itself.

**Sovereignty note**: pass `NULL` for `table_names` and auto-discovery pulls every table visible to the connection (via `INFORMATION_SCHEMA`, `SQL SECURITY INVOKER`, so it only sees what the calling session's own privileges allow). If your schema contains sensitive metadata (e.g. a `payroll_secrets` table), pass an explicit table list to keep that metadata inside your database boundary. `table_names` is capped at 512 entries; `fractal_schema_context` `SIGNAL`s a clean error past that, rather than silently truncating.

---

## Configuration & Security

### Environment Variables
These are process environment variables, read once by `mariadbd` at startup and cached for that process's entire lifetime (`src/fractalsql_textsql.c`'s `ensure_env_config`). There is **no SQL statement, sysvar, or GUC** that changes them: MariaDB never adopted a system-variable config surface for any reasoning tier. To change one, export a new value and **restart `mariadbd`**.

| Variable | Default | Notes |
| --- | --- | --- |
| `FRACTALSQL_TEXT_TO_SQL_MAX_ATTEMPTS` | `2` | Shared retry budget across GENERATE/ALLOWLIST/REVIEW/EXPLAIN rejections, clamped to `[1, 10]`. |
| `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` | `select` | `select_insert_update` permits writes; see **Secure it** below. |
| `FRACTALSQL_TEXT_TO_SQL_USE_REVIEW` | off | Set to a non-empty, non-`0` value to enable. Higher accuracy at the cost of latency. |

`fractal_t2s_config()` (0-arg UDF) reports the resolved values back as JSON, e.g. `{"max_attempts":2,"allowed_statements":"select","use_review":false}`, useful for confirming what a running server was actually started with, without needing shell access to it.

### Secure it: Authorization vs. Correctness
**Crucial**: this pipeline is a *correctness* aid, not an *authorization* mechanism. The allowlist and `PREPARE` checks catch shape problems, but they do not replace MariaDB grants.

To secure your Text-to-SQL implementation:
1. **Dedicated account**: create a restricted MariaDB user with `SELECT` grants only on the tables the use case needs.
2. **Execute as that account**: run the *returned* SQL as that restricted user, not as `root` or a DBA account.
3. **No Row-Level Security**: unlike PostgreSQL's RLS, MariaDB has no native row-level security mechanism. If you need row-level filtering, it has to live in the SQL itself (a `WHERE` clause the application adds, a view) or an application-layer check on the result. This is a real capability gap versus the PostgreSQL edition's RLS-based Visibility Boundary claim, not just different phrasing for the same guarantee.

---

## Validation & Testing

- **Fuzz Testing**: `tests/test_text_to_sql_fuzz.py` drives `fractal_t2s_check_allowlist` and the GENERATE round trip through stacked statements, bare DDL, disallowed statement types, a CTE feeding a top-level DELETE, `INTO OUTFILE`/`DUMPFILE`, and a malformed `WITH` clause, plus two positive controls.
- **Shadow Testing**: `tests/test_text_to_sql_shadow.py` runs a hard multi-constraint question against a real configured model and diffs the executed result against ground truth computed directly in SQL. One model per run: fixed-at-startup config means this can't loop over several models in one script, so rerun it against a differently-configured `mariadbd` to compare models.
- **Schema Context**: `tests/test_text_to_sql_schema_context.py` covers table names, comments, foreign keys, filtered vs. all-tables mode, and the clean-`SIGNAL` path for a nonexistent table.
- **Smoke**: `tests/test_text_to_sql_smoke.py` is the fast "is anything on fire" gate, deliberately not a correctness check (works against `scripts/ci/mock_llm.py`'s fixed reply too, with no real model attached).

---

## Known Limitations

- **No memory-safety fuzzing of the reasoning-plugin ABI**: an adversarial C plugin that hands `fractal_text_to_sql` a deliberately non-NUL-terminated response, to lock in a buffer-over-read fix, is not implemented here yet. Deferred, not silently dropped; see `build_test.sh`'s own header comment for the fuller account.
- **Distinct-value sampling**: the current version does not sample enum-like columns (e.g. `'Completed'` vs `'completed'`) to help the model with value normalization.
- **Table ranking**: for very large schemas, all visible tables are described linearly; a `fractal_search`-based relevance ranking to subset which tables get described is not implemented.
- **Schema caps**: `fractal_schema_context()` caps an explicit `table_names` list at 512 entries.
