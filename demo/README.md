<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# FractalSQL demo

**Status:** every file below is real, runnable, and verified against a
live `mariadbd` (all four compat-matrix majors via `build_test.sh`,
plus a dedicated container for the reasoning-tier files) and a real
Ollama endpoint. For the fastest path to running any of these, see
**[docs/getting-started.md](../docs/getting-started.md)** and
**[docs/docker-demo.md](../docs/docker-demo.md)**; this file is the
index of what's here, not the walkthrough.

`demo.sql` is a five-minute walkthrough of search and reasoning in one
script: Sniper Search, Scout Discovery, and LLM reasoning, including
Scout's output feeding straight into a reasoning call. Text-to-SQL has
its own walkthrough, see [Text-to-SQL](#text-to-sql) below.

`response-modes.sql` is a companion script for `text` / `code` / `json`
response modes, see [Response modes](#response-modes) below.

## Prerequisites

1. **UDFs are registered.** MariaDB has no `CREATE EXTENSION`; the
   equivalent is running the install scripts once:

   ```sh
   mariadb -u root -p < sql/install_udf.sql
   mariadb -u root -p < sql/install_agents.sql   -- for demo-agents.sql
   ```

   (already done automatically if you're using `docker compose up -d`,
   see docs/docker-demo.md).

2. **Reasoning is configured**, if you want sections 3–4 of `demo.sql`
   (or any other reasoning/text-to-sql/vectorizer/agent demo) to do
   more than error cleanly. Config is a set of `FRACTALSQL_*` process
   environment variables read ONCE by `mariadbd` at startup. There is
   **no** server config file, sysvar, or `SET GLOBAL` equivalent; see
   **[docs/reasoning-setup.md](../docs/reasoning-setup.md)** for the
   full config reference. `docker compose up -d` sets these for you,
   pointed at the bundled `ollama` service. Confirm reasoning works
   before running a reasoning demo:

   ```sql
   SELECT fractal_reason(CONNECTION_ID(), 'reply with a short confirmation that this connection works');
   ```

## Running it

```sh
mariadb -u root -p <your_database> < demo/demo.sql
```

There's no direct MariaDB-CLI per-statement timing toggle.
Wrap a call in `SET profiling = 1; ... SHOW PROFILES;` if you want
per-statement timing.

The script is safe to re-run: `demo_alerts` and `demo_embeddings` are
dropped and recreated at the start of their sections every time.

## What each section shows

Five sections: sanity check, seed data, Sniper Search, reasoning over
real data, Scout Discovery feeding reasoning. See `demo.sql`'s own
comments for the walkthrough; not re-narrated here to avoid two
sources of truth drifting apart.

## Response modes

`response-modes.sql` demonstrates `FSQL_REASONING_HTTP_RESPONSE_MODE`
(`text` / `code` / `json`). It's a separate file, not a section in
`demo.sql`, because the response mode is env-var-only and read once at
plugin init, so changing it needs an OS-level environment change plus a
full `mariadbd` restart. Run it as three manual passes: run `demo.sql`
first, then for each mode set the env var, restart `mariadbd`, and run
only that section's query.

## Enterprise Tier: QTL & CISO Audit

`enterprise-qtl-audit.sql` and `enterprise-stress.sql` cover the
Enterprise-tier ledger and audit surface. **Community edition works
fully without any of this**. Both run cleanly with the enterprise
library dormant (the default: every `fractal_ledger_*`/
`fractal_audit_unpack` call returns a clean `NULL`, never an error or
a crash) or, if you point `FRACTALSQL_ENTERPRISE_LIB` at a real
`libfractalsql-enterprise-*.so`, active: a genuine file-backed ledger
with chain verification and signature checking. See
**[docs/enterprise.md](../docs/enterprise.md)** for the full reference.

```sh
mariadb -u root -p <your_database> < demo/enterprise-qtl-audit.sql
mariadb -u root -p <your_database> < demo/enterprise-stress.sql
```

## Text-to-SQL

`demo-text-to-sql.sql` walks through `fractal_text_to_sql()` against a
three-table schema with real foreign keys. Same prerequisites as
`demo.sql`. See **[docs/text-to-sql-setup.md](../docs/text-to-sql-setup.md)**
for the full pipeline reference.

```sh
mariadb -u root -p <your_database> < demo/demo-text-to-sql.sql
```

`demo/text-to-sql-spike-*.sql` are a 4-part hand-rolled GENERATE →
REVIEW → EXPLAIN → negative-control validation spike, one model per
run (reasoning config is fixed per `mariadbd` process; restart with a
different `FRACTALSQL_HTTP_MODEL` to compare a different model, then
re-run Parts 1–4 from scratch).

## Industry vertical demos

Eleven runnable vertical walkthroughs are available (eight industry
verticals, three agentic verticals), each verified end-to-end against
a live MariaDB server and a real Ollama endpoint:
`demo-vertical-quant-finance.sql`, `demo-vertical-medtech-clinical.sql`,
`demo-vertical-recommendation-search.sql`,
`demo-vertical-sovereign-edge-ai.sql`,
`demo-vertical-maritime-defense.sql`,
`demo-vertical-fleet-logistics.sql`,
`demo-vertical-smart-cities-iot.sql`,
`demo-vertical-cybersecurity-threat-detection.sql`,
`demo-vertical-agentic-ops-devops.sql`,
`demo-vertical-agentic-fintech-mcts.sql`, and
`demo-vertical-agentic-customer-support.sql`. Each file is
self-contained: run it directly,

```sh
mariadb -u root -p <your_database> < demo/demo-vertical-<name>.sql
```

and see that file's own trailing comment for its `DROP TABLE` cleanup
(the tables it creates are permanent, not `TEMPORARY`, so they're left
in place for inspection after the script finishes).

Four of the eleven (MedTech, Maritime, Fleet, Cybersecurity) use a
native `fractal_vector(n)` type for their vector columns. This repo's
equivalent is either the portable JSON-array-string TEXT column (works
everywhere, 10.6+) or MariaDB's own native `VECTOR(n)` column type
(11.7+ only, see [demo-fractal-vector.sql](demo-fractal-vector.sql)
and **[docs/vectorizer-setup.md](../docs/vectorizer-setup.md)**'s
native-type section). These four verticals pick one of those two
paths per column, not a 1:1 type substitution.

Per-kit descriptive detail (which problem each vertical solves, its
data shape, and which productized agent composes it) lives in
**[docs/starter-kits.md](../docs/starter-kits.md)**, not repeated here.

One genuine architectural constraint applies here: MariaDB's
`information_schema` has zero visibility into `TEMPORARY` tables.
`demo-vertical-fleet-logistics.sql` and
`demo-vertical-cybersecurity-threat-detection.sql` use a plain
permanent `CREATE TABLE` for their cohort tables
(`vfl_route3_cohort`/`vcy_dmz_cohort`) rather than `CREATE TEMPORARY
TABLE`, since a temporary table can't be introspected this way.

## The sixteen agents

`demo-agents.sql` exercises the full agent surface. MariaDB has no
extension-dependency system, so the agents live in
`sql/install_agents.sql` as plain stored procedures. This edition
ships **16** agents; one of them, the portfolio-diversity agent
(`fractal_agent_diverse_portfolios`), calls an enterprise-tier
portfolio-optimization primitive and is dormant without
`FRACTALSQL_ENTERPRISE_LIB` set. See
**[docs/api-agency.md](../docs/api-agency.md)** for the full
reference, including exactly which agent maps to which real
`CALL fractal_agent_<name>(..., @result)` signature (every one
verified directly against `sql/install_agents.sql`, not inferred).

```sh
mariadb -u root -p <your_database> < sql/install_udf.sql
mariadb -u root -p <your_database> < sql/install_agents.sql
mariadb -u root -p <your_database> < demo/demo-agents.sql
```

## Full API benchmark

`benchmark-api-reference.sql` is a coverage pass over the full UDF
surface, distinct from [`benchmark.sql`](benchmark.sql)'s narrower
Sniper/Scout/vectorizer comparison. Neither of these is the same thing
as **[../bench/](../bench/)**'s research-grade head-to-head
suite (native `VECTOR(n)` index vs. Scout Mode, storage comparison);
these two demo files are quick coverage/smoke checks, not
latency/recall research.

```sh
mariadb -u root -p <your_database> < demo/benchmark-api-reference.sql
mariadb -u root -p <your_database> < demo/benchmark.sql
```

## Cleanup

```sql
DROP TABLE demo_alerts, demo_embeddings;
DROP TABLE order_items, orders, customers;                            -- demo-text-to-sql.sql
DROP TABLE bi_customer_features, bi_orders, bi_customers;             -- demo-business-intelligence.sql
DROP TABLE bmk_corpus, bmk_docs, bmk_modal;                            -- benchmark-api-reference.sql
DROP TABLE agents_demo_logs, agents_demo_caps, agents_demo_badstates,
           agents_demo_mem, agents_demo_catalog, agents_demo_data,
           agents_demo_patients, agents_demo_fcatalog, agents_demo_fwarmup,
           agents_demo_nodes, agents_demo_alloc, agents_demo_vehicles,
           agents_demo_tracks;                                        -- demo-agents.sql
DELETE FROM fractal_vectorizers WHERE source_table IN ('bt_bench_docs', 'bmk_docs', 'docs', 'docs_fv');
DROP TABLE bt_bench_docs, bt_bench_corpus, bt_bench_clusters;          -- benchmark.sql
DROP TABLE spike_candidates, spike_negative_control;                  -- text-to-sql-spike-*.sql
DROP TABLE vqf_assets, vqf_loadings, vqf_allocation_snapshots;         -- demo-vertical-quant-finance.sql
DROP TABLE vmc_patients;                                               -- demo-vertical-medtech-clinical.sql
DROP TABLE vrs_genres, vrs_catalog, vrs_modal_items;                   -- demo-vertical-recommendation-search.sql
DROP TABLE vse_nodes, vse_throughput;                                  -- demo-vertical-sovereign-edge-ai.sql
DROP TABLE vmd_vessels;                                                -- demo-vertical-maritime-defense.sql
DROP TABLE vfl_vehicles, vfl_route3_cohort;                            -- demo-vertical-fleet-logistics.sql
DROP TABLE vsc_sensors;                                                -- demo-vertical-smart-cities-iot.sql
DROP TABLE vcy_hosts, vcy_dmz_cohort;                                  -- demo-vertical-cybersecurity-threat-detection.sql
DROP TABLE vao_incident_logs, vao_agent_capabilities, vao_known_bad_states;  -- demo-vertical-agentic-ops-devops.sql
DROP TABLE vfm_trade_strategies, vfm_portfolios, vfm_assets,
           vfm_restrictions, vfm_historical_allocations;               -- demo-vertical-agentic-fintech-mcts.sql
DROP TABLE vcs_customer_sessions, vcs_customer_playbook, vcs_product_catalog;  -- demo-vertical-agentic-customer-support.sql
DELETE FROM fractal_vectorizers WHERE source_table IN ('vao_incident_logs', 'vfm_trade_strategies');
```

## Troubleshooting

- **Section 0 failing** → the UDFs aren't registered; re-run
  `sql/install_udf.sql` (and `sql/install_agents.sql` for
  `demo-agents.sql`).
- **A reasoning/text-to-sql/vectorizer/agent section erroring or
  returning `NULL`** → the endpoint isn't configured or isn't
  reachable. Check `FRACTALSQL_REASONING_PLUGIN`/`HTTP_URL`/`HTTP_MODEL`
  are set in `mariadbd`'s OWN process environment (not just your shell),
  see **[docs/reasoning-setup.md](../docs/reasoning-setup.md)**.
- **An enterprise-tier call returning `NULL` with no error** → this is
  the CORRECT, documented dormant-state behavior when
  `FRACTALSQL_ENTERPRISE_LIB` isn't set or the library isn't loaded,
  not a bug. See **[docs/enterprise.md](../docs/enterprise.md)**.

## Coverage status

Every file below has been verified end-to-end, including fixes for
real signature/argument bugs found by actually running each one.

| File | Status |
| --- | --- |
| demo.sql | verified |
| response-modes.sql | verified |
| demo-text-to-sql.sql | verified |
| demo-vectorizer.sql | verified |
| demo-fractal-vector.sql | verified |
| demo-agents.sql | verified (16 agents; the portfolio-diversity agent is enterprise-tier and probes for its own dormant state, see above) |
| demo-business-intelligence.sql | verified |
| benchmark.sql | verified |
| benchmark-api-reference.sql | verified |
| enterprise-qtl-audit.sql | verified in both states: dormant (no enterprise library) and active, against a real `libfractalsql-enterprise-sovereign-c.so`, including the optional CONNECT mirror's CISO audit decode |
| enterprise-stress.sql | verified in both states: dormant and active, including structural-truncation, entry-hash, and HMAC tamper detection (Phase D recipes, out-of-band against the ledger file) |
| text-to-sql-spike-1..4 | verified against a real Ollama endpoint |
| demo-workload.sh | verified |
| demo-vertical-*.sql (11 files) | verified, see [Industry vertical demos](#industry-vertical-demos) above |
