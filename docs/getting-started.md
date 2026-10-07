<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Getting Started: From Zero to Your First Agent

This guide takes you from a fresh checkout to a running agentic database in
about five minutes: no MariaDB install, no compiler, no model download
required to start. By the end you will have:

- a MariaDB 11.4 server with the fractalsql UDF set **and** the 16 agent
  stored procedures registered,
- a diverse vector search that runs with **no model** connected,
- a live reasoning call against a real LLM, and
- all 16 agents demoable on demand (MariaDB has no `CREATE EXTENSION`
  mechanism: UDFs and procedures are registered by running two plain SQL
  scripts, already done for you in the Docker image; see
  [Install without Docker](#5-install-without-docker) for the manual
  equivalent). One of the sixteen, `fractal_agent_diverse_portfolios`, is
  enterprise-tier and dormant without `FRACTALSQL_ENTERPRISE_LIB` set, see
  [`docs/api-agency.md`](api-agency.md) for the full account.

The fastest path is Docker. If you are putting this into a real MariaDB
server instead, jump to [Install without Docker](#5-install-without-docker)
and come back to the "first search" / "first agent" sections.

> **The 5-minute path:** [1. Running in 60 seconds](#1-running-in-60-seconds-docker)
> → [2. Your first search](#2-your-first-search-no-model-needed)
> → [3. Turn on reasoning](#3-turn-on-reasoning) → [4. Your first agent](#4-your-first-agent)
> → [where next](#where-next).

---

## 1. Running in 60 seconds (Docker)

From the repo root:

```bash
docker compose up -d
```

That starts a MariaDB 11.4 container (database `fractalsql_demo`) with the
fractalsql UDF set **and** the 16 agent procedures already registered (run
automatically as `docker-entrypoint-initdb.d` scripts on first start) plus
an Ollama container with **no model pulled** (you add a model when you want
reasoning, see [step 3](#3-turn-on-reasoning)). All the demo SQL ships
inside the image at `/demo/`, ready to run on demand.

Verify FractalSQL is alive:

```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo \
  -e "SELECT fractal_edition(), fractal_version();"
```

You should see:

```
edition   version
Community 2.0.9
```

MariaDB has no `CREATE EXTENSION` mechanism and nothing equivalent to
list: there is no extension-dependency system here, just two plain SQL
scripts
(`sql/install_udf.sql` then `sql/install_agents.sql`) run once. If both
functions above return a value, both scripts already ran successfully.

> **No `mariadb` client on your host?** Every command below uses
> `docker compose exec mariadb mariadb ...` so you never need a local
> client. If you do have one, the server is also exposed on host port
> `13306` (`mariadb -h 127.0.0.1 -P 13306 -uroot -pfractalsql fractalsql_demo`).

---

## 2. Your first search (no model needed)

FractalSQL's core is a **Stochastic Fractal Search** optimizer. It comes in
two flavours that solve different problems:

- **Sniper** (`fractal_search`): converge to the single best point in a
  continuous space.
- **Scout** (`fractal_search_explore`): discover the *diverse* structure of your
  own data, finding distinct "islands" instead of collapsing to one
  nearest neighbour.

Scout is what makes FractalSQL different from a plain vector DB, and it runs
with **no model connected**. `fractal_search_explore` takes the whole corpus as one
inline argument, since MariaDB's C UDF ABI can't run SQL against the
calling session and has no table-returning
UDFs at all, a hard architecture constraint (see
[`docs/api-discovery.md`](api-discovery.md) for the full account). Try it on
a tiny toy corpus:

```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo -e "
SELECT fractal_search_explore(
    '[[0.1,0.1,0.1],[0.9,0.9,0.9],[0.2,0.8,0.2]]',
    '[0.5,0.5,0.5]',
    '{\"population_size\": 20, \"iterations\": 10, \"walk\": 0}'
);"
```

You'll get back `{"population": [[...], [...], ...]}`, a spread of vectors
drawn from the distinct clusters in your corpus: the opposite of a `top-K`
query that would return rows all from the same neighbourhood. Re-running it
is safe and gives similar diverse coverage.

→ For the native-index-vs-Scout benchmark that makes the difference
concrete, see **[docs/features.md](features.md#-benchmarks--scaling)**.

---

## 3. Turn on reasoning

Search finds data; **reasoning** turns it into insight. Reasoning is opt-in.
It calls an LLM through a high-performance HTTP bridge, so you point it at a
provider (Ollama locally, or AWS Bedrock / Azure OpenAI / GCP Vertex in the
cloud).

**With the bundled Ollama**: pull a model once, then reason:

```bash
# one-time model pull (~13.8 GB for gpt-oss:20b; a few hundred MB for the embedder)
docker compose --profile pull-model run --rm pull-model
```

```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo -e "
SELECT fractal_reason(CONNECTION_ID(), 'Reply with exactly: FSQL_LIVE_OK');"
```

```
FSQL_LIVE_OK
```

`fractal_reason`/`fractal_embed` need `CONNECTION_ID()` as their first
argument (`fractalsqld`, the daemon every UDF body runs in, is one shared
multithreaded process for every connection's forwarded calls, so
Diversify/reasoning state has to be explicitly keyed per-session; see
[`docs/api-discovery.md`](api-discovery.md#diversify--repulsion-session-scoped)).

The embedder works the same way (it powers the vectorizer and any
RAG-style agent):

```sql
SELECT fractal_embed(CONNECTION_ID(), 'hello world');
--  [0.123, -0.045, ...]  (a fractal_vector JSON-array-string, not a native array)
```

→ To point at a cloud endpoint instead of local Ollama, see
**[docs/reasoning-setup.md](reasoning-setup.md)** (provider config, the
conf-vs-environment framing, the slow-hardware timeout notes).

---

## 4. Your first agent

The **Agency tier** composes Discovery + Cognition into self-correcting
routines. The image ships a single script that exercises all **16 agents**
end-to-end: anomaly triage, portfolio allocation, hybrid recall, route
planning, deterioration triage, regime detection, and the rest:

```bash
docker compose exec mariadb mariadb -uroot -pfractalsql fractalsql_demo < demo/demo-agents.sql
```

Each section sets up its own fixture tables (dropped and recreated first, so
it's re-runnable) and `CALL`s one agent. With a model pulled you get real
reasoned output for every section; without one, the retrieval/optimization
parts still run for the three no-LLM agents (`recall_hybrid`,
`recommend_diverse`, `feedback_audit`) and the other twelve return a clean
`NULL`-dispatch error rather than a broken result. `diverse_portfolios`
(enterprise-tier, the sixteenth) probes for its own dormant state
separately, see [`docs/api-agency.md`](api-agency.md).

> **The eleven industry starter kits are here too.** Eleven runnable
> industry walkthroughs (`demo-vertical-*.sql`) ship with this repo,
> live-verified against a real MariaDB server and a real Ollama endpoint.
> `demo-agents.sql` above
> is still the fastest guided tour of all 16 agents in one pass; jump to a
> specific `demo-vertical-*.sql` for a domain-shaped dataset instead. See
> [`docs/starter-kits.md`](starter-kits.md) for the full list and the
> problem→agent mapping.

→ To pick the right agent for your problem, see the decision table in
**[docs/api-agency.md](api-agency.md#which-agent-should-i-use)**.

---

## 5. Install without Docker

### Option A: one command

Clone the repo, then run the setup wizard for your platform. It detects
your MariaDB install, offers to install the matching package if it's not
there yet, registers the UDFs and agent procedures, and walks you through
picking a reasoning provider (local Ollama, an OpenAI-compatible endpoint,
or search only).

```bash
# Linux / macOS
git clone https://github.com/FractalSQLabs/fractalsql-mariadb.git
cd fractalsql-mariadb
./scripts/easy_install.sh
```

```powershell
# Windows
git clone https://github.com/FractalSQLabs/fractalsql-mariadb.git
cd fractalsql-mariadb
pwsh -File .\scripts\windows\easy_install.ps1
```

Already installed the package yourself? Run the same script and it detects
that, skipping straight to the wizard. Every prompt has a matching flag
(`--provider`, `--url`, `--model`, `--yes`, `--dry-run`, `-Provider`,
`-Url`, `-Model`, `-Yes`, `-DryRun`, ...) for non-interactive or CI use.
Run with `--help`/`-Help` for the full list. The script never phones home:
no telemetry, no usage reporting, all of it stays local to your box.

Applying a reasoning setting here does **not** need to be a restart. The
preferred source for all provider settings is the daemon's conf file,
`fractalsqld.conf` (the file `fractalsqld` was started with via `-c`;
`/etc/fractalsql/fractalsqld.conf` by default on Linux/macOS,
`C:\ProgramData\FractalSQL\fractalsqld.conf` on Windows), and
`fsqlctl reload` applies a changed value live -- the tier picks it up on
its next call, with `mariadbd` untouched:

```ini
# /etc/fractalsql/fractalsqld.conf -- provider keys alongside the
# daemon's own socket/key paths (socket_path, hmac_key_file)
reasoning_plugin = /usr/lib/mysql/plugin/fractalsql-reasoning-http.so
reasoning_url    = http://127.0.0.1:11434/v1/chat/completions
embed_url        = http://127.0.0.1:11434/v1/embeddings
```

```bash
fsqlctl reload   # applies every changed provider key on the next call
```

The provider conf keys cover all of it: `reasoning_plugin`,
`reasoning_url`, `reasoning_token`, `reasoning_model`,
`reasoning_allow_plaintext`, `embed_url`, `embed_model`, the `think*`
knobs, and the text-to-sql settings -- reload covers them the same way
(one exception: `enterprise_lib` cannot be swapped live while its
enterprise library is loaded; restart for that one). The
`FRACTALSQL_*`/`FSQL_*` process environment variables
remain the fallback for keys the conf
omits; they are read once at daemon startup, so changing a value that
lives only there still means a `fractalsqld` restart. The wizard above
writes the conf keys for you. See
**[docs/reasoning-setup.md](reasoning-setup.md)** for the full key list
and the reload semantics.

### Option B: manual / air-gapped

For anything that can't run a cloned script directly, such as a compliance
environment, an air-gapped box, or just wanting to see every step, grab
the package matching your CPU architecture from
[GitHub Releases](https://github.com/FractalSQLabs/fractalsql-mariadb/releases)
(one binary covers MariaDB 10.6 / 10.11 / 11.4 LTS / 12.3 LTS: the UDF
ABI is stable across those majors, no per-major package needed).

```bash
# Debian / Ubuntu
sudo apt install ./fractalsql-mariadb-amd64.deb

# RHEL / Rocky / Fedora
sudo dnf install ./fractalsql-mariadb-amd64.rpm
```

```powershell
# Windows: download FractalSQL-MariaDB-<major>-<version>-x64.msi for your
# MariaDB major from GitHub Releases and run it. It installs fractalsql.dll
# (the shim) into your MariaDB install's lib\plugin\, fractalsqld.exe (the
# daemon every UDF body runs in) under a fractalsqld\ folder alongside it,
# and drops the two SQL scripts below into share\doc\fractalsql-mariadb\
# for you to run manually (the installer does not run them itself).
#
# fractalsqld.exe must be running before any FractalSQL call works --
# the MSI does not register it as a service. See the installed
# share\doc\fractalsql-mariadb\README.txt, or run
# fractalsqld\fractalsqld-service.ps1 (also installed) to set that up.
```

Then register the UDFs and agents, once per database:

```bash
mariadb -u root -p mydb < sql/install_udf.sql
mariadb -u root -p mydb < sql/install_agents.sql
```

Both scripts are plain, idempotent SQL (`DROP ... IF EXISTS` then
`CREATE`); MariaDB has no extension/dependency-resolution mechanism to hook
into.

On **macOS** there is no `.deb`/`.rpm` equivalent, so releases ship a
per-arch `.zip` with `fractalsql.dylib` (the shim), `fractalsqld` (the
daemon), a launchd plist, and `install.sh`, which stages all of it (shim
into Homebrew MariaDB's `plugin_dir`, the daemon under
`/usr/local/libexec/fractalsql`, and loads it as a per-user LaunchAgent)
and registers the UDFs. See the release asset's own `README.txt` for the
manual steps if you'd rather not run `install.sh`.

→ Package paths, version matrices, and the reasoning plugin's
configuration surface (`fractalsqld.conf` keys plus their environment
fallbacks) are in **[docs/features.md](features.md)** and
**[docs/reasoning-setup.md](reasoning-setup.md)**.

---

## Where next

The documentation is a linear path. You just finished this guide, step 2 of
the path in the [README](../README.md#from-zero-to-your-first-agent).

| Step | Question | Go to |
|------|----------|-------|
| 3 | *"How do I apply this to **my** industry?"* | **[docs/starter-kits.md](starter-kits.md)** |
| 4 | *"How does a specific agent work, and what are its inputs?"* | **[docs/api-agency.md](api-agency.md)** |
| 5 | *"How do I build a proprietary agent that isn't in the box?"* | **[docs/composition-guide.md](composition-guide.md)** |

If you want the full Docker walkthrough (what's baked into the image,
cleanup), it's in **[docs/docker-demo.md](docker-demo.md)**.
