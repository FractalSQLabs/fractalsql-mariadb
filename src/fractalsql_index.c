/* src/fractalsql_index.c -- the fractal_index_* surface for MariaDB.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * ARCHITECTURE (this host is split-process; see service/README.md):
 *
 *   The shim (service/shim, GPL-2.0-only) links NO core code and NO core
 *   header. It forwards every UDF call to the fractalsqld daemon over the
 *   local socket. The daemon (service/daemon, Apache-2.0) links the core
 *   archive and is where every UDF body actually runs -- so THE INDEX
 *   MATHS LIVES HERE, in the daemon, and never in the shim.
 *
 *   The daemon is database-free by design: it cannot read a table. So the
 *   TABLE I/O lives in stored procedures (sql/install_udf.sql):
 *
 *     fractal_index_create(table, column [, options])  -- procedure
 *     fractal_index_rebuild(name)                      -- procedure
 *     fractal_index_drop(name)                         -- procedure
 *     fractal_index_info(name)                         -- procedure
 *     fractal_search(table, column, query, k [, options])  -- procedure
 *     fractal_index_candidates(table, column, query [, options]) -- procedure
 *
 *   Those procedures read the table in batches by primary-key range, feed
 *   the batches to the daemon through the ONE plumbing UDF below, and
 *   INSERT the finished cells into InnoDB tables created at runtime. At
 *   query time the procedure asks the daemon which cells to probe, selects
 *   those cells' rows from InnoDB, hands them back to the daemon, and then
 *   VERIFIES every candidate against the base table with the shared
 *   double-precision cosine (fsql_precision.h). The index never returns an
 *   unverified distance as an answer.
 *
 * THE PLUMBING UDF: fractal_index_op(request_json) -> response_json
 *
 *   One stateful UDF, so the whole protocol is in one place and one
 *   functions.def row. The request is a flat JSON object with an "op" key:
 *
 *     {"op":"train_begin","format":"INT8","dim":128,"nlist":0,...}
 *         -> {"token":"T1"}
 *     {"op":"train_add","token":"T1","corpus":"[[1,2],[3,4]]"}
 *         -> {"rows":2}
 *     {"op":"train_end","token":"T1"}
 *         -> {"token":"M1","model":"<hex>","dim":128,"nlist":32,"code_bytes":32}
 *     {"op":"encode","token":"M1","corpus":"[[1,2],[3,4]]"}
 *         -> {"cells":"0,1","codes":"<hex>"}
 *     {"op":"calibrate","token":"M1","corpus":"[[1,2],..]","k":10,"target":0.95,"samples":200}
 *         -> {"estimates":[..],"recommended_nprobe":P,"reaches_target":true}   (a recall ESTIMATE from the sample rows)
 *     {"op":"open","model":"<hex>"}                 -> {"token":"I1",...}
 *     {"op":"probe","token":"I1","query":"[1,2]","nprobe":4}
 *         -> {"cells":"3,7"}
 *     {"op":"load_cell","token":"I1","cell":3,"ids":"1,2,3","codes":"<hex>"}
 *         -> {"rows":3}
 *     {"op":"search","token":"I1","query":"[1,2]","nprobe":4,"shortlist":30}
 *         -> {"candidates":[{"doc_id":7,"distance":0.01}],
 *             "rows_scanned":42,"cells_probed":4}
 *     {"op":"verify","query":"[1,2]","ids":"1,2,3","corpus":"[[1,2],[3,4],[5,6]]"}
 *         -> {"distances":[0.0,0.5,0.9]}      (EXACT double cosines)
 *     {"op":"close","token":"I1"}                 -> {"ok":1}
 *
 *   A failure is {"error":"<message>"}; the calling procedure turns that
 *   into a SQL error.
 *
 * THE WEAK-SYMBOL GUARD
 *
 *   The vendored core archive in include/<platform>/ carries the IVF maths,
 *   and the daemon links that archive on every platform, so the entry
 *   points are referenced directly:
 *
 *     - GCC/Clang (Linux, macOS): a strong reference, so the linker pulls
 *       the archive member in. (A WEAK reference would not: an archive
 *       member is extracted only to resolve an undefined STRONG reference,
 *       so a weak one leaves the symbol NULL and the index silently
 *       unavailable even with a fresh archive.)
 *     - MSVC (Windows): the same strong reference against the same static
 *       .lib the daemon already links. It used to be a run-time lookup in
 *       the core's DLL instead, which needed that DLL to sit next to the
 *       daemon -- something a normal install does not have -- so the index
 *       reported itself unavailable on Windows while the same build was
 *       fine on Linux.
 *
 *   A build against a core that predates the index opts out explicitly with
 *   -DFSQL_NO_IVF (no reference to the entry points at all). Then EVERY
 *   index operation fails with the one agreed message:
 *     "fractalsql: this build of fractalsql-core does not carry the IVF
 *      index (rebuild the core and refresh include/<platform>)"
 *   so the SQL surface is identical on every platform.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */

#include <mysql.h>

#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <pthread.h>
#endif

#include "fractalsql.h"       /* FSQL_OK */
#include "fractalsql_sql.h"   /* fsql_ivf_* */
#include "fractalsql_parse.h" /* parse_corpus / parse_vector_csv */
#include "fsql_precision.h"   /* the ONE cosine (verification) */

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* The one message every index operation fails with when the core in use
 * does not carry the IVF index (see the header comment). */
#define FI_NO_IVF_MSG \
    "fractalsql: this build of fractalsql-core does not carry the IVF index " \
    "(rebuild the core and refresh include/<platform>)"

#define FI_MAX_DIM        8192
#define FI_MAX_CELLS      4096
#define FI_MAX_CORPUS_ROWS 100000

/* ------------------------------------------------------------------ */
/* The weak-symbol guard                                              */
/* ------------------------------------------------------------------ */

/* The core's IVF maths is referenced STRONGLY on POSIX. The linker extracts an archive member only
 * to resolve an undefined STRONG reference, so a weak reference would leave the symbol NULL -- the
 * index would then be silently unavailable even with a fresh archive. A build against a core that
 * predates the index is opted out of explicitly with -DFSQL_NO_IVF (no reference at all). */
#define FSQL_IVF_REF

/* On POSIX the entry points are redeclared WEAK, so an archive without
 * them still links (the address reads as NULL). On Windows the core is a
 * static .lib with no weak-symbol support, so the entry points are looked
 * up in the core DLL at run time instead -- and there is no redeclaration
 * to make (the header's dllimport would then conflict with it).
 *
 * That was the state when the vendored core had no IVF maths to offer.
 * The core now carries it (the same archive this daemon links statically),
 * so Windows resolves the entry points the same way every other platform
 * does: a strong reference against the archive the daemon already links.
 * The run-time lookup needed a core DLL sitting next to the daemon --
 * which a normal install does not have -- so the index reported itself
 * unavailable ("this build of fractalsql-core does not carry the IVF
 * index") on Windows while the same build was fine on Linux. A build
 * against a core that predates the index opts out with -DFSQL_NO_IVF,
 * exactly as on POSIX. */
