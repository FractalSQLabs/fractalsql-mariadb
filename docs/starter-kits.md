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
all 15 shipped agents end to end against synthetic fixtures in one file.

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
[`docs/api-agency.md`](api-agency.md#the-fifteen-recipes).

---

## The eleven vertical starter kits

**Domain verticals** (mostly no-model; only the closing narrative needs
reasoning): Quantitative Finance (`demo-vertical-quant-finance.sql`),
MedTech/Clinical (`demo-vertical-medtech-clinical.sql`),
Recommendation/Search (`demo-vertical-recommendation-search.sql`),
Sovereign/Edge AI (`demo-vertical-sovereign-edge-ai.sql`),
Maritime/Defense (`demo-vertical-maritime-defense.sql`), Fleet Logistics
(`demo-vertical-fleet-logistics.sql`), Smart Cities/IoT
(`demo-vertical-smart-cities-iot.sql`), Cybersecurity Threat Detection
(`demo-vertical-cybersecurity-threat-detection.sql`).

**Agentic verticals** (model-on, composed multi-step agents): DevOps/SRE
dispatch + safety barrier (`demo-vertical-agentic-ops-devops.sql`), FinTech
portfolio rebalance + MCTS-style exploration
(`demo-vertical-agentic-fintech-mcts.sql`), Customer Support recall +
recommend (`demo-vertical-agentic-customer-support.sql`).

MariaDB has no `CREATE TYPE`/typmod mechanism, so four of the eight
domain verticals (MedTech, Maritime, Fleet, Cybersecurity) use either
the native `VECTOR(n)` type (11.7+) or the portable TEXT/JSON path
instead (see
[`docs/vectorizer-setup.md`](vectorizer-setup.md#native-vectorn-storage-mariadb-117)),
not a direct type-for-type translation.

---

## Where next

- **"How does a specific agent work, and what are its inputs?"** → the
  per-agent recipes in [api-agency.md](api-agency.md#the-fifteen-recipes).
- **"How do I build a proprietary agent that isn't in the box?"** →
  [composition-guide.md](composition-guide.md): the primitives as building
  blocks and worked composition patterns.
- **All fifteen agents end-to-end** →
  `mariadb -uroot -p fractalsql_demo < demo/demo-agents.sql` (the
  regression demo every recipe example is drawn from).
- **A specific industry, against a domain-shaped dataset** →
  `mariadb -uroot -p <your_database> < demo/demo-vertical-<name>.sql`, see
  [demo/README.md](../demo/README.md#industry-vertical-demos) for the full
  list of eleven.
