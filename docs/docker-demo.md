<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Docker Demo: The Learning Path

Try FractalSQL without installing anything. `docker-compose.yml` at the repo
root builds a MariaDB 11.4 image with the UDF set pre-installed and stands
up a turnkey demo environment.

## 🛠️ Prerequisites

Docker and Docker Compose. The demo builds the extension from source inside
the container, so no local MariaDB installation or compiler is required.

---

## 🚀 Setup Guide

### 1. The turnkey default: `docker compose up -d`

One command, no flags, gives you the bare minimum:

- **MariaDB 11.4** running, database `fractalsql_demo`, with the fractalsql
  UDF set **and** the 16 agent stored procedures registered
  (`sql/install_udf.sql` / `sql/install_agents.sql` run automatically as
  `docker-entrypoint-initdb.d` scripts; MariaDB has no
  `CREATE EXTENSION`/dependent-extension mechanism to hook into).
- **Ollama** running with **no model pulled** (model download is opt-in,
  step 2).
- Every demo + the `bench/` head-to-head suite inside the container
  (`/demo/`, `/bench/`). Demos are **demoable on demand**: they are not
  run at init, because reasoning is inert until a model is pulled and the
  demos are re-runnable.

```bash
docker compose up -d
```

**Quick test** (works with no model; base Sniper search needs no LLM):
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo -e \
  "SELECT fractal_search('[[0.6,0.8,0.0]]', '[0.6,0.8,0.0]', 1, '{\"iterations\":100}');"
```

Confirm the UDF set loaded:
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo -e \
  "SELECT fractal_edition(), fractal_version();"
# expect: Community, 2.0.3
```

Run any demo (re-runnable; each recreates its own fixture tables):
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/<demo>.sql
```
(Redirect from the **host** side: the `mariadb` client reads its script
from stdin, unlike `psql`'s `-f` flag. Add `-T` to `docker compose exec` if
you're piping from a host file through a non-interactive shell.)

### 2. Cognition: pull a model (opt-in)

Reasoning (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) needs a
model. Ollama is already up from step 1; pull one with the `pull-model`
one-shot:
```bash
docker compose --profile pull-model run --rm pull-model
```
…or, equivalently, `docker compose exec ollama ollama pull gpt-oss:20b` (and
`nomic-embed-text`). This pulls ~13.8GB (gpt-oss:20b) + a few hundred MB
(nomic-embed-text). CPU-only inference may take several minutes per query on
modest hardware. See [docs/reasoning-setup.md](reasoning-setup.md)'s
hardware section. (Or point the reasoning env vars at a cloud endpoint
instead; see [Reasoning Setup](reasoning-setup.md). Note that changing them
means editing `docker-compose.yml`'s `environment:` block and running
`docker compose up -d --force-recreate mariadb`, not a live SQL statement;
see that doc's config-surface note.)

**Quick test** (now that a model is present):
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo -e \
  "SELECT fractal_reason(CONNECTION_ID(), 'summarize this', '{\"note\": \"hello from the demo\"}');"
```

Re-run the agents demo now for full reasoning output:
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-agents.sql
```

### 3. Vectorizer automation

No extra containers: reuse the model from step 2. Enables automatic
embedding pipelines:
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vectorizer.sql
```

---

## 🎓 The Learning Path

Run the demos in this order to see the progression from a vector search tool to a
sovereign agentic database. (Cognition/Agency demos need a model from step 2;
Discovery demos do not.)

### Level 1: Geometric Discovery
*Focus: Using the fractal core and domain-specific geometry to find structure in noise.*
- **Goal**: Learn to use SFS for high-precision convergence and domain-specific metrics (vascular, cortical, nerve).
- **Demos**:
  ```bash
  # MedTech: Clinical Telemetry & Patient Monitoring
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-medtech-clinical.sql
  # Maritime: AIS & Radar Tracking
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-maritime-defense.sql
  # Fleet: Last-Mile Delivery
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-fleet-logistics.sql
  # Smart Cities: IoT Sensor Grids
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-smart-cities-iot.sql
  ```