#if !defined(FSQL_NO_IVF)
#ifdef __cplusplus
extern "C" {
#endif

extern FSQL_IVF_REF fsql_ivf_trainer *fsql_ivf_trainer_new(const fsql_ivf_options_t *opt, int *rc_out);
extern FSQL_IVF_REF int  fsql_ivf_trainer_add(fsql_ivf_trainer *t, const float *vecs, size_t count);
extern FSQL_IVF_REF int  fsql_ivf_trainer_finish(fsql_ivf_trainer *t, uint8_t **model_out, size_t *model_len_out);
extern FSQL_IVF_REF void fsql_ivf_trainer_free(fsql_ivf_trainer *t);
extern FSQL_IVF_REF fsql_ivf_model *fsql_ivf_model_load(const uint8_t *blob, size_t len, int *rc_out);
extern FSQL_IVF_REF void fsql_ivf_model_free(fsql_ivf_model *m);
extern FSQL_IVF_REF int  fsql_ivf_model_info(const fsql_ivf_model *m, fsql_ivf_info_t *out);
extern FSQL_IVF_REF void fsql_ivf_free(void *p);
extern FSQL_IVF_REF int  fsql_ivf_encode(const fsql_ivf_model *m, const float *vec, uint32_t *cell_out, uint8_t *code_out);
extern FSQL_IVF_REF int  fsql_ivf_normalize(const float *in, size_t dim, float *out);
extern FSQL_IVF_REF fsql_ivf_index *fsql_ivf_index_new(const fsql_ivf_model *m);
extern FSQL_IVF_REF void fsql_ivf_index_free(fsql_ivf_index *x);
extern FSQL_IVF_REF int  fsql_ivf_index_set_cell(fsql_ivf_index *x, uint32_t cell, const int64_t *ids, const uint8_t *codes, size_t n);
extern FSQL_IVF_REF int  fsql_ivf_probe_cells(const fsql_ivf_model *m, const float *query, uint32_t nprobe, uint32_t *cells_out, uint32_t *n_out);
extern FSQL_IVF_REF int  fsql_ivf_search(const fsql_ivf_index *x, const float *query, uint32_t nprobe, uint32_t shortlist,
                                          int64_t *ids_out, double *dist_out, size_t *n_out, fsql_ivf_stats_t *stats_out);
extern FSQL_IVF_REF int  fsql_ivf_sample_rows(uint64_t n_rows, uint32_t count, uint64_t seed, uint64_t *out);
extern FSQL_IVF_REF int  fsql_ivf_exact_topk(const float *corpus_n, const int64_t *ids, size_t n, size_t dim, const float *query_n,
                                               int64_t self_id, int use_self, uint32_t k, int64_t *out_ids, size_t *n_out);
extern FSQL_IVF_REF int  fsql_ivf_estimate_recall(const fsql_ivf_index *x, const float *queries, const int64_t *self_ids,
                                                   const int64_t *truth, size_t nq, uint32_t k, const uint32_t *nprobes, size_t nnp,
                                                   uint32_t shortlist, double target, double *mean_out, double *se_out, double *lo_out,
                                                   double *scanned_out, uint32_t *recommended_out);

#ifdef __cplusplus
}
#endif
#endif /* !FSQL_NO_IVF */

/* The resolved entry points. Every call goes through this table, so a
 * build whose core does not carry the IVF index fails at RUN time (with
 * the agreed message) instead of at LINK time. */
typedef struct fi_api {
    int available;
    fsql_ivf_trainer *(*trainer_new)(const fsql_ivf_options_t *, int *);
    int  (*trainer_add)(fsql_ivf_trainer *, const float *, size_t);
    int  (*trainer_finish)(fsql_ivf_trainer *, uint8_t **, size_t *);
    void (*trainer_free)(fsql_ivf_trainer *);
    fsql_ivf_model *(*model_load)(const uint8_t *, size_t, int *);
    void (*model_free)(fsql_ivf_model *);
    int  (*model_info)(const fsql_ivf_model *, fsql_ivf_info_t *);
    void (*ivf_free)(void *);
    int  (*encode)(const fsql_ivf_model *, const float *, uint32_t *, uint8_t *);
    int  (*normalize)(const float *, size_t, float *);
    fsql_ivf_index *(*index_new)(const fsql_ivf_model *);
    void (*index_free)(fsql_ivf_index *);
    int  (*index_set_cell)(fsql_ivf_index *, uint32_t, const int64_t *, const uint8_t *, size_t);
    int  (*probe_cells)(const fsql_ivf_model *, const float *, uint32_t, uint32_t *, uint32_t *);
    int  (*search)(const fsql_ivf_index *, const float *, uint32_t, uint32_t, int64_t *, double *, size_t *, fsql_ivf_stats_t *);
    int  (*sample_rows)(uint64_t, uint32_t, uint64_t, uint64_t *);
    int  (*exact_topk)(const float *, const int64_t *, size_t, size_t, const float *, int64_t, int, uint32_t, int64_t *, size_t *);
    int  (*estimate_recall)(const fsql_ivf_index *, const float *, const int64_t *, const int64_t *, size_t, uint32_t,
                            const uint32_t *, size_t, uint32_t, double, double *, double *, double *, double *, uint32_t *);
} fi_api;

#if !defined(FSQL_NO_IVF)
/* The entry points are the core's own (strong references, see the redeclarations
 * above), so the linker pulls them out of the archive the daemon already links
 * and they are always there -- on every platform. */
static void fi_resolve(fi_api *api)
{
    memset(api, 0, sizeof *api);
    api->trainer_new     = fsql_ivf_trainer_new;
    api->trainer_add     = fsql_ivf_trainer_add;
    api->trainer_finish  = fsql_ivf_trainer_finish;
    api->trainer_free    = fsql_ivf_trainer_free;
    api->model_load      = fsql_ivf_model_load;
    api->model_free      = fsql_ivf_model_free;
    api->model_info      = fsql_ivf_model_info;
    api->ivf_free        = fsql_ivf_free;
    api->encode          = fsql_ivf_encode;
    api->normalize       = fsql_ivf_normalize;
    api->index_new       = fsql_ivf_index_new;
    api->index_free      = fsql_ivf_index_free;
    api->index_set_cell  = fsql_ivf_index_set_cell;
    api->probe_cells     = fsql_ivf_probe_cells;
    api->search          = fsql_ivf_search;
    api->sample_rows     = fsql_ivf_sample_rows;
    api->exact_topk      = fsql_ivf_exact_topk;
    api->estimate_recall = fsql_ivf_estimate_recall;
    api->available = 1;
}
#else
/* This build was told the core has no IVF maths: no reference to the entry points at all. */
static void fi_resolve(fi_api *api)
{
    memset(api, 0, sizeof *api);
    api->available = 0;
}
#endif

/* ------------------------------------------------------------------ */
/* Portable lock (same pattern as src/fractalsql_session.c)             */
/* ------------------------------------------------------------------ */

#if defined(_WIN32)
static INIT_ONCE        g_lock_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_lock;
static BOOL CALLBACK fi_init_lock_once(PINIT_ONCE ip, PVOID param, PVOID *ctx)
{
    (void) ip; (void) param; (void) ctx;
    InitializeCriticalSection(&g_lock);
    return TRUE;
}
static void fi_lock(void)
{
    InitOnceExecuteOnce(&g_lock_once, fi_init_lock_once, NULL, NULL);
    EnterCriticalSection(&g_lock);
}
static void fi_unlock(void) { LeaveCriticalSection(&g_lock); }
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void fi_lock(void)   { pthread_mutex_lock(&g_lock); }
static void fi_unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

/* ------------------------------------------------------------------ */
/* A tiny growable string buffer (the response builder)                */
/* ------------------------------------------------------------------ */

typedef struct fi_buf {
    char  *p;
    size_t len;
    size_t cap;
    int    failed;
} fi_buf;

static void fi_buf_init(fi_buf *b) { memset(b, 0, sizeof *b); }

static void fi_buf_free(fi_buf *b) { free(b->p); memset(b, 0, sizeof *b); }

static void fi_buf_add(fi_buf *b, const char *s, size_t n)
{
    if (b->failed) return;
    if (b->len + n + 1 > b->cap) {
        size_t nc = b->cap ? b->cap : 256;
        while (nc < b->len + n + 1) nc *= 2;
        char *np = (char *) realloc(b->p, nc);
        if (!np) { b->failed = 1; return; }
        b->p = np; b->cap = nc;
    }
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}

static void fi_buf_puts(fi_buf *b, const char *s) { fi_buf_add(b, s, strlen(s)); }

static void fi_buf_printf(fi_buf *b, const char *fmt, ...)
{
    char tmp[512];
    va_list ap, ap2;
    int n;
    va_start(ap, fmt);
    va_copy(ap2, ap);                          /* the second pass (a long result) reads its own copy */
    n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < 0) { va_end(ap2); b->failed = 1; return; }
    if ((size_t) n < sizeof tmp) { va_end(ap2); fi_buf_add(b, tmp, (size_t) n); return; }
    {
        char *big = (char *) malloc((size_t) n + 1);
        if (!big) { va_end(ap2); b->failed = 1; return; }
        vsnprintf(big, (size_t) n + 1, fmt, ap2);
        va_end(ap2);
        fi_buf_add(b, big, (size_t) n);
        free(big);
    }
}

/* ------------------------------------------------------------------ */
/* A tiny flat-JSON reader (the request side)                         */
/*                                                                      */
/* The request is a FLAT object: string, number, boolean or null values */
/* only. That is all the plumbing needs, and a flat reader cannot be    */
/* confused by nesting.                                                 */
/* ------------------------------------------------------------------ */

/* Returns a pointer to the value text for a top-level key, or NULL. The
 * value is either a quoted string (the returned pointer is INSIDE the
 * quotes, and *len_out is its length) or a bare token (number, true,
 * false, null). */
