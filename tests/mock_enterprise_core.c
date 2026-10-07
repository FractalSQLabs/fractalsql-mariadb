/* tests/mock_enterprise_core.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Test-only stand-in for the real, licensed enterprise core .so
 * (libfractalsql-enterprise-sovereign-c.so/.dylib), which this public
 * repo does not ship (see gate_26_enterprise_active's own comment in
 * build_test.sh and src/fractalsql_enterprise.c's file header).
 *
 * WHAT THIS IS NOT: a reimplementation of the real enterprise core.
 * fsql_ledger_flush/_load/_compact/_reset_soft/_reset_hard and the
 * fsql_optimize_portfolio_multimodal* family are, in the real product,
 * free to reach into the fsql_ctx the caller passes (it was constructed
 * by the SAME proprietary core build the enterprise .so ships as part
 * of) and drive genuinely new work through it -- gate_26_enterprise_active
 * confirms exactly that ("flush genuinely persists to a real ledger
 * file"). This file is built only from the PUBLIC fractalsql.h, so
 * fsql_ctx is -- correctly -- opaque to it; every function below
 * ignores the ctx argument it's handed and returns a canned, test-
 * controlled result instead of doing real work.
 *
 * WHAT THIS IS FOR: fractalsql_enterprise.c's OWN integration code --
 * ensure_enterprise_lib()'s dlopen/dlsym/signature-verification
 * machinery, and every fractal_ledger_ and fractal_optimize_portfolio_
 * multimodal UDF's own argument validation, ctx acquire/release, and
 * success/failure branch on the resolved function pointer's return
 * code -- is this repo's code, not the vendored core's, and untested
 * without SOMETHING loadable at FRACTALSQL_ENTERPRISE_LIB. This fixture
 * is that something. It also drives fractal_audit_log/fractal_ledger_
 * verify's storage layer for real: both call this file's OWN static
 * ledger_write_entry/read/scan code directly (kind=2, the audit chain),
 * with no dependency on anything this mock provides -- see
 * build_test.sh's new enterprise_mock gate for why audit_log/verify is
 * where the deep storage/HMAC/signature coverage actually comes from,
 * not from this file's trivial ledger-op stand-ins.
 *
 * Controlled via one environment variable, naming a SENTINEL FILE
 * rather than holding a boolean directly: FSQL_MOCK_ENT_FAIL is fixed
 * for the daemon's whole process lifetime (plain getenv, read fresh on
 * every call but the process's own environ never changes after exec),
 * so a literal on/off value in it could only be flipped by restarting
 * the daemon. A sentinel PATH lets the test instead touch/remove that
 * file between SQL calls on one still-running daemon: file present ->
 * every call fails (FSQL_ESTORAGE); absent, or the env var itself
 * unset -> every call succeeds. access(2), not a cached fopen: must
 * see every create/unlink the test makes without this library being
 * reloaded.
 *
 * Build: cc -shared -fPIC -std=c99 -I<repo>/include \
 *          tests/mock_enterprise_core.c -o <tmp>/mock_enterprise_core.so
 */
#include "fractalsql.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
/* access()/F_OK are POSIX (<unistd.h>); MSVC's CRT has no unistd.h at
 * all. <io.h>'s _access() is the direct MSVC CRT equivalent; its mode 0
 * means the same "existence only" check POSIX's F_OK does. (Confirmed
 * the same fix was needed porting this identical file to fractalsql-
 * postgresql's own gate 31 build on Windows -- that repo hit the exact
 * same cl.exe failure the first time it compiled this file there.) */
#if defined(_WIN32)
#include <io.h>
#define access _access
#ifndef F_OK
#define F_OK 0
#endif
#else
#include <unistd.h>
#endif

static int mock_should_fail(void) {
    const char *path = getenv("FSQL_MOCK_ENT_FAIL");
    return path != NULL && path[0] != '\0' && access(path, F_OK) == 0;
}

/* ---- the 8 required symbols (ensure_enterprise_lib's own check) ---- */

