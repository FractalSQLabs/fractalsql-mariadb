# FSQ wire protocol, version 2

This document specifies the wire protocol between a database-side client and
a FractalSQL daemon. It does not depend on any database product. The header
definitions are in `fsq_protocol.h`, the control opcode registry is in
`opcodes.def`, and the callable-function registry is in `functions.def`. All
three are normative. This document describes them.

Licence: MIT (see `REUSE.toml`).

Version 2 identifies a function by name in `UDF_INIT` and `UDF_CALL`, instead
of version 1's numeric opcode per function. The frame format, the lifecycle,
and the TLV argument and result encoding are unchanged from version 1.

## 1. Transport

- POSIX: a Unix domain socket of type `SOCK_STREAM`. The path comes from the
  daemon's `socket_path`. Access is limited by peer credentials
  (`SO_PEERCRED`, against `allowed_uids`).
- Windows: a named pipe `\\.\pipe\<name>`. Access is limited by the pipe DACL
  and by the client's user SID (`allowed_pipe_sid`).
- TCP is not part of this protocol.

## 2. Frame

Every message is one frame. All integers are little-endian.

| Offset | Size | Field           | Notes                                              |
|-------:|-----:|-----------------|----------------------------------------------------|
| 0      | 4    | magic           | ASCII `FSQ1`                                       |
| 4      | 2    | version         | `2`. A mismatch closes the connection.             |
| 6      | 2    | opcode          | See section 4.                                     |
| 8      | 4    | flags           | bit 0 `RESPONSE`, bit 1 `ERROR`. Requests use 0.   |
| 12     | 4    | request_id      | Chosen by the client, echoed in the response.      |
| 16     | 8    | context         | Idempotency token on `UDF_CALL` (section 5); 0 for every other request. The daemon replays a previous `UDF_CALL` response when the same nonzero token arrives again. |
| 24     | 4    | auth_len        | `32`. The length of the tag.                       |
| 28     | 4    | payload_len     | At most 80 MiB (`83886080`).                       |
| 32     | 32   | tag             | HMAC-SHA256 over bytes 0 to 31 followed by the payload. |
| 64     | N    | payload         | Opcode-specific. `N` is `payload_len`.             |

The tag is verified in constant time before the payload is parsed. A frame
with a bad magic, a bad version, a bad `auth_len`, an over-limit
`payload_len`, or a bad tag closes the connection. The receiver logs the
event without the payload.

The HMAC key is a hex string in a file that the daemon reads at start, from
`hmac_key_file`. Both sides must share it. The key is never sent in a frame.

A client sets `context` to 0 for every request except `UDF_CALL`, where it
chooses an idempotency token (below, section 5). Older daemons (pre-2.1)
echo it without interpreting it, which is the compatible behaviour.

## 3. Response

A response has `RESPONSE` set in `flags`, and the same `opcode` and
`request_id` as its request. Its payload starts with two fields, then the
body:

| Offset | Size | Field   |
|-------:|-----:|---------|
| 0      | 4    | status  |
| 4      | 4    | core_rc (signed) |
| 8      | ...  | body    |

`ERROR` is set when `status` is not `0`.

Status codes:

| Value | Name             | Meaning                                    |
|------:|------------------|--------------------------------------------|
| 0     | OK               | Success.                                   |
| 1     | ARGS             | The request is malformed or refers to an unknown handle. |
| 2     | LIMIT            | A size or count limit was exceeded.        |
| 3     | CORE             | The function reported an error for this call. |
| 4     | NOT_LICENSED     | Reserved.                                  |
| 5     | AUTH             | Reserved.                                  |
| 6     | INTERNAL         | The daemon could not complete the request. |
| 7     | NOTSUP           | Unknown opcode or unknown function.        |
| 8     | BUSY             | The call was cancelled: either `UDF_CALL` on a handle that `CANCEL` marked while it was idle, or a running call stopped by a `CANCEL`-requested interruption. |

## 4. Opcodes and functions

Opcodes are 16-bit values naming a control operation, and an opcode is never
reused. The registry is `opcodes.def`:

| Opcode   | Name         | Use                                                |
|---------:|--------------|-----------------------------------------------------|
| `0x0001` | `PING`       | See below.                                          |
| `0x0002` | `VERSION`    | See below.                                          |
| `0x0010` | `UDF_INIT`   | Open a handle on a named function. Section 5.       |
| `0x0011` | `UDF_CALL`   | Call through an open handle. Section 5.             |
| `0x0012` | `UDF_DEINIT` | Close a handle. Section 5.                          |
| `0x0013` | `CANCEL`     | Cooperatively cancel a handle's calls. Section 5.           |
| `0x0014` | `RELOAD`     | Tell the daemon to re-read its config file. Section 5.      |

