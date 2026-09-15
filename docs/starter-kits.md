<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Starter Kits: Apply FractalSQL to Your Industry

You have the extension running ([getting-started.md](getting-started.md)). Now:
**which end-to-end example do I run for *my* problem?**

FractalSQL ships eleven runnable industry walkthroughs: eight **domain
verticals** (a single `mariadb <` each, mostly no-model) and three **agentic
verticals** (composed multi-step agents, model-on). Each kit is a
self-contained script: it builds its own synthetic dataset, runs the agents
that genuinely fit that domain, and closes with a reasoned narrative. They
are all re-runnable (`DROP TABLE IF EXISTS` at the top of every section) and
all ship inside the Docker image at `/demo/`. Every one has been run end to
end against a real MariaDB server and a real Ollama endpoint -- see
[demo/README.md](../demo/README.md#industry-vertical-demos) for the exact
file list.

> In Docker, run any kit with:
> ```bash
> docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo \
>   < demo/<kit-file>.sql
> ```
> Without Docker: `mariadb -uroot -p <your_database> < demo/<kit-file>.sql`.
> Note the `<` redirect, not a `-f` flag: the `mariadb` CLI takes SQL from
> stdin.

## Which kit should I run?

| If your problem is… | Run this kit | Agents it exercises | Agent & recipe |
|---|---|---|---|
| Portfolio construction / regime detection | `demo-vertical-quant-finance.sql` | `fractal_agent_regime_triage`, `fractal_agent_rebalance_sibling`, `fractal_optimize_portfolio`, `fractal_dimension_dfa`/`_drift`, `fractal_search_trajectory` | [fractal_agent_regime_triage](api-agency.md#regime-triage-fractal_agent_regime_triage-general-purpose-no-table-args), [fractal_agent_rebalance_sibling](api-agency.md#rebalance-sibling-fractal_agent_rebalance_sibling) |
| Patient monitoring / clinical telemetry | `demo-vertical-medtech-clinical.sql` | `fractal_agent_patient_deterioration_triage`, `fractal_hybrid_clinical_search`, `fractal_search_trajectory`, vascular/cortical/nerve geometry | [fractal_agent_patient_deterioration_triage](api-agency.md#patient-deterioration-triage-fractal_agent_patient_deterioration_triage) |
| Recommendation / diverse search | `demo-vertical-recommendation-search.sql` | `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit`, `fractal_cross_modal_search` | [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse-fractal_agent_recommend_diverse-pure-retrieval-no-llm), [fractal_agent_feedback_audit](api-agency.md#feedback-audit-fractal_agent_feedback_audit-pure-analytics-no-llm) |
| Edge / autonomous fleet allocation | `demo-vertical-sovereign-edge-ai.sql` | `fractal_agent_schedule_workload`, `fractal_agent_allocate`, `fractal_dimension_boxcount`, Sniper (`fractal_search`), Scout | [fractal_agent_schedule_workload](api-agency.md#schedule-workload-fractal_agent_schedule_workload), [fractal_agent_allocate](api-agency.md#allocate-fractal_agent_allocate) |
| Maritime / aviation track anomaly | `demo-vertical-maritime-defense.sql` | `fractal_agent_track_anomaly`, `fractal_search_trajectory`, `fractal_dimension_dfa` | [fractal_agent_track_anomaly](api-agency.md#track-anomaly-fractal_agent_track_anomaly) |
| Fleet logistics / detour detection | `demo-vertical-fleet-logistics.sql` | `fractal_agent_detour_classify`, `fractal_search_trajectory`, `fractal_dimension_boxcount` | [fractal_agent_detour_classify](api-agency.md#detour-classify-fractal_agent_detour_classify) |
| Smart cities / IoT sensor grids | `demo-vertical-smart-cities-iot.sql` | `fractal_agent_network_coverage_alert`, `fractal_dimension_boxcount`/`fractal_morphological_complexity`, `fractal_dimension_dfa`/`_drift`, Scout | [fractal_agent_network_coverage_alert](api-agency.md#network-coverage-alert-fractal_agent_network_coverage_alert) |
| Cybersecurity / network behavior analytics | `demo-vertical-cybersecurity-threat-detection.sql` | `fractal_agent_track_anomaly`, `fractal_agent_regime_triage`, `fractal_search_trajectory`, `fractal_dimension_dfa`/`_drift` | [fractal_agent_track_anomaly](api-agency.md#track-anomaly-fractal_agent_track_anomaly), [fractal_agent_regime_triage](api-agency.md#regime-triage-fractal_agent_regime_triage-general-purpose-no-table-args) |
| **Agentic:** DevOps / SRE dispatch + safety | `demo-vertical-agentic-ops-devops.sql` | `fractal_agent_route_task`, `fractal_agent_outlier_intercept`, `fractal_agent_anomaly_triage` + `fractal_agent_detect_loop`, `fractal_search_agent`/`fractal_rag_agent` | [fractal_agent_route_task](api-agency.md#route-task-fractal_agent_route_task), [fractal_agent_outlier_intercept](api-agency.md#outlier-intercept-fractal_agent_outlier_intercept), [fractal_agent_anomaly_triage](api-agency.md#anomaly-triage-fractal_agent_anomaly_triage) |
| **Agentic:** FinTech portfolio rebalance + MCTS | `demo-vertical-agentic-fintech-mcts.sql` | `fractal_agent_rebalance_sibling`, `fractal_agent_plan_explore`, `fractal_sql_agent`, `fractal_optimize_portfolio` | [fractal_agent_rebalance_sibling](api-agency.md#rebalance-sibling-fractal_agent_rebalance_sibling), [fractal_agent_plan_explore](api-agency.md#building-blocks-the-primitives-agents-compose) |
| **Agentic:** Customer support recall + recommend | `demo-vertical-agentic-customer-support.sql` | `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse`, `fractal_agent_trajectory_predict` | [fractal_agent_recall_hybrid](api-agency.md#recall-hybrid-fractal_agent_recall_hybrid-pure-retrieval-no-llm), [fractal_agent_recommend_diverse](api-agency.md#recommend-diverse-fractal_agent_recommend_diverse-pure-retrieval-no-llm) |

> Not sure which agent does what? The
> [decision table](api-agency.md#which-agent-should-i-use) maps every problem
> shape to its agent.

## Domain kits (run with no model)

These eight run almost entirely **without a reasoning endpoint**: only the
closing `fractal_reason()` narrative needs one, so you can see the
retrieval/optimization/geometry results immediately and pull a model later
just for the summary. Every vector column in every kit uses the portable
JSON-array path (a `JSON` column of numbers), not the native `VECTOR(n)`
type: MariaDB has no `CREATE TYPE`/type-modifier mechanism, so this is the one
storage convention all eleven kits share. See
[vectorizer-setup.md](vectorizer-setup.md#native-vectorn-storage-mariadb-117)
if you want to use native `VECTOR(n)` (11.7+) in your own tables instead.

### Quantitative Finance — `demo-vertical-quant-finance.sql`
A 25-asset, 4-factor covariance model where `fractal_optimize_portfolio`
picks the best 8, and a 300-point price series with a deliberate
volatility regime change at t=150 that `fractal_dimension_dfa`/`_drift`
detect automatically. `fractal_search_trajectory` then finds which of 10
historical quarterly rebalances the new allocation most resembles.
Productized form: `fractal_agent_regime_triage` and
`fractal_agent_rebalance_sibling`.

### MedTech / Clinical — `demo-vertical-medtech-clinical.sql`
40 synthetic patients with a 5-dim vitals vector (heart rate, SpO2,
systolic, diastolic, temperature). `fractal_hybrid_clinical_search` over
an age/condition cohort computed with ordinary SQL, `fractal_search_trajectory`
for a patient's current vitals against their admission baseline, plus
all three domain-geometry functions on small pre-extracted fixtures: a
28-node vessel graph, an 8-vertex reference mesh, and an 80-fiber nerve
skeleton. Productized form: `fractal_agent_patient_deterioration_triage`.

### Recommendation / Search — `demo-vertical-recommendation-search.sql`
A 300-item, 6-genre catalog for diverse "you might also like" discovery,
plus the full stateful-diversity loop: enable Diversify, search, report
negative feedback on the top result, re-search the same query, confirm
it's now avoided. Also covers `fractal_cross_modal_search` (a 4-dim
content vector plus a 4-dim behavior vector, weighted). Productized
form: `fractal_agent_recommend_diverse` and `fractal_agent_feedback_audit`.

### Sovereign / Edge AI — `demo-vertical-sovereign-edge-ai.sql`
Search, reasoning, and optimization all run as pure C UDFs inside the
same `mariadbd` process, no external vector-DB service. A 50-node edge
fleet: Sniper search for an ideal node profile, Scout for diverse fleet
profiles, `fractal_dimension_boxcount` over a 20x20 deployment grid, and
`fractal_optimize_portfolio` repurposed as a general on-device resource
allocator picking 6-of-50 nodes for a distributed job. Productized form:
`fractal_agent_schedule_workload` and `fractal_agent_allocate`.

### Maritime / Defense — `demo-vertical-maritime-defense.sql`
30 synthetic AIS vessel tracks (a 4-dim lat/lon/speed/heading vector),
one with a deliberate course deviation. `fractal_search_trajectory` on
the current-vs-baseline delta for "what changed" detection, diverse
traffic-pattern clustering across the fleet, and `fractal_dimension_dfa`
on a 120-sample heading-change series to separate smooth transit from
erratic maneuvering. Productized form: `fractal_agent_track_anomaly`.

### Fleet Logistics — `demo-vertical-fleet-logistics.sql`
A 40-vehicle delivery fleet across 4 routes (a 4-dim route vector), one
vehicle running a deliberate detour. Diverse route/zone clustering, a
cohort-restricted search ("today's route-3 vehicles only"), detour
detection via `fractal_search_trajectory`, and GPS-trace complexity via
`fractal_dimension_boxcount` over a 200-sample wandering path.
Productized form: `fractal_agent_detour_classify`.

### Smart Cities / IoT — `demo-vertical-smart-cities-iot.sql`
A 400-sensor city grid (traffic / air-quality / noise) on a jittered
20x20 layout: spatial coverage diagnostics via `fractal_dimension_boxcount`/
`fractal_morphological_complexity`, an air-quality event detected via
`fractal_dimension_dfa`/`_drift` on a 240-sample series with a regime
shift at t=150, and diverse representative-zone sampling via Scout.
Productized form: `fractal_agent_network_coverage_alert`.

### Cybersecurity — `demo-vertical-cybersecurity-threat-detection.sql`
A 35-host fleet across three zones (a 4-dim behavior vector), one host
showing a stealthy compromise: outbound connections, destination ports,
and DNS query volume all spike while failed-auth stays flat, not a
brute-force signature. Diverse traffic-profile clustering for threat
hunting, a zone-restricted ("DMZ only") search, compromise detection via
`fractal_search_trajectory`, and beaconing-onset regime detection via
`fractal_dimension_dfa`/`_drift` on a 300-minute connection-rate series.
Productized form: `fractal_agent_track_anomaly` and
`fractal_agent_regime_triage`.

## Agentic kits (model-on, composed agents)

These three compose the six C-level **Universal Agents** into multi-step
**Domain Agents** as SQL/PSM stored PROCEDUREs (`CALL`, never `SELECT`,
since MariaDB's C UDF ABI gives no C function a way to run SQL against
the caller's own tables). The `CREATE PROCEDURE` blocks in
`sql/install_udf.sql` are the composition wiring to copy; the shipped
agents are the productized, non-stubbed form of the same primitives. See
[api-agency.md → Building blocks](api-agency.md#building-blocks-the-primitives-agents-compose)
for the primitives these compose.

### DevOps / SRE — `demo-vertical-agentic-ops-devops.sql`
A deployment bot stuck in a period-2 retry loop across 96 events (state
hash toggling between two values), caught by `fractal_agent_detect_loop`'s
short-period check even though its DFA exponent alone would miss it. A
drifting latency series with a step-up at cycle 64 feeds
`fractal_agent_anomaly_triage`. A capability map and a known-bad-states
library back `fractal_agent_route_task` and `fractal_agent_outlier_intercept`,
and the vectorized incident log backs `fractal_search_agent`/`fractal_rag_agent`
for root-cause synthesis.

### FinTech — `demo-vertical-agentic-fintech-mcts.sql`
`fractal_agent_plan_explore` runs MCTS-style branch exploration over 3
vectorized trade strategies. `fractal_sql_agent` answers a regulatory
audit question with auto-execution and retries against a small
portfolio/asset/restriction schema, catching a failing generated
statement instead of aborting. `fractal_agent_rebalance_sibling` then
runs a 2-asset portfolio rebalance against 3 historical allocation
snapshots.

### Customer Support — `demo-vertical-agentic-customer-support.sql`
One customer drifting from onboarding toward churn across four sessions
(a 3-dim state vector). `fractal_agent_trajectory_predict` forecasts the
drift from the baseline session to the latest one,
`fractal_agent_recall_hybrid` retrieves matching cases from a
churn-recovery playbook, and `fractal_agent_recommend_diverse` picks a
diverse set of retention offers. The only kit that needs no reasoning
endpoint configured at all.

## Where next

- **"How does a specific agent work, and what are its inputs?"** → the
  per-agent recipes in [api-agency.md](api-agency.md#the-sixteen-recipes).
- **"How do I build a proprietary agent that isn't in the box?"** →
  [composition-guide.md](composition-guide.md): the primitives as building
  blocks and worked composition patterns.
- **All sixteen agents end-to-end** →
  `mariadb -uroot -p fractalsql_demo < demo/demo-agents.sql` (the
  regression demo every recipe example is drawn from).
- **A specific industry, against a domain-shaped dataset** →
  `mariadb -uroot -p <your_database> < demo/demo-vertical-<name>.sql`, see
  [demo/README.md](../demo/README.md#industry-vertical-demos) for the full
  list of eleven.
