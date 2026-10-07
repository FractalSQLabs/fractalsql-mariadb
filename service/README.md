# FractalSQL service build

The FractalSQL engine runs in `fractalsqld`, a separate process. `mariadbd`
loads only a thin shim (`fractalsql.so`), which forwards every UDF call to
the daemon over a Unix socket (a named pipe on Windows).

## Layout and licences

| Path | Licence | Role |
|---|---|---|
| `shim/` | GPL-2.0-only | UDF shim, loaded by mariadbd. No core code, no OpenSSL. |
| `daemon/` | Apache-2.0 | `fractalsqld`. Links `../src` and the vendored core archive. |
| `protocol/` | MIT | Wire protocol v2: `fsq_protocol.h`, `opcodes.def`, `functions.def`. See `protocol/SPEC.md`. |
| `common/fsq_sha256.h` | Public domain | SHA-256 and HMAC, used by shim and daemon. |
| `cli/` | Apache-2.0 | `fsqlctl`, an independent control-plane CLI: no shim, daemon, or core header. |
| `sql/install_spike.sql` | Apache-2.0 | Installs the subset of UDFs `tests/spike_test.sh` uses. |
| `tests/`, `scripts/` | Apache-2.0 | Self-tests, license/boundary/symbol scans, code generators. |

## Build and test

    make -C service all      # build/fractalsql.so (shim) and build/fractalsqld (daemon)
    make -C service scan     # license scan, shim/core boundary check, symbol scan
    make -C service test     # protocol self-test + fsqlctl conformance

`ASAN=1` / `UBSAN=1` / `COVERAGE=1` instrument the daemon (never the
shim, which has no logic of its own).

The shim reads `socket_path` and `hmac_key_file` from the config named by
`FRACTALSQL_CONFIG` (default `/etc/fractalsql/fractalsql.conf`). The
daemon reads `socket_path`, `hmac_key_file`, and `allowed_uids`
(`allowed_pipe_sid` on Windows) from its own config -- named the same way,
but a distinct file: `fractalsqld.conf` (default
`/etc/fractalsql/fractalsqld.conf`). That file is now also the preferred
source for the provider settings (reasoning/embedding, text-to-SQL, and
Enterprise), with the daemon's boot environment as the fallback for keys
absent from the file; `fsqlctl reload` pushes all of them live, and the
consumer picks the pushed values up on its next call.

For the full functional suite against this build, see `build_test.sh`
(`build_test.ps1` on Windows) at the repo root.

For running `fractalsqld` and `fsqlctl` day to day (config file reference,
service setup per platform, every `fsqlctl` command, and reliability
guarantees), see [`docs/fractalsql-daemon.md`](../docs/fractalsql-daemon.md).

## Known limits

- Calls are serialized through one connection per `mariadbd` process: the
  shim holds a single persistent socket, guarded by one mutex. The mutex is
  held across automatic retries, so a persistent transport failure stalls
  every UDF caller in that server for at most 3 attempts x 60 s (the call
  timeout).
- `OP_CANCEL` cooperatively cancels a handle's calls: an in-flight call
  running in-repo adapter code (parsers, per-element loops) unwinds at its
  next loop boundary with `ERR_BUSY`, and the handle's next `UDF_CALL`
  fails with `ERR_BUSY` even if no call was running (the mark is one-shot).
  Code inside the vendored core archive is not interruptible. It's meant
  to be sent from a separate admin connection (`fsqlctl cancel HANDLE_ID`);
  MariaDB's own `KILL QUERY` does not reach the daemon and does not trigger
  it automatically.
- Transport failures are retried by class (`r` pure up to 3 attempts, `s`
  stateful one flagged resend replayed by the daemon's idempotency cache,
  `e` expensive never retried) -- see `functions.def` and SPEC.md. The
  cache is daemon memory: a daemon crash between executing a stateful call
  and its reply still loses that one answer (it never double-runs).
- Darwin: `build_test.sh` (run by `build-test.yml`'s `darwin-gate-matrix`)
  builds this service tree and runs its protocol self-test on every CI run,
  same as Linux and Windows. The release/install path (`scripts/package.sh`,
  `scripts/macos/install.sh`, `release.yml`'s `build-macos`) still ships the
  old in-process build instead of this one.