There is no opcode per callable function. `UDF_INIT` and `UDF_CALL` name the
function in their payload instead (section 5). The set of names a daemon
accepts is `functions.def`, where each row gives a name, its result kind
(`STR`, `INT`, or `REAL`), and its retry class (`r` pure, `s` stateful, `e`
expensive -- see section 5, "Retry classes"). A name not in that registry
gets `NOTSUP`.

Control requests:

- `PING`: empty request. Response body: `u16` protocol version.
- `VERSION`: empty request. Response body: a UTF-8 string, without a
  terminator.

## 5. Lifecycle payloads

A function name in a lifecycle payload is length-prefixed:

| Offset | Size | Field   | Notes                                    |
|-------:|-----:|---------|-------------------------------------------|
| 0      | 1    | namelen | At most 63.                               |
| 1      | namelen | name | ASCII, not NUL-terminated.               |

Each argument is a TLV entry:

| Offset | Size | Field     | Notes                                       |
|-------:|-----:|-----------|---------------------------------------------|
| 0      | 1    | type      | See below.                                  |
| 1      | 1    | is_null   | `1` means SQL NULL. The bytes that follow are ignored. |
| 2      | 4    | len       | Byte length of the value.                   |
| 6      | len  | bytes     | The value.                                  |

Type codes: `0` NULL, `1` STRING, `2` INT (`int64`, little-endian), `3` REAL
(IEEE 754 double, little-endian), `4` DECIMAL (sent as a string), `5` BINARY.

A TLV list must consume the whole payload exactly, or the request is
malformed. A request may carry at most 64 arguments.

The type code in `UDF_INIT` declares each argument's type, and the daemon
keeps it for the handle. In `UDF_CALL`, each value is read by the declared type
from `UDF_INIT`, not by the type byte in the call. The call's `is_null` byte is
still honoured. A client therefore encodes every call argument the same way it
encoded it at init.

**`UDF_INIT` (`0x0010`)**

- Request: `namelen` + `name`, then `u32` `nargs`, then `nargs` TLV entries.
- Response body: `u64` handle, `u32` max_length, `u8` maybe_null, `u32`
  nargs, then `nargs` bytes giving each argument's coercion code: `1` STRING,
  `2` INT, `3` REAL, `4` DECIMAL.

The handle belongs to the connection that created it.

**`UDF_CALL` (`0x0011`)**

- Request: `namelen` + `name`, then `u64` handle, then `u32` `nargs`, then
  `nargs` TLV entries. The name and the argument count must match the
  handle's.
- Response body: one TLV entry with the result. For a NULL result,
  `is_null` is `1`.
- A call that fails inside the function returns status `CORE`, with an empty
  body.

**`UDF_DEINIT` (`0x0012`)**

- Request: `u64` handle.
- Response: status `OK`, empty body. The daemon releases the handle even if
  the handle is unknown.

A connection's handles are released when the connection closes, so a client
that disconnects without deinitializing does not leak them.

**`CANCEL` (`0x0013`)**

- Request: `u64` handle.
- Response: status `OK` if the handle exists (on any connection), `ARGS` if
  not.
- Unlike `UDF_CALL`/`UDF_DEINIT`, `CANCEL` is not restricted to the handle's
  owning connection: it is meant to be sent from a separate client (an admin
  tool), since the owning connection's call may itself be the one blocked.
- The mark is one-shot. It has two effects:
  - An in-flight call running in-repo adapter code unwinds at its next
    element/row boundary and reports `BUSY` ("cancelled"). Code inside the
    vendored core archive is not interruptible this way.
  - The handle's next `UDF_CALL` after the mark is set fails with `BUSY`
    even if no call was running when `CANCEL` arrived. The mark then
    clears, so the call after that runs normally.

**`RELOAD` (`0x0014`)**

- Request: empty payload. Any nonzero payload is refused with `ARGS`.
- Response: status `OK` ("reloaded") when the daemon re-read its config
  file and published it; `ARGS` with the reason when it refused. The swap
  is all-or-nothing: a config that fails to parse or validate leaves the
  running configuration in effect, as do changes to `socket_path` or
  `hmac_key_file`, which clients read once at startup and cannot pick up
  live. A lowered `max_connections` limits new connections only.