### Level 2: Cognitive Synthesis
*Focus: Composing search with LLM reasoning to generate human-readable insights.*
- **Goal**: Learn to feed Scout Discovery results into `fractal_reason` and use `fractal_text_to_sql` for safe data exploration.
- **Demos**:
  ```bash
  # Recommendations: Advanced Discovery Engines
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-recommendation-search.sql
  # Sovereign: Edge & Autonomous Systems AI
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-sovereign-edge-ai.sql
  # BI: The Full Reasoning Loop (Question -> SQL -> Result -> Reason)
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-business-intelligence.sql
  ```

### Level 3: Autonomous Agency
*Focus: Building self-correcting, safe, and predictive agentic workflows.*
- **Goal**: Learn to use loop detection (DFA), trajectory prediction, and self-correcting SQL agents. The reference blueprint agents ship inline in each vertical demo; the sixteen installable agents are exercised by `demo-agents.sql` (which uses the real, already-registered `sql/install_agents.sql` product path).
- **Demos**:
  ```bash
  # DevOps: Autonomous Incident Triage & Self-Healing
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-agentic-ops-devops.sql
  # Support: Stateful Session & Churn Drift
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-agentic-customer-support.sql
  # FinTech: MCTS Scenario Exploration & Safe Execution
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-agentic-fintech-mcts.sql
  # Cyber: Threat Detection & Triage
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-vertical-cybersecurity-threat-detection.sql
  # The sixteen installable agents (already registered from docker-entrypoint-initdb.d)
  docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-agents.sql
  ```

See [Agent Recipes](api-agency.md#which-agent-should-i-use) for what each agent
does and when to use it.

### Other demos in the image

`/demo/` also contains `demo.sql` (the base walkthrough), `response-modes.sql`,
`demo-text-to-sql.sql`, `demo-vectorizer.sql`, `demo-fractal-vector.sql`,
`benchmark.sql`, `benchmark-api-reference.sql`, the `text-to-sql-spike-*.sql`
series, and the enterprise-tier `enterprise-qtl-audit.sql`/`enterprise-stress.sql`
(see [`docs/enterprise.md`](enterprise.md)). Run any the same way. See
[demo/README.md](../demo/README.md#industry-vertical-demos) for the full
industry-vertical list, including the eight non-agentic verticals not called
out above.

---

## 📊 Validation & Benchmarks

### Scout vs. native VECTOR(n) index (in-database demo)
See how Scout Discovery captures more distinct clusters than a plain
indexed top-K search, and how much slower it is for that diversity. It's the
classic index-vs-Scout tradeoff, at a
scale sized for `fractal_search_explore`'s inline-corpus-per-call architecture
(see [`docs/features.md`](features.md#-benchmarks--scaling) for why the
workable scale here is comparatively small):
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/benchmark.sql
```

### Full API surface
Exercise a broad slice of the UDF/procedure surface (Search, Reason,
Agents, Analytics) in one pass:
```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/benchmark-api-reference.sql
```

### Head-to-head research benchmark
`bench/` (distinct from `bench/tester/`, the pre-existing Node.js
throughput driver) runs the real native-index-vs-Scout head-to-head,
verified live against a real `mariadb:12.2` container. Python-based,
run from the host or in the container:
```bash
docker compose exec mariadb pip3 install --break-system-packages -r /bench/requirements.txt
docker compose exec mariadb mariadb -uroot -pfractalsql -e "CREATE DATABASE IF NOT EXISTS fractalsql_bench;"
docker compose exec mariadb python3 /bench/data_gen.py --host 127.0.0.1 --database fractalsql_bench
docker compose exec mariadb python3 /bench/head_to_head.py --host 127.0.0.1 --database fractalsql_bench
```
See `bench/README.md` for the exact output shape, the chosen default
scale (comparatively small, since `fractal_search_explore`
has no server-side index to lean on, see [features.md](features.md)), and the
tuning knobs.

---

## 🧹 Cleanup

```bash
docker compose down -v                       # default services + volumes
docker compose --profile pull-model down -v  # also remove the pulled-model volume
```

The `-v` flag removes the named volumes (MariaDB data, the Ollama model
cache). Drop it if you want to keep them for next time.
