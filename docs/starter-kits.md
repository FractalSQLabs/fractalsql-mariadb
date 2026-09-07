<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Starter Kits: Apply FractalSQL to Your Industry

You have the extension running ([getting-started.md](getting-started.md)).
The natural next question is: **which end-to-end example do I run for *my*
problem?**

**All eleven are available and verified.** Eleven runnable industry
walkthroughs (eight domain verticals, three agentic verticals) ship as
`demo/demo-vertical-*.sql`, each a self-contained script that builds
its own synthetic dataset, runs the agents that fit that domain, and
closes with a reasoned narrative. Every one has been run end to end
against a real MariaDB server and a real Ollama endpoint. See
[demo/README.md](../demo/README.md#industry-vertical-demos) for the exact
file list and how to run each one. This page's problem→agent mapping below
is still the fastest way to find which agent fits your problem shape, and
`demo/demo-agents.sql` remains a useful cross-industry pass that exercises
all 16 shipped agents end to end against synthetic fixtures in one file.

Run any kit directly:

```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/<kit-file>.sql
```

Without Docker: `mariadb -uroot -p <your_database> < demo/<kit-file>.sql`. Note
the `<` redirect, not a `-f` flag: the `mariadb` CLI takes SQL from stdin.

---

## Which agent should I run for my problem?

This is the same table as
[`api-agency.md`'s decision guide](api-agency.md#which-agent-should-i-use),
repeated here as a quick problem→agent lookup. Run
`demo/demo-agents.sql` to see all of these executing against real (synthetic)
data in one pass, or jump straight to the matching industry kit below to
see them running against a domain-shaped dataset.

| If your problem is… | Run this agent | Domain fit |
| --- | --- | --- |
| Portfolio construction | `fractal_agent_allocate` | Quant-Finance, Sovereign-Edge resource allocation |
| Diverse portfolio comparison (multiple candidates, enterprise-tier) | `fractal_agent_diverse_portfolios` | Quant-Finance, FinTech |
| Rebalance vs. historical allocations | `fractal_agent_rebalance_sibling` | Quant-Finance, FinTech |
| Regime/drift detection on one series | `fractal_agent_regime_triage` | Quant-Finance, Smart-Cities, Cybersecurity |
| Regime/drift detection on a table-backed entity series | `fractal_agent_anomaly_triage` | DevOps, Cybersecurity, MedTech |
| Patient monitoring / clinical telemetry | `fractal_agent_patient_deterioration_triage` | MedTech |
| Vessel/fleet track deviation + heading erraticism | `fractal_agent_track_anomaly` | Maritime, Fleet Logistics, Cybersecurity |
| Vehicle detour + GPS-trace complexity | `fractal_agent_detour_classify` | Fleet Logistics |
| Sensor-grid coverage health | `fractal_agent_network_coverage_alert` | Smart Cities / IoT |
| Recommendation / diverse search | `fractal_agent_recommend_diverse` + `fractal_agent_feedback_audit` | Recommendation, e-commerce |
| Cohort-restricted memory recall | `fractal_agent_recall_hybrid` | Customer Support, Recommendation |
| Sub-agent task dispatch | `fractal_agent_route_task` | DevOps, Cybersecurity, Sovereign-Edge |
| Node placement with vector refinement | `fractal_agent_schedule_workload` | Sovereign-Edge, DevOps |
| Pre-commit safety barrier | `fractal_agent_outlier_intercept` | Cybersecurity, FinTech fraud, Industrial-IoT |
| Natural-language question over tables | `fractal_agent_data_analyst` | Any vertical, general-purpose |

Full per-agent inputs, mechanics, and runnable examples are in
[`docs/api-agency.md`](api-agency.md#the-sixteen-recipes).

---

## The eleven vertical starter kits

Eight **domain verticals** (mostly no-model; only the closing narrative
needs reasoning) and three **agentic verticals** (model-on, composed
multi-step agents). Every vector column in every kit uses the portable
JSON-array path (a `JSON` column of numbers), not the native `VECTOR(n)`
type: MariaDB has no `CREATE TYPE`/type-modifier mechanism, so this is the one
storage convention all eleven kits share. See
[`docs/vectorizer-setup.md`](vectorizer-setup.md#native-vectorn-storage-mariadb-117)
if you want to use native `VECTOR(n)` (11.7+) in your own tables instead.

| If your problem is… | Run this kit | Productized agent(s) |
| --- | --- | --- |
| Portfolio construction / regime detection on a return series | `demo-vertical-quant-finance.sql` | `fractal_agent_regime_triage`, `fractal_agent_rebalance_sibling` |
| Patient monitoring / clinical telemetry | `demo-vertical-medtech-clinical.sql` | `fractal_agent_patient_deterioration_triage` |
| Recommendation / diverse search with feedback learning | `demo-vertical-recommendation-search.sql` | `fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit` |
| Edge / autonomous fleet resource allocation | `demo-vertical-sovereign-edge-ai.sql` | `fractal_agent_schedule_workload`, `fractal_agent_allocate` |
| Maritime / aviation track anomaly detection | `demo-vertical-maritime-defense.sql` | `fractal_agent_track_anomaly` |
| Fleet logistics / detour detection | `demo-vertical-fleet-logistics.sql` | `fractal_agent_detour_classify` |
| Smart cities / IoT sensor grid coverage | `demo-vertical-smart-cities-iot.sql` | `fractal_agent_network_coverage_alert` |
| Cybersecurity / network behavior analytics | `demo-vertical-cybersecurity-threat-detection.sql` | `fractal_agent_track_anomaly`, `fractal_agent_regime_triage` |
| **Agentic:** DevOps / SRE incident triage + self-healing | `demo-vertical-agentic-ops-devops.sql` | `fractal_agent_route_task`, `fractal_agent_outlier_intercept`, `fractal_agent_anomaly_triage`, `fractal_agent_detect_loop` |
| **Agentic:** FinTech scenario exploration + safe execution | `demo-vertical-agentic-fintech-mcts.sql` | `fractal_agent_plan_explore`, `fractal_sql_agent`, `fractal_agent_rebalance_sibling` |
| **Agentic:** Customer support churn drift + retention | `demo-vertical-agentic-customer-support.sql` | `fractal_agent_trajectory_predict`, `fractal_agent_recall_hybrid`, `fractal_agent_recommend_diverse` |

### Quantitative Finance: `demo-vertical-quant-finance.sql`
A 25-asset, 4-factor covariance model where `fractal_optimize_portfolio`
picks the best 8, and a 300-point price series with a deliberate
volatility regime change at t=150 that `fractal_dimension_dfa`/`_drift`
detect automatically. `fractal_search_trajectory` then finds which of 10
historical quarterly rebalances the new allocation most resembles.
Productized form: `fractal_agent_regime_triage` and
`fractal_agent_rebalance_sibling`.

### MedTech / Clinical: `demo-vertical-medtech-clinical.sql`
40 synthetic patients with a 5-dim vitals vector (heart rate, SpO2,
systolic, diastolic, temperature). `fractal_hybrid_clinical_search` over
an age/condition cohort computed with ordinary SQL, `fractal_search_trajectory`
for a patient's current vitals against their admission baseline, plus
all three domain-geometry functions on small pre-extracted fixtures: a
28-node vessel graph, an 8-vertex reference mesh, and an 80-fiber nerve
skeleton. Productized form: `fractal_agent_patient_deterioration_triage`.

### Recommendation / Search: `demo-vertical-recommendation-search.sql`
A 300-item, 6-genre catalog for diverse "you might also like" discovery,
plus the full stateful-diversity loop: enable Diversify, search, report
negative feedback on the top result, re-search the same query, confirm
it's now avoided. Also covers `fractal_cross_modal_search` (a 4-dim
content vector plus a 4-dim behavior vector, weighted). Productized
form: `fractal_agent_recommend_diverse` and `fractal_agent_feedback_audit`.

### Sovereign / Edge AI: `demo-vertical-sovereign-edge-ai.sql`
Search, reasoning, and optimization all run as pure C UDFs inside the
same `mariadbd` process, no external vector-DB service. A 50-node edge
fleet: Sniper search for an ideal node profile, Scout for diverse fleet
profiles, `fractal_dimension_boxcount` over a 20x20 deployment grid, and
`fractal_optimize_portfolio` repurposed as a general on-device resource
allocator picking 6-of-50 nodes for a distributed job. Productized form:
`fractal_agent_schedule_workload` and `fractal_agent_allocate`.

### Maritime / Defense: `demo-vertical-maritime-defense.sql`
30 synthetic AIS vessel tracks (a 4-dim lat/lon/speed/heading vector),
one with a deliberate course deviation. `fractal_search_trajectory` on
the current-vs-baseline delta for "what changed" detection, diverse
traffic-pattern clustering across the fleet, and `fractal_dimension_dfa`
on a 120-sample heading-change series to separate smooth transit from
erratic maneuvering. Productized form: `fractal_agent_track_anomaly`.

### Fleet Logistics: `demo-vertical-fleet-logistics.sql`
A 40-vehicle delivery fleet across 4 routes (a 4-dim route vector), one
vehicle running a deliberate detour. Diverse route/zone clustering, a
cohort-restricted search ("today's route-3 vehicles only"), detour
detection via `fractal_search_trajectory`, and GPS-trace complexity via
`fractal_dimension_boxcount` over a 200-sample wandering path.
Productized form: `fractal_agent_detour_classify`.

### Smart Cities / IoT: `demo-vertical-smart-cities-iot.sql`
A 400-sensor city grid (traffic / air-quality / noise) on a jittered
20x20 layout: spatial coverage diagnostics via `fractal_dimension_boxcount`/
`fractal_morphological_complexity`, an air-quality event detected via
`fractal_dimension_dfa`/`_drift` on a 240-sample series with a regime
shift at t=150, and diverse representative-zone sampling via Scout.
Productized form: `fractal_agent_network_coverage_alert`.

### Cybersecurity: `demo-vertical-cybersecurity-threat-detection.sql`
A 35-host fleet across three zones (a 4-dim behavior vector), one host
showing a stealthy compromise: outbound connections, destination ports,
and DNS query volume all spike while failed-auth stays flat, not a
brute-force signature. Diverse traffic-profile clustering for threat
hunting, a zone-restricted ("DMZ only") search, compromise detection via
`fractal_search_trajectory`, and beaconing-onset regime detection via
`fractal_dimension_dfa`/`_drift` on a 300-minute connection-rate series.
Productized form: `fractal_agent_track_anomaly` and
`fractal_agent_regime_triage`.

### DevOps / SRE: `demo-vertical-agentic-ops-devops.sql`
A deployment bot stuck in a period-2 retry loop across 96 events (state
hash toggling between two values), caught by `fractal_agent_detect_loop`'s
short-period check even though its DFA exponent alone would miss it. A
drifting latency series with a step-up at cycle 64 feeds
`fractal_agent_anomaly_triage`. A capability map and a known-bad-states
library back `fractal_agent_route_task` and `fractal_agent_outlier_intercept`,
and the vectorized incident log backs `fractal_search_agent`/`fractal_rag_agent`
for root-cause synthesis.

### FinTech: `demo-vertical-agentic-fintech-mcts.sql`
`fractal_agent_plan_explore` runs MCTS-style branch exploration over 3
vectorized trade strategies. `fractal_sql_agent` answers a regulatory
audit question with auto-execution and retries against a small
portfolio/asset/restriction schema, catching a failing generated
statement instead of aborting. `fractal_agent_rebalance_sibling` then
runs a 2-asset portfolio rebalance against 3 historical allocation
snapshots.

### Customer Support: `demo-vertical-agentic-customer-support.sql`
One customer drifting from onboarding toward churn across four sessions
(a 3-dim state vector). `fractal_agent_trajectory_predict` forecasts the
drift from the baseline session to the latest one,
`fractal_agent_recall_hybrid` retrieves matching cases from a
churn-recovery playbook, and `fractal_agent_recommend_diverse` picks a
diverse set of retention offers. The only kit that needs no reasoning
endpoint configured at all.

---

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
