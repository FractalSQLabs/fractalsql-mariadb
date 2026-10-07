<p align="center">
  <img src="../FractalSQLforMariaDB.jpg" alt="FractalSQL for MariaDB" width="720">
</p>

# FractalSQL Daemon

`fractalsqld` is the separate process that holds the actual engine — every
UDF body, the reasoning/embedding plugin, and the Enterprise ledger.
`mariadbd` loads only a thin shim (`fractalsql.so`/`.dll`) that forwards
every UDF call to it over a local socket. This page covers running the
daemon and its `fsqlctl` CLI directly, and what that two-process
architecture guarantees (and doesn't) for reliability.

Normal installs (the `.deb`/`.rpm`, the Windows MSI plus
`fractalsqld-service.ps1`, or macOS's `install.sh`) set all of this up for
you — see [`getting-started.md`](getting-started.md). The sections below
are for running it by hand, writing your own config, or scripting against
it. For the wire protocol itself, see
[`../service/protocol/SPEC.md`](../service/protocol/SPEC.md).

## Running `fractalsqld`

```
fractalsqld [-c config]
```

`-c` points at the config file (below). If omitted, it reads from
`FRACTALSQL_CONFIG` in the process environment, then falls back to a
platform default:

| Platform | Default config path |
| --- | --- |
| Linux/macOS | `/etc/fractalsql/fractalsqld.conf` |
| Windows | `C:\ProgramData\FractalSQL\fractalsqld.conf` |

On Windows, `fractalsqld --service` is how the Windows Service Control
Manager invokes it — `fractalsqld-service.ps1` (below) wires that up for
you; you don't pass `--service` yourself.

### Config file

One `key = value` per line, `#` for comments. `socket_path` and
`hmac_key_file` are required; everything else has a default.

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `socket_path` | yes | — | A Unix socket path (POSIX; under ~107 chars) or a Windows named pipe, which must start with `\\.\pipe\` (e.g. `\\.\pipe\fractalsqld`). |
| `hmac_key_file` | yes | — | Path to a file holding a hex-encoded key, shared with the shim's config. Generate one with `openssl rand -hex 32`. |
| `log_file` | no | stderr | Where log lines go. |
| `max_connections` | no | `64` | Concurrent client connections (the shim, `fsqlctl`, or both). |
| `idle_timeout_secs` | no | `300` | A connection idle this long is closed. |
| `allowed_uids` (POSIX) | no | the daemon's own uid | Comma-separated list of uids allowed to connect (checked via `SO_PEERCRED`/`getpeereid`). Set this to `mariadbd`'s uid. |
| `allowed_pipe_sid` (Windows) | no | the daemon's own user SID | Comma-separated list of SIDs allowed to connect. Set this to the SID of the account `mariadbd` runs as. |

### Provider keys

The remaining keys configure the reasoning, embedding, text-to-SQL and
Enterprise tiers. The config file is the **preferred** source for all of
them; a key absent from the file falls back to fractalsqld's process
environment (the `FRACTALSQL_*`/`FSQL_*` names those tiers have always
read), which is captured once at daemon startup — so a pure-environment
deployment behaves exactly as before. The legacy
`FRACTALSQL_TEXT_TO_SQL_*` names remain the text-to-sql tier's
fallback. All of them reload live with
`fsqlctl reload` (semantics below); the pushed value reaches the consumer
on that tier's *next* call.

| Key | Required | Default | Notes |
| --- | --- | --- | --- |
| `reasoning_plugin` | no | — | Path to the reasoning plugin (.so/.dll). |
| `reasoning_url` | no | — | HTTP reasoning endpoint. |
| `reasoning_token` | no | — | Secret — Bearer token for the reasoning endpoint. |
| `reasoning_model` | no | — | Model name sent to the reasoning endpoint. |
| `reasoning_allow_plaintext` | no | off | Permit a plain-HTTP (non-TLS) reasoning endpoint. |
| `embed_url` | no | — | Embeddings HTTP endpoint. |
| `embed_model` | no | — | Model name sent to the embeddings endpoint. |
| `think` | no | `none` | THINK reasoning-effort knob for hybrid-thinker models (`none`/`off`/`low`/`medium`/`high`/…). See [reasoning-setup.md](reasoning-setup.md). |
| `think_provider` | no | `openai` | Request shape THINK uses (`openai`, `ollama`, or `anthropic`). |
| `think_native_url` | no | — | Override URL for the ollama/anthropic native shape. |
| `think_num_ctx` | no | — | Ollama-native context-window cap. Must be an integer in `1`–`10000000`. |
| `t2s_max_attempts` | no | `2` | Text-to-SQL GENERATE retry budget, clamped to `1`–`10`. |
| `t2s_allowed_statements` | no | `select` | Exactly `select` or `select_insert_update` (the latter permits writes). |
| `t2s_use_review` | no | off | Add the text-to-SQL REVIEW pass. |
| `enterprise_lib` | no | — | Path to the FractalSQL Enterprise library. |
| `enterprise_ledger_path` | no | — | Ledger file path (opens per operation, so it can be swapped live). |
| `enterprise_ledger_key` | no | — | Secret — HMAC-SHA256 ledger key (unset means structural-only validation). |
| `enterprise_require_signature` | no | off | Refuse to load an enterprise library with no detached signature file. |

Example (Linux):

```ini
socket_path = /run/fractalsql/fractalsqld.sock
hmac_key_file = /etc/fractalsql/hmac.key
allowed_uids = 999
idle_timeout_secs = 300
```

Because `reasoning_token` and `enterprise_ledger_key` may sit in the file
as plaintext, the daemon's conf file is gated like `hmac_key_file`: a
world/groups-readable config refuses both startup and `fsqlctl reload`
(the message names "permissions"). Make it private — `chmod 600` on
POSIX, a private ACL on Windows.

The shim's own config (`fractalsql.conf`, same default-path convention,
`FRACTALSQL_CONFIG` for the shim's process — i.e. `mariadbd`'s environment)
only needs `socket_path` and `hmac_key_file`, pointing at the same socket
and key.

## Running it as a service

- **Linux**: `packaging/systemd/fractalsqld.service` (installed by the
  `.deb`/`.rpm`). `systemctl status|restart fractalsqld`; logs via
  `journalctl -u fractalsqld`. `Restart=on-failure` is already set.
- **Windows**: `scripts/windows/fractalsqld-service.ps1`:
  ```powershell
  .\fractalsqld-service.ps1 -Action install -Exe 'C:\path\to\fractalsqld.exe' -Config 'C:\path\to\fractalsqld.conf'
  Start-Service fractalsqld
  # ... later:
  .\fractalsqld-service.ps1 -Action uninstall
  ```
  Defaults to running as `NT AUTHORITY\LocalService`; pass `-Account` for a
  different one. Restarts automatically on crash (5s, 5s, 30s backoff).
- **macOS**: a per-user LaunchAgent, installed by `scripts/macos/install.sh`
  at `~/Library/LaunchAgents/com.fractalsqlabs.fractalsqld.plist`
  (`KeepAlive` is set). `launchctl kickstart -k
  gui/$(id -u)/com.fractalsqlabs.fractalsqld` to restart it by hand.

You don't need to do anything extra for the shim side of this: it
reconnects to the daemon lazily on the next call, with no explicit
"reconnect" step and no `mariadbd` restart.

## `fsqlctl`

`fsqlctl` is a standalone control-plane CLI: it speaks the wire protocol
directly, with no `mariadbd`, no shim, and no core header — just the
protocol headers in `service/protocol/`.

```
fsqlctl [-s socket] [-k keyfile] COMMAND [ARGS...]
```

| Flag | Default | Env var |
| --- | --- | --- |
| `-s socket` | `/run/fractalsql/fractalsqld.sock` | `FSQLCTL_SOCKET` |
| `-k keyfile` | `/etc/fractalsql/hmac.key` | `FSQLCTL_KEY` |

`fsqlctl` builds from the service tree (`make -C service all`) rather than
shipping in a package. There is no Windows CLI build: the daemon serves
the same `RELOAD` and `CANCEL` opcodes over its named pipe (see
[SPEC.md](../service/protocol/SPEC.md)), and on Windows a config-file edit
takes effect with a `fractalsqld` restart.

### Commands

- **`ping`** — checks that the daemon answers, prints the protocol version.
- **`version`** — prints the daemon's version string.
- **`check`** — checks the key file's permissions and the socket, then
  pings. The one command that doesn't need a working key file to start
  (it reports the problem instead of failing silently).
- **`call FUNCTION [ARG...]`** — runs any registered function and prints
  its result. Arguments are `s:TEXT` (string, also the default for a bare
  word), `i:N` (integer), `r:X` (real), or `NULL`:
  ```
  fsqlctl call fractal_vector_dims '[1,2,3]'
  fsqlctl call fractal_vector_norm '[3,4]'
  ```
- **`cancel HANDLE_ID`** — cooperatively cancels a call: an in-flight call
  that is running in-repo code (the text/CSV parsers and the analytic
  loops in the adapter layer) stops at its next loop boundary and reports
  an "interrupted" error, and the handle's next call fails with `ERR_BUSY`
  (the mark is one-shot — the following call runs normally). Code inside
  the vendored core archive can't be interrupted this way; those calls run
  to completion. Find a handle's id in the daemon's log or via
  `fsqlctl`'s `call` output.
- **`reload`** — tells the daemon to re-read its config file. The swap is
  all-or-nothing: an unparseable file or one that changes `socket_path` or
  `hmac_key_file` (both are read once by clients, so applying them live
  would strand every running `mariadbd`) is refused and the running
  configuration stays in effect. The same is true of the provider keys
  (above): all 18 of them reload live, but the pushed value reaches the
  consumer on that tier's *next* call — a reload never attempts a plugin
  or library load itself, so a bad or changed `reasoning_plugin` /
  `enterprise_lib` path surfaces at that next call, with its path named in
  the daemon log. Removing a key from the file reverts that setting to the
  boot-environment fallback on the next call. Validation is loud and
  specific (a deliberate file edit is operator intent): an unknown key is
  a WARN that names the key; `t2s_max_attempts` outside `1`–`10`,
  `t2s_allowed_statements` anything but `select` or
  `select_insert_update`, `think_num_ctx` outside `1`–`10000000`, and
  empty values are each refused by name (the environment fallback, by
  contrast, stays
  silent-clamping, as before). Two deliberate exceptions: `enterprise_lib`
  cannot be changed live *while an enterprise library is already loaded* —
  the reload is refused with a message that names the currently loaded
  library; restart the daemon to change it (changes while nothing is
  loaded are fine and re-arm the load attempt). And
  `enterprise_ledger_path`/`enterprise_ledger_key` swap live — ledger file
  I/O opens and closes per operation, so the next ledger operation opens
  the new file — but continuity of ledger content across a path change is
  your responsibility, not something the daemon does for you. A lowered
  `max_connections` applies to new connections only.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Failure reported by the daemon or the transport |
| `2` | Usage error |
| `3` | Authentication failure or the daemon closed the connection |
| `4` | Unknown function name (checked locally, before contacting the daemon) |

## Reliability

### The core guarantee

**A problem in `fractalsqld` never crashes or hangs `mariadbd`.** A daemon
crash, a hang, a plugin that misbehaves, an out-of-memory kill — all of it
surfaces to SQL as an error or a `NULL`, never a server crash. The shim is
the only FractalSQL code that runs inside the server process, and it is
built to stay crash-free regardless of what the daemon does: it never
writes more into a server result buffer than the server told it to expect.

This is continuously tested, not just asserted: `service/tests/spike_test.sh`
kills a live daemon mid-test and confirms the server keeps answering other
queries, then confirms the shim reconnects once the daemon comes back.

### What happens when fractalsqld is unreachable

| Situation | What you see | What to do |
| --- | --- | --- |
| Daemon down when a call starts | That call fails immediately with a clear error (not a hang, not a crash) | Start/restart `fractalsqld`; no server restart needed |
| Daemon restarts after being down | The next call after it's back up succeeds automatically | Nothing — the shim reconnects lazily, there's no explicit "reconnect" step |
| Daemon down briefly while a pure or stateful call is sent | The shim reconnects and retries the call itself (up to 3 attempts for pure functions, one resend for stateful ones) | Nothing, as long as the daemon comes back quickly — the failure only surfaces if every attempt is exhausted, reported as `... (after N attempt(s))` |
| Daemon crashes mid-call | Pure functions are retried transparently; stateful ones are resent with an idempotency token and replayed, not re-executed; reasoning/embedding calls are not retried | See "Retry safety" below |

### Automatic retries and idempotency

The shim classifies every function into three retry tiers (defined in
`service/protocol/functions.def`) and handles transport failures itself,
with no application-visible error unless every attempt fails:

- **Pure functions (47)** — Vector, Dimension, Search, Portfolio, Topology
  and the read-only Analytics/ledger readers. Safe to just re-run: the
  shim retries up to 3 times across a fresh connection.
- **Stateful functions (11)** — Diversify control, sessions, Feedback,
  the Enterprise ledger/audit mutators. Re-executing could double-write
  the ledger or corrupt state, so the shim resends *once* with an
  idempotency token and the daemon *replays* the already-computed result
  from its response cache instead of running the call a second time. The
  token is random per `mariadbd` boot and survives the reconnect (the
  cache is keyed by token, not by connection), so a single `mariadbd`
  restart can't cause a replay.
- **Expensive functions (4)** — `fractal_reason`, `fractal_embed` and the
  text-to-sql generation/review functions. Deterministic but costly:
  no automatic retry; the error surfaces and it's your call.

The daemon's replay cache is process memory: **a daemon crash can still
lose an in-flight stateful call's answer**. In that case the statement
fails with an error and re-running it is a fresh execution — but a call
that *completed and was never answered* is always replayed, never
double-run.

### What happens when a call runs too long

`fsqlctl cancel HANDLE_ID` (above) cooperatively stops a running call:
adapter-layer loops poll a cancellation flag at element/row boundaries and
unwind with an "interrupted" error, and the handle's next call is refused
with `ERR_BUSY`. This is best-effort by design — loops inside the vendored
core archive (the search swarm among them) run to completion — and KILL
QUERY in the server cannot reach the daemon.

### The embedding queue's own retry logic

`fractal_vectorizer_process_queue` has its own retry mechanism, independent
of the above, because an automated pipeline can't just surface an error to
a human and wait:

- A row whose embedding call failed goes back to `pending` (not `failed`)
  with its `attempts` counter incremented and the error recorded. The next
  `process_queue` call claims it again.
- Permanent problems (permission errors, an unreadable source row, a failed
  write-back) fail the row immediately — these aren't retried, since
  trying again won't change the outcome.
- Each vectorizer has a retry budget (`options.max_attempts`, default 3).
  A row that exhausts it is marked `failed` for good. See
  [`vectorizer-setup.md`](vectorizer-setup.md) for the full configuration.

### Known limits

A few things are deliberately outside what the daemon can do, and it's
worth knowing where the boundaries are:

- **Cancellation stops at the vendored core.** `fsqlctl cancel` cooperatively
  interrupts calls running in the adapter layer (the text/CSV parsers and
  the per-element analytic loops), but calls already running inside the
  vendored core archive's own code (the search swarm among them) run to
  completion, and the cancel mark applies to whatever comes next.
- **Reload never loads, and two provider edges stay static.** Provider
  settings reload live (`fsqlctl reload` reads them from the config; see
  the `reload` command), but a reload never performs the plugin or
  enterprise-library load itself — a new or changed path is picked up on
  the tier's next call, with a failure named in the daemon log.
  `enterprise_lib` can't switch libraries while one is loaded (restart
  the daemon to change it), and `FSQL_REASONING_HTTP_RESPONSE_MODE` is
  environment-only. SQL connections stay up through any of this —
  `mariadbd` is untouched by a daemon restart.
- **A daemon crash mid-call can lose a stateful call's answer.** The
  idempotency cache lives in the daemon's memory. If the daemon crashes
  between executing a stateful call and sending its reply, that result is
  gone and the statement fails — it never double-runs (the cache is keyed
  by a token drawn fresh per `mariadbd` boot), but the caller sees the
  error and decides whether to re-run.
