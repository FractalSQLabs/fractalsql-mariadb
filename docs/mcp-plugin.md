<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# FractalSQL MCP Plugin for MariaDB

FractalSQL's in-database agents are a micro-orchestration tier: retrieve -> reason ->
act -> guard loops running inside the database process, with the session registry, the
allowlist and the ledger as their safety rails. The MCP server is the macro-orchestration
bridge: it lets an external agent or MCP client -- Claude Desktop, Cursor, Windsurf,
Claude Code, LangChain, LlamaIndex, CrewAI, the Vercel AI SDK, an enterprise
workflow -- call a single FractalSQL primitive or agent recipe and get back a finished,
reasoned JSON result, without that external agent ever needing to know MariaDB's
`CALL proc(..., @var) / SELECT @var` stored-procedure convention, the vector-string
grammar, or `CONNECTION_ID()` session plumbing. Every tool name, argument, default and
return shape below is exactly the documented SQL surface (see the api-*.md set; this file
only adds MCP plumbing: transports, JSON-RPC framing, normalization).

The server ships in this repo under `mcp/`:

- package `fractalsql-mariadb-mcp`, version-locked to the engine release it
  was built against;
- stdio transport by default (launch it as a subprocess from your MCP client config);
  an optional HTTP transport (`--http <port>`) exists for one shared team deployment --
  it requires a Bearer token, and it either terminates TLS itself or sits behind your own
  reverse proxy (below);
- one MariaDB database per server instance; nothing about it is shared with the other
  engines' plugins.

## Quickstart

Prerequisite: this server is a **caller, not an installer**. Run
`sql/install_udf.sql` and `sql/install_agents.sql` against the target database first
(getting-started.md), and keep `fractalsqld` running -- it is a separate process that
holds every UDF body, the reasoning plugin and the enterprise ledger
(fractalsql-daemon.md). A call that reaches a stopped daemon fails immediately with a
clear error, not a hang or a crash; the MCP server passes whatever the shim ultimately
returns straight through.

Connection config, via environment or your MCP client's `env` block:

| Variable | Meaning |
|---|---|
| `MARIADB_HOST` / `MARIADB_PORT` / `MARIADB_DATABASE` / `MARIADB_USER` / `MARIADB_PASSWORD` | the MariaDB connection (ordinary) |
| `FSQLCTL_SOCKET` / `FSQLCTL_KEY` | the `fractalsqld` daemon's socket and its HMAC key file -- admin tools only |
| `FSQLCTL_CONF` | the daemon conf file's path (config introspection/read) |