static const char *fi_json_value(const char *json, const char *key, size_t *len_out)
{
    const char *p = json;

    if (!json || !key) return NULL;
    size_t klen = strlen(key);
    while ((p = strchr(p, '"')) != NULL) {
        /* p points at a quote. It must be the START of a key (preceded by
         * '{' or ',') for this to be a top-level key. */
        const char *before = p;
        while (before > json && (before[-1] == ' ' || before[-1] == '\t' || before[-1] == '\n' || before[-1] == '\r')) before--;
        if (before == json || (before[-1] != '{' && before[-1] != ',')) {
            /* Not a key position: skip this string (handling escapes). */
            p++;
            while (*p) {
                if (*p == '\\' && p[1]) { p += 2; continue; }
                if (*p == '"') break;
                p++;
            }
            if (*p != '"') return NULL;
            p++;
            continue;
        }
        if (strncmp(p + 1, key, klen) == 0 && p[1 + klen] == '"') {
            const char *v = p + 2 + klen;
            while (*v == ' ' || *v == '\t' || *v == '\n' || *v == '\r') v++;
            if (*v != ':') return NULL;
            v++;
            while (*v == ' ' || *v == '\t' || *v == '\n' || *v == '\r') v++;
            if (*v == '"') {
                const char *s = ++v;
                while (*v) {
                    if (*v == '\\' && v[1]) { v += 2; continue; }
                    if (*v == '"') break;
                    v++;
                }
                *len_out = (size_t)(v - s);
                return s;
            }
            {
                const char *s = v;
                while (*v && *v != ',' && *v != '}' && *v != ']') v++;
                *len_out = (size_t)(v - s);
                while (*s == ' ' || *s == '\t') s++;
                {
                    size_t n = *len_out;
                    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\n' || s[n - 1] == '\r')) n--;
                    *len_out = n;
                }
                return s;
            }
        }
        /* Not our key: skip the string. */
        p++;
        while (*p) {
            if (*p == '\\' && p[1]) { p += 2; continue; }
            if (*p == '"') break;
            p++;
        }
        if (*p != '"') return NULL;
        p++;
    }
    return NULL;
}

/* Copies a string value into out (unescaping the JSON escapes the SQL
 * side can produce). Returns 1 on success. */
static int fi_json_get_str(const char *json, const char *key, char *out, size_t cap)
{
    size_t len = 0;
    const char *v = fi_json_value(json, key, &len);
    size_t i, o = 0;
    if (!v) { if (cap) out[0] = 0; return 0; }
    for (i = 0; i < len && o + 1 < cap; i++) {
        char c = v[i];
        if (c == '\\' && i + 1 < len) {
            char e = v[++i];
            switch (e) {
            case 'n': c = '\n'; break;
            case 't': c = '\t'; break;
            case 'r': c = '\r'; break;
            case 'b': c = '\b'; break;
            case 'f': c = '\f'; break;
            case 'u': {
                /* Only the escapes the SQL side can produce are needed:
                 * a \uXXXX pair for a BMP code point. */
                unsigned code = 0;
                int k, ok = 1;
                for (k = 0; k < 4 && i + 1 < len; k++) {
                    char h = v[++i];
                    unsigned d;
                    if (h >= '0' && h <= '9') d = (unsigned)(h - '0');
                    else if (h >= 'a' && h <= 'f') d = (unsigned)(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') d = (unsigned)(h - 'A' + 10);
                    else { ok = 0; break; }
                    code = code * 16u + d;
                }
                if (!ok) { c = '?'; break; }
                if (code < 0x80u) c = (char) code;
                else if (code < 0x800u) {
                    /* Two UTF-8 bytes; the buffer has room for one byte
                     * here, so the rest is dropped rather than written
                     * out of bounds. */
                    c = (char)(0xC0u | (code >> 6));
                    if (o + 2 < cap) { out[o++] = c; out[o++] = (char)(0x80u | (code & 0x3Fu)); continue; }
                    break;
                } else {
                    c = '?';
                }
                break;
            }
            default: c = e; break;
            }
        }
        out[o++] = c;
    }
    if (cap) out[o] = 0;
    return 1;
}

static double fi_json_get_double(const char *json, const char *key, double dflt)
{
    size_t len = 0;
    const char *v = fi_json_value(json, key, &len);
    char tmp[64];
    double d;
    char *e;
    if (!v || len == 0 || len >= sizeof tmp) return dflt;
    memcpy(tmp, v, len); tmp[len] = 0;
    d = strtod(tmp, &e);
    if (e == tmp) return dflt;
    return d;
}

static long long fi_json_get_int(const char *json, const char *key, long long dflt)
{
    size_t len = 0;
    const char *v = fi_json_value(json, key, &len);
    char tmp[64];
    long long r;
    char *e;
    if (!v || len == 0 || len >= sizeof tmp) return dflt;
    memcpy(tmp, v, len); tmp[len] = 0;
    r = strtoll(tmp, &e, 10);
    if (e == tmp) return dflt;
    return r;
}

static int fi_json_get_bool(const char *json, const char *key, int dflt)
{
    size_t len = 0;
    const char *v = fi_json_value(json, key, &len);
    if (!v) return dflt;
    if (len == 4 && strncmp(v, "true", 4) == 0) return 1;
    if (len == 5 && strncmp(v, "false", 5) == 0) return 0;
    return dflt;
}

/* ------------------------------------------------------------------ */
/* Hex helpers                                                         */
/* ------------------------------------------------------------------ */

static int fi_hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void fi_hex_encode(fi_buf *b, const uint8_t *p, size_t n)
{
    static const char *hexd = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        char two[2];
        two[0] = hexd[(p[i] >> 4) & 0xF];
        two[1] = hexd[p[i] & 0xF];
        fi_buf_add(b, two, 2);
    }
}

/* Decodes a hex string into a malloc'd buffer. Returns the byte count or
 * -1 on a malformed input. */
static long fi_hex_decode(const char *hex, size_t hexlen, uint8_t **out)
{
    size_t n, i;
    uint8_t *buf;
    if (hexlen % 2u) return -1;
    n = hexlen / 2u;
    buf = (uint8_t *) malloc(n ? n : 1);
    if (!buf) return -1;
    for (i = 0; i < n; i++) {
        int hi = fi_hexval((unsigned char) hex[2 * i]);
        int lo = fi_hexval((unsigned char) hex[2 * i + 1]);
        if (hi < 0 || lo < 0) { free(buf); return -1; }
        buf[i] = (uint8_t)((hi << 4) | lo);
    }
    *out = buf;
    return (long) n;
}

/* ------------------------------------------------------------------ */
/* State: trainers, models and resident indexes                        */
/* ------------------------------------------------------------------ */

typedef struct fi_trainer {
    struct fi_trainer *next;
    char                token[24];
    fsql_ivf_trainer   *t;
} fi_trainer;

typedef struct fi_model {
    struct fi_model *next;
    char             token[24];
    fsql_ivf_model  *m;
    fsql_ivf_info_t  info;
} fi_model;

typedef struct fi_index {
    struct fi_index *next;
    char             token[24];
    fsql_ivf_model  *m;
    fsql_ivf_index  *x;
    fsql_ivf_info_t  info;
} fi_index;

static fi_trainer *g_trainers = NULL;
static fi_model   *g_models   = NULL;
static fi_index   *g_indexes  = NULL;
static unsigned long g_token_seq = 0;

static void fi_make_token(char *out, size_t cap, const char *prefix)
{
    unsigned long n;
    fi_lock();
    n = ++g_token_seq;
    fi_unlock();
    snprintf(out, cap, "%s%lu", prefix, n);
}

static fi_trainer *fi_find_trainer(const char *token)
{
    for (fi_trainer *t = g_trainers; t; t = t->next)
        if (strcmp(t->token, token) == 0) return t;
    return NULL;
}

static fi_model *fi_find_model(const char *token)
{
    for (fi_model *m = g_models; m; m = m->next)
        if (strcmp(m->token, token) == 0) return m;
    return NULL;
}

static fi_index *fi_find_index(const char *token)
{
    for (fi_index *i = g_indexes; i; i = i->next)
        if (strcmp(i->token, token) == 0) return i;
    return NULL;
}

static void fi_drop_trainer(const char *token, const fi_api *api)
{
    fi_trainer **link = &g_trainers;
    fi_lock();
    while (*link) {
        if (strcmp((*link)->token, token) == 0) {
            fi_trainer *dead = *link;
            *link = dead->next;
            if (dead->t && api->trainer_free) api->trainer_free(dead->t);
            free(dead);
            break;
        }
        link = &(*link)->next;
    }
    fi_unlock();
}

