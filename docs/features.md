<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# FractalSQL Feature Specification

FractalSQL is a tiered capability framework that runs discovery, reasoning,
and agentic workflows inside the MariaDB backend: no external RAG
middleware shuffling data between the database and the LLM. It provides a
progression from basic vector discovery to autonomous agentic reasoning.

---

## 🏗️ Capability Tiering Model

FractalSQL ships in two editions, each unlocking more of the four
capability tiers described below (Discovery → Cognition → Agency →
Analytics). The editions are a *build/licensing* axis; the capability tiers
are a *functional* axis. A single install belongs to one edition and
exposes whichever capability tiers that edition includes.

| Tier | Focus | Key Capabilities | Build / Requirement |
| --- | --- | --- | --- |
| **Community** | Discovery, Cognition, Agency | SFS Core, Sniper Search, Scout Discovery, In-DB Reasoning, Embeddings, 15 Agents | Base UDF set (`fractalsql.so`), everything most installs need |
| **Enterprise** | Governance | Activation gating plus a real, tamper-evident ledger storage layer. See [Enterprise Tier](enterprise.md) for the full scope |

---

## 🔍 Tier 1: Discovery

The foundation of FractalSQL is the **Stochastic Fractal Search (SFS)**
engine, which treats vector search as a continuous optimization problem
rather than an index lookup like standard HNSW.

### Sniper Search (`fractal_search`)
Pure SFS convergence to the single best point minimizing cosine distance to
a query. Also the corpus top-k search: pass a real inline corpus for top-k,
or an empty one (`''`) to run pure convergence with no corpus at all. It is
a "precision" tool for finding the absolute global minimum.

### Scout Discovery (`fractal_explore`)
An SFS population search blended with **Maximal Marginal Relevance (MMR)**
re-ranking, so the results cover the data's distinct basins of attraction
instead of the "mode collapse" common in top-K search. Unlike postgres's
`fractal_search_explore(table, col, ...)`, this repo's Scout Mode takes its
corpus as one inline argument. MariaDB's C UDF ABI has no SPI and no
table-returning UDFs at all, so there is no server-side table scan for it.

### Table-Backed Telemetry (`fractal_search_telemetry`)
A stored procedure that returns the $K$ nearest real table rows to a query
(`CALL fractal_search_telemetry(table, col, query, k, @result)`). This is
the ground-truth layer used by every table-backed agent.

---

## 🧠 Tier 2: Cognition

The Cognition tier adds a reasoning bridge to the SFS core, allowing it to
call LLMs and embedding models via a pluggable C provider interface. This
enables reasoning to happen *beside* the data.

### In-Database Reasoning (`fractal_reason`)
Dispatches a query and a context payload to a configured LLM provider.
`fractal_reason(session_id, query [, context])`. `session_id`
(`CONNECTION_ID()`) is required and first, a MariaDB-specific requirement
(one shared multithreaded server process, not one process per connection).
Because it runs inside the backend, you can feed it the results of a Scout
search or a SQL query in one statement.

**Provider-agnostic**: the same `fractal_reason()` call works against
**AWS Bedrock (SigV4)**, **Azure OpenAI**, **GCP Vertex AI**, or **local
Ollama**. Switch providers by restarting `mariadbd` with different env
vars (no live-reconfigure, see [Reasoning Setup](reasoning-setup.md) for
why). Local providers keep data on your own infrastructure; cloud
providers send it to that provider under your own account and agreement
(BAA-covered where your compliance posture requires it).

### Semantic Embeddings (`fractal_embed`)
Generates vectors from text using a purpose-trained embedding model,
`fractal_embed(session_id, input)`. Returns a `fractal_vector`
JSON-array-string (not a native array type: MariaDB has none across the
10.6-12.2 compat floor this repo targets). This removes the need for an
external embedding pipeline for many RAG use cases.

### Safe Text-to-SQL (`fractal_text_to_sql`)
Generates SQL from natural language, as a `CALL`-based stored procedure here
(`CALL fractal_text_to_sql(question, table_names_json, @sql, @err)`) rather
than a function, since the pipeline composes several C primitives via
SQL/PSM instead of running as a single UDF call. Four-stage safety
pipeline:
1. **GENERATE**: LLM produces a candidate, fenced-block extraction handled
   automatically.
2. **ALLOWLIST**: a hand-written lexical scanner rejects multi-statement,
   disallowed statement types, and `INTO OUTFILE`/`DUMPFILE`.
3. **REVIEW** (optional): a second LLM call critiques the candidate.
4. **EXPLAIN-equivalent**: `PREPARE`s (never executes) the candidate to
   catch column/type mismatches before returning the SQL.