Every other setting this server reads -- the HTTP transport's, the operator
switches, the session bounds, the engine's own and the audit chain's -- is
listed once, with its default, in
[Settings reference](#settings-reference) below. The HTTP transport's
authentication, protocol and session behaviour is described in
[Security](#security).

Requests whose JSON nests deeper than 128 levels are rejected with a parse error, and an HTTP request with ambiguous framing (a repeated or non-numeric `Content-Length`, or an unsupported `Transfer-Encoding`) is refused with `400`.

The server binary is the C++ build under `mcp/` (`mcp\dist\windows-mcp\fractalsql-mariadb-mcp.exe`
on Windows, `mcp/fractalsql-mariadb-mcp` on macOS/POSIX — see the mcp README for the
build/repro commands).

Claude Desktop / Cursor / Windsurf / Claude Code config (stdio; any MCP client that takes an `mcpServers` block):

```json
{
  "mcpServers": {
    "fractalsql-mariadb": {
      "command": "mcp\\dist\\windows-mcp\\fractalsql-mariadb-mcp.exe",
      "env": {
        "MARIADB_HOST": "127.0.0.1",
        "MARIADB_PORT": "3306",
        "MARIADB_DATABASE": "mydb",
        "MARIADB_USER": "fractal_analyst",
        "MARIADB_PASSWORD": "..."
      }
    }
  }
}
```

(or `mcp/fractalsql-mariadb-mcp` on macOS/POSIX, built per the mcp README).

**Other clients and frameworks.** Windsurf and Claude Code consume the
identical `mcpServers`-shaped config above unmodified, as does any other MCP
client that takes one. Frameworks that don't speak MCP's wire format natively
go through their own MCP client/adapter instead of anything bespoke here:
LangChain (`langchain-mcp-adapters`), LlamaIndex (`llama-index-tools-mcp`),
CrewAI (`MCPServerAdapter` in `crewai-tools`), and the Vercel AI SDK
(`experimental_createMCPClient`) each point their adapter at this same
binary/command the way they'd point at any other MCP server. Those adapters
are third-party and not maintained by this repo; what this project guarantees
is the standard MCP protocol surface, not any particular framework's wrapper
around it.

Sanity check: after registering, call `fractalsql_get_version` -- a healthy install
answers `{"edition": "Community", "version": "2.0.x", "daemon_version": "2.0.x"}`.

## The tools

Every tool's name is the underlying SQL symbol, unprefixed, and every
`inputSchema` mirrors that symbol's documented argument list 1:1 (defaults included).
Vector arguments are always JSON arrays of numbers (`[0.1,0.2,0.3]`) or nested arrays
for matrices/corpora; the adapter converts them to the engine's vector-string grammar
through its own parameter binding -- a client never sees `'0.1,0.2,0.3'` strings and
there is no string-concatenation SQL builder anywhere in the adapter.

Every engine-raised error is surfaced verbatim -- the clean, named `SIGNAL` text those
symbols raise is exactly what makes an agent able to self-correct a bad call.

### Discovery

| Tool | Purpose |
|---|---|
| `fractal_search` | Sniper-mode SFS convergence / inline-corpus top-k (this engine's one symbol does both: pass `corpus` for top-k, omit it for pure convergence; `{"debug":true}` in `params` gives the trajectory trace) |
| `fractal_search_debug` | The convergence view of the SFS: no corpus, no top-k, the walk's own trace on one query point -> `{dim, n_corpus, best_fit, best_point, trace:{...}}`. Pass `seed` for a byte-stable result |
| `fractal_search_explore` | Scout-mode diverse population search over an inline corpus (the anti-mode-collapse primitive) |
| `fractal_search_telemetry` | Ground-truth k-NN over a real table: `[{doc_id, dist}]`; `doc_id` is the table's single-column PK value |
| `fractal_hybrid_clinical_search` | Cohort-restricted telemetry: restrict the scan to an explicit `doc_ids` array first |
| `fractal_search_trajectory` | Drift-vector search (current - baseline). `doc_id` is a 0-indexed scan position here, not a row key |
| `fractal_cross_modal_search` | Weighted two-modality vector concatenation before the search (`alpha_weight`) |
| `fractal_diversify_enable` / `fractal_diversify_disable` / `fractal_diversify_set_params` | The session's Diversify/Repulsion layer (stateful, keyed to this connection) |
| `fractal_detect_collapse` | Current diversity quotient (null until a Diversify-aware search ran) |
| `fractal_explain_result` | `{dq, diversify_enabled, overhead_p99_us}` session diagnostics |
| `fractal_feedback_report` | Dwell/positive/negative engagement on a prior result handle -> feeds the shadow store |
| `fractal_isolate_background` | Convenience: report 'negative' with no dwell |
| `fractal_session_close` | Explicit early cleanup of this connection's session ctx (MariaDB has no on-disconnect hook) |

Worked example:

```
fractal_search_telemetry {"table_name": "documents", "vector_col": "embedding",
                          "query": [0.6,0.8,0.0], "k": 3}
-> [{"doc_id": 1, "dist": 0.0}, {"doc_id": 6, "dist": 0.0061}, ...]
```

### Cognition

| Tool | Purpose |
|---|---|
| `fractal_reason` | LLM dispatch (session plumbing is the adapter's job; you pass just `query` and optional `context`) |
| `fractal_embed` | Text -> embedding, returned as a plain JSON array of numbers |
| `fractal_text_to_sql` | NL -> one validated SQL statement; never auto-executed |
| `fractal_schema_context` | Plain-text schema description, exactly what a reasoning call gets as context (no `query_hint` parameter here) |

```
fractal_text_to_sql {"question": "top 5 customers by revenue"}
-> {"sql": "SELECT ... LIMIT 5", "error": null}
```

The generated SQL is DATA -- review it. It is never executed by this tool; execution
lives behind `fractal_sql_agent`'s explicit `auto_execute` flag (below).

### Agency -- the sixteen installable agents

`fractal_agent_anomaly_triage`, `fractal_agent_regime_triage`,
`fractal_agent_track_anomaly`, `fractal_agent_detour_classify`,
`fractal_agent_network_coverage_alert`, `fractal_agent_allocate`,
`fractal_agent_rebalance_sibling`, `fractal_agent_diverse_portfolios` (Enterprise),
`fractal_agent_route_task`, `fractal_agent_schedule_workload`,
`fractal_agent_outlier_intercept`, `fractal_agent_patient_deterioration_triage`,
`fractal_agent_data_analyst`, `fractal_agent_recall_hybrid` (no LLM),
`fractal_agent_recommend_diverse` (no LLM; leaves Diversify ENABLED for the session),
`fractal_agent_feedback_audit` (no LLM; disables it itself when done).

**Reasoning-endpoint failures inside agent calls** (partial-result
honesty, opt-in per session): this MCP layer opts every session into the
engine's `agent_partial_reasoning_fail` mode at connect (the session
key is set once per MCP session; `FSQL_MCP_AGENT_PARTIAL=off` disables
that). If the reasoning endpoint fails **after** the data step, the
tool returns the computed data half plus
`"reasoning_step_failed": "<the endpoint's error>"` with
`isError: false` instead of raising — set `FSQL_MCP_AGENT_PARTIAL=off`
to keep the engine's documented raise behavior. The error text is
bounded (a diagnostic too long to show in full ends with an explicit
`...[truncated]` marker, so a shortened message is never mistaken for
a whole one). The reasoning surface
itself (`fractal_reason`, `fractal_embed`, `fractal_text_to_sql`) is
not covered — there the reasoning call *is* the result or preempts the
data half — and an unconfigured reasoning provider always fails
loudly, in both modes.

```
fractal_agent_data_analyst {"question": "count orders per day last week", "table_names": ["orders"]}
-> {"analysis": "...", "generated_sql": "...", "result_json": {...}}
```

Which agent when? Pull the `fractalsql://agents` resource (below) for the full
decision table instead of reading sixteen descriptions.

### Agency -- the six Universal Agents

| Tool | Shape |
|---|---|
| `fractal_search_agent` | embed -> Scout -> reason over matched rows' real content -> `{answer, source_doc_ids, execution_time_ms}` |
| `fractal_rag_agent` | lighter single-turn: `{answer}` only |
| `fractal_sql_agent` | self-correcting NL->SQL with an explicit `auto_execute` flag (default false) -> `{generated_sql, execution_status, result_json}` |
| `fractal_agent_plan_explore` | MCTS-style strategy branches -> one entry per branch |
| `fractal_agent_trajectory_predict` | forecast state vs. a table's own history |
| `fractal_agent_detect_loop` | SimHash + Brent's cycle detection over a state log |

`fractal_sql_agent`'s `auto_execute` defaults to false and is NEVER defaulted for you:
pass `true` explicitly to run the generated SQL -- it executes under whatever account
this MCP server's connection was opened as. Point that connection at a
least-privilege account (below) before even considering it.

### Analytics

`fractal_dimension_dfa` (>=24 points in practice, not the documented 16),
`fractal_dimension_boxcount` (hundreds of points for a stable estimate, not 8),
`fractal_dimension_drift`, `fractal_state_fingerprint`, `fractal_cycle_detect`,
`fractal_change_point_detect`, `fractal_periodogram`,
`fractal_spectrogram_entropy`, `fractal_tda_persistence_diagram`,
`fractal_vector_lp_distance` (not a proper metric for 0<p<1 -- never substitute it
silently for cosine), `fractal_vector_quantize_int8`, `fractal_vector_quantize_binary`,
`fractal_vector_hamming_distance`, `fractal_vascular_network`,
`fractal_cortical_folding`, `fractal_nerve_plexus_metric`,
`fractal_morphological_complexity`, `fractal_optimize_portfolio`,
`fractal_optimize_portfolio_multimodal` / `_ex` / `_pareto` (Enterprise, NULL-dormant
on Community -> surfaced as a clean "enterprise tier not loaded" condition),
`fractal_optimize_subset`, `fractal_store_morphology`,
`fractal_mine_topology_negatives`.

**The canonical vector format.** `fractal_vector` (build the zero vector of a
dimension), `fractal_vector_from_text` (any vector -> canonical form) and
`fractal_vector_to_json` (any vector -> a JSON array of numbers) are the three
tools that move a vector between the engine's forms. The canonical form is a
fixed binary layout -- uint16 dimension little-endian, uint16 reserved (always
zero), then the dimension's little-endian float32 values -- carried as
**lowercase hex**: byte-stable, charset-safe, and storable in a `VARCHAR` or a
`BLOB` column (`UNHEX()` turns it back into the binary bytes). It travels as hex
rather than as a BLOB because the engine's own client protocol has no BLOB kind
to carry the raw bytes in.

```json
fractal_vector_from_text {"text": "[1,2,3]"}
-> {"value": "030000000000803f0000004000004040"}
fractal_vector_to_json {"vector": "030000000000803f0000004000004040"}
-> [1,2,3]
```

(The canonical hex is not itself JSON, so it arrives as the engine's
`{"value": "<text>"}` wrapper; a JSON-array result arrives as the array.)

Every `fractal_vector_*` function accepts the canonical form as input as well
as the JSON/CSV text form, so a stored vector round-trips through either
representation. `fractal_vector_to_json` is also the bridge to MariaDB 11.7+'s
native `VECTOR(n)` type: `VEC_FROMTEXT(fractal_vector_to_json(v))`.

### Enterprise (ledger)

`fractal_ledger_flush` / `_load` / `_verify` / `_compact` / `_reset_soft` /
`_reset_hard` / `_truth_count` / `_shadow_count`, `fractal_audit_unpack`,
`fractal_audit_log`. The write-path tools surface the clean dormant condition on
Community; `fractal_ledger_verify` is a read-only forensic query that works on every
tier. `fractal_ledger_reset_hard` empties in-memory history and carries the
destructive annotation -- a human-consent client UI asks before calling it.

### Vectorizer

`fractal_vectorizer_create`, `_pause`, `_resume`, `_drop` (irreversible ->
destructive annotation), `_enqueue` (this engine's manual per-row enqueue for rows the
triggers couldn't see), `_process_queue`. There is no background worker by design:
nothing embeds until you call `_process_queue` on your own schedule. Monitoring state
is the `fractalsql://vectorizer/status` resource.

The work queue does not grow forever: each `_process_queue` pass drops the rows that
finished over an hour ago and the rows that failed over a day ago, for that account's
own vectorizers only. The prune is best-effort -- an account without `DELETE` on the
queue simply keeps its old rows.

### Admin

| Tool | Talks to |
|---|---|
| `fractalsql_get_version` | the database (`fractal_version()`/`fractal_edition()`), plus the daemon's version when reachable |
| `fractalsql_get_config` | the database (`fractal_t2s_config()`) AND the daemon conf file -- see below |
| `fractalsql_set_config` | the daemon conf file + `fsqlctl reload` semantics |
| `fractalsql_configure_reasoning` | the daemon conf file + `fsqlctl reload` semantics |

**The two-credential-realm note (`5.2` of the design spec):** these are the only tools
in the suite that touch a process OTHER than the MariaDB connection. `fractalsqld`
listens on its own socket/named pipe and authenticates frames with its own HMAC key
file (`FSQLCTL_SOCKET` / `FSQLCTL_KEY`). MariaDB user grants govern the database
connection; the daemon key governs these admin tools. Don't conflate them.

Reload semantics carried through verbatim: provider keys (`reasoning_url`,
`embed_url`, models, think settings, `t2s_*`) reload live but apply on the tier's
NEXT call -- a reload never performs a plugin/library load itself;
`socket_path`/`hmac_key_file` are refused at reload (startup-only); the enterprise
keys (`enterprise_lib`, ledger path/key, signature posture) are refused as MCP
tool-call input at all -- enabling/disabling the enterprise tier is an operator action
against the daemon's config, not a remote call.

#### Path-shaped configuration values are refused, at both ends

Three configuration keys name a file on disk: `reasoning_plugin`,
`enterprise_lib`, `enterprise_ledger_path`. A value for any of them must be an
**absolute path with no `..` segments**. The reason is that a relative path
resolves differently depending on how the daemon was started, and a `..` segment
makes the path's meaning depend on the operator's directory tree -- so a value
that looks harmless in one working directory can name a different file in
another.

That rule is enforced in two places, and the MCP layer enforces it *before* it
writes:

- **At the daemon, at config load and reload.** The daemon validates the
  provider settings when it reads `fractalsqld.conf` (at startup) and again on
  every reload. A rejected value refuses the whole reload -- the daemon's log
  names the key and the rule (`provider key reasoning_plugin: must be an
  absolute path with no '..' segments`), and the client's reply is
  `reload failed: provider settings rejected (see the daemon log)`. The
  running configuration is left untouched.
- **At this MCP layer, before the write.** `fractalsql_set_config` checks the
  value first and refuses it with a `schema` error class and this message:

  ```
  'reasoning_plugin' must be an absolute path with no '..' segments (the daemon
  refuses such a path at load/reload time as well -- a relative path resolves
  differently depending on how the daemon was started, and a '..' segment makes
  the path's meaning depend on the operator's directory tree)
  ```

  The refusal happens before the conf file is touched, so a rejected value
  leaves the file byte-identical. The daemon's own check is the backstop for
  edits made outside this tool (a hand-edited conf file, `fsqlctl`).

  Of the three path keys, `reasoning_plugin` is the only one this tool can
  write at all: `enterprise_lib` and `enterprise_ledger_path` are
  operator-only (enabling or relocating the enterprise tier is an operator
  action against the daemon's config, never a remote call), so they are
  refused as tool input before the path rule is even reached. The daemon's
  check covers all three.

#### The per-session configuration overlay

The daemon's config file is process-wide: changing it means a filesystem edit
plus a reload, which is the right shape for an operator and the wrong shape for
a session that wants one knob changed for its own work. Five tools give a
**connection** a live, per-session override of the tuning keys, layered over
the daemon-wide values:

| Tool | Effect |
|---|---|
| `fractalsql_session_config_set` | sets ONE key for THIS connection -> `{ok:true}` or `{ok:false, reason:"..."}` |
| `fractalsql_session_config_get` | reads one key's EFFECTIVE value for this connection (its own override, else the daemon-wide one) |
| `fractalsql_session_config_reset` | drops every override this connection holds -> `{dropped:N}` |
| `fractalsql_session_config_list` | the connection's own overrides, as a JSON object |
| `fractalsql_session_config_keys` | every key the engine knows, as `{name, type, session_overridable}` objects -- so a caller can discover the knobs instead of hard-coding them |

A session may change the **tuning** keys and nothing else:
`reasoning_model`, `embed_model`, `think`, `think_num_ctx`, `t2s_max_attempts`,
`t2s_use_review`. The refusal is decided **by the engine**, by name, with the
reason -- this layer never decides what is allowed, it only reports the
refusal. The key is checked before the value, so the refusal always names the
key:

```
'reasoning_plugin' is a daemon-wide setting and cannot be changed by a session;
edit fractalsqld.conf and run `fsqlctl reload`
```

The keys a session may NOT change are refused because they would let one
connection re-point the shared daemon:

| Key | Why it is refused |
|---|---|
| `reasoning_plugin`, `enterprise_lib`, `enterprise_ledger_path` | which code the daemon loads -- a session that could name its own `.so` would run attacker-chosen code as the daemon |
| `reasoning_url`, `embed_url`, `think_native_url` | where the daemon's outbound traffic (and its bearer token) goes -- a session that could re-point the URL could exfiltrate the operator's token |
| `reasoning_token`, `enterprise_ledger_key` | the operator's own credentials -- a session never reads or replaces them |
| `reasoning_allow_plaintext`, `enterprise_require_signature` | transport-posture flags the operator set deliberately |
| `think_provider`, `t2s_allowed_statements` | routing and capability widening |

A secret's value is never returned: `fractalsql_session_config_get` reports
`'<redacted>'` when it is configured and `'<unset>'` when it is not.

**The `value` field is always a string.** A configuration value is text in the
config file and text in the overlay, so `"value"` is a STRING on every read (or
`null` when the key is not set) -- a value that happens to read as a number
(`"8192"`) comes back as the string `"8192"`, not as the number `8192`. A
client therefore never has to handle two shapes of the same field.

**The read path refuses the enterprise tier's keys by name.**
`fractalsql_session_config_get` refuses `enterprise_lib`,
`enterprise_ledger_path`, `enterprise_ledger_key` and
`enterprise_require_signature` with an "operator territory" error, even though
the engine's SQL surface will hand the effective value of every non-secret key
to anyone who can run a `SELECT`. That asymmetry is deliberate: the SQL surface
is a full-power database surface and is not a boundary, while this is an
agent-facing surface, where the enterprise tier's posture is the operator's to
read and to change -- against the daemon's own config, in person. The refusal
is consistent across both configuration surfaces of this plugin (the conf-file
tools refuse the same keys as tool input), so a caller does not have to learn
two different rules.

**Honest limitation.** The model and THINK overrides are applied to the
process environment the reasoning plugin reads, and the reasoning plugin reads
its own configuration when it is LOADED (the bridge env vars are baked into the
loaded context). So those overrides take effect for a tier that loads the plugin
AFTER the override is set -- a fresh tier, or the next reload -- rather than
mid-flight on an already-loaded plugin. `t2s_max_attempts` and `t2s_use_review`
are read by the engine on every call, so those two take effect immediately.

### Which tools reach outside the database (`openWorldHint`)

`openWorldHint` is set **per tool**, and it means exactly one thing: *this
call reaches an entity outside this database* -- a chat-LLM or an
embedding-provider dispatch. It is not a tier-wide flag, and it is not a
"this tool is complicated" flag.

The tools that carry it:

- the cognition tier's three provider dispatches -- `fractal_reason`,
  `fractal_embed`, `fractal_text_to_sql`;
- `fractal_search_agent`, `fractal_rag_agent`, `fractal_sql_agent`;
- the thirteen reasoning agents (`fractal_agent_allocate`,
  `fractal_agent_anomaly_triage`, `fractal_agent_data_analyst`,
  `fractal_agent_detour_classify`, `fractal_agent_diverse_portfolios`,
  `fractal_agent_network_coverage_alert`, `fractal_agent_outlier_intercept`,
  `fractal_agent_patient_deterioration_triage`,
  `fractal_agent_rebalance_sibling`, `fractal_agent_regime_triage`,
  `fractal_agent_route_task`, `fractal_agent_schedule_workload`,
  `fractal_agent_track_anomaly`);
- `fractal_agent_plan_explore` -- it dispatches no reasoning step, but the
  procedure embeds the caller's own `initial_state` label through the
  configured embedding provider before it explores the strategy table, so the
  call crosses the provider boundary. It carries `openWorldHint` but **not**
  `secretHint`: an embedded label is the caller's own data, not a credential.

The tools that do NOT carry it are the ones that only read and compute
inside this database: `fractal_agent_recall_hybrid`,
`fractal_agent_recommend_diverse`, `fractal_agent_feedback_audit`,
`fractal_agent_trajectory_predict`, `fractal_agent_detect_loop`, and
`fractal_schema_context`. The admin tools do not carry it either: they talk
to `fractalsqld`, which is a **local** process on the same host with its own
HMAC-authenticated boundary -- that boundary is described in the tool text,
but it is not an external provider, so the hint stays off. A client that
gates "this may leave the world" should not have to ask a human about a
local vector recall or a local config read.

The same five columns (`destructive`, `readOnly`, `idempotent`, `openWorld`,
`secret`) are pinned in `mcp/.mcp-safety-annotations-lock`, and the server
refuses to start when the registered surface disagrees with that lock -- so a
flip in either direction fails a gate rather than shipping silently.

With `FSQL_MCP_READ_ONLY=true` the server also calls `fractal_lock_destructive` on
its own connection id when it connects: a one-way latch after which the engine
refuses `fractal_ledger_flush`, `_compact`, `_reset_soft` and `_reset_hard` for that
id, so a mis-annotated tool cannot wipe the ledger either. It is keyed by session
id and does not stop a caller that passes a different one; see
[enterprise.md](enterprise.md) for the limit.

Every tool sends all four standard hints (`readOnlyHint`, `destructiveHint`,
`idempotentHint`, `openWorldHint`) explicitly, true or false. In the MCP spec
an omitted `destructiveHint` or `openWorldHint` defaults to true, so leaving a
false one out would make a closed-world, non-destructive tool look destructive
and open-world to a spec-following client. A tool nobody classified is
destructive by default, and `mcp/tests/mcp_smoke_client.py` checks every served
tool against a hand-maintained table (`EXPECTED_SAFETY`): a new tool must be
classified there by a person, which regenerating the safety lock alone does not
force.

### Idempotence follows the read-only posture

`idempotentHint` means "calling this again with the same arguments has no
additional effect". It is **derived**, not declared tool by tool, and it
follows `readOnlyHint`: a read touches nothing, so repeating it changes
nothing. The only exceptions are the two session-state tools --
`fractal_diversify_enable` and `fractal_diversify_disable` -- which are
idempotent without being read-only (enabling twice leaves Diversify on;
disabling twice leaves it off).

The consequence worth knowing: **none of the 20 provider-crossing tools is
idempotent.** Repeating one re-dispatches the chat-LLM or the embedding
call, so a client that honours the hint will not silently re-issue a paid
call after a timeout. That is the same rule the `no-retry` retry tier
states -- the retry decision stays the caller's.

The read-only posture itself is worth stating, because two of the closed-world
agents are not read-only at all:

- `fractal_agent_recommend_diverse` and `fractal_agent_feedback_audit` are
  **not** read-only. Both drive this session's Diversify layer (enable, set
  parameters, disable), so they change session state -- which their own
  descriptions and their `stateful` retry tier both say.
- `fractal_agent_detect_loop` (a pure computation over the caller's own
  state log), `fractal_agent_trajectory_predict` and `fractal_schema_context`
  (plain reads) **are** read-only.

## The procedure-based tool surface, and where the config actually lives

This section is the shape of the thing itself: what an MCP tool call
physically does, and which process owns the settings that decide whether it
works. It is here because the tool table above reads like a list of
functions, and the operational questions that follow -- "why did my
`fractal_reason` call fail", "which file do I edit to change the model",
"do I have to restart something" -- have answers that depend on this shape.

### The call path

An MCP tool call is **not** an in-process extension call. It travels:

```
MCP client  --JSON-RPC over stdio-->  fractalsql-mariadb-mcp
                                          |  (ordinary MariaDB client
                                          |   connection, driver-bound
                                          |   parameters)
                                          v
                                    MariaDB server
                                          |  the UDFs are a GPL shim
                                          |   loaded by mariadbd
                                          v
                                    fractalsqld  (the daemon)
                                          |  holds the core, the reasoning
                                          |   plugin and the ledger
                                          v
                                    the reasoning endpoint
```

Three consequences fall out of that shape, and they explain most of what
surprises people:

- **The MCP server is an ordinary database client.** It has no special
  privilege. It connects as the account named by `MARIADB_USER`, so
  everything it can do, a `SELECT` from that account can do too. That is
  the whole of its authorization model -- see the least-privilege note
  under Operational notes.
- **The tool's work happens in the daemon, not in the server.** The
  MariaDB server holds a shim, not the engine. The shim forwards each
  UDF call over its own socket to `fractalsqld`, which runs the body. A
  tool call therefore needs the daemon up even when the database is
  perfectly healthy.
- **The settings that make a call succeed live in the daemon's config
  file**, not in the database and not in the MCP server's environment.
  That is the next subsection.

### The daemon-side config model

`fractalsqld.conf` is a flat `key = value` file, one per line, `#` for
comments. The daemon reads it at startup and re-reads it on a reload
request. The full key table -- the two required ones (`socket_path`,
`hmac_key_file`) plus the provider and text-to-SQL keys -- is in
[fractalsql-daemon.md](fractalsql-daemon.md#provider-keys); the two files'
split is worth restating here, because it is the part that is easy to get
wrong:

| File | Read by | Holds |
|---|---|---|
| `fractalsql.conf` | the shim `mariadbd` loads | `socket_path` + `hmac_key_file` only -- how to reach the daemon |
| `fractalsqld.conf` | `fractalsqld` | everything else -- which plugin, which endpoint, which model, which ledger |

**Precedence is per key, and it is not sticky.** A key present in
`fractalsqld.conf` wins. A key *absent* from it falls back to the
daemon's own boot-time process environment (the `FRACTALSQL_*` / `FSQL_*`
names the tiers have always read), captured once at startup. If the
environment was silent too, the setting is simply unset. Deleting a key
from the file and reloading therefore takes its value back out -- that is
what makes a token or endpoint rotation complete, with no leftover
last-applied value.

**A live reload is `fsqlctl reload`.** The daemon re-reads the file and
pushes the values down to the tiers that consume them. The swap is
all-or-nothing: an unparseable file, an out-of-range value, or a change
to a startup-only key is refused and the running configuration stays in
effect. All 18 provider keys reload live, but the pushed value reaches
its consumer on that tier's **next call** -- a reload never performs a
plugin or library load itself, so a changed `reasoning_plugin` path
surfaces at that next call, with the path named in the daemon log.

Three keys are deliberately *not* live-reloadable:

- `socket_path` and `hmac_key_file` are read once by clients; applying
  them live would strand every running `mariadbd`. Restart the daemon.
- `enterprise_lib` cannot change while an enterprise library is already
  loaded (its resolved symbols have no replace path). The reload is
  refused, naming the loaded library; restart instead. A change made
  while nothing is loaded is fine and re-arms the load attempt.
- The reasoning plugin's own lower-level knobs -- `FSQL_REASONING_HTTP_RESPONSE_MODE`
  and its siblings -- are environment-only, with **no** conf key. They
  are read once when the plugin context loads and baked into it for that
  context's lifetime, so they need a daemon restart with a new
  environment. See [reasoning-setup.md](reasoning-setup.md#response-modes).

The MCP admin tools drive exactly this channel: `fractalsql_set_config`
and `fractalsql_configure_reasoning` write the conf file and then
request a reload, and their result says which of the two happened --
`"reloaded": true`, or `"reloaded": false` with the daemon's own refusal
reason, in which case the file edit is intact for a restart instead.

### What the tiers actually are

The provider surface is not a bag of unrelated settings; it is a small
number of tiers, each with its own consumer, its own validation, and its
own reload behavior. The bitmask that tracks which of them are present
in a conf snapshot is `src/fractalsql_provider.h`'s `FSQL_PROV_*` set --
one bit per key, grouped by tier:

| Tier | Keys | `FSQL_PROV_*` bits |
|---|---|---|
| Reasoning | `reasoning_plugin`, `reasoning_url`, `reasoning_token`, `reasoning_model`, `reasoning_allow_plaintext` | `REASONING_PLUGIN`, `REASONING_URL`, `REASONING_TOKEN`, `REASONING_MODEL`, `REASONING_PLAINTEXT` |
| Embedding | `embed_url`, `embed_model` | `EMBED_URL`, `EMBED_MODEL` |
| THINK | `think`, `think_provider`, `think_native_url`, `think_num_ctx` | `THINK`, `THINK_PROVIDER`, `NATIVE_URL`, `NUM_CTX` |
| Text-to-SQL | `t2s_max_attempts`, `t2s_allowed_statements`, `t2s_use_review` | `T2S_MAX_ATTEMPTS`, `T2S_ALLOWED`, `T2S_USE_REVIEW` |
| Enterprise | `enterprise_lib`, `enterprise_ledger_path`, `enterprise_ledger_key`, `enterprise_require_signature` | `ENT_LIB`, `ENT_LEDGER_PATH`, `ENT_LEDGER_KEY`, `ENT_REQUIRE_SIG` |

Each tier implements the same two-entry-point contract, one pair per
consumer (`fractalsql_cognition_*`, `fractalsql_textsql_*`,
`fractalsql_enterprise_*`):

- `check_provider` is read-only validation. It answers the
  cross-state questions the daemon cannot know -- chiefly, that an
  enterprise library which is already loaded cannot be swapped. A
  failure here refuses the whole reload, with a one-line reason.
- `apply_provider` performs the swap, under the consumer's own dispatch
  lock, with full rollback on allocation failure: nothing is ever
  half-applied. It never `dlopen`s anything and performs no I/O, so it
  cannot hang the reload -- a new plugin or library path surfaces on
  that tier's next call instead.

The practical upshot for an MCP operator: **edit the conf file, reload,
and expect the change to take effect on the next call of the tier you
changed** -- not on the next tool call of any kind, and not necessarily
on the next call of any kind if the tier you changed is not the one the
next tool exercises.

### Which tier a tool touches

The tool table above maps onto the tiers directly, and the mapping is
what makes a failure diagnosable:

| Tools | Tier | What has to be right |
|---|---|---|
| `fractal_search`, `fractal_search_debug`, `fractal_search_explore`, the telemetry/hybrid/trajectory searches | Discovery | nothing but the daemon being up -- no model, no endpoint |
| `fractal_reason` | Reasoning | `reasoning_plugin` + `reasoning_url` (+ model) |
| `fractal_embed` | Embedding | `embed_url` (+ model) |
| `fractal_text_to_sql` | Text-to-SQL | the reasoning tier, plus the `t2s_*` knobs |
| the `fractal_agent_*` tools | Agency | the reasoning tier (except the ones documented as LLM-free), and the enterprise tier for the gated ones |
| `fractal_ledger_*`, `fractal_audit_*` | Enterprise | `enterprise_lib` (+ ledger path/key) |
| `fractal_vectorizer_*` | Vectorizer | the embedding tier, when the queue is processed |

The discovery tools are the ones that work with no model pulled and no
endpoint configured -- which is why they are the right first probe when
you are checking that a deployment is wired up at all.

### Diagnosing a call that fails

The error text names the missing piece, because the tiers report their
own configuration gaps rather than failing generically. A reasoning call
with no plugin configured says so by name and points at the key to set;
an embedding call with no endpoint does the same. So the first move on
any such failure is to read the message, then look up the key it names
in the provider-key table above.

Two things are worth knowing before you go looking:

- **The MCP server's environment is not the daemon's environment.** The
  MCP server's `MARIADB_*` variables decide how it connects; the daemon's
  `FRACTALSQL_*` / `FSQL_*` variables (and `fractalsqld.conf`) decide
  what a call can do. Setting a provider variable in the MCP client's
  `env` block has no effect on the tier.
- **A stopped daemon is a fast, clear failure, not a hang.** The
  shim's own error surfaces immediately; it is not a timeout. If a call
  fails with a connectivity-class error mentioning the daemon, check the
  daemon's health before suspecting the database.
- **A path-shaped config value is refused before it is written.** If
  `fractalsql_set_config` returns a `schema` error naming
  `'reasoning_plugin'` (or `enterprise_lib`, `enterprise_ledger_path`),
  the value was not an absolute path with no `..` segments. The conf
  file is untouched -- the refusal happens before the write. See the
  Admin section above for the full rule.

## Resources

| URI | Contents |
|---|---|
| `fractalsql://schema` | live `fractal_schema_context` output (all visible tables) |
| `fractalsql://config` | the resolved non-secret config surface (edition/version, t2s knobs, daemon conf minus secrets) |
| `fractalsql://ledger/{kind}` | `fractal_ledger_verify(kind)`'s audit report (1 = QTL chain, 2 = decision-audit chain) |
| `fractalsql://vectorizer/status` | the vectorizer status view's rows |
| `fractalsql://agents` | the "which agent should I use" decision table |

## Prompts

`incident_triage`, `portfolio_rebalance`, `patient_triage`, `fleet_detour_check`,
`track_anomaly_check`, `sensor_grid_health`, `churn_recovery`, `ask_my_data`,
`safe_sql_question`, `diversity_audit`, `ciso_ledger_check`. Each prompt names the
tools it will run and in what order; the execution-capable ones state the
least-privilege and allowed-statements warnings inline.

## Operational notes

- **doc_id semantics**: table-backed searches return the row's real PK value (stable
  under UPDATE). `fractal_search_trajectory`/`fractal_cross_modal_search` return a
  0-indexed scan position. Give `fractal_feedback_report` the PK-valued handle.
- **Session isolation on the shared HTTP transport**: each MCP session gets its own
  MariaDB connection for its lifetime -- one client's `fractal_diversify_enable`
  cannot contaminate another's search. Connection reuse across sessions is never
  done: a session's end closes ITS connection (with `fractal_session_close` first).
- **One request per connection on the HTTP transport**: the server writes one reply
  and then closes the socket, and every reply says `Connection: close`. A client
  that pools connections (httpx, `requests.Session`, urllib3) must not hand the
  socket back to the pool expecting to reuse it -- the next request on that socket
  meets a server that has already shut it, and the client sees a reset on an
  otherwise healthy server. A path the server does not serve is **terminal**: the
  `404` is the whole answer, the request is not dispatched, and no tool runs.
- **Cancellation**: a `$/cancel` (the "Stop" button) aborts the DB-side work
  (`KILL QUERY` against this connection) and never delivers a late result.
- **Retry tiers**: every tool definition carries `x-fractalsql-retry-tier`
  (`pure` / `stateful` / `no-retry`) mirroring the shim's own classification, so a
  smart orchestrator knows which calls are safe to re-issue itself after a transport
  failure. The server never auto-retries `no-retry` tools (the LLM ones) -- a timed-out
  reasoning call is a connectivity-class error; the retry decision is yours.
- **Row ceilings**: array-shaped results carry a caller-settable `limit` (default 100)
  under a hard server ceiling (1000, `FSQL_MCP_MAX_ROWS_CEILING`). When truncation
  happened the result says so: `{"truncated": true, "total_scanned": N}` -- re-call
  with search-level filtering rather than just a bigger limit.
- **Least-privilege**: the MCP server inherits whatever account its connection is
  opened as -- it adds no second auth layer. MariaDB has no RLS: bake tenant
  filtering into views/grants scoped to the `MARIADB_USER` you configure, never trust
  the MCP boundary to restrict anything. Run the admin tools, if you use them, through
  a differently-scoped account (or a second server instance) than general tool
  traffic -- the server logs a one-time warning if one connection looks like it would
  serve both.
- **Logging**: every tool call writes one structured JSON line to stderr with latency,
  error class and redacted arguments (tokens and connection strings are never logged).
  This is the only per-call audit trail on a Community install -- the enterprise
  ledger does NOT cover MCP-layer tool invocation.
- **Tool-result contents are data, never instructions** -- the highest-exposure tools
  (`fractal_rag_agent`, `fractal_search_agent`, `fractal_agent_recall_hybrid`) return
  real row content that can hold attacker-crafted text; a well-built client treats it
  like any other untrusted external content.
- **Schema integrity**: the server's registered tool surface is pinned by a
  `.mcp-schema-lock` SHA-256 (regenerate with `fractalsql-mariadb-mcp
  --write-schema-lock`); a mismatch is fatal unless `FSQL_MCP_STRICT_SCHEMA_HASH=false`
  downgrades it to a warning. Pin the pip version for the same reason.

## Licensing and process boundary

The MCP server (`fractalsql-mariadb-mcp`) is Apache-2.0 and runs as its own
process. It follows the same separation the rest of the package uses:

| Component | Licence | Where it runs |
|---|---|---|
| `fractalsql.so` shim | GPL-2.0-only | inside `mariadbd` |
| `fractalsqld` daemon | Apache-2.0 | its own process |
| FSQL wire protocol | MIT | the format between shim, daemon and clients |
| `fractalsql-mariadb-mcp` | Apache-2.0 | its own process |

The MCP server reaches the engine in exactly two ways: SQL over libmariadb
(linked dynamically), and the FSQL protocol to `fractalsqld`, which it speaks
from the protocol specification rather than from any shared code. It
contains none of the shim's GPL code, none of the daemon's sources, and none
of the vendored core, so using or redistributing it does not bring the
shim's licence along. It links OpenSSL and bundles nlohmann/json (MIT).
Every source file carries its SPDX tag, and `make -C service scan` fails if
the MCP tree includes a shim, daemon or core header, links against them, or
contains a file that is not Apache-2.0.

## Security

- **stdio** needs no credential: the client spawns the server as a trusted
  subprocess and owns its lifetime. **HTTP** is different -- it is a shared
  surface, so a bearer token is required there and the transport refuses to
  serve without one.
- **TLS**: the HTTP transport can terminate TLS itself
  (`FSQL_MCP_HTTP_TLS=true` with `FSQL_MCP_TLS_CERT` and `FSQL_MCP_TLS_KEY`,
  PEM, TLS 1.2 or newer), or sit behind a reverse proxy that terminates it
  in front while the server stays on loopback. A bind on a non-loopback
  address without TLS is refused at startup -- the bearer token and every
  result would travel in clear text -- unless
  `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` is set. A certificate that will not
  load, a key that will not parse, and a certificate and key that do not
  belong together are all hard startup failures: the process exits having
  listened on nothing and never falls back to plaintext.
- **Supply chain**: the tool surface is pinned by the committed
  `.mcp-schema-lock` and the safety annotations by
  `.mcp-safety-annotations-lock`; a mismatch is a startup failure unless
  `FSQL_MCP_STRICT_SCHEMA_HASH=false` downgrades the schema one to a
  warning. Regenerate with `--write-schema-lock` and
  `--write-safety-annotations-lock` and commit the result with the change
  that moved the surface.
- **Least privilege**: the server inherits whatever the MariaDB account it
  connects as can do, and adds no second auth layer on the database side.
  The daemon's own HMAC key (`FSQLCTL_KEY`) is a separate credential, for
  the admin tools alone.

### Authentication

On the HTTP transport a bearer token is the credential, and there are two
ways to hold one.

**The deployment token.** `FSQL_MCP_AUTH_TOKEN` (or
`FSQL_MCP_AUTH_TOKEN_FILE`, hot-reloaded on mtime change so a secrets
manager can rotate it in place without a restart) is one secret for the
whole deployment. Every holder of it is the same identity.

**Per-client credentials.** `FSQL_MCP_TOKEN_POLICY_FILE` points at a JSON
file that names clients, so each caller can be revoked on its own and can be
given its own tool allowlist:

```json
{
  "tokens": [
    { "name": "analyst", "sha256": "<hex sha256 of that client's token>",
      "tools": ["fractal_search", "fractal_agent_data_analyst"],
      "expires": "2027-01-31T00:00:00Z" },
    { "name": "batch", "sha256": "<hex sha256>", "tools": "*" }
  ]
}
```

The file holds the SHA-256 of each token, never the token itself, so it is
safe to keep in a repository or a config store. A client that presents its
own token *is* that client: its name is how the server tells that client
apart, and in the modern era that name is also the key its calls are
scheduled under, so one client cannot take the whole expensive-call
budget. Its allowlist bounds what it can call -- a tool outside the list is
not even listed back to it. `expires` is optional and is an ISO-8601 date
or date-time; an expired credential is refused. `tools` is either `"*"` or
a list of tool names.

A policy file that cannot be read or parsed is a **startup failure**: the
server exits with status 2 and names the problem, because an operator who
asked for named clients would otherwise get an open server. A *replacement*
file that turns malformed later, while the server is running, is different:
the last good policy stays in force and the error is reported, so a typo
never widens access.

What the server does with a request, in the order it decides:

| Situation | Answer |
| --- | --- |
| A repeated `Content-Length`, a non-numeric one, an unsupported `Transfer-Encoding`, or both `Content-Length` and `Transfer-Encoding` | `400` -- the framing is ambiguous and is never resolved in favor of one reading |
| `GET /healthz` and `GET /readyz` | served without a token (probes need orchestrator access without a credential baked into a healthcheck command); the JSON-RPC path is never exempt |
| A path the server does not serve | `404` -- **before** the token check. The 404 IS the answer, the request is not dispatched, and no tool runs. That ordering is a deliberate trade: a misconfigured client gets a clear "wrong path" instead of a misleading `401`, and the only thing an unauthenticated caller learns from it is which path the JSON-RPC endpoint is on (`/healthz` already says that) |
| A browser `Origin` header that is not on `FSQL_MCP_ALLOWED_ORIGINS` | `403`, also **before** the token, so an unapproved origin never reaches the credential check |
| No credential presented | `401` with `WWW-Authenticate: Bearer realm="fractalsql-mcp"` |
| A credential that was presented but is wrong, expired, or unknown | `401` with `WWW-Authenticate: Bearer realm="fractalsql-mcp", error="invalid_token"` |
| A token in the query string instead of the `Authorization` header | `401` -- the header is the only place a credential is read from, because a query string lands in proxy logs and access logs |
| A chunked request body | `411` -- send a `Content-Length` instead |
| A declared `Content-Length` over 32 MB | `413` |
| `GET` or `DELETE` on a modern-era request | `405` -- the modern era has no GET stream and no protocol session to tear down |

Repeated failed authentications are slowed down (the wait grows with the
number of consecutive failures, capped at two seconds, and a success pays
one failure back), so a stolen-token guessing attempt is not free. The
comparison itself is constant-time, and no token is ever written to a log
line.

The origin check applies to a browser-driven client only: a request that
carries no `Origin` header is not a browser request and is let through, and
a loopback origin is always allowed. `FSQL_MCP_ALLOWED_ORIGINS` is a
comma-separated list of the extra origins to allow.

There is no request-signing scheme, and that is deliberate: a standard MCP
client cannot sign its requests, so making a signature mandatory would
break every client while a *replay* of a captured request stays possible
either way. The controls that do work are the ones a deployment can
actually operate: a token that can be rotated without downtime, credentials
that can expire, credentials that can be revoked one client at a time, and
per-client allowlists that bound what a leaked token can reach.

### Protocol versions

The server speaks both protocol eras at once, and the era a call arrived
in is on the operator's log line for that call.

**The legacy era** is the handshake-based one: `initialize` first, an
`Mcp-Session-Id` for the calls that follow, and the protocol revision
carried in the handshake. The server speaks five revisions --
`2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25` and `2026-07-28` --
and the handshake echoes back the revision the client asked for when it
recognises it, and `2025-06-18` when the client names none.

**The modern era** is the stateless one: every request carries its own
metadata, and there is no protocol session at all. A modern request must
name one of the two modern revisions (`2025-11-25` or `2026-07-28`), must
carry three headers -- `MCP-Protocol-Version`, `Mcp-Method`, and, for the
methods that address something by name (`tools/call`, `prompts/get`,
`resources/read`), `Mcp-Name` -- and the headers must agree with the body,
which carries the same revision in its metadata
(`_meta.io.modelcontextprotocol/protocolVersion`):

| Mismatch | Answer |
| --- | --- |
| A required header is missing, or a header disagrees with the body | `-32020` (HeaderMismatch), HTTP `400` |
| The revision is not one the modern era serves | `-32022` (UnsupportedProtocolVersionError), HTTP `400`, with `data.supported` (the revisions served) and `data.requested` (the one asked for) |
| A method this server does not have | `-32601`, HTTP `404` |

The modern era also adds the discovery method `server/discover`, which
returns every revision this server speaks (all five, legacy and modern
alike) together with the server's name, version and capabilities. Every
modern result carries `resultType` (`complete`), and a list result also
carries `ttlMs` (`0`) and `cacheScope` (`session`).

`FSQL_MCP_PROTOCOL_ERA` chooses what is served: `dual` (the default)
serves both, `modern` serves the modern era only and refuses the legacy
handshake outright (answering `-32000` and naming the revisions it
speaks). The tools, the arguments and the results are the same in both
eras; only the framing differs.

### Session state

Two kinds of server-side state exist, and both are bounded.

A **protocol session** is the legacy era's `Mcp-Session-Id`. It owns one
MariaDB connection for its lifetime, so one client's
`fractal_diversify_enable` cannot contaminate another's search, and it
ends with `fractal_session_close`, with a `DELETE` on the MCP path, or
with the session's own idle timeout.

A **context handle** is the modern era's `context_id`: an opaque hex
string the server mints. A caller that passes no handle gets one back in
the result; a caller that passes one back keeps using the same engine
state. The handle is bound to the credential that created it: a different
token is told the handle does not exist, so a client can neither use nor
probe for a handle it does not own. In the legacy era the session header
supplies the context, and a `context_id` that names a different context is
refused rather than silently served on the session's own state.

| Setting | Default | What it bounds |
| --- | --- | --- |
| `FSQL_MCP_SESSION_TTL_SECS` | 3600 | How long an idle session or handle survives. |
| `FSQL_MCP_MAX_SESSIONS` | 64 | How many exist at once. |

Expired state is dropped together with the database connections behind it,
so neither the registry nor the connections behind it can grow without
bound; a request that would exceed the cap is answered `503` ("too many
open MCP sessions") rather than queued.

### Data at rest

The audit chain lives in a **file** the enterprise tier owns, not in the
database: `enterprise_ledger_path` in `fractalsqld.conf` names it (the
default is `fractalsql_ledger.dat`, relative to the daemon's working
directory), and the chain is a hash-linked append-only log, one record per
entry, each record carrying the hash of the one before it.

**The chain file is owner-only.** The chain file, its CSV mirror
(`<ledger>.csv`) and the head file (`<ledger>.head`) are all created with
mode `0600` -- read and write for its owner and nobody else -- and
tightened again on every open, so a file left behind by an older build
keeps no wider permissions. Give the files the same protection as the data
they hold, and encryption at rest on the volume when the data warrants it.

**The head file sits beside it and says how long the chain was.**
`<ledger>.head` holds, per chain kind, the number of records that were
ever appended to that kind. A hash chain cannot show that its newest
records were cut off the end -- nothing follows the last record to
disagree with it -- and the counter lives outside the chain, so a
truncation cannot pull it down and hide itself. Each head record carries
an HMAC-SHA256 MAC over its own content, keyed with the enterprise ledger
key, so a counter that has been edited is detected rather than trusted.
The head file is replaced atomically, so a reader never sees a
half-written record.

Verification names the failure rather than collapsing it into one "bad
chain" answer:

| What `fractal_ledger_verify` found | What it says |
| --- | --- |
| The head record has no MAC | it was written before the ledger key was set |
| The head record's MAC does not match its contents | the head was edited by hand |
| The head file will not parse | it is corrupt, or was edited by hand |
| The chain holds fewer rows than the head recorded | rows were removed, or the ledger was replaced |

**The head can be published to a log you control.** With
`FSQL_LEDGER_ANCHOR_LOG=stderr` (or `syslog` where the platform has one)
the daemon emits one JSON line on every append:

```json
{"event":"ledger_head","kind":2,"rows":17,"hash":"<hex of the newest entry hash>"}
```

`kind` is the chain, `rows` is how many records that chain has ever held,
and `hash` is the newest entry hash. A chain whose tail was deleted no
longer matches the last line published, so a truncation is visible from
the log even though it is invisible from the file alone. Nothing is
published while the anchor log is off.

**The text of an audit entry can be redacted.** The question an agent was
asked, the SQL it generated, the analysis it wrote and the rows it read can
all carry customer data. `FSQL_AUDIT_REDACT` decides what the chain
keeps:

| `FSQL_AUDIT_REDACT` | What is stored |
| --- | --- |
| `none` (default) | The text, as it is. |
| `hash` | `sha256:<hex> len=<bytes>` -- the fingerprint of the text and its length, so equal texts stay comparable and the length is known, but the text is not. |
| `truncate` | The first 64 characters of the text. |

Redaction reaches the fields nested inside the entry as well as the entry
itself, and leaves everything else alone: identifiers, counts, statuses
and the attribution block are stored as they are. The values returned to
the caller are never redacted -- the agent still answers with the real
question, the real SQL and the real analysis; only what is persisted
changes.

**The chain is bounded by size.** The ledger is append-only, so it is
capped rather than rotated: `FRACTALSQL_LEDGER_MAX_BYTES` (default 1 GiB;
`0` for unbounded) is the size past which appends are refused. The
operator archives the file and starts a new chain.

**A reasoning plugin has to be verified.** A native plugin is loaded only
if its detached `.sig` is a valid Ed25519 signature, or its SHA-256
matches `FRACTALSQL_REASONING_PLUGIN_SHA256` (64 hex digits). A plugin
with neither is refused. `FRACTALSQL_REASONING_ALLOW_UNVERIFIED` is the
operator's explicit opt-out of that check; set it only when you have
another way to establish what you are loading.

**What else is stored, and where.**

| What | Where |
| --- | --- |
| The audit chain entries (QTL truth/shadow blobs on kind 1, decision-audit JSON on kind 2) | the ledger file the enterprise tier owns, named by `enterprise_ledger_path` |
| A SQL-queryable view of the same records | the CSV mirror beside it, `<ledger>.csv` -- the CONNECT engine table `fractalsql_ledger` reads it, and that table's `FILE_NAME` is set separately, so point it at the mirror you actually want |
| The chain head (record counts and their MACs) | `<ledger>.head`, beside the chain file |
| The bearer token / per-client credential file | a file on the MCP server's host -- the file you point `FSQL_MCP_AUTH_TOKEN_FILE` or `FSQL_MCP_TOKEN_POLICY_FILE` at |
| The engine's configuration, including the ledger key | `fractalsqld.conf`, which the daemon refuses to start or reload with while it is readable by other accounts |
| Your own tables, and the row content the tools return | your MariaDB database, under the account's grants |
| The MCP server's own request log | stderr, one JSON line per tool call, secret-sanitized |
| The vectorizer work queue | the `fractal_vectorizer_queue` table; each time the queue is processed the engine drops finished rows after an hour and failed rows after a day, for that account's own vectorizers |

## Settings reference

Every setting this server reads, with its default.

**Connecting to the database.**

| Setting | Default | Meaning |
| --- | --- | --- |
| `MARIADB_HOST` | `127.0.0.1` | the MariaDB server |
| `MARIADB_PORT` | `3306` | its port |
| `MARIADB_DATABASE` | -- | the database to open |
| `MARIADB_USER` | `root` | the account; the server inherits whatever rights it has |
| `MARIADB_PASSWORD` | -- | that account's password |
| `FSQLCTL_SOCKET` | -- | the `fractalsqld` daemon's socket (a Unix socket path or `\\.\pipe\<name>`) -- the admin tools only |
| `FSQLCTL_KEY` | -- | the daemon's HMAC key file -- the admin tools only |
| `FSQLCTL_CONF` | `/etc/fractalsql/fractalsqld.conf` (`C:\ProgramData\FractalSQL\fractalsqld.conf` on Windows) | the daemon config file's path, for the config read/write tools |

**The HTTP transport.** (`--http`, `--bind`/`--host`, `--tool` and
`--category` set the same things from the command line.)

| Setting | Default | Meaning |
| --- | --- | --- |
| `FSQL_MCP_HTTP_PORT` | `8765` | the port to listen on |
| `FSQL_MCP_BIND` | `127.0.0.1` | the address to listen on |
| `FSQL_MCP_HTTP_PATH` | `/mcp` | the path the JSON-RPC endpoint is served on |
| `FSQL_MCP_HTTP_TLS` | `false` | serve HTTPS instead of HTTP (TLS 1.2 or newer) |
| `FSQL_MCP_TLS_CERT` / `FSQL_MCP_TLS_KEY` | -- | the certificate and its private key, PEM; both are required when TLS is on |
| `FSQL_MCP_ALLOW_PLAINTEXT_NONLOOPBACK` | unset | allow a plaintext listener on a non-loopback address; without it the server refuses to start |
| `FSQL_MCP_ALLOWED_ORIGINS` | loopback origins only | extra browser origins allowed to call the server |
| `FSQL_MCP_AUTH_TOKEN` / `FSQL_MCP_AUTH_TOKEN_FILE` | -- | the bearer token; without one of these (or a policy file) the HTTP transport refuses to serve |
| `FSQL_MCP_TOKEN_POLICY_FILE` | -- | per-client credentials and their tool allowlists |
| `FSQL_MCP_MAX_CONNECTIONS` | `256` | most connections served at once; on POSIX the effective value never exceeds half the process's descriptor limit |
| `FSQL_MCP_SHUTDOWN_DRAIN_MS` | `5000` | how long a shutdown waits for in-flight work before letting go of it |
| `FSQL_MCP_LOG_LEVEL` | `normal` | `normal` or `verbose` |
| `FSQL_MCP_CONNECT_TIMEOUT` | `10` | seconds to wait for the database connection and its handshake |

**What a caller may do.**

| Setting | Default | Meaning |
| --- | --- | --- |
| `FSQL_MCP_READ_ONLY` | `false` | refuse every tool marked destructive, and latch each session's connection read-only on the engine side as well |
| `FSQL_MCP_PROTOCOL_ERA` | `dual` | `dual` serves both protocol eras; `modern` serves the modern era only |
| `FSQL_MCP_ALLOW_AUTO_EXECUTE` | off | whether a model may pass `auto_execute=true` to the tools that take it |
| `FSQL_MCP_CONFIG_WRITES` | `safe` | `off` refuses every configuration write, `safe` allows only the model names and the think mode, `all` allows any key the operator has not reserved; an unrecognised value is treated as `safe` |
| `FSQL_MCP_ENABLED_CATEGORIES` | all | comma-separated tool categories to publish |
| `FSQL_MCP_TOOL_WHITELIST` | all | comma-separated tool names to publish |
| `FSQL_MCP_MAX_SESSIONS` | `64` | how many sessions and context handles exist at once |
| `FSQL_MCP_SESSION_TTL_SECS` | `3600` | how long an idle session or handle survives |
| `FSQL_MCP_MAX_ROWS_CEILING` | `1000` | hard cap on the rows a result may carry (the per-call default is 100) |
| `FSQL_MCP_MAX_CONCURRENT_CHEAP` | `50` | concurrent cheap calls |
| `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE` | `5` | concurrent expensive calls |
| `FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT` | `2` | concurrent expensive calls from one client |
| `FSQL_MCP_MAX_QUEUE_WAIT_MS` | `900000` | how long a call waits for a slot before it is refused |
| `FSQL_MCP_AGENT_PARTIAL` | `on` | `off` keeps the engine's documented raise-first behaviour for reasoning-endpoint failures inside agent calls |

**The locks and the manifest.** The registered tool surface is pinned by a
`.mcp-schema-lock` file (a SHA-256 of the tool surface) and the safety
hints by a `.mcp-safety-annotations-lock` file. A missing lock file
refuses to start; `FSQL_MCP_ALLOW_MISSING_LOCKS=true` (or an explicit
`FSQL_MCP_REQUIRE_LOCKS=false`) turns that into a warning. A schema
mismatch is fatal unless `FSQL_MCP_STRICT_SCHEMA_HASH=false` turns it into
a warning instead. Regenerate both with `--write-schema-lock` and
`--write-safety-annotations-lock`, and commit them with the change that
moved the surface.

| Setting | Default | Meaning |
| --- | --- | --- |
| `FSQL_MCP_SCHEMA_LOCK` | `mcp/.mcp-schema-lock`, looked up in the working directory first and then next to the executable | the tool-surface lock's path |
| `FSQL_MCP_SAFETY_LOCK` | `mcp/.mcp-safety-annotations-lock`, looked up the same way | the safety-annotation lock's path |
| `FSQL_MCP_MANIFEST` | `mcp/manifest.json` | where `--write-manifest` writes the tool manifest |
| `FSQL_MCP_REQUIRE_LOCKS` | unset | `false` lets the server start without its locks |
| `FSQL_MCP_ALLOW_MISSING_LOCKS` | unset | `true` lets the server start without its locks |
| `FSQL_MCP_STRICT_SCHEMA_HASH` | `true` | a tool-surface mismatch refuses to start |

**The engine and the daemon.** These configure the engine the MCP server
calls, and are read by the engine or the daemon rather than by the MCP
server.

| Setting | Default | Meaning |
| --- | --- | --- |
| `FSQL_AUDIT_REDACT` | `none` | `none`, `hash` or `truncate`: what the audit chain keeps of an entry's free text |
| `FSQL_LEDGER_ANCHOR_LOG` | `off` | `stderr` or `syslog`: publish the chain's head on every append |
| `FRACTALSQL_LEDGER_MAX_BYTES` | `1073741824` | the size past which ledger appends are refused; `0` for unbounded |
| `FRACTALSQL_AUDIT_REQUIRE_ACTOR` | unset | set to refuse a bare two-argument `fractal_audit_log` call that names no actor |
| `FRACTALSQL_REASONING_PLUGIN_SHA256` | -- | the 64 hex digits the reasoning plugin's SHA-256 must match |
| `FRACTALSQL_REASONING_ALLOW_UNVERIFIED` | unset | set to load a reasoning plugin that is neither signed nor pinned |
| `FRACTALSQL_HTTP_TOKEN` | -- | the bearer token sent to the reasoning and text-to-SQL provider (`FSQL_REASONING_HTTP_TOKEN` takes precedence) |
| `FRACTALSQL_HTTP_ALLOW_PLAINTEXT` | unset | set to let the provider be reached over plaintext HTTP (`FSQL_REASONING_HTTP_ALLOW_PLAINTEXT` takes precedence) |
| `FRACTALSQL_HTTP_THINK` | -- | the think mode the provider is asked for (`FSQL_REASONING_HTTP_THINK` takes precedence) |
| `FRACTALSQL_HTTP_THINK_PROVIDER` | -- | the URL of the provider that does the thinking (`FSQL_REASONING_HTTP_THINK_PROVIDER` takes precedence) |
| `FRACTALSQL_HTTP_NATIVE_URL` | -- | the URL of the native (built-in) provider (`FSQL_REASONING_HTTP_NATIVE_URL` takes precedence) |
| `FRACTALSQL_HTTP_NUM_CTX` | -- | how many context items to send the provider (`FSQL_REASONING_HTTP_NUM_CTX` takes precedence) |

The enterprise tier's own four settings -- `FRACTALSQL_ENTERPRISE_LIB`,
`FRACTALSQL_ENTERPRISE_LEDGER_PATH`, `FRACTALSQL_ENTERPRISE_LEDGER_KEY`
and `FRACTALSQL_ENTERPRISE_REQUIRE_SIGNATURE` -- and the
`FRACTALSQL_TEXT_TO_SQL_*` trio are documented with the features they
configure, in [enterprise.md](enterprise.md) and
[text-to-sql-setup.md](text-to-sql-setup.md).

## Troubleshooting

| Symptom | What to do |
|---|---|
| `fractalsql_get_version` -> connectivity error / connection refused | MariaDB not reachable: check `MARIADB_HOST/PORT`, that the engine service is up, and the account. The error text is the client's own, sanitized. |
| every UDF/procedure call fails with `cannot connect`-style daemon text or a `BUSY`/`ARGS` shim error | `fractalsqld` is down or unreachable at `FSQLCTL_SOCKET`'s implicit path -- but note: the SHIM connects via the shim's own config (fractalsqld.conf of the mariadbd process), not `FSQLCTL_SOCKET` (admin tools only). See fractalsql-daemon.md's health chapter. |
| `fractal_reason` -> connectivity error "the embed/reasoning tier is not configured" | Reasoning keys live in fractalsqld.conf; use `fractalsql_configure_reasoning` (or edit the conf + restart/reload). Local models may need up to 300s to cold-load -- set the daemon timeouts before judging a call failed. |
| `fractal_search_telemetry` -> `45000` SIGNAL about primary keys / schema-qualified names / no rows | As documented: the target table needs exactly one single-column `PRIMARY KEY`, a bare name, an existing vector column, non-empty results. |
| Enterprise-tier tools -> `fractal_agent_diverse_portfolios: enterprise tier not loaded` (proc) or the NULL-dormant condition (UDFs) | That tool needs the enterprise library under `FRACTALSQL_ENTERPRISE_LIB` in the daemon's environment (enterprise.md). Nothing is broken; it needs a license. |
| startup stderr: `tool-schema hash mismatch` | A packaged update changed the tool surface: regenerate via `--write-schema-lock` and commit in the same PR -- or, if you didn't expect it, treat the install as untrusted (set `FSQL_MCP_STRICT_SCHEMA_HASH=true` to hard-fail). |
| startup stderr: version-skew warning (`version_skew`) | The engine on the other end of the connection is not the release this plugin was built against the documented SQL surface of -- pin/align versions. |
| `fractalsql_set_config` -> "the daemon did NOT accept the reload: ..." | Read the returned reason (range/empty/startup-only). The daemon kept its previous config (all-or-nothing); the file edit is intact for a restart instead. |
| `server busy` | Concurrency caps from 10.7 -- lower parallelism, or raise `FSQL_MCP_MAX_CONCURRENT_*` deliberately. |
| `fractal_search` returned NULL all of a sudden | Documented behavior: out-of-range SFS params make the WHOLE call NULL (e.g. `iterations > 10000`); fix the knobs. |
| A result carries `reasoning_step_failed: ...` with `isError: false` | The agent's data half computed fine; the LLM endpoint failed and the session reports it instead of discarding the computation (partial-result honesty). Fix the reasoning endpoint/model config via `fractalsql_configure_reasoning` and re-call. Set `FSQL_MCP_AGENT_PARTIAL=off` to return to the engine's raise-first behavior. |
| 401 behind a shared deployment right after rotating the token | Token files hot-reload by mtime; if you rotated the env var instead, that's a restart (no hot-reload for env secrets). |