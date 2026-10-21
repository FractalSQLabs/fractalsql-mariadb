<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# FractalSQL demo

`demo.sql` is a runnable, five-minute walkthrough of search and
reasoning in one script: Sniper Search, Scout Discovery, and LLM
reasoning — including Scout's output feeding straight into a reasoning
call, which is the pattern the rest of the docs point at but don't show
running end to end in one place. Text-to-SQL has its own walkthrough —
see [Text-to-SQL](#text-to-sql) below.

`response-modes.sql` is a companion script for `text` / `code` / `json`
response modes — see [Response modes](#response-modes) below for why
it's a separate file from `demo.sql`.

## Prerequisites

1. **The UDFs are registered.** MariaDB has no `CREATE EXTENSION`; the
   equivalent is running the install scripts once:

   ```sh
   mariadb -u root -p < sql/install_udf.sql
   mariadb -u root -p < sql/install_agents.sql   -- for demo-agents.sql
   ```

2. **Reasoning is configured.** Sections 0–2 of `demo.sql` only need the
   UDFs themselves, but sections 3–4 call `fractal_reason()`, which
   needs a working LLM endpoint. Follow
   [../docs/reasoning-setup.md](../docs/reasoning-setup.md) first —
   Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, and any
   OpenAI-compatible endpoint are all documented there, and
   `docker compose up -d` sets the whole thing up for you (see
   [docs/docker-demo.md](../docs/docker-demo.md)). Config is a set of
   `FRACTALSQL_*` process environment variables read ONCE by `mariadbd`
   at startup — there is no server config file, sysvar, or `SET GLOBAL`
   equivalent. Confirm it works before running this demo:

   ```sql
   SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation that this connection works');
   ```

   If that returns NULL or errors, `demo.sql` will hit the same error
   at section 3 — fix it there first rather than debugging through the
   demo script.

## Running it

```sh
mariadb -u root -p <your_database> < demo/demo.sql
```

MariaDB's CLI has no per-statement timing toggle; wrap a call in
`SET profiling = 1; ... SHOW PROFILES;` if you want per-statement
timing — worth watching, since the reasoning calls (sections 3–4) are
the slow part. A cloud endpoint typically responds in a few seconds; a
local Ollama model can take much longer on a cold load (see "Handling
Constrained Hardware" in `docs/reasoning-setup.md` if a call times
out).

The script is safe to re-run: `demo_alerts` and `demo_embeddings` are
dropped and recreated at the start of their sections every time, so
there's no stale-state cleanup to do between runs.

## What each section shows

- **0 — Sanity check.** `fractal_edition()` / `fractal_version()`
  confirm the UDFs are actually registered before anything else runs.
- **1 — Setup.** A small `demo_alerts` table with a deliberate story in
  it: a login-attempt count that escalates (3 → 3 → 17) and a latency
  spike in the last ~10 minutes. Nothing here calls the LLM yet.
- **2 — Sniper Search.** `fractal_search()` converges to a single best
  point for a query vector — the fast, precise mode. No table needed;
  it operates on the query vector alone.
- **3 — Reasoning over real data.** `fractal_reason()` gets a real
  `context` argument this time — the alerts from the last hour,
  serialized to JSON via a subquery — rather than an empty ping. Expect
  the model to notice the login-attempt escalation and the latency
  spike; exact wording varies by model and provider.
- **4 — Scout Discovery feeding reasoning.** `fractal_search_explore()`
  samples a diversity-spread population from `demo_embeddings`, and
  that population is handed to `fractal_reason()` as context in the
  same statement. This is the differentiator pattern: diversity-sampled
  context instead of a plain `WHERE` filter, in one pipeline.

## Response modes

`response-modes.sql` demonstrates the three shapes a reasoning reply
can come back in — plain text, fenced-code extraction, and JSON — see
[docs/reasoning-setup.md](../docs/reasoning-setup.md#response-modes) for
the full explanation of the `FSQL_REASONING_HTTP_RESPONSE_MODE` knob
behind them.

It's a **separate file from `demo.sql`**, not another section in it,
because the three shapes are not three settings of one knob:

- `fractal_reason()` always returns raw model text. There is no
  per-call or per-session way to put it into a fenced-extraction mode.
- The fenced-code extraction is `fractal_t2s_generate()`'s own
  behavior — the plugin asks the model for a single fenced code block
  and strips the fence markers on extraction. It is not a general
  caller-facing response mode.
- There is no server-side "json" mode at all. The JSON section asks
  the model for JSON in the prompt and validates the reply
  client-side with MariaDB's own `JSON_VALID()`.

So the file needs no environment change and no restart to run: read
it as three sections, each demonstrating one of the shapes through the
surface that actually provides it. The file's own header has the
full reasoning, straight from `src/fractalsql_cognition.c` and
`src/fractalsql_textsql.c`.

1. Run `demo.sql` first if you haven't — `response-modes.sql` reuses
   its `demo_alerts` table.
2. Run the whole file:
   ```sh
   mariadb -u root -p <your_database> < demo/response-modes.sql
   ```

What to expect: the fenced-code section returns a bare SQL statement
with no prose wrapper (no "Here's a query that does that:" preamble,
no visible fence markers). The JSON section returns the model's reply
next to `JSON_VALID()` of that same reply, so a `1` is proof the
reply actually parsed as JSON, not just "looks like JSON" — and a `0`
is a real, expected outcome worth reading, not a bug to work around:
a model that wraps its JSON in markdown fencing fails `JSON_VALID()`
here rather than being quietly accepted.

In the [Docker demo](../docs/docker-demo.md#docker-demo-the-learning-path),
skip the manual pass above: `run_demo.sh --include-response-modes`
runs the file for you in the demo container, against the `demo_alerts`
table `demo.sql` leaves behind.

## Enterprise Tier — QTL & CISO Audit

`enterprise-qtl-audit.sql` exercises the enterprise-tier **Quantized Ternary
Ledger** (append-only, tamper-evident Truth/Shadow record of search/feedback
events, persisted as a hash-chained file in the datadir) and **CISO audit
unpack** surface. Unlike every other demo here, it runs cleanly in **two**
states and tells you which one it found:

- **Dormant (default):** the enterprise core library is not loaded, so
  the nine functions (eight `fractal_ledger_*` functions plus
  `fractal_audit_unpack`) are registered but inactive. The demo seeds
  real engagement events with the community `fractal_feedback_report()`
  primitive, then the first enterprise call comes back `NULL` and the
  demo prints a single `Enterprise edition not loaded` notice explaining
  how to activate it. It exits successfully — safe to run on a
  community-only checkout or in CI.
- **Active:** with the enterprise shared library staged in and
  `FRACTALSQL_ENTERPRISE_LIB` pointed at it (a `mariadbd` restart), the
  demo flushes the seeded ledgers to the real ledger file via the
  file-backed storage path, decodes the persisted QTL blob back into a
  CISO event log with `fractal_audit_unpack()`, then exercises `load` /
  `compact` / `reset_soft` / `reset_hard` end to end.

```sh
mariadb -u root -p <your_database> < demo/enterprise-qtl-audit.sql
```

See the [Enterprise Tier](../README.md#enterprise-tier) section of the
root README and [docs/enterprise.md](../docs/enterprise.md) for the
activation steps and the function reference. The optional CONNECT
mirror (`sql/install_enterprise_connect.sql`) makes the persisted
ledger queryable as a plain SQL table — the CISO decode there runs
straight from SQL.

### Enterprise Tier — Stress & Tamper-Evidence

`enterprise-stress.sql` is the companion to the audit demo above: it
hammers the same enterprise ledger surface under load. Phases A–C run
end to end: it fills the in-memory Truth/Shadow ledgers to their
**capacity bound** (64 each, `FSQL_TRUTH/SHADOW_DEFAULT_CAP` — 128
events total with disjoint doc_ids; beyond 64 of either kind the ledger
evicts the lowest-weight entry, so 64/64 is the real cap), churns
**5 flush/load cycles at capacity**, and builds a short 3-link
append-only chain, each verified by `fractal_ledger_verify`.
**Phase D — tamper-evidence** is documented in the script's header
comment as out-of-band recipes rather than run in-script (MariaDB's C
UDF ABI has no way for a UDF to flip a byte mid-script): structurally
(truncating the persisted ledger file below its 9-byte header, rejected
by the record-length walk) and cryptographically (setting
`FRACTALSQL_ENTERPRISE_LEDGER_KEY` to HMAC-SHA256-tag every record and
flipping a middle payload byte the structural check cannot see, rejected
by the MAC on load). Same dual-state, safe-on-community shape as the
audit demo (dormant → single notice; active → all phases run clean).

> **Scope note:** by default (`FRACTALSQL_ENTERPRISE_LEDGER_KEY` unset)
> the QTL format carries no MAC, so the tamper-evidence demonstrated is
> **structural only** (truncation / count-length mismatch). A targeted
> payload byte-flip (e.g. changing a stored `doc_id`) is **not** detected
> by the structural check. Setting `FRACTALSQL_ENTERPRISE_LEDGER_KEY` (an
> environment variable read once at `mariadbd` startup) adds an
> **HMAC-SHA256 envelope**: every flush tags the persisted record and
> every load verifies the tag before the core decodes, so that same
> byte-flip **is** detected.
>
> **Cross-restart / tamper coverage** (flush on one `mariadbd` lifetime,
> load rehydrating the ledger in a fresh one, and a byte-level payload
> tamper caught by the MAC on load) is exercised by `build_test` **gate
> 26** — not something a single `mariadb <` script can do to itself.

```sh
mariadb -u root -p <your_database> < demo/enterprise-stress.sql
```

## Text-to-SQL

`demo-text-to-sql.sql` walks through `fractal_text_to_sql()` against
a richer three-table schema with real foreign keys (`customers` ->
`orders` -> `order_items`) — single-table questions, a question
requiring a join, and a question requiring all three tables, plus
capturing and running a generated statement yourself. Same
prerequisites as `demo.sql` (UDFs registered, reasoning configured).
Full pipeline explanation, the allowlist reference, and the
execution-role grant pattern are in
[docs/text-to-sql-setup.md](../docs/text-to-sql-setup.md).

Here `fractal_text_to_sql()` is a stored **procedure**, not a scalar
function — it is called as
`CALL fractal_text_to_sql(question, table_names_json, @sql, @err)`
and the two OUT parameters are read back, because a MariaDB stored
function cannot call a stored procedure at all. Two consequences worth
knowing before you read the demo:

- **It never signals on failure.** A failed generation returns
  cleanly with `@sql = NULL` and `@err` set to the reason; it is not
  an SQL error. Branch on `@err IS NULL` rather than expecting an
  exception.
- **The table list is a JSON string, not an array.** The second
  argument is `'["customers", "orders"]'` — a JSON array of table
  names — or `NULL` to let it auto-discover every table visible to
  the session. (MariaDB's stored-procedure parameter types have no
  array type, hence the JSON string.)

```sh
mariadb -u root -p <your_database> < demo/demo-text-to-sql.sql
```

`demo/text-to-sql-spike-*.sql` are a 4-part hand-rolled GENERATE →
REVIEW → EXPLAIN → negative-control validation spike, kept as the
record of how the function was validated before it shipped — history,
not the recommended starting point. Reasoning config is fixed per
`mariadbd` process: restart with a different `FRACTALSQL_HTTP_MODEL`
to compare a different model, then re-run Parts 1–4 from scratch.

## Industry vertical demos

Forty-two runnable walkthroughs — twenty-seven **domain kits** and fifteen
**agentic verticals** — each with its own synthetic dataset and its own
subset of the function surface chosen for genuine domain fit, not forced
coverage. Every one ends with a `fractal_reason()` narrative call over
real computed results, same closing pattern as `demo.sql`. Same
prerequisites as `demo.sql` (UDFs registered; the final reasoning
section in each needs [reasoning configured](../docs/reasoning-setup.md)
— every earlier section runs without it; the two newest kits,
Biotech & Genomics and Edge Swarm, need no reasoning at all — see their
entries below). All forty-two are also wired
into the Docker demo — see
[the Learning Path](../docs/docker-demo.md#docker-demo-the-learning-path),
including `run_demo.sh` to run all forty-two (plus every other demo in
this directory) in one pass instead of one client session per file.
Four (MedTech, Maritime, Fleet, Cybersecurity) store their vector
columns via this repo's two native paths — the portable
JSON-array-string `TEXT` column (works everywhere, 10.6+) or MariaDB's
own `VECTOR(n)` type (11.7+) — picking one per column rather than a 1:1
type substitution; see [demo-fractal-vector.sql](demo-fractal-vector.sql)
and [docs/vectorizer-setup.md](../docs/vectorizer-setup.md) for the
type story.

```sh
mariadb -u root -p <your_database> < demo/demo-vertical-quant-finance.sql
```

- **[demo-vertical-quant-finance.sql](demo-vertical-quant-finance.sql)** —
  Quantitative Finance & Algorithmic Trading. A 25-asset factor-model
  portfolio (`fractal_optimize_portfolio` picks the best 8) and a
  300-point price series with a deliberate volatility regime change at
  t=150 (`fractal_dimension_dfa`/`fractal_dimension_drift`).
  `fractal_search_trajectory` finds which of 10 historical quarterly
  rebalances the new allocation most resembles.
- **[demo-vertical-medtech-clinical.sql](demo-vertical-medtech-clinical.sql)** —
  MedTech, Clinical Telemetry & Patient Monitoring. 40 synthetic
  patients with a fixed five-field clinical vitals vector where
  dimension-drift protection actually matters:
  `fractal_hybrid_clinical_search` over an age/condition cohort computed
  with ordinary SQL, `fractal_search_trajectory` for a patient's current
  vitals vs. their own admission baseline, plus the domain-geometry
  functions (`fractal_vascular_network`, `fractal_cortical_folding`,
  `fractal_nerve_plexus_metric`) on small, pre-extracted geometric
  fixtures — a vessel graph, a reference unit-cube mesh, a nerve fiber
  skeleton.
- **[demo-vertical-recommendation-search.sql](demo-vertical-recommendation-search.sql)** —
  Advanced Recommendation, Search & Discovery Engines. A 300-item, 6-genre
  catalog for diverse "you might also like" discovery
  (`fractal_search_explore`), table-backed top-k
  (`fractal_search_telemetry`), and the **full stateful-diversity
  loop**: enable Diversify, search, report negative feedback on the
  top result, re-search the same query, confirm it's now avoided — the
  real differentiator over plain top-K or MMR, neither of which is
  stateful across searches. Also covers `fractal_cross_modal_search`
  (content + behavior vectors, weighted).
- **[demo-vertical-sovereign-edge-ai.sql](demo-vertical-sovereign-edge-ai.sql)** —
  Sovereign, Edge & Autonomous Systems AI. FractalSQL's whole story fits
  this vertical natively — search, reasoning, and optimization all run
  as pure C UDFs inside the same `mariadbd` process, no external
  vector-DB service required. A 50-node edge-compute fleet: Sniper
  Search for an ideal node profile, Scout Discovery for diverse fleet
  profiles, `fractal_dimension_boxcount` over a facility deployment
  grid, and `fractal_optimize_portfolio` repurposed as a general
  on-device black-box resource allocator (picking 6-of-50 nodes for a
  distributed job under contention risk).
- **[demo-vertical-maritime-defense.sql](demo-vertical-maritime-defense.sql)** —
  Maritime, Aviation & Defense (AIS & Radar Tracking). 30 synthetic AIS
  vessel tracks (a fixed four-field track-state vector), one given a
  deliberate course deviation. `fractal_search_trajectory` on the
  current-vs-baseline track delta (a direct fit for "what changed"
  deviation detection), nearest-track/diverse-track clustering
  across the fleet, and `fractal_dimension_dfa` on heading-change
  series to separate smooth transit from erratic maneuvering.
- **[demo-vertical-fleet-logistics.sql](demo-vertical-fleet-logistics.sql)** —
  Autonomous Fleet Management & Last-Mile Delivery. A 40-vehicle
  delivery fleet, one running a deliberate detour. Diverse route/zone
  clustering for depot coverage, a cohort-restricted search ("today's
  route-3 vehicles only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses, built here with an ordinary
  filtered table instead of that clinically-named function), detour
  detection via `fractal_search_trajectory`, and GPS-trace complexity
  via `fractal_dimension_boxcount`.
- **[demo-vertical-smart-cities-iot.sql](demo-vertical-smart-cities-iot.sql)** —
  Smart Cities & IoT Sensor Grids. A 400-sensor city grid
  (traffic/air-quality/noise): spatial coverage diagnostics
  (`fractal_dimension_boxcount`/`fractal_morphological_complexity`),
  an air-quality event detected via `fractal_dimension_dfa`/
  `fractal_dimension_drift` on a sensor series with a deliberate
  regime shift, and diverse representative-zone sampling via Scout
  Discovery.
- **[demo-vertical-cybersecurity-threat-detection.sql](demo-vertical-cybersecurity-threat-detection.sql)** —
  Cybersecurity & Threat Detection (network behavior analytics). A
  35-host fleet across three zones, one host showing a stealthy
  compromise pattern — outbound connections, destination ports, and DNS
  query volume all spike while failed-auth stays flat, not a brute-force
  signature. Diverse traffic-profile clustering for threat hunting
  (`fractal_search_explore`), a zone-restricted search ("DMZ hosts
  only" — the same cohort-then-search composition
  `fractal_hybrid_clinical_search` uses), compromise detection via
  `fractal_search_trajectory`, and connection-rate regime-change
  detection via `fractal_dimension_dfa`/`fractal_dimension_drift` on a
  beaconing-onset series.
- **[demo-vertical-biotech-genomics.sql](demo-vertical-biotech-genomics.sql)** —
  Biotech & Genomics (structural bioinformatics / single-cell
  transcriptomics). Two showcases for the newest primitives:
  `fractal_tda_persistence_diagram` over a PCA/UMAP-reduced-style point
  cloud standing in for a cell-cycle trajectory that loops back on
  itself (G1 → S → G2/M → G1) — topological data analysis is a real,
  published technique for detecting exactly this kind of cyclic
  structure in single-cell data — and `fractal_vector_lp_distance`
  comparing synthetic gene-expression profiles under L1 (Manhattan,
  the more standard genomics choice) vs the extension's default L2,
  with the demo narrative explaining *why* they disagree. Needs no
  reasoning at all. Carries the TDA scope note (betti1 is the 1-skeleton
  cycle rank, not full homology) from the install script verbatim.
- **[demo-vertical-agentic-edge-swarm.sql](demo-vertical-agentic-edge-swarm.sql)** —
  Agentic Edge Swarms (many small autonomous agents coordinating under
  tight memory/battery/bandwidth budgets). Three showcases for the same
  operating envelope: `fractal_vector_quantize_int8`/`_binary` +
  `fractal_vector_hamming_distance` compressing a swarm agent's local
  observation memory 4x/32x, `fractal_state_fingerprint` +
  `fractal_cycle_detect` catching an agent stuck in a "cognitive
  wobble" period-2 loop with O(1) memory per step, and
  `fractal_optimize_subset` doing battery-constrained task routing.
  Despite the "agentic" name it exercises the primitives directly, not
  the agent procedures — needs no reasoning at all.

One genuine architectural constraint applies to two of the above:
MariaDB's `information_schema` has zero visibility into `TEMPORARY`
tables, so `demo-vertical-fleet-logistics.sql` and
`demo-vertical-cybersecurity-threat-detection.sql` use a plain
permanent `CREATE TABLE` for their cohort tables
(`vfl_route3_cohort`/`vcy_dmz_cohort`) rather than `CREATE TEMPORARY
TABLE` — a temporary table can't be introspected that way.

### Agentic verticals (Universal Agent composition)

The three agentic verticals exercise the C-level **Universal Agents**
(`fractal_agent_detect_loop`, `fractal_agent_plan_explore`,
`fractal_agent_trajectory_predict` — installed as ordinary stored
procedures in this edition) composed into **Domain Agents** — see
[docs/api-agency.md](../docs/api-agency.md) for the composition
pattern. Unlike the domain verticals above, every section here needs
reasoning configured (the agents call `fractal_reason`/`fractal_embed`),
and each is a clean, re-runnable regression test of a recently-fixed
agent code path — nothing commented out, no skip-wrappers.

- **[demo-vertical-agentic-ops-devops.sql](demo-vertical-agentic-ops-devops.sql)** —
  DevOps/SRE: Autonomous Incident Triage & Self-Healing. The
  embed-coupled agents on a real vectorized `vao_incident_logs` corpus:
  `fractal_search_agent` and `fractal_rag_agent` (a question embedded
  and Scout-searched over the embedded log lines, with and without the
  reasoning step), `fractal_agent_detect_loop` on a period-2
  state-hash array (the short-period check the DFA-only threshold
  misses), drift analysis over a real latency series, plus
  `fractal_agent_route_task` and `fractal_agent_outlier_intercept`
  Domain Agent compositions.
- **[demo-vertical-agentic-fintech-mcts.sql](demo-vertical-agentic-fintech-mcts.sql)** —
  FinTech: Scenario Exploration & Safe Execution. `fractal_agent_plan_explore`
  over a vectorized `vfm_trade_strategies` corpus (the embed-coupling
  satisfied by the vectorizer), text-to-SQL-driven execution with a
  thrown error surfaced as a clean failure row rather than aborting the
  call, and `fractal_optimize_portfolio` rebalancing.
- **[demo-vertical-agentic-customer-support.sql](demo-vertical-agentic-customer-support.sql)** —
  Customer Support: Stateful Session & Churn Drift.
  `fractal_agent_trajectory_predict` reading a baseline + latest state
  vector by PK and deriving the drift from the data itself, plus
  `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, and
  the `fractal_diversify_enable` stateful-diversity loop.


### Newer verticals (automotive, aerospace, telecom, climate tech, RF)

- **[demo-vertical-ev-battery-lifecycle.sql](demo-vertical-ev-battery-lifecycle.sql)** —
  EV Battery Lifecycle (agentic kit). 3 vehicles x 96 readings (state of health, pack temperature, cell voltage); one vehicle develops an accelerating thermal ramp and SoH fade. Chains `fractal_agent_patient_deterioration_triage` (cohort search plus baseline-vs-current trajectory drift: a vehicle's intake baseline plays the patient's admission baseline) with `fractal_agent_anomaly_triage` (the DFA drift exponent of the temperature series), each shown hand-composed first and then as the shipped one-call agent, closing with one maintenance / safety recommendation.
- **[demo-vertical-adas-safety-validation.sql](demo-vertical-adas-safety-validation.sql)** —
  ADAS Safety Validation (agentic kit). A pre-commit safety barrier. `fractal_agent_outlier_intercept` screens three proposed maneuvers against a history of known-bad states (cosine by default, exact Euclidean when magnitude should count: a gentle lane change is intercepted by cosine but allowed by l2), and `fractal_search_trajectory` flags a vehicle whose routing vector has strayed from the fleet baseline. Closes with one go / no-go verdict.
- **[demo-vertical-v2x-warranty-triage.sql](demo-vertical-v2x-warranty-triage.sql)** —
  V2X Warranty Triage (agentic kit). Routes an incoming diagnostic-trouble-code event to the best-capable repair workflow under a token budget (`fractal_agent_route_task`), then recalls similar historical warranty claims with a strict metadata filter (`fractal_agent_recall_hybrid`; a two-predicate model-year-and-component cohort is shown with `fractal_hybrid_clinical_search`). Closes with a dispatch + claim-context summary.
- **[demo-vertical-critical-inventory-routing.sql](demo-vertical-critical-inventory-routing.sql)** —
  Critical Inventory Routing (agentic kit). Six depots x 64 days of consumption. `fractal_dimension_dfa` finds the depot whose demand is accelerating (non-linear) rather than merely high; `fractal_optimize_portfolio` picks which 3 depots get the scheduled replenishment run with the risk matrix inflated by the DFA exponent; the bursty depot is flagged for expedited restock instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step. Closes with the rebalancing rationale.
- **[demo-vertical-heavy-industry-predictive-maintenance.sql](demo-vertical-heavy-industry-predictive-maintenance.sql)** —
  Heavy-Industry Predictive Maintenance (agentic kit). Four pumps and drives x 96 readings; one pump develops an accelerating bearing-vibration defect. `fractal_agent_anomaly_triage` flags the vibration regime shift and `fractal_agent_patient_deterioration_triage` measures drift from the asset's intake baseline with a same-class cohort search (an asset plays the patient). Closes with a maintenance-window recommendation. This is the wear / lifecycle half of heavy-industry monitoring.
- **[demo-vertical-climatech-grid-balancing.sql](demo-vertical-climatech-grid-balancing.sql)** —
  Climate Tech: Grid Balancing (agentic kit). Grid-frequency telemetry for three balancing areas; one loses damping and its oscillation envelope grows. `fractal_dimension_drift` (the volatility-regime recipe from the quant-finance kit, applied to a grid) detects it, and `fractal_optimize_portfolio` chooses the 4 of 6 generation and storage resources that carry the response, with a ramp-risk matrix in which solar and wind share weather risk. `fractal_agent_anomaly_triage` and `fractal_agent_allocate` are the shipped one-call forms. Closes with the dispatch-plan rationale.
- **[demo-vertical-hazmat-occupational-triage.sql](demo-vertical-hazmat-occupational-triage.sql)** —
  Hazmat / Occupational Exposure (domain kit). 36 workers across work zones and shifts; a reactor-bay night-shift crew shows elevated dose rate, temperature and heart rate. `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with exposure columns in place of clinical vitals). Closes with a medical-countermeasure dispatch recommendation.
- **[demo-vertical-scenario-planning-simulation.sql](demo-vertical-scenario-planning-simulation.sql)** —
  Scenario Planning & Simulation (domain kit). 24 candidate continuity scenarios in four clusters. Scout (`fractal_search_explore`) picks six deliberately different ones with no model; `fractal_agent_plan_explore` (MCTS-style exploration, needs an embedding endpoint) generates scenario variants from a seed state description. Closes with a summary of the scenario set.
- **[demo-vertical-avionics-fault-prediction.sql](demo-vertical-avionics-fault-prediction.sql)** —
  Avionics Fault Prediction (domain kit). A 12-aircraft fleet with planned-path and current-state vectors in 3D; one flight has drifted far off plan and has erratic heading changes. `fractal_agent_track_anomaly` generalizes straight from the maritime kit's 2D tracks to 3D flight paths (trajectory deviation search plus the heading-change DFA exponent). Closes with a reasoned classification of the deviation.
- **[demo-vertical-satellite-constellation-coverage.sql](demo-vertical-satellite-constellation-coverage.sql)** —
  Satellite Constellation Coverage (domain kit). A 20 x 20 footprint lattice, healthy vs a copy missing an 8 x 8 dead zone (the gap raises lacunarity). `fractal_agent_network_coverage_alert` combines the footprint morphology with link-quality telemetry drift; `fractal_agent_schedule_workload` models launch-slot scheduling for the replacement payload. Coverage-gap angle only: orbital drift and collision detection are a different problem.
- **[demo-vertical-telecom-account-anomaly-screening.sql](demo-vertical-telecom-account-anomaly-screening.sql)** —
  Telecom Account-Anomaly Screening (domain kit). Screens proposed account changes (SIM swap, port-out, new device, location jump) against a history of known-anomalous patterns with `fractal_agent_outlier_intercept`, reused verbatim: the same shape as the ADAS kit. Shows cosine (shape of the event) against exact Euclidean (intensity counts). A general pre-commit safety check, not a fraud-specific product.
- **[demo-vertical-telecom-traffic-routing.sql](demo-vertical-telecom-traffic-routing.sql)** —
  Telecom Traffic Routing (domain kit). Five session requests dispatched to the best-capable of four network nodes under a token budget with `fractal_agent_route_task`, reused verbatim; then re-routed over only the nodes with headroom so a loaded node's request is re-homed. Nearest-capable-node dispatch, not multi-hop rerouting around a failed node.
- **[demo-vertical-climatech-emissions-monitoring.sql](demo-vertical-climatech-emissions-monitoring.sql)** —
  Climate Tech: Emissions Monitoring (domain kit). Methane, CO2 and pipeline-pressure sensors; one methane sensor starts leaking (an accelerating concentration ramp). `fractal_agent_anomaly_triage` is reused verbatim to flag the shift into a leak regime; the same call screens a water-distribution pressure series. Closes with a leak narrative and field response.
- **[demo-vertical-climatech-risk-exposure.sql](demo-vertical-climatech-risk-exposure.sql)** —
  Climate Tech: Risk Exposure (domain kit). A 20 x 20 hazard-sensor grid with dry-season and wet-season fuel-moisture deficit indices. `fractal_agent_network_coverage_alert` is reused verbatim: morphology of the elevated-hazard region plus telemetry drift, shaped like the smart-cities kit's sensor grid. Closes with an exposure narrative for an insured portfolio.
- **[demo-vertical-rf-spectrum-sensing.sql](demo-vertical-rf-spectrum-sensing.sql)** —
  RF Spectrum Sensing (domain kit). Three channels x 256 samples: a beacon that gets jammed partway through, an empty noise channel and a steady carrier. `fractal_periodogram` says which frequencies dominate, the new `fractal_spectrogram_entropy` says how ordered the spectrum is window by window, and `fractal_change_point_detect` localizes when the order was lost, straight from the entropy series. A raw-primitive showcase: no agents and no model until the closing triage narrative.


### Event-stream, document, spatial and allocation kits

- **[demo-vertical-event-stream-anomaly-triage.sql](demo-vertical-event-stream-anomaly-triage.sql)** —
  Event-Stream Anomaly Triage (domain kit). Four endpoints x 96 one-minute intervals of request latency; one endpoint (EP-C) develops an accelerating latency ramp (a timeout cascade) and a second (EP-B) has a retry-storm oscillation in its request rate. `fractal_agent_anomaly_triage` flags the latency regime shift, `fractal_periodogram` finds the retry-storm period, and `fractal_search_trajectory` finds which endpoints' success-rate / latency / timeout / fill health has moved the same way EP-C's did.
- **[demo-vertical-outlier-interception-footprint.sql](demo-vertical-outlier-interception-footprint.sql)** —
  Outlier Interception & Footprint Analysis (domain kit). Screens proposed traffic sessions against a history of known-abuse signatures with `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean when magnitude should count), then uses `fractal_dimension_boxcount` on click-coordinate clouds: organic traffic fills the page (a high box-counting dimension) while an automated farm hammering a handful of targets collapses onto a line (a dimension near 1).
- **[demo-vertical-agentic-budget-reallocation.sql](demo-vertical-agentic-budget-reallocation.sql)** —
  Agentic Budget Reallocation (agentic kit). Six channels x 64 days of attributed outcomes. `fractal_dimension_dfa` finds the channel whose response is accelerating (a non-linear surge a plain average would hide); `fractal_optimize_portfolio` picks which 3 channels receive the scheduled budget increase with the risk matrix inflated by the DFA exponent; the surging channel is flagged for a capped, monitored test instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step, and `fractal_agent_route_task` dispatches each journey to the best-matching model under a token budget.
- **[demo-vertical-stalled-process-triage.sql](demo-vertical-stalled-process-triage.sql)** —
  Stalled-Process Triage (domain kit). 36 open items across segments and stages; three tier-1 items in the review stage show the same stall signature (time-in-stage far above the healthy velocity, falling engagement, a silent owner, deepening concessions). `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort search plus baseline-vs-current drift, with item-health columns in place of clinical vitals): an item's stage-entry telemetry plays the patient's admission baseline.
- **[demo-vertical-intent-matching-discovery.sql](demo-vertical-intent-matching-discovery.sql)** —
  Intent Matching & Diverse Selection (domain kit). 24 target entities in four intent clusters (category + stage signal vectors) and a 30-item content library. Scout (`fractal_search_explore`, the diversity-first MMR search) picks six deliberately different entities around a target profile instead of six near-duplicates, and `fractal_agent_recommend_diverse` returns a repulsion-diverse set of content items for the chosen entity: no model needed for either.
- **[demo-vertical-agentic-next-action-ranking.sql](demo-vertical-agentic-next-action-ranking.sql)** —
  Agentic Ranking & Next-Action Recommendation (agentic kit). 30 candidates across segments, a 12-item action catalog and a natural-language question over the candidate table. `fractal_agent_recall_hybrid` recalls the most similar past candidates inside one segment (a strict metadata filter), `fractal_agent_recommend_diverse` proposes a diverse set of next actions (not four variations of 'send an email'), and `fractal_sql_agent` answers a status question in plain English by generating and running the SQL.
- **[demo-vertical-document-risk-drift.sql](demo-vertical-document-risk-drift.sql)** —
  Document Risk Drift & Diverse Alternatives (domain kit). Four agreements x 96 weekly clause-risk reviews; one agreement's amended terms drift into a new regime (an accelerating risk creep). `fractal_dimension_drift` (the regime-detection recipe from the quant-finance kit, applied to document risk) finds it; Scout (`fractal_search_explore`) pulls six deliberately different clause variants out of the 24-clause corpus so the reviewer sees the spread rather than six near-copies; and `fractal_agent_recommend_diverse` proposes diverse approved replacement language.
- **[demo-vertical-coordinated-record-detection.sql](demo-vertical-coordinated-record-detection.sql)** —
  Record Clustering & Severity Trajectory (domain kit). A review desk screens new submissions against known ring signatures with `fractal_agent_outlier_intercept`, finds the records that moved from the normal severity baseline the way a staged ring does with `fractal_search_trajectory`, and measures the geographic footprint of event locations with `fractal_dimension_boxcount` (organic events scatter across the city; a staged ring repeats along one road).
- **[demo-vertical-sensor-telemetry-allocation.sql](demo-vertical-sensor-telemetry-allocation.sql)** —
  Sensor Telemetry & Resource Allocation (agentic kit). Six sites x 64 days of resource demand from soil-moisture sensors. `fractal_dimension_dfa` finds the site whose demand is accelerating (a non-linear trend or a failing supply line) rather than merely high; `fractal_optimize_portfolio` picks which 3 sites get the scheduled service run with the risk matrix inflated by the DFA exponent; the accelerating site is flagged for an inspection instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.
- **[demo-vertical-simulated-economy-drift.sql](demo-vertical-simulated-economy-drift.sql)** —
  Simulated-Economy Drift & Loop Detection (agentic kit). Six markets x 96 days of price index; every market carries a weekly demand cycle, and one (mkt-d) enters an accelerating inflation spiral. `fractal_periodogram` confirms the weekly cycle, `fractal_dimension_dfa` flags the market that is inflating non-linearly, and `fractal_optimize_portfolio` picks the 3 markets for the scheduled sink program (the inflating market goes to an emergency price-cap instead). `fractal_agent_detect_loop` then watches trade-state logs: an automated actor that flips between the same two item states is detected while a varied actor is not.
- **[demo-vertical-multi-series-replenishment.sql](demo-vertical-multi-series-replenishment.sql)** —
  Multi-Series Forecasting & Replenishment (agentic kit). Six locations x 64 days of unit demand. `fractal_dimension_dfa` finds the location whose demand is accelerating (a viral item or a local event) rather than merely high; `fractal_optimize_portfolio` picks which 3 locations get the scheduled replenishment from the central hub with the risk matrix inflated by the DFA exponent; the surging location is flagged for an expedited pick instead. `fractal_agent_allocate` is the shipped one-call form of the optimizer step.
- **[demo-vertical-periodicity-portfolio-selection.sql](demo-vertical-periodicity-portfolio-selection.sql)** —
  Periodicity Detection & Portfolio Selection (domain kit). Six items x 96 days of sales velocity with a weekly demand cycle of differing strength. `fractal_periodogram` quantifies which items are genuinely periodic; `fractal_optimize_portfolio` picks the 3 items that get the scheduled action (a Sharpe-style trade of margin recovered against demand volatility); `fractal_agent_recommend_diverse` proposes a diverse set of substitute items. On the Enterprise edition `fractal_agent_diverse_portfolios` (multimodal optimization) also returns structurally different schedules; on the Community edition that step reports "enterprise tier not loaded".
- **[demo-vertical-agentic-recall-recommendation.sql](demo-vertical-agentic-recall-recommendation.sql)** —
  Agentic Recall & Diverse Recommendation (agentic kit). 24 candidate offers in four clusters and 30 abandoned sessions across categories. Scout (`fractal_search_explore`) picks six deliberately different offers around the user's profile so the follow-up tests variety rather than six near-identical offers; `fractal_agent_recall_hybrid` recalls the most similar past sessions inside the user's category (a strict metadata filter); and `fractal_sql_agent` answers a question over the session table in plain English.
- **[demo-vertical-spatial-footprint-portfolio-risk.sql](demo-vertical-spatial-footprint-portfolio-risk.sql)** —
  Spatial Footprint Complexity & Portfolio Risk (domain kit). Three districts' parcel footprints (a dense grid, a single arterial strip and a two-corridor district) measured with `fractal_dimension_boxcount`: the lower the dimension the more linear the frontage and the more a valuation depends on a few corridors. Six asset classes x 64 months of index values feed `fractal_dimension_dfa` and `fractal_optimize_portfolio` (pick 3 classes for the renewal push; the accelerating one is flagged), and Scout (`fractal_search_explore`) selects six deliberately different comparable parcels so the reviewer sees the spread of the market, not six near-twins.
**A note on `fractal_dimension_boxcount`/`fractal_morphological_complexity`
fixture design**, visible across several of the scripts above: both
functions need enough *space-filling* points (a grid, a path, a real
geometric structure) for the internal box-counting estimator to work —
`fractal_dimension_boxcount`'s documented "≥ 8 points and a
non-degenerate bounding box" is *necessary, not sufficient* (500
uniform-random 2-D points succeeded in testing, 64 did not), and a
sparse or purely random scatter, even well past that minimum, can fail
it and return `NULL` rather than a wrong number. Every fixture above
was chosen and verified against a live server with that requirement in
mind.

## The sixteen agents

`demo-agents.sql` validates the sixteen installable agents shipped in
`sql/install_agents.sql` — the productized, callable form of the Domain
Agent reference blueprints plus generalized agents that cover the
vertical demo sections the blueprints don't cover (see
[docs/api-agency.md](../docs/api-agency.md) for which agent to use).
MariaDB has no extension-dependency system, so the agents are plain
stored procedures called as `CALL fractal_agent_<name>(..., @result)`.
It exercises all sixteen end-to-end:

- **`fractal_agent_anomaly_triage`** — over a drifting latency series (real
  `fractal_dimension_drift` → real `fractal_reason`).
- **`fractal_agent_allocate`** — on a real `mu`/`cov` (real
  `fractal_optimize_portfolio` → real `fractal_reason`).
- **`fractal_agent_route_task`** — matches a task embedding to the nearest
  capability row (real `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_outlier_intercept`** — screens a state vector against known
  bad states and compares the real nearest-distance to a threshold (real
  `fractal_search_telemetry` → real `fractal_reason`).
- **`fractal_agent_recall_hybrid`** — vector recall restricted by a metadata
  cohort (real `fractal_hybrid_clinical_search`); pure retrieval, no LLM step.
- **`fractal_agent_recommend_diverse`** — repulsion-diverse top-k over a catalog
  (real `fractal_diversify_enable` + real `fractal_search_telemetry`); pure
  retrieval, no LLM step.
- **`fractal_agent_data_analyst`** — a natural-language question over your
  tables (real text-to-SQL with execution → real `fractal_reason`); the
  horizontal catch-all with no vertical preset.
- **`fractal_agent_patient_deterioration_triage`** — cohort-restricted
  nearest patient + baseline→current drift (real
  `fractal_hybrid_clinical_search` + real `fractal_search_trajectory` →
  real `fractal_reason`); the cohort is caller-built so `age>65 AND
  condition='sepsis'` composes in ordinary SQL.
- **`fractal_agent_feedback_audit`** — a self-contained diversify/repulsion
  audit cycle (real collapse detection + real `fractal_explain_result`);
  pure analytics, **no LLM**, self-disables diversify.
- **`fractal_agent_schedule_workload`** — refines a task vector then finds
  the nearest node (real `fractal_search` + real `fractal_search_telemetry`
  → real `fractal_reason`).
- **`fractal_agent_rebalance_sibling`** — optimized book vs nearest
  historical allocation (real `fractal_optimize_portfolio` + real
  `fractal_search_trajectory` → real `fractal_reason`).
- **`fractal_agent_diverse_portfolios`** — enterprise tier; companion to
  `fractal_agent_allocate` returning several structurally distinct good
  portfolios instead of one (real `fractal_optimize_portfolio_multimodal`
  → real `fractal_reason`); dormant on community, exception-guarded so
  the demo still completes cleanly.
- **`fractal_agent_detour_classify`** — route deviation + GPS-trace
  complexity (real `fractal_search_trajectory` + real
  `fractal_dimension_boxcount` → real `fractal_reason`).
- **`fractal_agent_track_anomaly`** — track deviation + heading DFA (real
  `fractal_search_trajectory` + real `fractal_dimension_dfa` → real
  `fractal_reason`).
- **`fractal_agent_network_coverage_alert`** — sensor-grid morphology +
  telemetry drift (real `fractal_morphological_complexity` + real
  `fractal_dimension_drift` → real `fractal_reason`); 20×20 grid (400 pts).
- **`fractal_agent_regime_triage`** — single-series regime change (real
  `fractal_dimension_dfa` + real `fractal_dimension_drift` → real
  `fractal_reason`).

The three Universal Agent primitives above (`detect_loop`,
`plan_explore`, `trajectory_predict`) are installed alongside them as
procedures too — the agentic verticals exercise those; `demo-agents.sql`
covers the sixteen.

Thirteen agents are cognition (end in `fractal_reason`); three are pure
retrieval/analytics with no endpoint needed (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`). The script closes with a
`fractal_reason()` narrative over the computed results — same closing
pattern as every other demo.

**Prerequisites:** in addition to the base UDFs and reasoning (same as
`demo.sql`), register the agent procedures:

```sh
mariadb -u root -p < sql/install_udf.sql          -- prerequisite (already done for demo.sql)
mariadb -u root -p < sql/install_agents.sql       -- the agent procedures
```

```sh
mariadb -u root -p <your_database> < demo/demo-agents.sql
```

The script is safe to re-run: `agents_demo_logs` and the agent fixture
tables (`agents_demo_caps`, `agents_demo_badstates`, `agents_demo_mem`,
`agents_demo_catalog`, `agents_demo_data`, `agents_demo_patients`,
`agents_demo_fcatalog`/`agents_demo_fwarmup`, `agents_demo_nodes`,
`agents_demo_alloc`, `agents_demo_vehicles`, `agents_demo_tracks`) are
dropped and recreated at the top of their sections. The eight
non-agentic vertical demos (`demo-vertical-quant-finance.sql`,
`demo-vertical-medtech-clinical.sql`, `demo-vertical-recommendation-search.sql`,
`demo-vertical-sovereign-edge-ai.sql`, `demo-vertical-maritime-defense.sql`,
`demo-vertical-fleet-logistics.sql`, `demo-vertical-smart-cities-iot.sql`,
`demo-vertical-cybersecurity-threat-detection.sql`) are likewise presets —
each rewired section keeps its raw-primitive call as a commented blueprint
above the shipped agent call that generalizes it (the 3 agentic vertical
reference blueprints — `demo-vertical-agentic-ops-devops.sql`,
`demo-vertical-agentic-fintech-mcts.sql`,
`demo-vertical-agentic-customer-support.sql` — stay untouched).
The agent procedures themselves are only dropped by re-running
`sql/install_agents.sql` (see [Cleanup](#cleanup)).

## Full API benchmark

`benchmark-api-reference.sql` is a coverage pass exercising the
callable UDF surface, grouped by category, against small generated
fixtures — a correctness-plus-latency smoke pass over the whole API
surface, distinct from [`benchmark.sql`](benchmark.sql)'s narrower
Sniper-Search/Scout-Discovery/vectorizer-throughput comparison (which
stays scoped to that, see its own header comment). Reasoning-dependent
calls (`fractal_reason`, `fractal_text_to_sql`, `fractal_embed`) are
wrapped in a generic `bmk_safe_call()` helper so a missing or
misconfigured reasoning/embedding endpoint degrades that one row
instead of aborting the rest of the benchmark.

```sh
mariadb -u root -p <your_database> < demo/benchmark-api-reference.sql
```

## Cleanup

The demo tables are left in place after running so you can poke at the
results. Drop them when you're done:

```sql
DROP TABLE demo_alerts, demo_embeddings;
DROP TABLE order_items, orders, customers;                            -- demo-text-to-sql.sql
DROP TABLE bi_customer_features, bi_orders, bi_customers;             -- demo-business-intelligence.sql
DROP TABLE spike_candidates, spike_negative_control;                  -- text-to-sql-spike-*.sql
DROP TABLE bt_bench_docs, bt_bench_corpus, bt_bench_clusters;         -- benchmark.sql
DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;        -- demo-vertical-quant-finance.sql
DROP TABLE vmc_patients;                                              -- demo-vertical-medtech-clinical.sql
DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;                  -- demo-vertical-recommendation-search.sql
DROP TABLE vse_nodes, vse_throughput;                                 -- demo-vertical-sovereign-edge-ai.sql
DROP TABLE vmd_vessels;                                               -- demo-vertical-maritime-defense.sql
DROP TABLE vfl_vehicles, vfl_route3_cohort;                           -- demo-vertical-fleet-logistics.sql
DROP TABLE vsc_sensors;                                               -- demo-vertical-smart-cities-iot.sql
DROP TABLE vcy_hosts, vcy_dmz_cohort;                                 -- demo-vertical-cybersecurity-threat-detection.sql
DROP TABLE vao_incident_logs, vao_agent_capabilities, vao_known_bad_states;  -- demo-vertical-agentic-ops-devops.sql
DROP TABLE vfm_trade_strategies, vfm_portfolios, vfm_assets,
           vfm_restrictions, vfm_historical_allocations;              -- demo-vertical-agentic-fintech-mcts.sql
DROP TABLE vcs_customer_sessions, vcs_customer_playbook, vcs_product_catalog;  -- demo-vertical-agentic-customer-support.sql
DROP TABLE bmk_corpus, bmk_docs, bmk_modal;                           -- benchmark-api-reference.sql
DROP TABLE agents_demo_logs, agents_demo_caps, agents_demo_badstates,
           agents_demo_mem, agents_demo_catalog, agents_demo_data,
           agents_demo_patients, agents_demo_fcatalog, agents_demo_fwarmup,
           agents_demo_nodes, agents_demo_alloc, agents_demo_vehicles,
           agents_demo_tracks;                                        -- demo-agents.sql
DELETE FROM fractal_vectorizers WHERE source_table IN ('bt_bench_docs', 'bmk_docs', 'docs', 'docs_fv', 'vao_incident_logs', 'vfm_trade_strategies');
DROP PROCEDURE IF EXISTS bmk_safe_call;
-- The agent procedures are only dropped by re-running sql/install_agents.sql.
DROP TABLE ebl_telemetry;  -- demo-vertical-ev-battery-lifecycle.sql
DROP TABLE asv_known_bad, asv_proposed, asv_routes;  -- demo-vertical-adas-safety-validation.sql
DROP TABLE v2x_capabilities, v2x_claims;  -- demo-vertical-v2x-warranty-triage.sql
DROP TABLE cir_depots, cir_consumption, cir_profile, cir_result;  -- demo-vertical-critical-inventory-routing.sql
DROP TABLE hpm_readings;  -- demo-vertical-heavy-industry-predictive-maintenance.sql
DROP TABLE cgb_freq, cgb_resources, cgb_result;  -- demo-vertical-climatech-grid-balancing.sql
DROP TABLE hot_workers;  -- demo-vertical-hazmat-occupational-triage.sql
DROP TABLE sps_scenarios, sps_scout;  -- demo-vertical-scenario-planning-simulation.sql
DROP TABLE afp_flights;  -- demo-vertical-avionics-fault-prediction.sql
DROP TABLE scc_footprints, scc_slots;  -- demo-vertical-satellite-constellation-coverage.sql
DROP TABLE taa_known_anomalous, taa_proposed;  -- demo-vertical-telecom-account-anomaly-screening.sql
DROP TABLE ttr_nodes, ttr_requests;  -- demo-vertical-telecom-traffic-routing.sql
DROP TABLE cem_readings;  -- demo-vertical-climatech-emissions-monitoring.sql
DROP TABLE cre_grid;  -- demo-vertical-climatech-risk-exposure.sql
DROP TABLE rfs_capture, rfs_entropy;  -- demo-vertical-rf-spectrum-sensing.sql
DROP TABLE esa_latency, esa_rate, esa_lprof, esa_rprof, esa_health, esa_traj;  -- demo-vertical-event-stream-anomaly-triage.sql
DROP TABLE oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim;  -- demo-vertical-outlier-interception-footprint.sql
DROP TABLE abr_outcome, abr_prof, abr_result, abr_models, abr_events, abr_routed;  -- demo-vertical-agentic-budget-reallocation.sql
DROP TABLE spt_items, spt_traj, spt_triage;  -- demo-vertical-stalled-process-triage.sql
DROP TABLE imd_entities, imd_picks, imd_content, imd_rec;  -- demo-vertical-intent-matching-discovery.sql
DROP TABLE anr_candidates, anr_recall, anr_actions, anr_rec;  -- demo-vertical-agentic-next-action-ranking.sql
DROP TABLE drd_risk, drd_prof, drd_clauses, drd_picks, drd_approved, drd_rec;  -- demo-vertical-document-risk-drift.sql
DROP TABLE crd_known, crd_proposed, crd_screen, crd_records, crd_traj, crd_locations, crd_dim;  -- demo-vertical-coordinated-record-detection.sql
DROP TABLE sta_demand, sta_prof, sta_result;  -- demo-vertical-sensor-telemetry-allocation.sql
DROP TABLE sed_price, sed_prof, sed_result, sed_loop;  -- demo-vertical-simulated-economy-drift.sql
DROP TABLE msr_units, msr_prof, msr_result;  -- demo-vertical-multi-series-replenishment.sql
DROP TABLE pps_sales, pps_prof, pps_result, pps_catalog, pps_rec;  -- demo-vertical-periodicity-portfolio-selection.sql
DROP TABLE arr_offers, arr_picks, arr_sessions, arr_recall;  -- demo-vertical-agentic-recall-recommendation.sql
DROP TABLE sfp_parcels, sfp_dim, sfp_index, sfp_prof, sfp_result, sfp_comps, sfp_picks;  -- demo-vertical-spatial-footprint-portfolio-risk.sql
```

## Troubleshooting

- **Section 0 fails** — the UDFs aren't registered in this database.
  Re-run `sql/install_udf.sql` (and `sql/install_agents.sql` for
  `demo-agents.sql`). See [../docs/getting-started.md](../docs/getting-started.md).
- **Section 3 or 4 fails** — reasoning isn't configured, or the endpoint
  is unreachable/misconfigured. See the Troubleshooting section in
  [../docs/reasoning-setup.md](../docs/reasoning-setup.md) — it covers
  the specific failure shapes you'll see (plugin not loaded, HTTP 401,
  timeout, non-2xx response) and what each one means.
- **The reasoning response reads oddly** (e.g. the model asks for data
  instead of describing it) — check that the `context` subquery in that
  section actually returned rows. An empty or NULL context still gets
  sent as `'{}'`, and the model's default system prompt explicitly
  expects "database search results" to analyze; with nothing there, it
  will say so rather than hallucinate an answer.
- **An enterprise-tier call returning `NULL` with no error** — this is
  the correct, documented dormant-state behavior when
  `FRACTALSQL_ENTERPRISE_LIB` isn't set or the library didn't load, not
  a bug. See [docs/enterprise.md](../docs/enterprise.md).

## Before you start

Start `fractalsqld` (the daemon behind `fractalsql.so` -- see
[../service/README.md](../service/README.md)) before running `demo.sql` and
`response-modes.sql`.
