<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# Sovereign Reasoning Setup Guide

The **Cognition Tier** is the intelligence layer of FractalSQL. It provides
a pluggable bridge that lets MariaDB call Large Language Models (LLMs) and
embedding providers directly from SQL.

By bringing reasoning directly into the MariaDB backend, FractalSQL lets you
synthesize, analyze, and reason over your data without an external
application-middleware hop. Sovereignty here is a deployment choice, not a
guarantee baked into every provider: local models (Ollama/vLLM) keep data
on your own infrastructure, while cloud providers (Bedrock, Azure OpenAI,
Vertex) send it to that provider under your own account and compliance
agreement.

---

## 🧠 The Cognition Model

The Cognition tier provides `fractal_reason(session_id, query
[, context])`. Unlike traditional RAG, which relies on external
orchestrators, FractalSQL performs the synthesis inside the backend:

1. **Context Assembly**: You use ordinary SQL (subqueries, `JSON_ARRAYAGG`,
   or `fractal_explore`) to gather the precise data needed.
2. **Sovereign Dispatch**: The extension dispatches the query and context
   to your configured LLM via a dedicated C-bridge.
3. **In-Place Synthesis**: The response is returned directly into your
   query result, allowing you to combine reasoning with standard SQL
   filters, joins, and aggregations in a single statement.

`session_id` (pass `CONNECTION_ID()`) is required and first. MariaDB is
one shared multithreaded process for every connection, so
reasoning/embedding context is explicitly keyed per-connection rather than
living in a process-global static.

---

## 🛠️ Prerequisites

To activate the Cognition tier, you need a reasoning plugin and a
configured endpoint.