static void fi_drop_model(const char *token, const fi_api *api)
{
    fi_model **link = &g_models;
    fi_lock();
    while (*link) {
        if (strcmp((*link)->token, token) == 0) {
            fi_model *dead = *link;
            *link = dead->next;
            if (dead->m && api->model_free) api->model_free(dead->m);
            free(dead);
            break;
        }
        link = &(*link)->next;
    }
    fi_unlock();
}

static void fi_drop_index(const char *token, const fi_api *api)
{
    fi_index **link = &g_indexes;
    fi_lock();
    while (*link) {
        if (strcmp((*link)->token, token) == 0) {
            fi_index *dead = *link;
            *link = dead->next;
            if (dead->x && api->index_free) api->index_free(dead->x);
            if (dead->m && api->model_free) api->model_free(dead->m);
            free(dead);
            break;
        }
        link = &(*link)->next;
    }
    fi_unlock();
}

/* ------------------------------------------------------------------ */
/* Vector helpers                                                      */
/* ------------------------------------------------------------------ */

/* Parses a bracketed-JSON corpus ("[[1,2],[3,4]]") into float32 rows.
 * expected_dim of 0 means "take the first row's dimension". */
static int fi_parse_corpus(const char *text, size_t len, size_t expected_dim,
                            float ***rows_out, size_t *n_rows_out, size_t *dim_out,
                            char *err, size_t ecap)
{
    double *dv = NULL;
    size_t  n = 0, dim = 0, i;
    float **rows = NULL;
    float  *flat = NULL;

    if (!parse_corpus(text, len, expected_dim, &dv, &n, &dim, err)) return -1;
    if (n == 0 || dim == 0) {
        free(dv);
        snprintf(err, ecap, "fractalsql: the corpus is empty");
        return -1;
    }
    if (dim > FI_MAX_DIM) {
        free(dv);
        snprintf(err, ecap, "fractalsql: dimension %llu exceeds the %d limit", (unsigned long long) dim, FI_MAX_DIM);
        return -1;
    }
    flat = (float *) malloc(n * dim * sizeof(float));
    rows = (float **) malloc(n * sizeof(float *));
    if (!flat || !rows) {
        free(dv); free(flat); free((void *) rows);
        snprintf(err, ecap, "fractalsql: out of memory");
        return -1;
    }
    for (i = 0; i < n * dim; i++) flat[i] = (float) dv[i];
    for (i = 0; i < n; i++) rows[i] = flat + i * dim;
    free(dv);
    *rows_out = rows; *n_rows_out = n; *dim_out = dim;
    return 0;
}

static void fi_free_corpus(float **rows, size_t n, size_t dim)
{
    (void) dim;
    if (!rows) return;
    if (n > 0) free(rows[0]);
    free((void *) rows);
}

/* Parses one vector text into a float32 buffer. */
static int fi_parse_one(const char *text, size_t len, float **out, size_t *dim_out, char *err, size_t ecap)
{
    double *dv = NULL;
    size_t  n = 0, i;
    float  *fv;
    if (!parse_vector_csv(text, len, &dv, &n, err)) return -1;
    if (n == 0 || n > FI_MAX_DIM) {
        free(dv);
        snprintf(err, ecap, "fractalsql: the query vector is empty or too wide");
        return -1;
    }
    fv = (float *) malloc(n * sizeof(float));
    if (!fv) { free(dv); snprintf(err, ecap, "fractalsql: out of memory"); return -1; }
    for (i = 0; i < n; i++) fv[i] = (float) dv[i];
    free(dv);
    *out = fv; *dim_out = n;
    return 0;
}

/* ------------------------------------------------------------------ */
/* The operations                                                      */
/* ------------------------------------------------------------------ */

static int fi_fmt_from_name(const char *s)
{
    if (!s) return -1;
    if (!strcmp(s, "INT8"))  return FSQL_IVF_FMT_INT8;
    if (!strcmp(s, "INT4"))  return FSQL_IVF_FMT_INT4;
    if (!strcmp(s, "FP16"))  return FSQL_IVF_FMT_FP16;
    if (!strcmp(s, "FP32"))  return FSQL_IVF_FMT_FP32;
    return -1;
}

static const char *fi_fmt_name(int fmt)
{
    switch (fmt) {
    case FSQL_IVF_FMT_INT8: return "INT8";
    case FSQL_IVF_FMT_INT4: return "INT4";
    case FSQL_IVF_FMT_FP16: return "FP16";
    case FSQL_IVF_FMT_FP32: return "FP32";
    default: return "?";
    }
}