FSQL_API int fsql_ledger_flush(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_load(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_compact(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_reset_soft(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_reset_hard(fsql_ctx *ctx) {
    (void) ctx;
    return mock_should_fail() ? FSQL_ESTORAGE : FSQL_OK;
}

FSQL_API int fsql_ledger_truth_count(const fsql_ctx *ctx, size_t *out) {
    (void) ctx;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    *out = 0;
    return FSQL_OK;
}

FSQL_API int fsql_ledger_shadow_count(const fsql_ctx *ctx, size_t *out) {
    (void) ctx;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    *out = 0;
    return FSQL_OK;
}

/* Pure echo, not real unpacking (see the file header): copies the
 * caller's blob back out verbatim, exercising fractal_audit_unpack's
 * own buffer-growth retry loop (FSQL_ETRUNCATED when it doesn't fit)
 * without claiming to decode anything. */
FSQL_API int fsql_audit_unpack(const void *blob, size_t blob_len,
                               char *json_out, size_t *json_cap) {
    if (mock_should_fail()) return FSQL_ESTORAGE;
    if (blob_len > *json_cap) {
        *json_cap = blob_len;
        return FSQL_ETRUNCATED;
    }
    if (blob_len > 0) memcpy(json_out, blob, blob_len);
    *json_cap = blob_len;
    return FSQL_OK;
}

/* ---- optional symbols (fsql_optimize_portfolio_multimodal family) -- */

/* One canned candidate: uniform weights over the first k assets,
 * everything past asset k-1 left at 0.0. Real diversity/Sharpe search
 * is the proprietary core's job; this just gives the UDF-level JSON
 * assembly loop (ent_jsonbuf_*) real, bounded data to walk. */
static void
mock_uniform_weights(double *out_weights, size_t n_assets, size_t k) {
    size_t i;
    double w = (k > 0) ? (1.0 / (double) k) : 0.0;
    for (i = 0; i < n_assets; i++) out_weights[i] = (i < k) ? w : 0.0;
}

FSQL_API int
fsql_optimize_portfolio_multimodal(const double *mu, const double *cov,
                                   size_t n_assets, size_t k,
                                   int n_restarts,
                                   double overlap_threshold,
                                   double quality_frac,
                                   uint64_t seed,
                                   double *out_weights,
                                   double *out_sharpes,
                                   int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts;
    (void) overlap_threshold; (void) quality_frac; (void) seed;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    mock_uniform_weights(out_weights, n_assets, k);
    out_sharpes[0] = 0.5;
    *out_n_found = 1;
    return FSQL_OK;
}

FSQL_API int
fsql_optimize_portfolio_multimodal_ex(const double *mu, const double *cov,
                                      size_t n_assets, size_t k,
                                      int n_restarts,
                                      double overlap_threshold,
                                      double quality_frac,
                                      uint64_t seed,
                                      int use_obl, int diffusion_mode,
                                      double *out_weights,
                                      double *out_sharpes,
                                      int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts;
    (void) overlap_threshold; (void) quality_frac; (void) seed;
    (void) use_obl; (void) diffusion_mode;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    mock_uniform_weights(out_weights, n_assets, k);
    out_sharpes[0] = 0.5;
    *out_n_found = 1;
    return FSQL_OK;
}

FSQL_API int
fsql_optimize_portfolio_multimodal_pareto(const double *mu, const double *cov,
                                          size_t n_assets, size_t k,
                                          int n_restarts, int max_front,
                                          uint64_t seed,
                                          int use_obl, int diffusion_mode,
                                          double *out_weights,
                                          double *out_returns,
                                          double *out_risks,
                                          int *out_n_found) {
    (void) mu; (void) cov; (void) n_restarts; (void) max_front;
    (void) seed; (void) use_obl; (void) diffusion_mode;
    if (mock_should_fail()) return FSQL_ESTORAGE;
    mock_uniform_weights(out_weights, n_assets, k);
    out_returns[0] = 0.1;
    out_risks[0]   = 0.05;
    *out_n_found   = 1;
    return FSQL_OK;
}