### 1. The Reasoning Plugin
The reasoning plugin (`fractalsql-reasoning-http.so` or `.dll`) is a
standalone `dlopen`'d shared object; it is **not** a MariaDB `INSTALL
SONAME` plugin. MariaDB's plugin loader requires an exact
interface-version/`MYSQL_VERSION_ID` match to the running server, down to
the patch level, and a single prebuilt `.so` could never satisfy that across
this repo's 10.6-12.3 compat matrix the way a stable UDF ABI does. Instead,
this repo's own C code `dlopen`s it directly, the same portable mechanism
`src/fractalsql_enterprise.c` uses for the (separate) enterprise library.
See `docker/Dockerfile`'s own header comment for the full rejected-design
account.

**Find your `plugin_dir`**:
```sql
SELECT @@plugin_dir;
```
Common paths:
- **Debian/Ubuntu (apt)**: `/usr/lib/mysql/plugin/`
- **RHEL/Rocky (dnf)**: `/usr/lib64/mariadb/plugin/`
- **macOS (Homebrew)**: `/opt/homebrew/Cellar/mariadb/<version>/lib/plugin/` (Apple Silicon) or `/usr/local/Cellar/mariadb/<version>/lib/plugin/` (Intel) — resolve it with `realpath "$(mariadb -N -B -e 'SELECT @@plugin_dir;')"`; see the canonical-path note in Step 1 for why the `/opt/homebrew/opt/mariadb/...` symlink form won't work
- **Windows**: `C:\Program Files\MariaDB <major>\lib\plugin\`

Copy `fractalsql-reasoning-http.so`/`.dll` there (the `.deb`/`.rpm`
packages already do this for you).

### 2. Technical Requirements
- **Extension Version**: `fractalsql-mariadb` 2.0.0+ (`SELECT fractalsql_version();`).
- **Host Dependencies**: `libcurl` 7.75.0+ (required for AWS SigV4 auth). The `.deb`/`.rpm` packages declare `libcurl4`/`libcurl.so.4()(64bit)` as a real dependency.
- **Endpoint**: An LLM provider (Ollama, AWS Bedrock, Azure OpenAI, GCP Vertex, or any OpenAI-compatible API).

---

## 🚀 Setup Sequence

## Step 1: Point mariadbd at the plugin

**There is no server config file, sysvar, or `SET GLOBAL` here.** No
reasoning tier registers a server system variable. Configuration is a
**process environment variable**, read
once by `mariadbd` and cached for that process's entire lifetime. Set it
**before** `mariadbd` starts:

```bash
# systemd EnvironmentFile, docker run -e, or your process manager's
# equivalent. Not a server config file; plain process-environment syntax.
FRACTALSQL_REASONING_PLUGIN=/usr/lib/mysql/plugin/fractalsql-reasoning-http.so
```

**The path must be canonical**: the reasoning core resolves the value
with `realpath()` and refuses to load anything whose configured path
doesn't equal its own resolution ("reasoning plugin path is not
canonical" on the server's stderr). Symlinked directory segments never
pass that check — on macOS/Homebrew that means the familiar
`/opt/homebrew/opt/mariadb/...` form is rejected (it's a symlink into
the versioned `Cellar` directory), so always resolve the real path
first:

```bash
FRACTALSQL_REASONING_PLUGIN="$(realpath "$(mariadb -N -B -e 'SELECT @@plugin_dir;')")/fractalsql-reasoning-http.so"
```

The plugin loads lazily on the first reasoning call in a session, but there
is no live reload: changing any of these
variables means restarting `mariadbd`.

## Step 2: Universal LLM Connectivity

One of the core strengths of this design is **zero provider lock-in**: the
provider bridge abstracts each provider's API, so your SQL calls to
`fractal_reason()` remain identical whether you're using a local model for
privacy or a cloud provider for scale.

Pick your provider and export the corresponding block. Only one should be
active at a time.

## Ollama (Local or Private Network)
The gold standard for fully air-gapped, sovereign deployments. Traffic
stays inside your network perimeter.

```bash
FRACTALSQL_HTTP_URL=http://127.0.0.1:11434/v1/chat/completions
FRACTALSQL_HTTP_ALLOW_PLAINTEXT=1
FRACTALSQL_HTTP_MODEL=gpt-oss:20b
FRACTALSQL_HTTP_EMBED_URL=http://127.0.0.1:11434/v1/embeddings
FRACTALSQL_HTTP_EMBED_MODEL=nomic-embed-text
```
*Note: Run `ollama pull gpt-oss:20b` (and `nomic-embed-text`) before
connecting. See `docker-compose.yml` at the repo root for a working
turnkey example of exactly this.*

## OpenAI-Compatible (OpenAI, Together AI, Fireworks, vLLM)
```bash
FRACTALSQL_HTTP_URL=https://api.openai.com/v1/chat/completions
FRACTALSQL_HTTP_TOKEN=sk-...
FRACTALSQL_HTTP_MODEL=gpt-4o-mini
```

## AWS Bedrock
Bedrock uses AWS SigV4 signing. The URL must point to the
**OpenAI-compatible** surface.

```bash
FRACTALSQL_HTTP_URL=https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1/chat/completions
FRACTALSQL_HTTP_MODEL=amazon.nova-lite-v1:0
```
**Critical**: Auth type and region are set via the reasoning plugin's own
lower-level env vars (see [Advanced Configuration](#-advanced-configuration)
below), not the `FRACTALSQL_*` bridge names.

## Azure OpenAI
Azure requires a separate deployment for the chat model.

```bash
FRACTALSQL_HTTP_URL=https://<resource>.openai.azure.com/openai/deployments/<deployment>/chat/completions?api-version=2024-02-01
FRACTALSQL_HTTP_TOKEN=<azure-api-key>
FRACTALSQL_HTTP_MODEL=gpt-4o
```

## Google Vertex AI
Vertex AI exposes an OpenAI-compatible endpoint on the `openai/v1` path of
your project's region endpoint. Auth is a Google **service-account OAuth
access token** (a short-lived bearer), supplied via `FRACTALSQL_HTTP_TOKEN`
exactly like an API key. No SigV4-style signing is needed.

```bash
FRACTALSQL_HTTP_URL=https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/endpoints/openapi/chat/completions
FRACTALSQL_HTTP_TOKEN=<gcp-oauth-access-token>
FRACTALSQL_HTTP_MODEL=google/gemini-2.5-flash
```

**Generating the token**: `FRACTALSQL_HTTP_TOKEN` must be a valid Google
OAuth access token for a service account with the Vertex AI User role:

```sh
gcloud auth activate-service-account --key-file=sa-key.json
gcloud auth print-access-token    # paste the output into FRACTALSQL_HTTP_TOKEN
```

**Rotating it requires a restart.** `FRACTALSQL_HTTP_TOKEN` is read once by
`mariadbd` and cached for the process's lifetime: there is no server system
variable for it, so no SQL-level live rotation exists here.
The token is short-lived (~1 hour) and this repo has
**no mechanism to rotate it without restarting `mariadbd`**. For a
long-running Vertex install, plan around scheduled restarts (or front it
with a token-refreshing proxy that MariaDB's `FRACTALSQL_HTTP_URL` points
at instead) rather than assuming live rotation is available.

---

## ⚖️ Hardware & Performance (Local Reasoning)

For users deploying Ollama locally, hardware affects "cold-load" latency.

| Resource | Recommendation | Notes |
| --- | --- | --- |
| **GPU VRAM** | 8GB → 16GB | 8GB runs Phi-4/Gemma4 (Q4); 16GB runs GPT-OSS 20B. |
| **System RAM** | 16GB+ | Covers model, OS, and MariaDB overhead. |
| **CPU** | AVX2 Support | Essential for acceptable CPU-side inference (Post-2016). |

### Handling Constrained Hardware
Local models can take up to 300s to cold-load into memory. To prevent
`curl` from aborting the request, raise the timeout and low-speed windows.
These are the reasoning plugin's own **lower-level** env vars (see below),
not the `FRACTALSQL_*` bridge names, so they're set the same way on every
FractalSQL binding:

```bash
export FSQL_REASONING_HTTP_TIMEOUT_MS=330000
export FSQL_REASONING_HTTP_LOW_SPEED_SECS=300
```
`docker-compose.yml` at the repo root sets exactly these two values for the
bundled demo. Like everything else on this page, this is process
environment, not a config file. Restart `mariadbd` after changing them.

---

## 🛠️ Advanced Configuration

### Two layers of environment variables: don't conflate them

This repo's C code (`src/fractalsql_cognition.c`,
`src/fractalsql_textsql.c`) reads one set of variables and **translates**
them, at plugin-load time, into a second, lower-level set the vendored
`fractalsql-reasoning-http.so` plugin itself reads.

| You set (this repo's bridge) | Becomes (the plugin's own var) |
| --- | --- |
| `FRACTALSQL_HTTP_URL` | `FSQL_REASONING_HTTP_URL` |
| `FRACTALSQL_HTTP_TOKEN` | `FSQL_REASONING_HTTP_TOKEN` |
| `FRACTALSQL_HTTP_MODEL` | `FSQL_REASONING_HTTP_MODEL` |
| `FRACTALSQL_HTTP_ALLOW_PLAINTEXT` | `FSQL_REASONING_HTTP_ALLOW_PLAINTEXT` |
| `FRACTALSQL_HTTP_EMBED_URL` | `FSQL_REASONING_HTTP_URL` (embed dispatch reuses the URL slot) |
| `FRACTALSQL_HTTP_EMBED_MODEL` | `FSQL_REASONING_HTTP_MODEL` (embed dispatch reuses the model slot) |
| `FRACTALSQL_HTTP_THINK` | `FSQL_REASONING_HTTP_THINK` |
| `FRACTALSQL_HTTP_THINK_PROVIDER` | `FSQL_REASONING_HTTP_THINK_PROVIDER` |
| `FRACTALSQL_HTTP_NATIVE_URL` | `FSQL_REASONING_HTTP_NATIVE_URL` |
| `FRACTALSQL_HTTP_NUM_CTX` | `FSQL_REASONING_HTTP_NUM_CTX` |

A **third** family exists with **no `FRACTALSQL_*` bridge at all**. Set
these directly, they're read straight by the plugin: `FSQL_REASONING_HTTP_TIMEOUT_MS`,
`FSQL_REASONING_HTTP_LOW_SPEED_SECS`, `FSQL_REASONING_HTTP_SYSTEM_PROMPT`
(see [Security & Governance](#-security--governance) below).

You will only ever need to set the `FRACTALSQL_*` names yourself for normal
provider config; the translation happens automatically. This table exists
so the `FSQL_REASONING_HTTP_*` names you'll see in plugin log lines or
`docker-compose.yml` comments make sense, and so you know which family a
given knob belongs to when this page or the plugin's own docs mention one
you haven't seen before.

### Response Modes
Shape how the plugin post-processes the LLM response, set internally by
this repo's own C code depending on which function you called. You don't
set `FSQL_REASONING_HTTP_RESPONSE_MODE` yourself for normal use:
- `text` (`fractal_reason`, `fractal_t2s_review`): Raw content.
- `code` (`fractal_t2s_generate`): Forces a single fenced code block and
  extracts it automatically.
- `json`: Forces a fenced JSON block and validates structural integrity
  (available at the plugin level; not currently dispatched to by any
  function in this repo).

### Reasoning Effort (THINK)
Unlike Response Modes, this one you *do* set yourself. It throttles
hybrid-thinker models (Granite 4.2, OpenAI o-series, Claude extended
thinking, DeepSeek-R1, QwQ) whose internal reasoning trace otherwise
dominates latency and VRAM. Applies to `fractal_reason`,
`fractal_t2s_generate`, and `fractal_t2s_review` (chat tiers only:
`fractal_embed` never sees it, by design, since no provider applies
reasoning effort to an embeddings request).

- `FRACTALSQL_HTTP_THINK`: `none` (default) | `off` | anything else
  (`low`, `medium`, `high`, ...). `none`/unset sends no thinking-control
  field, so the model's own default applies. `off` is a different,
  explicit disable, not just an alias, since a hybrid-thinker model's own
  default is often ON. Any other value is forwarded to the provider as
  is; it isn't checked against a fixed list, since each provider's
  effort tiers keep changing.
- `FRACTALSQL_HTTP_THINK_PROVIDER`: `openai` (default) | `ollama` |
  `anthropic` | `vllm` | `grok`. Selects the field/shape your backend
  actually honors. There's no cross-vendor standard for this the way
  there is for chat completions, so it's an explicit choice, never
  auto-detected. `openai` names a *shape*, not a vendor: it's also the
  correct choice for Azure OpenAI, AWS Bedrock, and Google Vertex AI's
  OpenAI-compatible surfaces, since this is independent of whatever
  `AUTH_TYPE`-equivalent credential config those providers use. `grok`
  is for xAI's Grok models on Bedrock's OpenAI-compatible surface, which
  take a nested `reasoning.effort` field rather than `openai`'s
  top-level one. `ollama`/`anthropic` switch to that provider's native
  request/response shape entirely (required for Ollama specifically,
  since its OpenAI-compatible endpoint ignores thinking control).
- `FRACTALSQL_HTTP_NATIVE_URL`: optional, routes the ollama-native/
  anthropic-native request elsewhere without touching `FRACTALSQL_HTTP_URL`.
- `FRACTALSQL_HTTP_NUM_CTX`: optional, Ollama-native only. Context window
  cap (e.g. reducing VRAM use on constrained hardware; see
  [Handling Constrained Hardware](#handling-constrained-hardware)).

`THINK=none` (the default) is byte-identical to this repo's behavior
before this option existed. The plugin never surfaces the raw reasoning
trace regardless of provider, the same trace-isolation guarantee as its
existing "never leak `choices[0].message.reasoning`" behavior, extended
to the native Ollama/Anthropic shapes.

### Target-System Hints
`fractal_t2s_generate` sets `FSQL_REASONING_HTTP_SYSTEM_TAG` automatically,
derived from `VERSION()` (e.g. `mariadb1011`). A plain UDF has no access
to the connected server's own version the way the orchestrating stored
procedure does, so this repo's `CALL fractal_text_to_sql(...)` computes and
passes it through for you.

---

## 🔒 Security & Governance

### The Sovereign Guardrail: Dedicated Accounts
Never run reasoning queries as `root`. Create a restricted account to bound
what the LLM can see.

```sql
CREATE USER 'fsql_reasoning'@'%' IDENTIFIED BY '...';
GRANT SELECT (id, title, body) ON mydb.documents TO 'fsql_reasoning'@'%';
```
MariaDB supports column-level `GRANT` (as above), so scope the account down
to exactly the columns the reasoning queries need.

### No Row-Level Security
**MariaDB has no native Row-Level Security mechanism.** There is no
engine-level policy you can enable so the context subquery only
returns rows the current session's user may see.
If cross-tenant leakage into an LLM context is a concern, the
filtering has to live in the SQL itself (an explicit `WHERE`, a view scoped
by the connecting account's own grants) or an application-layer check;
there is no engine-enforced backstop to fall back on.

### Prompt Injection (OWASP LLM01)
The plugin prepends a baseline anti-injection instruction to every system
message as a best-effort mitigation. No system-prompt instruction can fully
prevent prompt injection from untrusted context, since the model still
can't reliably distinguish instructions from data. Treat it as raising the
bar, not closing the door. The real defense is architectural: column-level
grants restricting what the context subquery can see (above), and treating
every LLM response as untrusted output, never executed as SQL directly
(this is exactly what the [Text-to-SQL](text-to-sql-setup.md) allowlist +
`PREPARE`-only check exist to enforce). To replace the baseline
instruction, set `FSQL_REASONING_HTTP_SYSTEM_PROMPT`.

---

## 📋 Production Checklist

- [ ] **Plugin Path**: `FRACTALSQL_REASONING_PLUGIN` is absolute, **canonical** (it equals its own `realpath` — no symlinked segments, e.g. not Homebrew's `/opt/homebrew/opt/...` form), readable by the `mysql` user, and set in `mariadbd`'s process environment (not a config file).
- [ ] **Auth Model**: A dedicated reasoning account is used with column-level `SELECT` grants, not `root`.
- [ ] **No RLS fallback**: any row-level filtering the workload needs is enforced in the SQL/view itself; confirmed there is no engine-level backstop here.
- [ ] **Egress Review**: Cloud endpoints' DPA/BAA have been reviewed for the specific data classification.
- [ ] **Token Rotation Plan**: for a cloud provider with a short-lived token, a restart or refreshing-proxy plan is in place; there is no live rotation.
- [ ] **Output Safety**: LLM responses are treated as untrusted display text and never executed as SQL directly.