/* train_begin */
static void fi_op_train_begin(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char        fmtname[16] = "INT8";
    long long   dim = 0, nlist = 0, pca = 0, iters = 0, sample = 0, seed = 1;
    int         fmt;
    fsql_ivf_options_t o;
    fsql_ivf_trainer  *t;
    int         rc = 0;
    fi_trainer *ent;

    fi_json_get_str(req, "format", fmtname, sizeof fmtname);
    fmt = fi_fmt_from_name(fmtname);
    if (fmt < 0) { snprintf(err, ecap, "fractalsql: vector_format must be INT8, INT4, FP16 or FP32"); return; }
    dim    = fi_json_get_int(req, "dim", 0);
    nlist  = fi_json_get_int(req, "nlist", 0);
    pca    = fi_json_get_int(req, "pca_dim", 0);
    iters  = fi_json_get_int(req, "iters", 0);
    sample = fi_json_get_int(req, "sample", 0);
    seed   = fi_json_get_int(req, "seed", 1);
    if (dim <= 0 || dim > FI_MAX_DIM) { snprintf(err, ecap, "fractalsql: the index dimension must be 1..%d", FI_MAX_DIM); return; }
    if (nlist < 0 || nlist > FI_MAX_CELLS) { snprintf(err, ecap, "fractalsql: nlist must be 0..%d", FI_MAX_CELLS); return; }
    if (pca < 0 || pca > FI_MAX_DIM) { snprintf(err, ecap, "fractalsql: pca_dim must be 0..%d", FI_MAX_DIM); return; }
    if (iters < 0 || iters > 100) { snprintf(err, ecap, "fractalsql: iters must be 0..100"); return; }
    if (sample < 0 || sample > 1000000) { snprintf(err, ecap, "fractalsql: sample must be 0..1000000"); return; }
    if (seed <= 0) seed = 1;

    memset(&o, 0, sizeof o);
    o.struct_size = sizeof o;
    o.dim = (uint32_t) dim;
    o.format = (uint32_t) fmt;
    o.nlist = (uint32_t) nlist;
    o.pca_dim = (fmt <= FSQL_IVF_FMT_INT4) ? (uint32_t) pca : 0u;
    o.kmeans_iters = (uint32_t) iters;
    o.sample = (uint32_t) sample;
    o.seed = (uint64_t) seed;

    t = api->trainer_new(&o, &rc);
    if (!t) {
        snprintf(err, ecap, "fractalsql: the index options were refused for dimension %lld "
                            "(INT8/INT4 need dimension <= 4096 and pca_dim <= dimension)", dim);
        return;
    }
    ent = (fi_trainer *) calloc(1, sizeof *ent);
    if (!ent) { api->trainer_free(t); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    fi_make_token(ent->token, sizeof ent->token, "T");
    ent->t = t;
    fi_lock();
    ent->next = g_trainers;
    g_trainers = ent;
    fi_unlock();
    fi_buf_printf(out, "{\"token\":\"%s\"}", ent->token);
}

/* train_add */
static void fi_op_train_add(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    char     *corpus = NULL;
    size_t    clen = 0;
    float   **rows = NULL;
    size_t    nrows = 0, dim = 0;
    fi_trainer *t;
    int       rc;

    (void) api;
    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no trainer token"); return; }
    {
        size_t vlen = 0;
        const char *v = fi_json_value(req, "corpus", &vlen);
        if (!v) { snprintf(err, ecap, "fractalsql: no corpus"); return; }
        corpus = (char *) malloc(vlen + 1);
        if (!corpus) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
        memcpy(corpus, v, vlen); corpus[vlen] = 0; clen = vlen;
    }
    fi_lock();
    t = fi_find_trainer(token);
    fi_unlock();
    if (!t) { free(corpus); snprintf(err, ecap, "fractalsql: no trainer named '%s'", token); return; }
    if (fi_parse_corpus(corpus, clen, 0, &rows, &nrows, &dim, err, ecap) != 0) { free(corpus); return; }
    free(corpus);
    if (nrows > FI_MAX_CORPUS_ROWS) {
        fi_free_corpus(rows, nrows, dim);
        snprintf(err, ecap, "fractalsql: a training batch carries more than %d rows", FI_MAX_CORPUS_ROWS);
        return;
    }
    rc = api->trainer_add(t->t, rows[0], nrows);
    fi_free_corpus(rows, nrows, dim);
    if (rc != FSQL_OK) { snprintf(err, ecap, "fractalsql: the trainer refused the batch"); return; }
    fi_buf_printf(out, "{\"rows\":%llu}", (unsigned long long) nrows);
}

/* train_end */
static void fi_op_train_end(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    uint8_t  *blob = NULL;
    size_t    blen = 0;
    int       rc = 0;
    fi_trainer *t;
    fi_model  *ent;
    fsql_ivf_info_t info;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no trainer token"); return; }
    fi_lock();
    t = fi_find_trainer(token);
    fi_unlock();
    if (!t) { snprintf(err, ecap, "fractalsql: no trainer named '%s'", token); return; }
    rc = api->trainer_finish(t->t, &blob, &blen);
    if (rc != FSQL_OK || !blob) {
        if (blob) api->ivf_free(blob);
        snprintf(err, ecap, "fractalsql: the trainer could not be finished (no vectors to index?)");
        return;
    }
    ent = (fi_model *) calloc(1, sizeof *ent);
    if (!ent) { api->ivf_free(blob); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    ent->m = api->model_load(blob, blen, &rc);
    if (!ent->m) {
        api->ivf_free(blob);
        free(ent);
        snprintf(err, ecap, "fractalsql: the trained model failed validation");
        return;
    }
    api->model_info(ent->m, &info);
    ent->info = info;
    fi_make_token(ent->token, sizeof ent->token, "M");
    fi_lock();
    ent->next = g_models;
    g_models = ent;
    fi_unlock();
    fi_drop_trainer(token, api);

    fi_buf_printf(out, "{\"token\":\"%s\",\"model\":\"", ent->token);
    fi_hex_encode(out, blob, blen);
    fi_buf_printf(out, "\",\"dim\":%u,\"format\":\"%s\",\"nlist\":%u,\"pca_dim\":%u,\"code_bytes\":%u,\"model_bytes\":%llu}",
                  info.dim, fi_fmt_name((int) info.format), info.nlist, info.pca_dim, info.code_bytes, blen);
    api->ivf_free(blob);
}

/* encode */
static void fi_op_encode(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    char     *corpus = NULL;
    size_t    clen = 0, vlen = 0;
    const char *v;
    float   **rows = NULL;
    size_t    nrows = 0, dim = 0, i;
    fi_model *m;
    fi_index *ixh = NULL;
    fsql_ivf_model *mdl = NULL;
    fsql_ivf_info_t minfo;
    uint8_t *code = NULL;
    uint32_t *cells = NULL;
    size_t    codebytes = 0;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no model token"); return; }
    v = fi_json_value(req, "corpus", &vlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no corpus"); return; }
    corpus = (char *) malloc(vlen + 1);
    if (!corpus) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(corpus, v, vlen); corpus[vlen] = 0; clen = vlen;

    fi_lock();
    m = fi_find_model(token);
    if (m) { mdl = m->m; minfo = m->info; }
    else {                                                                   /* an opened index encodes too (a refresh) */
        ixh = fi_find_index(token);
        if (ixh != NULL) { mdl = ixh->m; minfo = ixh->info; }
    }
    fi_unlock();
    if (!mdl) { free(corpus); snprintf(err, ecap, "fractalsql: no model named '%s'", token); return; }
    if (fi_parse_corpus(corpus, clen, minfo.dim, &rows, &nrows, &dim, err, ecap) != 0) { free(corpus); return; }
    free(corpus);

    /* The cells and the codes come back as two PARALLEL JSON arrays, so
     * the SQL side can join them to the row ids by ordinality (JSON_TABLE
     * with FOR ORDINALITY) without splitting a flat string. */
    codebytes = minfo.code_bytes ? minfo.code_bytes : 1;
    cells = (uint32_t *) malloc(sizeof(uint32_t) * (nrows ? nrows : 1));
    code  = (uint8_t *)  malloc((size_t) codebytes * (nrows ? nrows : 1));
    if (!cells || !code) {
        free(cells); free(code);
        fi_free_corpus(rows, nrows, dim);
        snprintf(err, ecap, "fractalsql: out of memory");
        return;
    }
    for (i = 0; i < nrows; i++) {
        if (api->encode(mdl, rows[i], &cells[i], code + i * codebytes) != FSQL_OK) {
            free(cells); free(code);
            fi_free_corpus(rows, nrows, dim);
            snprintf(err, ecap, "fractalsql: the encode pass failed on row %llu", (unsigned long long) i);
            return;
        }
    }
    fi_buf_puts(out, "{\"cells\":[");
    for (i = 0; i < nrows; i++) {
        if (i) fi_buf_puts(out, ",");
        fi_buf_printf(out, "%u", cells[i]);
    }
    fi_buf_puts(out, "],\"codes\":[");
    for (i = 0; i < nrows; i++) {
        if (i) fi_buf_puts(out, ",");
        fi_buf_puts(out, "\"");
        fi_hex_encode(out, code + i * codebytes, codebytes);
        fi_buf_puts(out, "\"");
    }
    fi_buf_printf(out, "],\"code_bytes\":%u,\"rows\":%llu}", minfo.code_bytes, (unsigned long long) nrows);
    free(cells); free(code);
    fi_free_corpus(rows, nrows, dim);
}

/* calibrate: estimate the recall of a model on a SAMPLE of the corpus. The request carries the sample rows (a few thousand at most); the
 * op encodes them, builds a temporary index over them with the trained model, uses each sample row as a query (left out of its own ground
 * truth) against the exact top-k of the sample, and runs the core's recall estimate at nprobe 1,2,4..nlist. The figure is an estimate from
 * a sample, not a measurement of the full table:
 *   {"op":"calibrate","token":"M1","corpus":"[[..],..]","k":10,"target":0.95,"samples":200,"shortlist":0,"seed":1}
 *     -> {"samples":S,"k":10,"target":0.95,"shortlist":N,"rows":R,"estimates":[{"nprobe":1,"recall":..,"se":..,"ci95_low":..,
 *         "mean_rows_scanned":..},..],"recommended_nprobe":P,"reaches_target":true|false} */
#define FI_CALIB_MIN_ROWS 12
#define FI_CALIB_MAX_ROWS 20000
static void fi_op_calibrate(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char token[24] = "";
    char *corpus = NULL;
    size_t vlen = 0, nrows = 0, dim = 0, i, c;
    const char *v;
    float **rows = NULL;
    fi_model *m;
    fi_index *ixh;
    fsql_ivf_model *mdl = NULL;
    fsql_ivf_info_t info;
    fsql_ivf_index *x = NULL;
    float *xn = NULL, *q = NULL;
    int64_t *ids = NULL, *self = NULL, *truth = NULL, *cellids = NULL;
    uint32_t *cells = NULL, *cellcnt = NULL;
    uint8_t *codes = NULL, *cellcodes = NULL;
    uint64_t *pos = NULL;
    uint32_t np[32], rec = 0, shortlist, K;
    double mean[32], se[32], lo[32], sc[32], target;
    size_t nnp = 0, codebytes;
    long long samples;
    int rc = FSQL_OK, er = FSQL_ERR_INVALID;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no model token"); return; }
    v = fi_json_value(req, "corpus", &vlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no corpus"); return; }
    corpus = (char *) malloc(vlen + 1);
    if (!corpus) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(corpus, v, vlen); corpus[vlen] = 0;
    fi_lock();
    m = fi_find_model(token);
    if (m) { mdl = m->m; info = m->info; }
    else if ((ixh = fi_find_index(token)) != NULL) { mdl = ixh->m; info = ixh->info; }
    fi_unlock();
    if (!mdl) { free(corpus); snprintf(err, ecap, "fractalsql: no model named '%s'", token); return; }
    if (fi_parse_corpus(corpus, vlen, info.dim, &rows, &nrows, &dim, err, ecap) != 0) { free(corpus); return; }
    free(corpus);
    if (nrows < FI_CALIB_MIN_ROWS || nrows > FI_CALIB_MAX_ROWS) {
        fi_free_corpus(rows, nrows, dim);
        snprintf(err, ecap, "fractalsql: calibration needs %d to %d sample rows (got %llu)", FI_CALIB_MIN_ROWS, FI_CALIB_MAX_ROWS,
                 (unsigned long long) nrows);
        return;
    }
    K = (uint32_t) fi_json_get_int(req, "k", 10);
    if (K < 1) K = 1;
    if (K > 100) K = 100;
    if (K >= nrows) K = (uint32_t) nrows - 1u;
    target = fi_json_get_double(req, "target", 0.95);
    if (target <= 0.0 || target > 1.0) target = 0.95;
    samples = fi_json_get_int(req, "samples", 200);
    if (samples < 20) samples = 20;
    if (samples > 2000) samples = 2000;
    if ((size_t) samples > nrows) samples = (long long) nrows;
    shortlist = (uint32_t) fi_json_get_int(req, "shortlist", 0);
    if (shortlist < K + 5u) shortlist = K * 3u > K + 5u ? K * 3u : K + 5u;
    codebytes = info.code_bytes ? info.code_bytes : 1;

    xn = (float *) malloc(nrows * dim * sizeof(float));
    q = (float *) malloc((size_t) samples * dim * sizeof(float));
    ids = (int64_t *) malloc(nrows * sizeof(int64_t));
    cells = (uint32_t *) malloc(nrows * sizeof(uint32_t));
    codes = (uint8_t *) malloc(nrows * codebytes);
    self = (int64_t *) malloc((size_t) samples * sizeof(int64_t));
    truth = (int64_t *) malloc((size_t) samples * K * sizeof(int64_t));
    pos = (uint64_t *) malloc((size_t) samples * sizeof(uint64_t));
    cellcnt = (uint32_t *) calloc(info.nlist ? info.nlist : 1, sizeof(uint32_t));
    cellids = (int64_t *) malloc(nrows * sizeof(int64_t));
    cellcodes = (uint8_t *) malloc(nrows * codebytes);
    if (!xn || !q || !ids || !cells || !codes || !self || !truth || !pos || !cellcnt || !cellids || !cellcodes) {
        snprintf(err, ecap, "fractalsql: out of memory");
        goto done;
    }
    for (i = 0; i < nrows; i++) {
        ids[i] = (int64_t) i;
        if (api->normalize(rows[i], dim, xn + i * dim) != FSQL_OK ||
            api->encode(mdl, rows[i], &cells[i], codes + i * codebytes) != FSQL_OK || cells[i] >= info.nlist) {
            snprintf(err, ecap, "fractalsql: the calibration encode failed on sample row %llu", (unsigned long long) i);
            goto done;
        }
        cellcnt[cells[i]]++;
    }
    x = api->index_new(mdl);
    if (!x) { snprintf(err, ecap, "fractalsql: out of memory building the calibration index"); goto done; }
    for (c = 0; c < info.nlist; c++) {
        size_t n = 0;
        if (!cellcnt[c]) continue;
        for (i = 0; i < nrows; i++) {
            if (cells[i] != c) continue;
            cellids[n] = ids[i];
            memcpy(cellcodes + n * codebytes, codes + i * codebytes, codebytes);
            n++;
        }
        if (api->index_set_cell(x, (uint32_t) c, cellids, cellcodes, n) != FSQL_OK) {
            snprintf(err, ecap, "fractalsql: out of memory loading a calibration cell");
            goto done;
        }
    }
    rc = api->sample_rows(nrows, (uint32_t) samples, (uint64_t) fi_json_get_int(req, "seed", 1), pos);
    for (i = 0; rc == FSQL_OK && i < (size_t) samples; i++) {
        size_t nt = 0;
        memcpy(q + i * dim, rows[pos[i]], dim * sizeof(float));
        self[i] = ids[pos[i]];
        rc = api->exact_topk(xn, ids, nrows, dim, xn + pos[i] * dim, self[i], 1, K, truth + i * K, &nt);
        if (rc == FSQL_OK && nt != K) rc = FSQL_ERR_INVALID;
    }
    if (rc != FSQL_OK) { snprintf(err, ecap, "fractalsql: the calibration ground truth failed"); goto done; }
    for (c = 1; c < info.nlist && nnp < 30; c *= 2u) np[nnp++] = (uint32_t) c;
    np[nnp++] = info.nlist;
    er = api->estimate_recall(x, q, self, truth, (size_t) samples, K, np, nnp, shortlist, target, mean, se, lo, sc, &rec);
    if (er != FSQL_OK && er != 1) { snprintf(err, ecap, "fractalsql: the recall estimate failed"); goto done; }
    fi_buf_printf(out, "{\"samples\":%lld,\"k\":%u,\"target\":%g,\"shortlist\":%u,\"rows\":%llu,\"estimates\":[", samples, K, target, shortlist,
                  (unsigned long long) nrows);
    for (i = 0; i < nnp; i++)
        fi_buf_printf(out, "%s{\"nprobe\":%u,\"recall\":%.4f,\"se\":%.4f,\"ci95_low\":%.4f,\"mean_rows_scanned\":%.0f}", i ? "," : "", np[i],
                      mean[i], se[i], lo[i], sc[i]);
    fi_buf_printf(out, "],\"recommended_nprobe\":%u,\"reaches_target\":%s}", rec, er == FSQL_OK ? "true" : "false");
done:
    if (x) api->index_free(x);
    free(xn); free(q); free(ids); free(cells); free(codes); free(self); free(truth); free(pos); free(cellcnt); free(cellids); free(cellcodes);
    fi_free_corpus(rows, nrows, dim);
}

/* open: load a model blob and make a resident index for it */
static void fi_op_open(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      *hex = NULL;
    size_t     hexlen = 0;
    const char *v;
    uint8_t   *blob = NULL;
    long       blen;
    fi_model  *m;
    fi_index  *ix;
    fsql_ivf_model *model = NULL;
    fsql_ivf_index *x = NULL;
    fsql_ivf_info_t info;
    int        rc = 0;

    v = fi_json_value(req, "model", &hexlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no model blob"); return; }
    hex = (char *) malloc(hexlen + 1);
    if (!hex) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(hex, v, hexlen); hex[hexlen] = 0;
    blen = fi_hex_decode(hex, hexlen, &blob);
    free(hex);
    if (blen <= 0) { if (blob) free(blob); snprintf(err, ecap, "fractalsql: the model blob is not valid hex"); return; }
    model = api->model_load(blob, (size_t) blen, &rc);
    free(blob);
    if (!model) { snprintf(err, ecap, "fractalsql: the model blob failed validation (corrupt index?)"); return; }
    x = api->index_new(model);
    if (!x) { api->model_free(model); snprintf(err, ecap, "fractalsql: out of memory opening the index"); return; }
    api->model_info(model, &info);
    m = (fi_model *) calloc(1, sizeof *m);
    ix = (fi_index *) calloc(1, sizeof *ix);
    if (!m || !ix) {
        free(m); free(ix);
        api->index_free(x); api->model_free(model);
        snprintf(err, ecap, "fractalsql: out of memory");
        return;
    }
    m->m = model; m->info = info;
    ix->m = model; ix->x = x; ix->info = info;
    fi_make_token(ix->token, sizeof ix->token, "I");
    fi_lock();
    m->next = g_models; g_models = m;
    ix->next = g_indexes; g_indexes = ix;
    fi_unlock();
    fi_buf_printf(out, "{\"token\":\"%s\",\"dim\":%u,\"format\":\"%s\",\"nlist\":%u,\"pca_dim\":%u,\"code_bytes\":%u}",
                  ix->token, info.dim, fi_fmt_name((int) info.format), info.nlist, info.pca_dim, info.code_bytes);
}

/* probe: which cells a search would touch */
static void fi_op_probe(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    char     *query = NULL;
    size_t    qlen = 0;
    const char *v;
    float    *qf = NULL;
    size_t    dim = 0;
    fi_index *ix;
    uint32_t *cells = NULL;
    uint32_t  nc = 0, i;
    long long nprobe;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no index token"); return; }
    v = fi_json_value(req, "query", &qlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no query vector"); return; }
    query = (char *) malloc(qlen + 1);
    if (!query) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(query, v, qlen); query[qlen] = 0;
    nprobe = fi_json_get_int(req, "nprobe", 8);
    if (nprobe < 1) nprobe = 1;
    if (nprobe > FI_MAX_CELLS) nprobe = FI_MAX_CELLS;

    fi_lock();
    ix = fi_find_index(token);
    fi_unlock();
    if (!ix) { free(query); snprintf(err, ecap, "fractalsql: no index named '%s'", token); return; }
    if (fi_parse_one(query, qlen, &qf, &dim, err, ecap) != 0) { free(query); return; }
    free(query);
    if ((int) dim != (int) ix->info.dim) {
        free(qf);
        snprintf(err, ecap, "fractalsql: the query dimension %llu does not match the index dimension %u", (unsigned long long) dim, ix->info.dim);
        return;
    }
    cells = (uint32_t *) malloc(sizeof(uint32_t) * (size_t) nprobe);
    if (!cells) { free(qf); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    if (api->probe_cells(ix->m, qf, (uint32_t) nprobe, cells, &nc) != FSQL_OK) {
        free(cells); free(qf);
        snprintf(err, ecap, "fractalsql: the probe failed");
        return;
    }
    free(qf);
    fi_buf_puts(out, "{\"cells\":[");
    for (i = 0; i < nc; i++) {
        if (i) fi_buf_puts(out, ",");
        fi_buf_printf(out, "%u", cells[i]);
    }
    fi_buf_printf(out, "],\"n\":%u}", nc);
    free(cells);
}

/* load_cell: hand the daemon one cell's rows */
static void fi_op_load_cell(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    char     *ids = NULL, *codes = NULL;
    size_t    idslen = 0, codeslen = 0;
    const char *v;
    long long cell;
    fi_index *ix;
    uint8_t  *codebuf = NULL;
    long      codebytes;
    int64_t  *idbuf = NULL;
    size_t    n = 0, i;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no index token"); return; }
    cell = fi_json_get_int(req, "cell", -1);
    if (cell < 0 || cell >= FI_MAX_CELLS) { snprintf(err, ecap, "fractalsql: the cell number is out of range"); return; }
    v = fi_json_value(req, "ids", &idslen);
    if (!v) { snprintf(err, ecap, "fractalsql: no cell ids"); return; }
    ids = (char *) malloc(idslen + 1);
    if (!ids) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(ids, v, idslen); ids[idslen] = 0;
    v = fi_json_value(req, "codes", &codeslen);
    if (!v) { free(ids); snprintf(err, ecap, "fractalsql: no cell codes"); return; }
    codes = (char *) malloc(codeslen + 1);
    if (!codes) { free(ids); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(codes, v, codeslen); codes[codeslen] = 0;

    fi_lock();
    ix = fi_find_index(token);
    fi_unlock();
    if (!ix) { free(ids); free(codes); snprintf(err, ecap, "fractalsql: no index named '%s'", token); return; }

    /* The ids are a CSV of decimal row ids. */
    {
        size_t count = 0;
        for (i = 0; i < idslen; i++) if (ids[i] == ',') count++;
        n = count + 1;
    }
    idbuf = (int64_t *) malloc(sizeof(int64_t) * (n ? n : 1));
    if (!idbuf) { free(ids); free(codes); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    {
        char *p = ids, *e;
        for (i = 0; i < n; i++) {
            long long v2 = strtoll(p, &e, 10);
            if (e == p) { free(idbuf); free(ids); free(codes); snprintf(err, ecap, "fractalsql: the cell ids are malformed"); return; }
            idbuf[i] = (int64_t) v2;
            p = e;
            if (*p == ',') p++;
        }
    }
    codebytes = fi_hex_decode(codes, codeslen, &codebuf);
    free(ids); free(codes);
    if (codebytes < 0) { free(idbuf); snprintf(err, ecap, "fractalsql: the cell codes are not valid hex"); return; }
    if ((size_t) codebytes != n * (size_t) ix->info.code_bytes) {
        free(idbuf); free(codebuf);
        snprintf(err, ecap, "fractalsql: the cell payload is corrupt (%ld code bytes for %llu rows)", codebytes, (unsigned long long) n);
        return;
    }
    if (api->index_set_cell(ix->x, (uint32_t) cell, idbuf, codebuf, n) != FSQL_OK) {
        free(idbuf); free(codebuf);
        snprintf(err, ecap, "fractalsql: out of memory loading the cell");
        return;
    }
    free(idbuf); free(codebuf);
    fi_buf_printf(out, "{\"rows\":%llu,\"cell\":%lld}", (unsigned long long) n, cell);
}

/* search: the candidates, plus the statistics that prove the index was used */
static void fi_op_search(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char      token[24] = "";
    char     *query = NULL;
    size_t    qlen = 0;
    const char *v;
    float    *qf = NULL;
    size_t    dim = 0;
    fi_index *ix;
    long long nprobe, shortlist;
    int64_t  *ids = NULL;
    double   *dists = NULL;
    size_t    ncand = 0, i;
    fsql_ivf_stats_t st;

    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no index token"); return; }
    v = fi_json_value(req, "query", &qlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no query vector"); return; }
    query = (char *) malloc(qlen + 1);
    if (!query) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(query, v, qlen); query[qlen] = 0;
    nprobe    = fi_json_get_int(req, "nprobe", 8);
    shortlist = fi_json_get_int(req, "shortlist", 30);
    if (nprobe < 1) nprobe = 1;
    if (nprobe > FI_MAX_CELLS) nprobe = FI_MAX_CELLS;
    if (shortlist < 1) shortlist = 1;
    if (shortlist > 100000) shortlist = 100000;

    fi_lock();
    ix = fi_find_index(token);
    fi_unlock();
    if (!ix) { free(query); snprintf(err, ecap, "fractalsql: no index named '%s'", token); return; }
    if (fi_parse_one(query, qlen, &qf, &dim, err, ecap) != 0) { free(query); return; }
    free(query);
    if ((int) dim != (int) ix->info.dim) {
        free(qf);
        snprintf(err, ecap, "fractalsql: the query dimension %llu does not match the index dimension %u", (unsigned long long) dim, ix->info.dim);
        return;
    }
    ids   = (int64_t *) malloc(sizeof(int64_t) * (size_t) shortlist);
    dists = (double *)  malloc(sizeof(double)  * (size_t) shortlist);
    if (!ids || !dists) { free(ids); free(dists); free(qf); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memset(&st, 0, sizeof st);
    if (api->search(ix->x, qf, (uint32_t) nprobe, (uint32_t) shortlist, ids, dists, &ncand, &st) != FSQL_OK) {
        free(ids); free(dists); free(qf);
        snprintf(err, ecap, "fractalsql: the index search failed");
        return;
    }
    free(qf);
    fi_buf_puts(out, "{\"candidates\":[");
    for (i = 0; i < ncand; i++) {
        if (i) fi_buf_puts(out, ",");
        fi_buf_printf(out, "{\"doc_id\":%lld,\"distance\":%.17g}", (long long) ids[i], dists[i]);
    }
    fi_buf_printf(out, "],\"rows_scanned\":%llu,\"cells_probed\":%u,\"cells_missing\":%u,\"n\":%llu}",
                  (unsigned long long) st.rows_scanned, st.cells_probed, st.cells_missing, ncand);
    free(ids); free(dists);
}

/* verify: the EXACT double-precision cosine for a set of rows. The rows'
 * vectors arrive as text (from the base table) and are narrowed to float32
 * exactly as the index build narrowed them, so the distances are the same
 * bits the other hosts produce. */
static void fi_op_verify(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char     *query = NULL, *ids = NULL, *corpus = NULL;
    size_t    qlen = 0, idslen = 0, clen = 0;
    const char *v;
    float    *qf = NULL;
    size_t    dim = 0;
    float   **rows = NULL;
    size_t    nrows = 0, rdim = 0, i;

    (void) api;
    v = fi_json_value(req, "query", &qlen);
    if (!v) { snprintf(err, ecap, "fractalsql: no query vector"); return; }
    query = (char *) malloc(qlen + 1);
    if (!query) { snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(query, v, qlen); query[qlen] = 0;
    v = fi_json_value(req, "corpus", &clen);
    if (!v) { free(query); snprintf(err, ecap, "fractalsql: no corpus"); return; }
    corpus = (char *) malloc(clen + 1);
    if (!corpus) { free(query); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(corpus, v, clen); corpus[clen] = 0;
    v = fi_json_value(req, "ids", &idslen);
    if (!v) { free(query); free(corpus); snprintf(err, ecap, "fractalsql: no ids"); return; }
    ids = (char *) malloc(idslen + 1);
    if (!ids) { free(query); free(corpus); snprintf(err, ecap, "fractalsql: out of memory"); return; }
    memcpy(ids, v, idslen); ids[idslen] = 0;

    if (fi_parse_one(query, qlen, &qf, &dim, err, ecap) != 0) { free(query); free(corpus); free(ids); return; }
    free(query);
    if (fi_parse_corpus(corpus, clen, dim, &rows, &nrows, &rdim, err, ecap) != 0) { free(corpus); free(ids); free(qf); return; }
    free(corpus);
    if (rdim != dim) {
        fi_free_corpus(rows, nrows, rdim); free(ids); free(qf);
        snprintf(err, ecap, "fractalsql: a candidate row has a different dimension from the query");
        return;
    }
    fi_buf_puts(out, "{\"distances\":[");
    {
        char *p = ids, *e;
        for (i = 0; i < nrows; i++) {
            long long idv = strtoll(p, &e, 10);
            if (e == p) break;
            if (i) fi_buf_puts(out, ",");
            fi_buf_printf(out, "%.17g", fsqlp_cosine_distance_f(rows[i], qf, dim));
            p = e;
            if (*p == ',') p++;
            (void) idv;
        }
    }
    fi_buf_printf(out, "],\"rows\":%llu}", (unsigned long long) nrows);
    fi_free_corpus(rows, nrows, rdim);
    free(ids); free(qf);
}

/* close: drop a resident index (or a model) */
static void fi_op_close(const fi_api *api, const char *req, fi_buf *out, char *err, size_t ecap)
{
    char token[24] = "";
    if (!fi_json_get_str(req, "token", token, sizeof token)) { snprintf(err, ecap, "fractalsql: no token"); return; }
    fi_drop_index(token, api);
    fi_drop_model(token, api);
    fi_buf_puts(out, "{\"ok\":1}");
}

/* ------------------------------------------------------------------ */
/* The UDF: fractal_index_op(request_json) -> response_json             */
/*                                                                     */
/* ERROR REPORTING: the daemon's UDF dispatch carries a call error as */
/* a FLAG, not as a message (a failing body cannot name its own cause */
/* to the client -- see service/daemon/fractalsqld.c's core_fail), so  */
/* this UDF never fails: it REPORTS its errors in the response, as     */
/* {"error":"<message>"}, and the calling stored procedure turns that  */
/* into a SQL error with that exact text. The one exception is the    */
/* "this core has no IVF index" case, which is refused in _init: the */
/* daemon DOES carry an init message to the client, so the agreed      */
/* message reaches the user verbatim.                                  */
/* ------------------------------------------------------------------ */

/* Writes a JSON string body (quotes and backslashes escaped). */
static void fi_json_escape(fi_buf *b, const char *s)
{
    for (; *s; s++) {
        char c = *s;
        if (c == '"' || c == '\\') { char two[2]; two[0] = '\\'; two[1] = c; fi_buf_add(b, two, 2); }
        else if (c == '\n') fi_buf_puts(b, "\\n");
        else if (c == '\r') fi_buf_puts(b, "\\r");
        else if (c == '\t') fi_buf_puts(b, "\\t");
        else fi_buf_add(b, &c, 1);
    }
}

FRACTAL_EXPORT bool
fractal_index_op_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    static fi_api api;
    static int     api_ready = 0;

    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_index_op(request_json): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 0;
    /* The response can carry a model blob (hex) or a batch of codes, so
     * the result buffer is generous -- but bounded, so a runaway batch
     * cannot make the daemon allocate without limit. */
    initid->max_length = 8UL * 1024UL * 1024UL;

    if (!api_ready) {
        fi_resolve(&api);
        api_ready = 1;
    }
    return false;
}

FRACTAL_EXPORT void
fractal_index_op_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT char *
fractal_index_op(UDF_INIT *initid, UDF_ARGS *args, char *result,
                 unsigned long *length, char *is_null, char *error)
{
    static fi_api api;
    static int     api_ready = 0;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    char    *req = NULL;
    char     op[32] = "";
    fi_buf   out;
    size_t   reqlen;

    (void) error;   /* this UDF reports its errors in the response */

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    reqlen = args->lengths[0];
    if (reqlen > 64UL * 1024UL * 1024UL) {
        snprintf(errbuf, sizeof errbuf, "fractal_index_op: the request is too long");
        goto report;
    }
    req = (char *) malloc(reqlen + 1);
    if (!req) {
        snprintf(errbuf, sizeof errbuf, "fractalsql: out of memory");
        goto report;
    }
    memcpy(req, args->args[0], reqlen);
    req[reqlen] = 0;

    if (!api_ready) {
        fi_resolve(&api);
        api_ready = 1;
    }
    if (!fi_json_get_str(req, "op", op, sizeof op)) {
        snprintf(errbuf, sizeof errbuf, "fractal_index_op: the request has no op");
        goto report;
    }

    /* The ops that need the core's IVF maths are refused (with the one
     * agreed message) when this build of fractalsql-core does not carry
     * them. The "verify" op -- the exact double-precision cosine, used by
     * the exact fallback of the indexed search -- needs no IVF symbol at
     * all and keeps working. */
    if (!api.available &&
        strcmp(op, "verify") != 0 && strcmp(op, "close") != 0) {
        snprintf(errbuf, sizeof errbuf, "%s", FI_NO_IVF_MSG);
        goto report;
    }

    fi_buf_init(&out);
    errbuf[0] = 0;
    if (!strcmp(op, "train_begin"))      fi_op_train_begin(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "train_add"))   fi_op_train_add(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "train_end"))   fi_op_train_end(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "encode"))      fi_op_encode(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "calibrate"))   fi_op_calibrate(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "open"))        fi_op_open(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "probe"))       fi_op_probe(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "load_cell"))   fi_op_load_cell(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "search"))      fi_op_search(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "verify"))      fi_op_verify(&api, req, &out, errbuf, sizeof errbuf);
    else if (!strcmp(op, "close"))       fi_op_close(&api, req, &out, errbuf, sizeof errbuf);
    else {
        snprintf(errbuf, sizeof errbuf, "fractal_index_op: unknown op '%s'", op);
    }

    if (errbuf[0]) {
        fi_buf_free(&out);
        goto report;      /* the report block frees req */
    }
    if (out.failed || !out.p) {
        fi_buf_free(&out);
        snprintf(errbuf, sizeof errbuf, "fractal_index_op: out of memory building the response");
        goto report;
    }
    if (out.len + 1 > (size_t) initid->max_length) {
        fi_buf_free(&out);
        snprintf(errbuf, sizeof errbuf, "fractal_index_op: the response is larger than the %u byte limit",
                 (unsigned) initid->max_length);
        goto report;
    }
    memcpy(result, out.p, out.len);
    result[out.len] = 0;
    *length = (unsigned long) out.len;
    *is_null = 0;
    fi_buf_free(&out);
    free(req);
    return result;

report:
    /* The response carries the failure, so the calling procedure can
     * raise it as a SQL error with this exact text. */
    free(req);
    {
        fi_buf e;
        fi_buf_init(&e);
        fi_buf_puts(&e, "{\"error\":\"");
        fi_json_escape(&e, errbuf);
        fi_buf_puts(&e, "\"}");
        if (e.failed || !e.p) {
            fi_buf_free(&e);
            *length = 0;
            *is_null = 0;
            *error = 1;
            return NULL;
        }
        if (e.len + 1 > (size_t) initid->max_length) {
            fi_buf_free(&e);
            *length = 0;
            *is_null = 0;
            *error = 1;
            return NULL;
        }
        memcpy(result, e.p, e.len);
        result[e.len] = 0;
        *length = (unsigned long) e.len;
        *is_null = 0;
        fi_buf_free(&e);
        return result;
    }
}

/* ------------------------------------------------------------------ */
/* The tombstone: the OLD fractal_search(vector_csv, query_csv, k,      */
/* params) surface.                                                     */
/*                                                                      */
/* The table-free convergence function was renamed fractal_sfs_converge: */
/* it runs SFS toward a direction; it is NOT a retrieval function. This */
/* is NOT an alias -- the old call fails, and the message says what     */
/* changed. The indexed search is the stored PROCEDURE fractal_search   */
/* (table, column, query, k [, options]).                              */
/*                                                                      */
/* The failure is raised in _init, because the daemon carries an INIT  */
/* message to the client (it does not carry a call-error message), so  */
/* this is the one place where the wording reaches the user verbatim.  */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_search_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    (void) initid;
    (void) args;
    /* The wording matters: MariaDB truncates the message it carries to
     * the client, so the NEW name has to be in the first line. */
    SFS_INIT_ERROR(message,
        "fractalsql: fractal_search was renamed fractal_sfs_converge (the table-free "
        "convergence function: it runs SFS toward the query direction and is not a "
        "retrieval function). fractal_search is now the INDEXED search over a table: "
        "CALL fractal_search(table_name, vector_col, query, k, options_json) -- a "
        "stored procedure, because a MariaDB UDF cannot read a table.");
    return true;
}

FRACTAL_EXPORT void
fractal_search_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT char *
fractal_search(UDF_INIT *initid, UDF_ARGS *args, char *result,
                unsigned long *length, char *is_null, char *error)
{
    (void) initid; (void) args; (void) result;
    *length = 0;
    *is_null = 0;
    *error = 1;
    return NULL;
}
