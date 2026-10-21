/* src/fractalsql_enterprise.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Declares the QTL ledger's file-backed storage VFS for fractalsql_session.c
 * to wire into fractal_session_acquire's ctx construction. See
 * fractalsql_enterprise.c's file header for the full design.
 */
#ifndef FRACTALSQL_ENTERPRISE_H
#define FRACTALSQL_ENTERPRISE_H

#include <stdbool.h>
#include <stddef.h>

#include "fractalsql_sql.h"

/* Always-populated fsql_storage_vfs_t for the QTL ledger. Safe to pass to
 * every fsql_new_sovereign() call, including on a Community deployment:
 * the callbacks only ever run when fractal_ledger_flush/_load are actually
 * invoked, which itself requires FRACTALSQL_ENTERPRISE_LIB to be loaded
 * (gated upstream by ensure_enterprise_lib() in fractalsql_enterprise.c),
 * so wiring it in unconditionally costs nothing while the enterprise tier
 * is dormant -- community search/diversify/feedback never touch it. */
const fsql_storage_vfs_t *fractal_ledger_storage_vfs(void);

/* True iff FRACTALSQL_ENTERPRISE_LIB has successfully loaded and resolved
 * all 8 required symbols. Lets other translation units (fractalsql.c's
 * portfolio_audit_log_best_effort) gate their own best-effort audit-log
 * calls without duplicating the dlopen/dlsym machinery here. */
bool fractal_enterprise_lib_loaded(void);

/* Authenticity gate for the reasoning plugin, which is native code run in the
 * server (or daemon) process. Called before every fsql_load_reasoning(). Trusted when:
 * FRACTALSQL_REASONING_ALLOW_UNVERIFIED is set (operator opt-out); or the plugin's SHA-256
 * equals FRACTALSQL_REASONING_PLUGIN_SHA256; or <plugin>.sig is a valid detached Ed25519
 * signature by the FractalSQLabs release key (the one that signs the enterprise core).
 * Returns true when trusted; otherwise false with a message in err. */
bool fractal_plugin_verify(const char *path, char *err, size_t errsz);

/* Append one kind=2 (general decision-audit chain) entry to the ledger,
 * a second, independent append-only chain alongside kind=1's QTL blobs,
 * same hash-chain/CSV-mirror guarantees, queryable via
 * `SELECT ... FROM fractalsql_ledger WHERE kind = 2` once the CONNECT
 * mirror table is installed (see sql/install_enterprise_connect.sql).
 * `json` should be a complete, self-contained JSON object (the caller
 * builds {"type":...,"entry":...}). Returns FSQL_OK or an
 * FSQL_ESTORAGE* code; every internal/automatic call site is expected to
 * treat this as best-effort (check fractal_enterprise_lib_loaded() first,
 * ignore this function's return value); only the public fractal_audit_log
 * SQL UDF surfaces a real error on failure. */
int fractal_ledger_write_kind2(const char *json, size_t len);

/* Plain SHA-256 (fractalsql_hmac.h's fsql_sha256), exposed so other
 * translation units (fractalsql.c's portfolio_audit_log_best_effort)
 * can hash an inputs blob without each pulling in the whole vendored
 * HMAC header themselves. Keeps that header's single translation-unit
 * ownership in fractalsql_enterprise.c, the ledger's own home. */
void fractal_ledger_sha256(const unsigned char *msg, size_t msglen, unsigned char out[32]);

#endif /* FRACTALSQL_ENTERPRISE_H */