- The provider keys (`reasoning_*`, `embed_*`, `think*`, `t2s_*`,
  `enterprise_*`) are also in scope: the config file is the preferred
  source for them (the daemon's boot environment is the fallback for keys
  absent from the file, captured once at startup), and all of them are
  pushed to the consumers on reload. The pushed value reaches the
  consumer on that tier's *next* call -- a reload never attempts a plugin
  or enterprise-library load itself, so a new or changed path is loaded
  then, and a failure is named in the daemon log at that call. Removing a
  key reverts that setting to the boot-environment fallback on the next
  call. Validation is loud and named (unknown key: WARN naming the key;
  `t2s_max_attempts` outside 1..10, `t2s_allowed_statements` not exactly
  `select` or `select_insert_update`, `think_num_ctx` outside 1..10000000,
  and empty
  values: refused). One exception: a change to `enterprise_lib` while an
  enterprise library is already loaded is refused (`ARGS` naming the
  loaded library); restart the daemon to change it.
  `enterprise_ledger_path` and `enterprise_ledger_key` swap live (ledger
  file I/O opens per operation), but continuity of ledger content across
  a path change is the operator's responsibility. The
  `FSQL_REASONING_HTTP_RESPONSE_MODE` response-mode knob has no conf key
  and remains environment-only.
- A daemon may also answer `ARGS` because the config file is unreadable;
  in every refusal case the daemon keeps running with its current
  configuration.

**Retry classes (`functions.def`, third field)**

- `r` (pure): re-executing the call is always safe. A client retries it
  across reconnects, up to 3 attempts.
- `s` (stateful): re-execution could double a side effect. A client
  resends it *once* with the same idempotency token.
- `e` (expensive): deterministic but costly (external provider calls). No
  automatic retry.

**Idempotency on `UDF_CALL`**

- A client puts a nonzero `context` (the idempotency token) on every
  `UDF_CALL` and keeps it stable across the attempts of one logical call.
  A new token per logical call, drawn from a per-process random base, so a
  replayed token never outlives the client that minted it.
- The daemon remembers the last response (status + body) for each executed
  nonzero token whose status was `OK` or `CORE`. When the same token
  arrives again -- even on a different connection, after a disconnect and
  reconnect -- the daemon replays the stored response instead of running
  the call again. Tokens are unbounded; clients must never reuse a token
  for a different logical call.
- Cached entries are keyed by token alone, have per-aggregate and
  per-entry size bounds, and are evicted FIFO once over budget; a very
  late resend of a cache-evicted token therefore re-executes. This is
  safe by the retry-class contract above: only `s`-class (and, on a
  transport failure, `r`-class) clients resend, and a `r`-class
  re-execution has no side effects.

## 6. Limits and timeouts

- Payload: at most 80 MiB per frame.
- Function name: at most 63 bytes.
- Arguments: at most 64 per call.
- Error text: at most 512 bytes.
- Idle connections close after `idle_timeout_secs` (default 300).

## 7. Security

- Every frame is authenticated with HMAC-SHA256 before parsing.
- Peer identity is checked on connect, and the connection is refused if the
  peer is not on the allow-list.
- The key file must not be readable by other users. POSIX checks the mode
  bits, and Windows checks the DACL.
- Logs carry opcodes, function names, sizes, peer identities, and error text.
  They never carry argument or result bytes, or the key.

## 8. Conformance

A conforming client needs only this document, `opcodes.def`, and
`functions.def`. The shim is one client. `service/cli/fsqlctl.c` is a second,
independent one: it is a control-plane CLI that includes no shim, daemon, or
core header, and it talks to the daemon with no MariaDB involved; it
exercises `PING`, `CANCEL`, and `RELOAD`.
`service/tests/cli_test.sh` runs it against a live daemon.

## 9. Combinations of protocol revisions

The protocol is version 2 with additive revisions. Combinations:

| Client \ Daemon | Pre-2.1 (context opaque, no RELOAD) | 2.1+ (token replay, RELOAD) |
| --- | --- | --- |
| Pre-2.1 client (context always 0, no resends) | Unchanged | Works as before: every call re-executes (context 0 never hits the cache). |
| 2.1+ client | The daemon ignores the token and re-executes on the reconnect itself for `r`-class functions; an `s`-class single resend therefore re-executes instead of replaying -- today's behaviour, which is safe only because pre-2.1 daemons ran no retries. A `RELOAD` request gets `NOTSUP`. | Full behaviour. |

The one combination to avoid running side-effecting `s`-class calls against
a pre-2.1 daemon *and* retrying them client-side: without token replay the
resend re-executes.
