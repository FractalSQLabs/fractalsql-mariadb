/* src/fractalsql_interrupt.h - cooperative cancellation seam.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Long-running UDF bodies (large corpus parses, per-element analytics
 * loops) take far longer than a single SQL statement's worth of attention
 * an operator can give them, so they need an abort path that stops them
 * partway. There is no way for the *caller* to signal this from inside a
 * MariaDB UDF (the UDF API exposes no thread handle, so nothing like a
 * KILL-QUERY flag is reachable from the adapters) -- instead, the host
 * process that runs these bodies installs an interruption hook and the
 * loops poll it at row/element boundaries.
 *
 * fractalsqld (the daemon) installs a hook that reads the active handle's
 * cancel flag -- set through the CANCEL control request, which is exactly
 * why CANCEL can arrive on a separate connection while this one is busy.
 * Other hosts (tests, other embedders) install their own or leave unset:
 * with no hook installed the poll reports "not interrupted" and costs one
 * NULL test per boundary.
 *
 * A standalone TU with no <mysql.h> dependency, so fuzz/parse-test builds
 * can link it alongside fractalsql_parse.c without a MariaDB dev package
 * (the same seam fractalsql_parse.h documents).
 */
#ifndef FRACTALSQL_INTERRUPT_H
#define FRACTALSQL_INTERRUPT_H

#ifdef __cplusplus
extern "C" {
#endif

/* Interrupt check: returns nonzero when the interrupted work should stop
 * and unwind. Installed with fractalsql_interrupt_hook_set(NULL) to
 * disable again. */
typedef int (*fractalsql_interrupt_fn)(void);

/* Installs (fn != NULL) or removes (fn == NULL) the interruption hook.
 * Not thread-safe by itself: install once at startup, before any worker
 * thread runs, like every other piece of process-global setup. */
void fractalsql_interrupt_hook_set(fractalsql_interrupt_fn fn);

/* Polls the hook at a loop boundary. Returns 0 with no hook installed.
 * Loop bodies call this in the cheap places only -- once per row or per
 * element, never per byte. */
int fractalsql_interrupt_poll(void);

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_INTERRUPT_H */