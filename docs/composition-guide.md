<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Composition Guide: Build Your Own Agent

You have read the [fifteen agent recipes](api-agency.md#the-fifteen-recipes)
and, maybe, run the industry starter kits (see
[`docs/starter-kits.md`](starter-kits.md) for the full list of eleven).
Now the question is: **how do I build a proprietary agent that isn't in
the box?**

The good news: there is no framework to learn. Every FractalSQL primitive
(the search functions, the reasoning bridge, the table-backed search
compositions) is an **ordinary SQL function or procedure**. A custom agent
is just a `CREATE PROCEDURE ... SQL SECURITY INVOKER` that calls them in
sequence, feeds one's output into the next's input via a local `DECLARE`d
variable, and returns a shaped result through an `OUT JSON` parameter. The
15 shipped agents are exactly this, productized. Read any of them in
`sql/install_agents.sql` as a worked template; they're all under 100 lines
and follow the same shape (validate inputs → gather via a search primitive
or dynamic SQL → analyze → `fractal_reason` → assemble the `OUT` JSON).

> **No separate "Universal Agent" C-level tier here, but all six are
> available.** fractalsql-postgresql has an intermediate layer of six
> C-level Universal Agents (`fractal_search_agent`, `fractal_rag_agent`,
> `fractal_sql_agent`, `fractal_agent_plan_explore`,
> `fractal_agent_trajectory_predict`, `fractal_agent_detect_loop`) that the
> sixteen recipes are built on top of. This repo has no SPI, so none of
> the six exist as C-level primitives here. A MariaDB stored
> PROCEDURE can reach the same table access via dynamic SQL
> (`PREPARE`/`EXECUTE`), which is exactly how the table-backed
> compositions below already work. All six are implemented as stored
> procedures in `sql/install_agents.sql`/`sql/install_udf.sql`
> (`fractal_sql_agent` lives in `sql/install_udf.sql`, the other five in
> `sql/install_agents.sql`) and are building blocks you can call directly
> (see Pattern B below), not just internal to the 15 shipped recipes.

---

## The building blocks

Full signatures and behaviour are in
[api-agency.md → Building blocks](api-agency.md#building-blocks-the-primitives-agents-compose);
here is the pick-list.

| Block | Role | Use it when… |
|---|---|---|
| `fractal_search` | Sniper-mode convergence over an inline corpus | You need the single best point, or a refinement pass over a task vector |
| `fractal_explore` | Scout-mode diverse population, inline corpus | You need a *spread* of results, not one answer |
| `fractal_search_telemetry` (procedure) | Real top-k rows from a table | You have a real table and want ground-truth nearest matches |
| `fractal_hybrid_clinical_search` (procedure) | Cohort-restricted top-k | You need a metadata-filtered search, not the whole table |
| `fractal_search_trajectory` (procedure) | Delta-vector search over a table | You need "what changed": baseline vs. current state |
| `fractal_cross_modal_search` (procedure) | Weighted two-vector search | You have two embedding spaces (e.g. content + behavior) to blend |
| `fractal_reason` | LLM synthesis over retrieved content | You want a human-readable read on a computed result |
| `fractal_dimension_dfa`/`_drift`/`_boxcount` | Time-series/point-cloud structure | You need a safety monitor, regime-change detector, or complexity score |
| `fractal_sql_agent` (procedure) | NL → SQL with self-correction, `auto_execute` optional | You need structured answers from tables, not vector prose |
| `fractal_agent_trajectory_predict` (procedure) | Baseline→current drift prediction against a table's own latest row | You need "where is this heading next," not just "how far has it drifted" |
| `fractal_search_agent` (procedure) | Embed → search a table → reason over matched rows' content | You want a full retrieval+answer pipeline in one call, with source ids and timing back |
| `fractal_rag_agent` (procedure) | Same pipeline, answer-only | You just want the answer text, no extra bookkeeping |
| `fractal_agent_plan_explore` (procedure) | Embed → search a strategy table for diverse candidate branches | You need several distinct next-step options scored, not one |
| `fractal_agent_detect_loop` (procedure) | DFA + short-period check on a state-hash log | You need a standalone loop/cycle guard outside a specific recipe |

Everything above is a plain `CALL`/`SELECT` you can chain directly.
Table-backed compositions are procedures with a trailing `OUT p_result
JSON`, never a `SELECT function(...)` the way postgres's SPI-backed
equivalents work.

---

## The composition principle

A composition is a pipeline with up to four stages:

1. **Retrieve**: find the relevant rows (`fractal_explore` for diversity
   over an inline corpus, or a table-backed procedure for "what changed" /
   a real cohort). Build the corpus/query strings with ordinary SQL first.
2. **Reason**: `fractal_reason(session_id, query, context)` over the
   retrieved rows' *content* (not raw vectors); pass `CONNECTION_ID()` as
   `session_id`.
3. **Act** (optional): `fractal_sql_agent` (or `fractal_text_to_sql`,
   see [`docs/text-to-sql-setup.md`](text-to-sql-setup.md)) when the agent
   must run a query, under a guardrailed account (below).
4. **Guard** (optional): `CALL fractal_agent_detect_loop(log_hashes, @result)`
   on the agent's own state-hash log (same DFA math `anomaly_triage`/
   `regime_triage` already use for a different signal, plus a short-period
   repetition check), and/or an `outlier_intercept`-style
   distance-to-known-bad-state screen before a proposed action runs.

Stages 1–2 are the common case (most "answer my data" agents). Add 3 when
the agent must *do* something. Add 4 any time the agent is autonomous.

---

## Worked patterns

### Pattern A: "Answer my corpus" (single-turn RAG)

```sql
DELIMITER $$
CREATE PROCEDURE tier1_answer(IN p_question TEXT, OUT p_answer TEXT)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_ctx TEXT;
    -- narrow the corpus with ordinary SQL first, then reason over it
    SELECT JSON_ARRAYAGG(JSON_OBJECT('title', title, 'body', body))
      INTO v_ctx
      FROM (SELECT title, body FROM runbook_chunks
             WHERE team = 'sre' AND updated_at > NOW() - INTERVAL 90 DAY
             ORDER BY updated_at DESC LIMIT 25) t;
    SET p_answer = fractal_reason(CONNECTION_ID(), p_question, v_ctx);
END$$
DELIMITER ;

CALL tier1_answer('What does our runbook say about a node that stops heartbeating?', @a);
SELECT @a;
```

### Pattern B: Self-correcting read-only analyst

`fractal_sql_agent` generates SQL and (with `auto_execute => true`, check
its own signature in `sql/install_udf.sql`, it composes
`fractal_text_to_sql`'s pipeline) runs it, retrying on allowlist/EXPLAIN
failure. Compose it when the user's question is about *tables*, not vector
prose. **Always** behind the guardrails in
[Safe Agency](#safe-agency--guardrails):

```sql
-- run the RETURNED sql as a least-privilege account, not root/DBA
CREATE USER IF NOT EXISTS 'fractal_analyst'@'%' IDENTIFIED BY '...';
GRANT SELECT ON mydb.invoices TO 'fractal_analyst'@'%';
```

Set `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS=select` on `mariadbd`'s own
environment (not a per-role GUC the way postgres's
`ALTER ROLE ... SET fractalsql.text_to_sql_allowed_statements` works: this
repo's config is a single process-wide env var, see
[`docs/text-to-sql-setup.md`](text-to-sql-setup.md)), then run the analyst's
queries through that restricted account.

`data_analyst` (`fractal_agent_data_analyst`) is the productized version of
this pattern: NL→SQL inside its own composition, with the retry loop and a
reasoned summary of the result set already wired.

### Pattern C: Multi-step agent with a safety barrier

This is the pattern `fractal_agent_route_task` +
`fractal_agent_outlier_intercept` productize separately; see
`demo/demo-vertical-agentic-ops-devops.sql` for a full DevOps starter kit
composing detection, dispatch, and a safety barrier together (see
[`docs/starter-kits.md`](starter-kits.md)). A minimal skeleton illustrating
the same four-stage shape from scratch:

```sql
DELIMITER $$
CREATE PROCEDURE tier1_resolve(
    IN p_incident_id BIGINT, IN p_question TEXT, OUT p_result JSON
)
SQL SECURITY INVOKER
BEGIN
    DECLARE v_retrieved JSON;
    DECLARE v_n_retrieved INT DEFAULT 0;
    DECLARE v_sql TEXT;
    DECLARE v_err TEXT;
    DECLARE v_answer TEXT;

    -- 1. RETRIEVE: recent notes for this incident, via ordinary SQL
    SELECT JSON_ARRAYAGG(JSON_OBJECT('title', title, 'body', body))
      INTO v_retrieved
      FROM (SELECT title, body FROM incident_notes
             WHERE incident_id = p_incident_id
             ORDER BY updated_at DESC LIMIT 20) t;
    SET v_n_retrieved = IFNULL(JSON_LENGTH(v_retrieved), 0);

    -- 2. ACT: if retrieval is thin, fall back to NL->SQL over the metrics table
    IF v_n_retrieved < 3 THEN
        CALL fractal_text_to_sql(p_question, '["metrics"]', v_sql, v_err);
        SET p_result = JSON_OBJECT('step', 'sql_fallback', 'sql', v_sql, 'error', v_err);
    ELSE
        -- 3. REASON over the retrieved context
        SET v_answer = fractal_reason(CONNECTION_ID(), p_question, v_retrieved);
        SET p_result = JSON_OBJECT('step', 'answer', 'text', v_answer);
    END IF;

    -- 4. GUARD: your own state-hash log, checked for drift the same way
    -- anomaly_triage checks a metric series, see fractal_dimension_drift
    -- in api-analytics.md for the primitive to compose here.
END$$
DELIMITER ;
```

> The skeleton is illustrative: your state-hash/loop-detection scheme is
> yours to define; the wiring (retrieve, fall back to
> `fractal_text_to_sql`, reason) is the part to copy. `route_task` +
> `outlier_intercept`, run one after another against the same incident,
> is the closest existing shipped composition to this pattern. See
> [`docs/api-agency.md`](api-agency.md#route-task--fractal_agent_route_task).

---

## Safe Agency & Guardrails

`fractal_sql_agent`/`fractal_text_to_sql` (and any composition that calls
them with execution enabled) generate and can execute SQL. Treat it the way
you'd treat any NL→SQL surface:

- **Run the returned SQL under a least-privilege account.** Grant the
  connecting account only the schema/table privileges you want the agent
  able to read or write. Pattern B's `fractal_analyst` account is the
  model.
- **Restrict the allowed statements.**
  `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS` (a process env var, not a
  per-role setting, see [`docs/text-to-sql-setup.md`](text-to-sql-setup.md))
  gates which statement classes the pipeline may emit; keep it at the
  default `select` unless the workload genuinely needs writes.
- **No Row-Level Security.** Unlike PostgreSQL, MariaDB has no native RLS.
  If the agent's context subquery must be scoped per-tenant/per-user, that
  filtering has to live in the SQL itself (a `WHERE` clause, a view), not
  in a policy the engine enforces for you. A real capability gap, not just
  different phrasing, see [`docs/reasoning-setup.md`](reasoning-setup.md#-security--governance).

For autonomous agents (Pattern C), add the **safety barriers** described
above: a drift/regime check on the agent's own state-hash log, and an
`outlier_intercept`-style screen that checks a proposed action's state
vector against known-bad-state clusters before the action runs.

---

## Two notes to carry over

These bit the shipped agents; they'll bite yours too.

- **Table-backed procedures need a single-column, real `PRIMARY KEY`.**
  `_fractalsql_scan_corpus` and the other table-scanning helpers `SIGNAL`
  cleanly if the table has none or a composite one; resolve your own
  numeric PK, don't rely on row position.
- **Diversify is connection-scoped, not global, but it IS sticky.**
  `recommend_diverse` calls `fractal_diversify_enable(CONNECTION_ID())` as
  a side effect so re-searches on the SAME connection avoid recently
  rejected items. It stays on for that connection until you disable it,
  reset it with `fractal_diversify_disable(CONNECTION_ID())` when your
  session is done, or call `feedback_audit`, which runs the whole audit
  cycle and self-disables. See
  [`docs/api-discovery.md`](api-discovery.md#diversify--repulsion-session-scoped)
  for the full connection-scoped-ctx mechanism and its documented residual
  risk under connection-id reuse.

---

## Where next

- **Full signatures and per-agent behaviour** →
  [api-agency.md](api-agency.md) (the primitives and the fifteen recipes).
- **The industry-vertical gap and problem→agent mapping** →
  [starter-kits.md](starter-kits.md).
- **Configure the reasoning endpoint** the primitives call →
  [reasoning-setup.md](reasoning-setup.md).
- **Validate your composition** against the same demo path the shipped
  agents use → `mariadb -uroot -p fractalsql_demo < demo/demo-agents.sql`.
