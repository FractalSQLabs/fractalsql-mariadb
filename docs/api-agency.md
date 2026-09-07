<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Sovereign Agency

FractalSQL ships **sixteen installable agents**: autonomous, self-correcting
routines that compose the extension's Discovery, Analytics, and Cognition
primitives into end-to-end workflows. Each agent is a *recipe* for a
recurring agentic pattern: "drift on a metric series," "match a task to the
best capable sub-agent," "block an action near a known-bad state." You pick
the recipe that matches your problem, point it at your tables and columns,
and get back real computed results plus a human-readable read.

This page is written for the **driver**, not the mechanic. For each agent
you'll find: what problem it solves, when to reach for it, the inputs it
needs, how it works inside, what it returns, a runnable example, and the
non-obvious notes. If you want to build a recipe that isn't in the box,
see [Composing your own](#composing-your-own) and
[Building blocks](#building-blocks-the-primitives-agents-compose) further
down.

> **Every "installable agent" here is a stored PROCEDURE, not a function.**
> MariaDB's C UDF ABI gives a C function no way to run SQL
> against the caller's tables, and there are no table-returning functions at all, so
> every agent that needs to read a caller-named table, or return more than
> one scalar, is a plain SQL/PSM stored procedure with a trailing
> `OUT p_result JSON` parameter, composing the C-level primitives
> (`fractal_search`, `fractal_reason`, `fractal_dimension_*`, ...) via
> ordinary `CALL`s and dynamic SQL, never a C-level "Universal Agent"
> function. Every example on this page is `CALL fractal_agent_x(...args..., @result); SELECT @result;`,
> never `SELECT fractal_agent_x(...) FROM ...`.

---

## Install

```sql
SOURCE sql/install_udf.sql;      -- the base UDF set (prerequisite)
SOURCE sql/install_agents.sql;   -- the 15 agent procedures below
```

Both scripts are idempotent (`DROP ... IF EXISTS` then `CREATE`) plain SQL.
There is no `CREATE EXTENSION`/dependency-resolution mechanism in MariaDB to
hook into, so `install_agents.sql` just assumes `install_udf.sql` already
ran and calls its functions/procedures directly (see
`sql/install_agents.sql`'s own header comment for the exact prerequisite
list).

Twelve agents end in a `fractal_reason` step and need reasoning configured
(env vars, not a sysvar; see [`docs/reasoning-setup.md`](../docs/reasoning-setup.md) for
the full setup). Three are **pure retrieval/analytics** with no LLM step
(`recall_hybrid`, `recommend_diverse`, `feedback_audit`) and need no
endpoint. Confirm reasoning before running the cognition agents:

```sql
SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation');
```

---

## Which agent should I use?

Pick by the problem shape, not by the function name.

| Your problem | Agent | Recipe in one line | LLM? |
| --- | --- | --- | --- |
| "Is this entity's metric series drifting into a new regime?" (table-backed, per-entity) | `anomaly_triage` | drift exponent on one entity's series → LLM triage | ✓ |
| "Is this single series in a regime change?" (array-in, no table) | `regime_triage` | DFA + drift over one series → LLM triage | ✓ |
| "Did this vessel/host track deviate from the fleet?" | `track_anomaly` | trajectory deviation + heading DFA → LLM triage | ✓ |
| "Did this vehicle detour, and how complex is its GPS trace?" | `detour_classify` | trajectory deviation + box-counting → LLM classify | ✓ |
| "Is my sensor grid's coverage degrading?" | `network_coverage_alert` | spatial morphology + telemetry drift → LLM alert | ✓ |
| "What's the best cardinality-constrained allocation?" | `allocate` | SFS Sharpe optimizer → LLM rationale | ✓ |
| "I want several genuinely different allocations to choose from, not just one" (enterprise-tier) | `diverse_portfolios` | multi-restart SFS + diverse-select → LLM rationale | ✓ |
| "Rebalance, and compare to the nearest historical allocation?" | `rebalance_sibling` | optimizer + trajectory search → LLM rationale | ✓ |
| "Which sub-agent should handle this incoming task?" | `route_task` | nearest-capability search + budget accounting → LLM rationale | ✓ |
| "Which node should this workload land on (with vector refinement)?" | `schedule_workload` | `fractal_search` refine + nearest node → LLM rationale | ✓ |
| "Should I block this proposed action (is it near a known-bad state)?" | `outlier_intercept` | distance-to-bad-state safety barrier → LLM justification | ✓ |
| "Triage a patient against a cohort + baseline→current drift" | `patient_deterioration_triage` | cohort search + trajectory drift → LLM triage | ✓ |
| "Ask a natural-language question over my tables" | `data_analyst` | NL→SQL→execute → LLM analysis | ✓ |
| "Recall similar past memories, restricted by a metadata filter" | `recall_hybrid` | cohort-restricted vector recall | no |
| "Recommend diverse items, avoiding recently-rejected ones" | `recommend_diverse` | repulsion-diverse top-k | no |
| "Audit my recommender's diversity health" | `feedback_audit` | diversify loop + collapse detection | no |

> **A guarantee about the outputs.** Every field in `p_result` is a **real
> primitive result, not a literal**. `threat_score` is the computed drift
> exponent; `allocation`/`sharpe` are the optimizer's own
> `{"sharpe":..,"weights":[..]}` JSON and risk-adjusted return (no hardcoded
> value); `routed_to` is the real nearest capability id and `confidence` is
> derived from `1/(1+distance)`; `intercepted` is a real distance-vs-threshold
> comparison; `mem_id`/`content` are the real recalled row; `item_id`/`score`
> are the real catalog id and `1 − cosine_distance`. The twelve cognition
> agents' `triage_summary`/`rationale`/`analysis` fields are real
> `fractal_reason` output. Every agent `SIGNAL`s a clean error on bad input
> (empty target table, NULL series, filter matching no rows) with an
> agent-named message, matching this repo's error-message convention
> throughout.

---

## The sixteen recipes

### Anomaly triage: `fractal_agent_anomaly_triage`
**Triage drift on one entity's metric time series.**

Use it when you have a per-entity metric series in a table (latency, error
rate, vitals, sensor reading) and want to know whether that entity has
drifted into a new regime: Cybersecurity host triage, DevOps incident
triage, MedTech patient monitoring, Smart-Cities sensor regime change. For a
single series you already hold as a JSON array (no per-row table), use
[regime_triage](#regime-triage-fractal_agent_regime_triage-general-purpose-no-table-args) instead.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_log_table` | `VARCHAR(128)` | your metric table |
| `p_metric_col` | `VARCHAR(64)` | the numeric metric column to read as the series |
| `p_time_col` | `VARCHAR(64)` | the timestamp column to order the series by |
| `p_filter_col` | `VARCHAR(64)` | the entity-id column to filter on (e.g. `host`) |
| `p_filter_val` | `VARCHAR(255)` | which entity (e.g. `'host-1'`) |
| `p_baseline_window` | `INT` | recent-window size for the drift comparison (32 is a safe default, see Notes) |
| `p_result` (OUT) | `JSON` | `{"threat_score":.., "anomaly_type":"vector_drift", "triage_summary":".."}` |

**How it works.** (1) Reads the entity's metric series ordered by time into
a JSON-array-string via dynamic SQL. (2) Runs
`fractal_dimension_drift(series, baseline_window)` for the regime-change
drift exponent. (3) Calls `fractal_reason` to synthesize a human-readable
triage over the drift result.

**Example**
```sql
DROP TABLE IF EXISTS agents_demo_logs;
CREATE TABLE agents_demo_logs (metric DOUBLE, ts TIMESTAMP, host VARCHAR(32));
INSERT INTO agents_demo_logs (metric, ts, host)
SELECT 50.0 + MOD(seq, 8) * 1.3 + IF(seq > 48, 30.0, 0.0),
       NOW() - INTERVAL (96 - seq) SECOND, 'host-1'
FROM (
    SELECT @rownum := @rownum + 1 AS seq
    FROM information_schema.columns, (SELECT @rownum := 0) r
    LIMIT 96
) s;

CALL fractal_agent_anomaly_triage(
    'agents_demo_logs', 'metric', 'ts', 'host', 'host-1', 32, @result);
SELECT @result;
```

**Notes.** `SIGNAL`s `fractal_agent_anomaly_triage: no rows matching the
filter` if the filter matches no rows. `baseline_window` must be large
enough for DFA. This repo's own testing found the documented minimum of
"n>=16" is not actually sufficient in practice (real minimum closer to
~24); 32 is safe.

---

### Allocate: `fractal_agent_allocate`
**Cardinality-constrained portfolio allocation.**

Use it when you want the best allocation of a fixed number of assets from a
universe: Quant-Finance portfolios, Sovereign-Edge resource allocation,
FinTech rebalancing. You supply expected returns (`mu`) and risk (`cov`);
the agent runs the SFS Sharpe maximizer and reasons a rationale.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_mu` | `JSON` | expected returns per asset, e.g. `'[0.05,0.1]'` |
| `p_cov` | `JSON` | covariance matrix, **flattened 1-D row-major n×n**, e.g. `'[1.0,0.0,0.0,1.0]'` |
| `p_cardinality` | `INT` | how many assets to hold |
| `p_context` | `TEXT` | optional label passed to the reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"allocation":{"sharpe":..,"weights":[..]}, "sharpe":.., "rationale":".."}` |

**How it works.** (1) `fractal_optimize_portfolio(mu, cov, cardinality)`:
the SFS cardinality-constrained Sharpe maximizer. (2) Extracts the real
Sharpe from the optimizer's own output. (3) `fractal_reason` explains the
allocation.

**Example**
```sql
-- 2 assets, hold 1; cov is the 2x2 identity flattened row-major.
CALL fractal_agent_allocate(
    '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1,
    '{"portfolio": "agents-demo"}', @result);
SELECT @result;
```

**Notes.** `p_cov` must be a **flattened 1-D row-major** matrix, not a
nested JSON array. A mismatched length surfaces the underlying primitive's
own clean error.

---

### Route task: `fractal_agent_route_task`
**Match an incoming task to the best capable sub-agent.**

Use it as a sub-agent dispatcher: DevOps task routing, Customer Support
intent routing, Cybersecurity analyst routing, Sovereign-Edge orchestration.
You pass the task as an embedding (the agent does not embed it for you); it
finds the nearest capability row and accounts a token budget.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_task_emb` | `JSON` | the incoming task's embedding, e.g. `'[0.9,0.1,0]'` |
| `p_cap_table` | `VARCHAR(128)` | table of capability rows |
| `p_cap_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_budget` | `INT` | remaining token/cost budget |
| `p_cost_per_route` | `INT` | cost charged for this routing decision |
| `p_result` (OUT) | `JSON` | `{"routed_to":.., "confidence":.., "remaining_budget":.., "rationale":".."}` |

**How it works.** (1) `fractal_search_telemetry(cap_table, cap_emb_col,
task_emb, 1)` finds the nearest capability by real cosine distance. (2)
`confidence` is derived from that real distance. (3) `p_budget -
p_cost_per_route` is the accounted remaining budget. (4) `fractal_reason`
explains the routing choice.

**Example** (live-verified against a real Ollama endpoint, see
`build_test.sh`'s `gate_24_agents`):
```sql
DROP TABLE IF EXISTS bt_caps;
CREATE TABLE bt_caps (id BIGINT PRIMARY KEY AUTO_INCREMENT, emb TEXT);
INSERT INTO bt_caps (emb) VALUES ('[1,0,0]'), ('[0,1,0]');

CALL fractal_agent_route_task('[0.9,0.1,0]', 'bt_caps', 'emb', 1000, 100, @result);
SELECT @result;
-- {"routed_to": "1", "confidence": "0.998...", "remaining_budget": 900, "rationale": "..."}
```

**Notes.** `p_cap_table` needs a real embedding column readable as a
fractal_vector JSON-array-string (or `VEC_TOTEXT()` of a native `VECTOR(n)`
column, see [`api-discovery.md`](api-discovery.md)).

---

### Outlier intercept: `fractal_agent_outlier_intercept`
**Pre-commit safety barrier: block an action near a known-bad state.**

Use it before committing a risky action: Cybersecurity anomalous-command
blocking, FinTech fraud interception, Industrial-IoT unsafe-setpoint
blocking.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_state_vec` | `JSON` | the proposed action's state vector |
| `p_history_table` | `VARCHAR(128)` | table of known-bad states |
| `p_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_threshold` | `DOUBLE` | distance below which the action is intercepted |
| `p_result` (OUT) | `JSON` | `{"intercepted":true\|false, "reason":".."}` |

**How it works.** (1) `fractal_search_telemetry(history_table, emb_col,
state_vec, 1)` finds the nearest known-bad state by real cosine distance.
(2) `intercepted = (nearest_distance < threshold)`, a real comparison, not
a heuristic. (3) `fractal_reason` justifies the decision.

**Example**
```sql
CALL fractal_agent_outlier_intercept('[0.95,0.05,0]', 'bt_history', 'emb', 0.1, @result);
SELECT @result;
```

**Notes.** `p_history_table` must have at least one row, or the underlying
search primitive `SIGNAL`s cleanly rather than returning a meaningless
result.

---

### Recall hybrid: `fractal_agent_recall_hybrid` (pure retrieval, no LLM)
**Cohort-restricted vector recall.**

Use it for memory recall scoped to a hard filter: Customer Support
"recall past tickets from THIS account," Cybersecurity "recall alerts
from THIS host."

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_mem_table` | `VARCHAR(128)` | table of memories/records |
| `p_vec_col` | `VARCHAR(64)` | that table's embedding column |
| `p_query_vec` | `JSON` | the query embedding |
| `p_filter_col` | `VARCHAR(64)` | the metadata column to restrict the cohort by, or `NULL` to use every row in `p_mem_table` as the cohort |
| `p_filter_val` | `VARCHAR(255)` | which cohort (ignored when `p_filter_col` is `NULL`) |
| `p_k` | `INT` | how many results |
| `p_content_col` | `VARCHAR(64)` | the column to return as `content`, or `NULL` to return `"content": null` for every hit |
| `p_result` (OUT) | `JSON` | a JSON array `[{"mem_id":.., "content":".."}, ...]` |

**How it works.** `p_mem_table` must have exactly one single-column
`PRIMARY KEY`; that column's real values are what come back as `mem_id`.
`fractal_hybrid_clinical_search(mem_table, vec_col, query_vec, [cohort
primary keys], k)` restricted to the rows where `filter_col = filter_val`
(or every row, when `filter_col` is `NULL`): a real metadata-filtered
cohort, not a post-filter over an unfiltered top-k.

**Example** (live-verified against a real 2-row cohort, `build_test.sh`
`gate_24_agents`):
```sql
DROP TABLE IF EXISTS bt_memories;
CREATE TABLE bt_memories (id BIGINT PRIMARY KEY AUTO_INCREMENT, region VARCHAR(20), vec TEXT, content VARCHAR(100));
INSERT INTO bt_memories (region, vec, content) VALUES ('east','[1,0,0]','shipped'), ('west','[0,1,0]','refunded');

CALL fractal_agent_recall_hybrid('bt_memories', 'vec', '[1,0,0]', 'region', 'east', 5, 'content', @result);
SELECT @result;  -- contains "shipped", never "refunded" (west cohort excluded)
```

**Notes.** A `p_filter_val` that matches no rows `SIGNAL`s
`fractal_agent_recall_hybrid: filter matched no rows` rather than returning
an empty result. `p_result` only comes back as an empty JSON array `[]` in
the narrower case where the cohort itself is non-empty but the underlying
search returns no hits for it. `p_mem_table` without exactly one
single-column primary key is rejected up front with a clean `SIGNAL`,
since there is no id column to return `mem_id` values from otherwise.

---

### Recommend diverse: `fractal_agent_recommend_diverse` (pure retrieval, no LLM)
**Repulsion-diverse top-k, avoiding recently-rejected items.**

Use it for a recommender that shouldn't keep re-surfacing items the user
already dismissed: e-commerce, content feeds, alert de-duplication.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_catalog_table` | `VARCHAR(128)` | table of recommendable items |
| `p_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_query_vec` | `JSON` | the query embedding |
| `p_k` | `INT` | how many results |
| `p_result` (OUT) | `JSON` | a JSON array `[{"item_id":.., "score":..}, ...]` |

**How it works.** Enables this connection's Diversify/Repulsion state
(`fractal_diversify_enable(CONNECTION_ID())`), then calls
`fractal_search_telemetry(catalog_table, emb_col, query_vec, k)`, which
itself always threads `CONNECTION_ID()` into the underlying search as its
`session_id`, so the Diversify state just enabled actually applies:
repulsion-diverse top-k per that procedure's own header comment. `score`
is `1 − cosine_distance`. **Leaves Diversify enabled on this session
afterward.** Call
`fractal_diversify_disable(CONNECTION_ID())` yourself when done, or use
[`feedback_audit`](#feedback-audit-fractal_agent_feedback_audit-pure-analytics-no-llm) below,
which cleans up after itself.

**Example** (live-verified, `build_test.sh` `gate_24_agents`):
```sql
CALL fractal_agent_recommend_diverse('bt_memories', 'vec', '[1,0,0]', 2, @result);
SELECT @result;  -- contains "item_id" keys, real scored items
```

---

### Data analyst: `fractal_agent_data_analyst`
**Natural-language question over your tables, horizontal catch-all.**

Use it whenever the shape of the question doesn't fit a more specific agent
above; this is the general-purpose recipe.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_question` | `TEXT` | the natural-language question |
| `p_table_names` | `JSON` | e.g. `'["orders","customers"]'`, or `NULL` for auto-discovery of all visible tables |
| `p_max_retries` | `INT` | GENERATE/ALLOWLIST/EXPLAIN retry budget |
| `p_context` | `TEXT` | optional label passed to the final reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"analysis":.., "generated_sql":.., "result_json":{..}}` |

**How it works.** (1) `fractal_sql_agent(question, table_names,
max_retries, auto_execute=TRUE)`, the self-correcting GENERATE →
ALLOWLIST → EXPLAIN-equivalent → EXECUTE pipeline (see
[`text-to-sql-setup.md`](text-to-sql-setup.md)). (2) `fractal_reason`
narrates the result set into `analysis`.

**Example**
```sql
CALL fractal_agent_data_analyst(
    'How many paid orders does each customer have?', NULL, 2, NULL, @result);
SELECT @result;
```

**Notes.** Same allowlist/EXPLAIN safety pipeline as
`fractal_sql_agent`/`fractal_text_to_sql`. A question that can only be
answered by a disallowed statement type (e.g. an UPDATE, with the default
`allowed_statements=select`) returns an `execution_status` of `"failed"`
with the real rejection reason, never silently executes it anyway.

---

### Patient deterioration triage: `fractal_agent_patient_deterioration_triage`
**Cohort search + baseline→current drift, MedTech.**

Use it for a patient-monitoring triage that combines "who's similar to this
patient" with "how has this patient changed."

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_patient_table` | `VARCHAR(128)` | table of patient vitals/embeddings |
| `p_vec_col` | `VARCHAR(64)` | that table's embedding column |
| `p_query_vec` | `JSON` | the current patient's query embedding |
| `p_baseline_vec` | `JSON` | this patient's baseline state |
| `p_current_vec` | `JSON` | this patient's current state |
| `p_cohort_doc_ids` | `JSON` | which rows count as the comparison cohort, or `NULL` to use every row in `p_patient_table` (which then needs exactly one single-column `PRIMARY KEY`) |
| `p_k` | `INT` | how many ranked cohort candidates to return in `cohort_matches` (default 5 if NULL) |
| `p_result` (OUT) | `JSON` | `{"nearest_cohort_id":.., "cohort_distance":.., "drift_distance":.., "rationale":.., "cohort_matches":[{"id":..,"distance":..},...]}` |

**How it works.** (1) `fractal_hybrid_clinical_search` finds up to `p_k`
nearest cohort matches, ranked ascending by distance, returned in
`cohort_matches`; `nearest_cohort_id`/`cohort_distance` remain the top-1
entry for backward compatibility. (2) `fractal_search_trajectory(patient_table,
vec_col, baseline_vec, current_vec, 1)` for the real baseline→current
drift against the single nearest point. (3) `fractal_reason` synthesizes
the triage.

**Example**
```sql
CALL fractal_agent_patient_deterioration_triage(
    'bt_patients', 'vec', '[0.5,0.5,0]', '[0.9,0.1,0]', '[0.5,0.5,0]',
    '["1","2","3"]', 5, @result);
SELECT @result;
```

**Notes.** `p_k` controls only the cohort-search half; the trajectory/drift
search always compares a single baseline point to a single current point (a
scalar "how far did this patient move" question, not a k-NN one), so it stays
fixed at its nearest point regardless of `p_k`. `cohort_matches[0]` always
equals `(nearest_cohort_id, cohort_distance)`. `rationale` reasons over only
the single nearest cohort match plus the drift distance, not over every entry
in `cohort_matches`.

---

### Feedback audit: `fractal_agent_feedback_audit` (pure analytics, no LLM)
**Self-contained diversify health-check cycle.**

Use it to check whether your Diversify/Repulsion layer is actually keeping
recommendations diverse: a monitoring/ops recipe, not a per-request one.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_catalog_table` | `VARCHAR(128)` | table of recommendable items |
| `p_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_query_vec` | `JSON` | the query embedding to audit against |
| `p_warmup_table` | `VARCHAR(128)` | table of recent negative-feedback items |
| `p_warmup_vec_col` | `VARCHAR(64)` | that table's embedding column |
| `p_warmup_count` | `INT` | how many warmup rows to feed as rejected |
| `p_k` | `INT` | how many results per warmup search (default 3, see How it works); the final audit-target search always uses `k=1` |
| `p_result` (OUT) | `JSON` | `{"diversity_quotient":.., "explanation":{..}}` |

**How it works.** (1) Enables repulsion and sets its window/sigma/weight
params. (2) Warms the D_q rolling window by running `p_warmup_count`
searches (each with top-`k`, per `p_k`) against `p_catalog_table`, using
each row of `p_warmup_table` as a query vector in turn
(`fractal_detect_collapse` returns `NaN` on an empty window, so this step
is required, not optional). (3) Runs one more `k=1` search for the real
audit target (`p_query_vec`) and reports its top match as negative
feedback via `fractal_isolate_background`. (4) Reads back
`fractal_detect_collapse` (`diversity_quotient`) and
`fractal_explain_result` (`explanation`). (5) **Disables Diversify itself**
before returning: a complete, self-contained audit cycle, unlike
`recommend_diverse` above, which leaves it on for the caller.

**Example**
```sql
CALL fractal_agent_feedback_audit(
    'bt_catalog', 'emb', '[1,0,0]', 'bt_recent_rejections', 'emb', 5, 10, @result);
SELECT @result;
```

---

### Schedule workload: `fractal_agent_schedule_workload`
**Node placement with a vector-refinement step.**

Like `route_task`, but with an extra `fractal_search` refinement pass
`route_task` lacks. Use it when the task embedding itself should be
locally optimized (Sniper Search) before matching against nodes.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_task_vec` | `JSON` | the workload's initial embedding |
| `p_node_table` | `VARCHAR(128)` | table of candidate nodes |
| `p_node_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_iterations` | `INT` | currently controls `fractal_search`'s `k`, not its SFS iteration count; see Notes |
| `p_population` | `INT` | SFS refinement population size |
| `p_k` | `INT` | how many node matches to consider |
| `p_context` | `TEXT` | optional label passed to the reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"assigned_node":.., "confidence":.., "rationale":".."}` |

**How it works.** (1) `fractal_search([task_vec], task_vec, iterations,
{"population_size": population, "diffusion_factor": 2})` refines the task
embedding (Sniper Search: a single-row corpus containing just the task
vector, converging toward its own locally optimal point). (2)
`fractal_search_telemetry(node_table, node_emb_col, refined_vec, k)` finds
the nearest node. (3) `fractal_reason` explains the placement.

**Example**
```sql
CALL fractal_agent_schedule_workload(
    '[0.5,0.5,0]', 'bt_nodes', 'emb', 20, 30, 3, NULL, @result);
SELECT @result;
```

**Notes.** In the current implementation, `p_iterations` is passed into
`fractal_search`'s positional `k` argument, not into its `params.iterations`
key, so it does not control the SFS refinement's generation count (that
stays at `fractal_search`'s own default of 30 regardless of what you pass
here). Because the refinement corpus is always a single vector (the task
embedding wrapped in its own one-row array), `fractal_search`'s `top_k`
output can never have more than one entry no matter what `k` is asked for,
so `p_iterations` currently has no observable effect on the result. Pass
any positive integer; `p_population` (the SFS population size) is the
knob that does affect the refinement.

---

### Rebalance sibling: `fractal_agent_rebalance_sibling`
**Optimizer + trajectory search: rebalance and compare to history.**

Use it when a rebalance decision should be informed by the nearest
historically similar allocation, not just the raw optimizer output.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_mu` | `JSON` | expected returns per asset |
| `p_cov` | `JSON` | flattened row-major covariance matrix |
| `p_cardinality` | `INT` | how many assets to hold |
| `p_alloc_table` | `VARCHAR(128)` | table of historical allocations |
| `p_alloc_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_baseline_vec` | `JSON` | the baseline allocation vector to compare drift against |
| `p_seed` | `BIGINT` | RNG seed passed through to the optimizer, for reproducibility |
| `p_context` | `TEXT` | optional label passed to the reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"sharpe":.., "weights":[..], "nearest_alloc_id":.., "nearest_distance":.., "rationale":".."}` |

**How it works.** (1) `fractal_optimize_portfolio(mu, cov, cardinality)`.
(2) `fractal_search_trajectory(alloc_table, alloc_emb_col, baseline_vec,
[new allocation as current], 1)` finds the nearest historical sibling
allocation and its real drift. (3) `fractal_reason` explains both together.

**Example**
```sql
CALL fractal_agent_rebalance_sibling(
    '[0.05,0.1]', '[1.0,0.0,0.0,1.0]', 1,
    'bt_allocations', 'emb', '[0.5,0.5]', 42, NULL, @result);
SELECT @result;
```

---

### Detour classify: `fractal_agent_detour_classify`
**Trajectory deviation + GPS-trace complexity, fleet/logistics.**

Use it to classify whether a vehicle detoured AND how structurally complex
that detour's path was.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_vehicle_table` | `VARCHAR(128)` | table of vehicle route embeddings |
| `p_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_baseline_vec` | `JSON` | the planned-route embedding |
| `p_current_vec` | `JSON` | the actual-route embedding |
| `p_gps_trace` | `JSON` | the raw GPS point sequence, for box-counting |
| `p_boxcount_dim` | `INT` | dimension parameter for `fractal_dimension_boxcount` |
| `p_result` (OUT) | `JSON` | `{"nearest_fleet_id":.., "trajectory_distance":.., "trace_complexity":.., "rationale":".."}` |

**How it works.** (1) `fractal_search_trajectory(vehicle_table, emb_col,
baseline_vec, current_vec, 1)` for the real route deviation. (2)
`fractal_dimension_boxcount(gps_trace, boxcount_dim)` for the trace's real
fractal complexity. (3) `fractal_reason` classifies the combination.

**Example**
```sql
CALL fractal_agent_detour_classify(
    'bt_vehicles', 'emb', '[1,0,0]', '[0.7,0.7,0]',
    '[[0,0],[1,0.1],[2,0.4],[3,0.2],[4,1.1]]', 2, @result);
SELECT @result;
```

**Notes.** `p_gps_trace` needs enough points for a meaningful box-count.
This repo's own testing found `fractal_dimension_boxcount`'s real minimum
input size is far higher than its documented "n>=8" (closer to ~500 points
for a stable estimate); a short trace is accepted but its `trace_complexity`
should be treated as low-confidence.

---

### Track anomaly: `fractal_agent_track_anomaly`
**Trajectory deviation + heading-series DFA, fleet/logistics or maritime.**

Use it to flag a vessel/vehicle track that both deviated from its expected
path AND shows erratic heading behavior.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_track_table` | `VARCHAR(128)` | table of track embeddings |
| `p_emb_col` | `VARCHAR(64)` | that table's embedding column |
| `p_baseline_vec` | `JSON` | the expected-track embedding |
| `p_current_vec` | `JSON` | the actual-track embedding |
| `p_heading_series` | `JSON` | the raw heading-angle series over time |
| `p_result` (OUT) | `JSON` | `{"nearest_fleet_id":.., "trajectory_distance":.., "dfa_exponent":.., "rationale":".."}` |

**How it works.** (1) `fractal_search_trajectory(track_table, emb_col,
baseline_vec, current_vec, 1)` for real deviation. (2)
`fractal_dimension_dfa(heading_series)` for the real DFA scaling exponent
on heading. (3) `fractal_reason` triages the combination.

**Example**
```sql
CALL fractal_agent_track_anomaly(
    'bt_tracks', 'emb', '[1,0,0]', '[0.6,0.8,0]',
    '[0.1,0.15,0.09,0.2,0.31,0.05, ... /* >=24 points, see Notes */]',
    @result);
SELECT @result;
```

**Notes.** Same DFA minimum-input-size caveat as `anomaly_triage` above:
`p_heading_series` needs at least ~24 points for a meaningful exponent.

---

### Network coverage alert: `fractal_agent_network_coverage_alert`
**Spatial morphology + telemetry drift, no table args.**

Use it for a sensor-grid/network coverage health check where you already
have the point cloud and drift series in hand; this agent takes them
directly, no table lookup.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_point_cloud` | `JSON` | the sensor/node point cloud |
| `p_drift_series` | `JSON` | a coverage-metric series over time |
| `p_boxcount_dim` | `INT` | dimension parameter for `fractal_dimension_boxcount` |
| `p_drift_win` | `INT` | window size for `fractal_dimension_drift` |
| `p_drift_threshold` | `DOUBLE` | drift exponent above which coverage is flagged degrading |
| `p_context` | `TEXT` | optional label passed to the reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"morph_dimension":.., "lacunarity":.., "drift_detected":true\|false, "rationale":".."}` |

**How it works.** (1) `fractal_morphological_complexity(point_cloud)` for
the grid's real spatial complexity. (2)
`fractal_dimension_drift(drift_series, drift_win)` for the real drift
exponent, compared against `drift_threshold`. (3) `fractal_reason` composes
the alert.

**Example**
```sql
CALL fractal_agent_network_coverage_alert(
    '[[0,0,0],[1,0,0],[0,1,0],[1,1,1]]',
    '[0.9,0.91,0.88,0.7,0.5,0.3, ... /* series */]',
    3, 16, 0.6, NULL, @result);
SELECT @result;
```

---

### Regime triage: `fractal_agent_regime_triage` (general-purpose, no table args)
**DFA + drift over one series → LLM triage.**

Use it for any single series (not table-backed) where you want a general
regime-change read: the array-in counterpart to `anomaly_triage`.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_series` | `JSON` | the series to analyze |
| `p_win` | `INT` | window size for `fractal_dimension_drift` |
| `p_drift_threshold` | `DOUBLE` | drift exponent above which a regime change is flagged |
| `p_context` | `TEXT` | optional label passed to the reason call (NULL ok) |
| `p_result` (OUT) | `JSON` | `{"dfa_exponent":.., "drift_detected":true\|false, "recent_alpha":.., "baseline_alpha":.., "rationale":".."}` |

**How it works.** (1) `fractal_dimension_dfa(series)` for the real DFA
exponent. (2) `fractal_dimension_drift(series, win)` for the real drift
exponent, compared against `drift_threshold`. (3) `fractal_reason` triages
the combination.

**Example**
```sql
CALL fractal_agent_regime_triage(
    '[50.1,51.2,49.8,50.5, ... /* >=24 points */]', 16, 0.6, NULL, @result);
SELECT @result;
```

---

### Diverse portfolios: `fractal_agent_diverse_portfolios` (enterprise-tier)
**A diverse SET of cardinality-constrained allocations, not just one.**

Use it when a single best allocation ([allocate](#allocate-fractal_agent_allocate)
above) isn't enough and you want several genuinely different candidates to
choose from, at comparable quality: Quant-Finance scenario comparison,
FinTech client-facing "here are three ways to do this" tooling. Enterprise-
tier: calls `fractal_optimize_portfolio_multimodal` (or
`fractal_optimize_portfolio_multimodal_pareto` in `pareto` mode), dlopen'd
from the enterprise core `.so` (see [`enterprise.md`](enterprise.md)).
Dormant on a Community deployment.

**Inputs**

| Argument | Type | What it is |
| --- | --- | --- |
| `p_mu` | `JSON` | expected returns per asset, e.g. `'[0.05,0.1]'` |
| `p_cov` | `JSON` | covariance matrix, **flattened 1-D row-major n×n**, e.g. `'[1.0,0.0,0.0,1.0]'` |
| `p_cardinality` | `INT` | how many assets to hold |
| `p_n_restarts` | `INT` | independent search restarts to attempt, 1-64 (`NULL` defaults to 8) |
| `p_overlap_threshold` | `DOUBLE` | max allowed asset overlap between any two returned candidates, 0.0-1.0 (`NULL` defaults to 0.3); sharpe mode only — the pareto front has no overlap filter |
| `p_quality_frac` | `DOUBLE` | a candidate must reach at least this fraction of the best Sharpe found, 0.0 exclusive-1.0 (`NULL` defaults to 0.8); sharpe mode only |
| `p_context` | `TEXT` | optional label passed to the reason call (`NULL` ok) |
| `p_objective_mode` | `TEXT` | optimization objective: `'sharpe'` (default, also used for `NULL`) or `'pareto'` |
| `p_result` (OUT) | `JSON` | sharpe mode: `{"optimization":{"n_found":..,"candidates":[{"sharpe":..,"weights":[..]},...]}, "rationale":".."}`; pareto mode: candidates carry `{"return":..,"risk":..,"sharpe":..}` instead |

**How it works.** (1) In `sharpe` mode,
`fractal_optimize_portfolio_multimodal(mu, cov, cardinality, n_restarts,
overlap_threshold, quality_frac, 0)`: runs the SFS Sharpe maximizer
`n_restarts` times with different derived seeds, then greedy
diverse-selects the results by asset overlap and a quality floor. In
`pareto` mode, `fractal_optimize_portfolio_multimodal_pareto(mu, cov,
cardinality, n_restarts, 8, 0, 0, 'gaussian')`: same independent restarts,
but scores each by decomposed return/risk and reduces them to a
non-dominated Pareto front (see
[`enterprise.md`](enterprise.md) for both UDFs' full parameter stories). (2)
`fractal_reason` explains the trade-offs across the returned set.

**Example**
```sql
-- 2 assets, hold 1; cov is the 2x2 identity flattened row-major. Needs
-- FRACTALSQL_ENTERPRISE_LIB set and mariadbd restarted, see enterprise.md.
CALL fractal_agent_diverse_portfolios(
    '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1, 4, 0.3, 0.8,
    '{"portfolio": "agents-demo-diverse"}', 'sharpe', @result);
SELECT @result;

-- Pareto mode: a return/risk front instead of sharpe-ranked candidates.
CALL fractal_agent_diverse_portfolios(
    '[0.05, 0.1]', '[1.0, 0.0, 0.0, 1.0]', 1, 4, NULL, NULL,
    '{"portfolio": "agents-demo-diverse-pareto"}', 'pareto', @result);
SELECT @result;
```

**Notes.** `SIGNAL`s a clean `fractal_agent_diverse_portfolios: enterprise
tier not loaded` error, rather than passing a `NULL` optimization result
through as if it were real data, when no enterprise library is loaded.
`p_cov` must be flattened 1-D row-major, same as `allocate` above.

---

### A note on id resolution

`fractal_search_telemetry`, `fractal_hybrid_clinical_search`, and
`fractal_search_trajectory` return `doc_id` as the target table's own real
primary-key value, not a position index. There is no separate resolution
step and no separate "which column is the id" argument: every
table-searching agent above just requires its target table to have exactly
one single-column `PRIMARY KEY`, and returns that column's real value
directly (`nearest_cohort_id`, `assigned_node`, `mem_id`, and so on are all
real primary-key values, never a position index).

`recommend_diverse` calls `fractal_diversify_enable(CONNECTION_ID())` as a
side effect on your own connection (so re-searches on this same connection
avoid recently-rejected items reported via `fractal_feedback_report`);
reset it with `fractal_diversify_disable(CONNECTION_ID())` when your
session is done. `feedback_audit` runs the whole audit cycle (enable →
warmup → isolate → read-back) and self-disables Diversify, so it leaves
the connection clean without any caller cleanup.

---

## Building blocks: the primitives agents compose

Six procedures underneath the sixteen recipes above are general-purpose
composition primitives rather than one fixed recipe each. MariaDB's C UDF
ABI gives a C function no way to run SQL against the calling session,
so each is a plain stored PROCEDURE that reaches its target table via
dynamic SQL (`PREPARE`/`EXECUTE`), the same mechanism the table-backed
search compositions below use. All six are plain stored procedures,
living in `sql/install_agents.sql` (five of them) and `sql/install_udf.sql`
(`fractal_sql_agent`) alongside the 15 recipes above:

- `fractal_agent_trajectory_predict(table_name, vector_col, baseline_id, forecast_steps, risk_threshold, OUT result)`:
  baseline-to-current drift prediction against a table's own latest row.
- `fractal_search_agent(query, table_name, vector_col, pop_size, iterations, OUT result)`:
  embed the query, Scout-search a caller-named table's vector column,
  reason over the matched rows' real content, and return the answer plus
  `source_doc_ids` and a real (not hardcoded) `execution_time_ms`.
- `fractal_rag_agent(query, table_name, vector_col, meta_filter, OUT answer)`:
  a thin wrapper around `fractal_search_agent` with fixed
  `pop_size=50`/`iterations=15`, returning only the answer text.
  `meta_filter` is accepted for signature parity but currently unused.
- `fractal_sql_agent(question, table_names, max_retries, auto_execute, OUT generated_sql, OUT status, OUT result_json)`:
  self-correcting Text-to-SQL with an optional auto-execute step, the
  `auto_execute`-capable sibling of `fractal_text_to_sql`; see
  [`text-to-sql-setup.md`](text-to-sql-setup.md) for the full behavior.
- `fractal_agent_plan_explore(initial_state, strategy_table, vector_col, max_branches, OUT result)`:
  embed `initial_state`, Scout-search `strategy_table` for up to
  `max_branches` candidate branches, and return each branch's real row id,
  its own vector (`plan_trajectory`), and `score = 1 - distance`, as a JSON
  array in `p_result` (MariaDB has no `RETURNS TABLE`, so this replaces
  a set-returning function).
- `fractal_agent_detect_loop(log_hashes, OUT result)`: a pure numeric
  function needing no table access at all. It flags a loop if either the DFA
  scaling exponent on `log_hashes` exceeds 0.9, or a tight discrete
  repetition period is found (period search capped at n/4).

Each of these six is a MariaDB stored PROCEDURE with a trailing `OUT`
parameter, called with `CALL ...(..., @result); SELECT @result;`, the
same convention as the 15 recipes above.

- **Search**: `fractal_search`, `fractal_explore` (inline-corpus Scout mode),
  see [`api-discovery.md`](api-discovery.md).
- **Table-backed search compositions**: `fractal_search_telemetry`,
  `fractal_hybrid_clinical_search`, `fractal_search_trajectory`,
  `fractal_cross_modal_search`, `fractal_agent_trajectory_predict`,
  `fractal_search_agent`, `fractal_rag_agent`, `fractal_agent_plan_explore`:
  plain SQL/PSM stored procedures (`CALL ...(table, col, ..., @result)`)
  that scan a real table into an in-memory corpus and call the same core
  search primitive `fractal_search` itself wraps. See
  `sql/install_udf.sql`'s own header comment near
  `CREATE PROCEDURE fractal_search_telemetry` for the full mechanism, and
  the Universal Agent procedures' own header comments in
  `sql/install_agents.sql` for the same pattern applied to each one.
- **Table-free composition**: `fractal_agent_detect_loop`, pure numeric,
  no dynamic SQL needed.
- **Analytics**: `fractal_dimension_dfa`/`_boxcount`/`_drift`,
  `fractal_optimize_portfolio`, `fractal_morphological_complexity`, see
  [`api-analytics.md`](api-analytics.md).
- **Cognition**: `fractal_reason`, `fractal_embed`, see
  [`api-cognition.md`](api-cognition.md).
- **Diversify/Repulsion state**: `fractal_diversify_enable`/`_disable`/
  `_set_params`, `fractal_feedback_report`, `fractal_detect_collapse`,
  connection-scoped via `CONNECTION_ID()`.

Every one of these is an ordinary function or procedure you can `CALL`/
`SELECT` directly and compose into your own stored procedure: a custom
agent is just a `CREATE PROCEDURE ... SQL SECURITY INVOKER BEGIN ... END`
that calls them in sequence and returns a shaped `OUT` result, exactly like
the 15 recipes above.

---

## Reference blueprints: industry verticals

Eleven runnable industry walkthroughs ship as `demo/demo-vertical-*.sql`:
three agentic verticals (DevOps/SRE, FinTech, Customer Support) plus eight
further industry-vertical demos covering quant finance, MedTech, and
others. Every one has been run end-to-end against a real MariaDB server
and a real Ollama endpoint. See
[demo/README.md](../demo/README.md#industry-vertical-demos) for the exact
list. The 15 recipes above, the six Universal Agent procedures in
[Building blocks](#building-blocks-the-primitives-agents-compose) above,
and the primitives in [Composing your own](#composing-your-own) below, are
the same building blocks those blueprints compose.

---

## Composing your own

The composition principle is simple: every primitive is an ordinary
function or procedure, so a custom agent is just a
`CREATE PROCEDURE ... SQL SECURITY INVOKER` that calls them in sequence,
feeds one's output into the next's input via a local `DECLARE`d variable,
and returns a shaped `JSON` result through an `OUT` parameter. Read any of
the 15 recipes in `sql/install_agents.sql` as a worked template; they're
all under 100 lines each and follow the same shape (validate inputs →
gather via dynamic SQL or a search primitive → analyze → `fractal_reason` →
assemble the `OUT` JSON).

---

## Validate

`demo/demo-agents.sql` exercises the agent procedures end-to-end against a
live install. Run it with:

```sh
mariadb -u<user> -p <database> < demo/demo-agents.sql
```

`build_test.sh`'s gate 24 (`gate_24_agents`) smoke-tests three of the
compositions (`recall_hybrid`, `recommend_diverse`, `route_task`) in a
throwaway cluster against a real reasoning round trip, so the agent wiring
is also covered by the automated regression suite across all four
compat-matrix MariaDB majors (10.6 / 10.11 / 11.4 / 12.3).