---

## 🤖 Tier 3: Agency

The Agency tier composes the Discovery and Cognition primitives into
autonomous routines: **15 installable agent stored procedures** plus 5
Universal Agent compositions, each a productized recipe for a
recurring pattern.

> **No separate "Universal Agent" C-level tier; all six are available
> as stored procedures.** Six intermediate functions
> (`fractal_search_agent`, `fractal_rag_agent`, `fractal_sql_agent`,
> `fractal_agent_plan_explore`, `fractal_agent_trajectory_predict`,
> `fractal_agent_detect_loop`) sit underneath the recipes above. None
> exist here as C-level primitives (no SPI), but a MariaDB stored
> PROCEDURE reaches the same table access via dynamic SQL
> (`PREPARE`/`EXECUTE`) instead, the same mechanism the table-backed
> Discovery primitives already use. All six are implemented this way
> (`fractal_sql_agent` in `sql/install_udf.sql`, the other five in
> `sql/install_agents.sql`) and are callable directly, not just
> internal to the 15 recipes. See [`docs/api-agency.md`](api-agency.md)
> for the full building-blocks list.

### Agent Sample

| Agent Procedure | Composes | Capability Provided |
| --- | --- | --- |
| `fractal_agent_data_analyst` | `fractal_text_to_sql` → `fractal_reason` | NL question over your tables, with a reasoned summary. |
| `fractal_agent_route_task` | `fractal_search_telemetry` → `fractal_reason` | Match an incoming task to the best capable sub-agent. |
| `fractal_agent_regime_triage` | `fractal_dimension_dfa`/`_drift` → `fractal_reason` | Flag a series drifting into a new regime. |
| `fractal_agent_recommend_diverse` | Diversify-aware `fractal_search_telemetry` | Repulsion-diverse top-k, avoiding recently-rejected items. |
| `fractal_agent_patient_deterioration_triage` | `fractal_hybrid_clinical_search` → `fractal_search_trajectory` → `fractal_reason` | Cohort search + baseline→current drift. |

Full table of all 15 in [`docs/api-agency.md`](api-agency.md#which-agent-should-i-use).

### Safe Agency & Guardrails

To prevent "hallucination-driven" database corruption, the Agency tier
relies on two primary guardrails:

1. **The `PREPARE`-only barrier**: `fractal_text_to_sql`/`fractal_sql_agent`
   `PREPARE` (never `EXECUTE`) the generated SQL as part of validation. A
   malformed candidate is caught mechanically and fed back to the LLM for a
   retry, with nothing ever run against your session's transaction state
   during validation itself.
2. **The Deterministic Allowlist**: `FRACTALSQL_TEXT_TO_SQL_ALLOWED_STATEMENTS`
   (a process env var, not a per-role setting) strictly limits the types of
   SQL the pipeline can generate (e.g., preventing `DROP TABLE` even if the
   LLM suggests it).

---

## 📐 Tier 4: Analytics

The final tier provides mathematical primitives for analyzing the "shape"
of data and state, turning raw vectors into actionable structural insights.

### Fractal Dimension Analysis
- **DFA (`fractal_dimension_dfa`)**: Analyzes the scaling exponent of a
  time series to distinguish between noise, random walks, and structured
  signals.
- **Box-Counting (`fractal_dimension_boxcount`)**: Measures the
  Minkowski-Bouligand dimension of a point cloud to evaluate spatial
  complexity.
- **Drift (`fractal_dimension_drift`)**: Detects regime changes by
  comparing the DFA exponent of a recent window against a baseline.

### Domain-Specific Geometry
FractalSQL provides optimized routines for pre-extracted biological and
technical geometry: vascular networks (tortuosity, branch-density),
cortical folding (Gyrification Index), nerve plexus (density, dimension),
and morphological complexity (box-counting + lacunarity for segmented
masks).

### Portfolio Optimization
`fractal_optimize_portfolio` uses the SFS engine to solve
cardinality-constrained Sharpe-ratio maximization: the best $K$ assets in a
large universe without the exponential cost of a brute-force search.

---

## 📈 Benchmarks & Scaling

### Native `VECTOR(n)` index vs. Scout Discovery

At 5000 vectors across 50 Gaussian clusters, dim=128, a **much smaller**
default than postgres's 100k-row comparison, and deliberately so: Scout
Mode (`fractal_explore`) has no server-side scan at all, every call
re-sends the whole corpus as a client-supplied string; at postgres's scale
that string would be hundreds of megabytes per query. See
`benchmark/README.md` for the full methodology and reasoning. This is a
real architectural ceiling, not a smaller-is-easier choice. Measured
directly against a real `mariadb:12.2` container:

- **Native `VECTOR(n)` index** (top-50) typically discovered **~1 cluster**,
  in single-digit milliseconds (measured: 4.6 ms avg).
- **Scout** (pop=50) typically discovered **~5-7 clusters**, roughly
  **40-45x slower** than the native index at this scale (measured: 197.5 ms
  avg, 43.3x slower, 4.7x more clusters discovered).

That tradeoff is the whole point of Scout Mode, not a hidden cost: it's
$O(N \times d)$ (linear scan) by design, and it's the only way here to
guarantee your LLM receives a genuinely diverse set of perspectives rather
than a single collapsed cluster. It is not a drop-in replacement for the
native index. Use it where diversity matters more than latency (curated
sub-corpora, not full-corpus top-k at scale).

### Storage: TEXT/JSON-string vs. native `VECTOR(n)`

MariaDB has no equivalent of postgres's custom `fractal_vector` SQL type
(no `CREATE TYPE`/typmod mechanism at all). The real comparison here is
this repo's portable TEXT/JSON-array-string convention against MariaDB's
own built-in `VECTOR(n)` column type (11.7+). Measured at 5000 rows,
dim=128, MariaDB 12.2: `VECTOR(n)` is **~2.4x smaller on disk** (fixed 4
bytes/dim, architecturally fixed, not data-dependent) and loads **~2x
faster** in bulk. It was **~50% slower**, in this measurement, for
`fractal_search_trajectory`-style table-backed search latency, since the
`VEC_TOTEXT()` conversion step this repo's search compositions need to read
a native column costs more than reading plain `TEXT` directly. Not a clean
sweep either way; measure on your own workload (see `benchmark/README.md`'s
`vector_type_head_to_head.py` section for the full numbers and caveats).

---

## 📚 API Reference

(Detailed argument tables, defaults, and ranges are available in the
detailed per-tier references.)

**Discovery**
- `fractal_search(vector_csv, query_csv, k, params)`: Sniper Mode convergence, or corpus top-k. → **[api-discovery.md](api-discovery.md)**
- `fractal_explore(corpus, query, params)`: Scout Mode diverse exploration. → **[api-discovery.md](api-discovery.md)**
- `fractal_search_telemetry(table, col, query, k, OUT result)`: Ground-truth row retrieval. → **[api-discovery.md](api-discovery.md)**

**Cognition**
- `fractal_reason(session_id, query [, context])`: LLM dispatch. → **[api-cognition.md](api-cognition.md)**
- `fractal_embed(session_id, input)`: Semantic vector generation. → **[api-cognition.md](api-cognition.md)**
- `fractal_text_to_sql(question, table_names, OUT sql, OUT err)`: Safe SQL generation. → **[api-cognition.md](api-cognition.md)**

**Agency**
- `fractal_agent_data_analyst(...)`: NL question over tables + reasoned summary. → **[api-agency.md](api-agency.md)**
- `fractal_agent_route_task(...)`: Sub-agent dispatch. → **[api-agency.md](api-agency.md)**
- `fractal_agent_regime_triage(...)` / `_anomaly_triage(...)`: Drift/regime detection. → **[api-agency.md](api-agency.md)**
- `fractal_agent_recommend_diverse(...)` / `_recall_hybrid(...)`: Diverse/cohort-restricted retrieval. → **[api-agency.md](api-agency.md)**
- 10 more, full list → **[api-agency.md](api-agency.md#which-agent-should-i-use)**

**Analytics**
- `fractal_dimension_dfa(series)`: DFA scaling exponent. → **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_boxcount(points, dim)`: Box-counting dimension. → **[api-analytics.md](api-analytics.md)**
- `fractal_dimension_drift(series, win)`: Regime change detection. → **[api-analytics.md](api-analytics.md)**
- `fractal_optimize_portfolio(...)`: Cardinality-constrained optimization. → **[api-analytics.md](api-analytics.md)**
- `fractal_vascular_network(...)`: Vessel tortuosity/density. → **[api-analytics.md](api-analytics.md)**
- `fractal_cortical_folding(...)`: Gyrification Index. → **[api-analytics.md](api-analytics.md)**
- `fractal_nerve_plexus_metric(...)`: Fiber plexus density. → **[api-analytics.md](api-analytics.md)**
- `fractal_morphological_complexity(...)`: Mask complexity. → **[api-analytics.md](api-analytics.md)**
