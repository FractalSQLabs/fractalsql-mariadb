/* src/fractalsql.c
 * fractalsql-mariadb v2.0.0: Stochastic Fractal Search for MariaDB (UDF).
 *
 * Compatible with MariaDB 10.6, 10.11, 11.4 LTS, and 12.2 (rolling).
 * The UDF ABI has been stable across these majors.
 *
 * SQL surface
 *   fractal_search(vector_csv, query_csv, k, params) -> JSON STRING
 *
 *     vector_csv  corpus of stored vectors:
 *                   '[[v11,v12,...],[v21,...],...]'
 *                   'v11,v12,...;v21,...;...'
 *                   or '' for empty corpus
 *     query_csv   single query vector, same string formats accepted
 *     k           positive integer, top-k count
 *     params      JSON object of SFS tuning knobs:
 *                   {"iterations":30,
 *                    "population_size":50,
 *                    "diffusion_factor":2,
 *                    "walk":0.5,
 *                    "debug":false,
 *                    "session_id":0}
 *                 session_id (optional, default 0/none): pass
 *                 CONNECTION_ID() to run this search on your session's
 *                 persistent, Diversify-aware ctx (see
 *                 fractal_diversify_enable and fractalsql_session.h)
 *                 instead of a fresh throwaway one. This is required for
 *                 fractal_diversify_* settings to actually affect this
 *                 call, and for D_q/overhead stats to accumulate across
 *                 calls. Omit it for the default, stateless behavior.
 *
 * Output (canonical fsql_search_ptr shape: the same JSON every binding emits):
 *   { "dim":        <int>,
 *     "n_corpus":   <int>,
 *     "best_fit":   <double>,
 *     "best_point": [d1, d2, ...],
 *     "top_k":      [{"idx": <int>, "dist": <double>}, ...] }
 *
 * Vendored pure-C core
 *   Statically links include/libfractalsql-community-minimal-c.a from
 *   fractalsql-core's deploy.sh drop. No LuaJIT runtime dependency.
 */

#include <mysql.h>

#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql.h"
#include "fractalsql_sql.h"     /* sovereign-tier additions (v2 Analytics/Portfolio) */
#include "fractalsql_session.h" /* connection-scoped ctx registry for Discovery/Diversify */
#include "fractalsql_parse.h"   /* parse_vector_csv prototype (shared with fractalsql_vector.c) */
#include "fractalsql_enterprise.h" /* fractal_enterprise_lib_loaded/fractal_ledger_write_kind2/_sha256 */

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

/* Single source of truth for the shipped version. fractalsql_version()
 * below returns this, and scripts/package.sh derives the .deb/.rpm
 * VERSION from this same #define via sed. Keeping both readers on one
 * #define avoids the UDF's self-reported version and the package
 * metadata's version silently drifting apart. */
#define FSQL_VERSION "2.0.0"

/* strncasecmp is POSIX (<strings.h>), not standard C. MSVC has no
 * <strings.h> at all, only the underscore-prefixed _strnicmp. Used by
 * fractal_feedback_report's kind-string parser below. */
#if defined(_MSC_VER)
#  define strncasecmp _strnicmp
#else
#  include <strings.h>
#endif

/* Supply-side DoS guards, sized the same way as the redis/valkey blob
 * caps elsewhere in this codebase.
 *
 * The UDF gets two
 * caller-controlled blobs (vector_csv, query_csv) that drive an
 * n_corpus * dim * sizeof(double) malloc inside parse_corpus. Without
 * a ceiling, a multi-GiB corpus blob would translate into a
 * multi-GiB allocation and OOM-kill the server. The per-row vector
 * grow loop in parse_vector_csv is similarly unbounded.
 *
 * Numbers chosen to comfortably exceed real-world embedding queries
 * (4 MiB query CSV ≈ 250 K floats; 256 MiB corpus CSV ≈ 30 K rows of
 * 1024-dim float32 in CSV form) while keeping the worst-case decode
 * memory inside an order of magnitude of normal usage. */
#define MAX_QUERY_BYTES    ((unsigned long) 4u   * 1024u * 1024u)   /* 4 MiB  */
#define MAX_CORPUS_BYTES   ((unsigned long) 256u * 1024u * 1024u)   /* 256 MiB */
#define MAX_QUERY_DIM      (1u * 1024u * 1024u)                     /* 1 M elem */

/* ------------------------------------------------------------------ */
/* Per-invocation context, held in initid->ptr across the UDF lifecycle. */
/* ------------------------------------------------------------------ */
typedef struct sfs_ctx {
    fsql_ctx *ctx;   /* pure-C core context */
} sfs_ctx;

#define SFS_INIT_ERROR(msg, ...) \
    (snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__))

/* ------------------------------------------------------------------ */
/* Argument parsing                                                   */
/* ------------------------------------------------------------------ */

#ifdef FRACTAL_HAVE_VECTOR_TYPE
/* MySQL 9.0 VECTOR values arrive as binary strings of packed
 * little-endian float32. Disambiguated from CSV by leading byte. */
static bool
looks_like_vector_binary(const char *s, size_t n)
{
    if (n == 0 || n % 4 != 0) return false;
    unsigned char c = (unsigned char) s[0];
    if (c == '[' || c == '-' || c == '+' || c == '.' || c == ' ' ||
        c == '\t' || c == '\n' || c == '\r' ||
        (c >= '0' && c <= '9'))
        return false;
    return true;
}

static bool
parse_vector_binary(const char *s, size_t n,
                    double **out, size_t *n_out, char *errmsg)
{
    size_t  count = n / 4;
    double *v = malloc(count * sizeof(double));
    if (v == NULL) {
        SFS_INIT_ERROR(errmsg, "fractalsql: oom decoding VECTOR");
        return false;
    }
    for (size_t i = 0; i < count; i++) {
        float f;
        memcpy(&f, s + i * 4, 4);
        v[i] = (double) f;
    }
    *out = v;
    *n_out = count;
    return true;
}
#endif

bool
parse_vector_csv(const char *src, size_t srclen,
                 double **out, size_t *n_out, char *errmsg)
{
    char   *buf, *p, *end;
    size_t  cap = 16, n = 0;
    double *v;

#ifdef FRACTAL_HAVE_VECTOR_TYPE
    if (looks_like_vector_binary(src, srclen))
        return parse_vector_binary(src, srclen, out, n_out, errmsg);
#endif

    buf = malloc(srclen + 1);
    if (buf == NULL) {
        SFS_INIT_ERROR(errmsg, "fractalsql: oom parsing vector");
        return false;
    }
    memcpy(buf, src, srclen);
    buf[srclen] = '\0';

    v = malloc(cap * sizeof(double));
    if (v == NULL) { free(buf); SFS_INIT_ERROR(errmsg, "fractalsql: oom"); return false; }

    p = buf;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ',' ||
               *p == '[' || *p == ']' || *p == '\n' || *p == '\r')
            p++;
        if (*p == '\0') break;

        errno = 0;
        double d = strtod(p, &end);
        if (end == p) {
            SFS_INIT_ERROR(errmsg, "fractalsql: invalid number near '%.20s'", p);
            free(buf); free(v); return false;
        }
        if (errno == ERANGE) {
            SFS_INIT_ERROR(errmsg, "fractalsql: value out of range");
            free(buf); free(v); return false;
        }

        if (n == cap) {
            size_t ncap = cap * 2;
            double *nv = realloc(v, ncap * sizeof(double));
            if (nv == NULL) {
                SFS_INIT_ERROR(errmsg, "fractalsql: oom growing vector");
                free(buf); free(v); return false;
            }
            v = nv; cap = ncap;
        }
        v[n++] = d;
        p = end;
    }
    free(buf);

    if (n == 0) {
        SFS_INIT_ERROR(errmsg, "fractalsql: vector must have at least one element");
        free(v); return false;
    }
    *out = v;
    *n_out = n;
    return true;
}

static bool
parse_corpus(const char *src, size_t srclen, size_t expected_dim,
             double **out, size_t *n_rows_out, size_t *dim_out, char *errmsg)
{
    double *store = NULL;
    size_t  cap_rows = 0, n_rows = 0, dim = expected_dim;
    size_t  i, start;
    bool    in_brackets = false;

    i = 0;
    while (i < srclen && (src[i] == ' ' || src[i] == '\t' ||
                          src[i] == '\n' || src[i] == '\r')) i++;
    if (i < srclen && src[i] == '[') {
        size_t j = i + 1;
        while (j < srclen && (src[j] == ' ' || src[j] == '\t' ||
                              src[j] == '\n' || src[j] == '\r')) j++;
        if (j < srclen && src[j] == '[') {
            in_brackets = true;
            i++;
            while (srclen > i && (src[srclen - 1] == ' ' ||
                                  src[srclen - 1] == '\t' ||
                                  src[srclen - 1] == '\n' ||
                                  src[srclen - 1] == '\r')) srclen--;
            if (srclen > i && src[srclen - 1] == ']') srclen--;
        }
    }

    {
        size_t j = i;
        while (j < srclen && (src[j] == ' ' || src[j] == '\t' ||
                              src[j] == '\n' || src[j] == '\r' ||
                              src[j] == '[' || src[j] == ']')) j++;
        if (j >= srclen) {
            *out = NULL; *n_rows_out = 0; *dim_out = dim;
            return true;
        }
    }

    start = i;
    for (; i <= srclen; i++) {
        bool at_sep;
        if (i == srclen)                                       at_sep = true;
        else if (src[i] == ';')                                at_sep = true;
        else if (in_brackets && src[i] == '[' && i > start)    at_sep = true;
        else                                                   at_sep = false;
        if (!at_sep) continue;

        size_t end = i;
        while (end > start && (src[end - 1] == ' ' || src[end - 1] == '\t' ||
                               src[end - 1] == ']' || src[end - 1] == ',' ||
                               src[end - 1] == '\n' || src[end - 1] == '\r'))
            end--;
        size_t s = start;
        while (s < end && (src[s] == ' ' || src[s] == '\t' ||
                           src[s] == '[' || src[s] == '\n' || src[s] == '\r'))
            s++;

        if (s < end) {
            double *row;
            size_t  row_n;
            if (!parse_vector_csv(src + s, end - s, &row, &row_n, errmsg)) {
                free(store); return false;
            }
            if (dim == 0) dim = row_n;
            if (row_n != dim) {
                SFS_INIT_ERROR(errmsg,
                    "fractalsql: corpus row %zu has dim %zu, expected %zu",
                    n_rows, row_n, dim);
                free(row); free(store); return false;
            }
            if (n_rows == cap_rows) {
                size_t ncap = cap_rows ? cap_rows * 2 : 16;
                double *nv = realloc(store, ncap * dim * sizeof(double));
                if (nv == NULL) {
                    SFS_INIT_ERROR(errmsg, "fractalsql: oom growing corpus");
                    free(row); free(store); return false;
                }
                store = nv; cap_rows = ncap;
            }
            memcpy(store + n_rows * dim, row, dim * sizeof(double));
            free(row);
            n_rows++;
        }
        start = (i < srclen && src[i] == '[') ? i : i + 1;
    }
    *out = store; *n_rows_out = n_rows; *dim_out = dim;
    return true;
}

/* Parse a CSV or JSON-bracket string of non-negative integers (edge and
 * face vertex indices for the Analytics-tier functions), using the same
 * CSV/JSON-array string convention parse_vector_csv already established
 * for float8[] arguments. Rejects negative values and
 * non-integers outright rather than silently truncating: an
 * out-of-range or negative index fed to the core's edge/face arrays
 * would read out of bounds there instead of failing cleanly here. */
static bool
parse_index_csv(const char *src, size_t srclen,
                size_t **out, size_t *n_out, char *errmsg)
{
    char   *buf, *p, *end;
    size_t  cap = 16, n = 0;
    size_t *v;

    buf = malloc(srclen + 1);
    if (buf == NULL) {
        SFS_INIT_ERROR(errmsg, "fractalsql: oom parsing index array");
        return false;
    }
    memcpy(buf, src, srclen);
    buf[srclen] = '\0';

    v = malloc(cap * sizeof(size_t));
    if (v == NULL) { free(buf); SFS_INIT_ERROR(errmsg, "fractalsql: oom"); return false; }

    p = buf;
    while (*p) {
        while (*p == ' ' || *p == '\t' || *p == ',' ||
               *p == '[' || *p == ']' || *p == '\n' || *p == '\r')
            p++;
        if (*p == '\0') break;

        if (*p == '-') {
            SFS_INIT_ERROR(errmsg, "fractalsql: index must be non-negative near '%.20s'", p);
            free(buf); free(v); return false;
        }

        errno = 0;
        long long iv = strtoll(p, &end, 10);
        if (end == p) {
            SFS_INIT_ERROR(errmsg, "fractalsql: invalid index near '%.20s'", p);
            free(buf); free(v); return false;
        }
        if (errno == ERANGE || iv < 0) {
            SFS_INIT_ERROR(errmsg, "fractalsql: index out of range near '%.20s'", p);
            free(buf); free(v); return false;
        }

        if (n == cap) {
            size_t ncap = cap * 2;
            size_t *nv = realloc(v, ncap * sizeof(size_t));
            if (nv == NULL) {
                SFS_INIT_ERROR(errmsg, "fractalsql: oom growing index array");
                free(buf); free(v); return false;
            }
            v = nv; cap = ncap;
        }
        v[n++] = (size_t) iv;
        p = end;
    }
    free(buf);

    *out = v;
    *n_out = n;
    return true;
}

/* ------------------------------------------------------------------ */
/* Growable output buffer, shared by every Analytics/Portfolio UDF     */
/* below that returns a JSON object (as opposed to fractal_search's    */
/* fixed-lifetime buffer owned by the core ctx, or a scalar REAL       */
/* return with no buffer at all). Allocated once in _init, grown as    */
/* needed in the main call (portfolio's "weights" array scales with    */
/* n_assets, so a fixed stack buffer isn't safe), and freed in         */
/* _deinit. Per the MariaDB UDF STRING-result contract, the returned   */
/* pointer must stay valid until the next call on the same initid;     */
/* reusing one buffer across calls on the same connection satisfies    */
/* that.                                                                */
/* ------------------------------------------------------------------ */
typedef struct json_out_ctx {
    char  *buf;
    size_t cap;
} json_out_ctx;

static bool
json_out_ensure(json_out_ctx *jo, size_t need)
{
    size_t ncap;
    char  *nb;
    if (need <= jo->cap) return true;
    ncap = jo->cap ? jo->cap : 256;
    while (ncap < need) ncap *= 2;
    nb = realloc(jo->buf, ncap);
    if (nb == NULL) return false;
    jo->buf = nb; jo->cap = ncap;
    return true;
}

static bool
json_out_generic_init(UDF_INIT *initid, char *message)
{
    json_out_ctx *jo = calloc(1, sizeof(*jo));
    if (jo == NULL) {
        SFS_INIT_ERROR(message, "fractalsql: out of memory");
        return true;
    }
    initid->ptr        = (char *) jo;
    initid->maybe_null = 1;
    initid->max_length = 16 * 1024 * 1024;
    return false;
}

static void
json_out_generic_deinit(UDF_INIT *initid)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    if (jo == NULL) return;
    free(jo->buf);
    free(jo);
    initid->ptr = NULL;
}

/* diffusion_mode text -> the FSQL_SFS_DIFFUSE_* int the core expects
 * (include/sfs_core_c.h). */
static bool
parse_diffusion_mode(const char *mode, int *out, char *errmsg)
{
    if (strcmp(mode, "gaussian") == 0) { *out = 0; return true; } /* FSQL_SFS_DIFFUSE_GAUSSIAN */
    if (strcmp(mode, "levy") == 0)     { *out = 1; return true; } /* FSQL_SFS_DIFFUSE_LEVY */
    SFS_INIT_ERROR(errmsg,
        "fractalsql: diffusion_mode must be 'gaussian' or 'levy' (got '%s')", mode);
    return false;
}

/* ------------------------------------------------------------------ */
/* Minimal JSON-ish key lookup for the params object                  */
/* ------------------------------------------------------------------ */

static bool
json_find_key(const char *s, size_t slen, const char *key, size_t *out_pos)
{
    size_t klen = strlen(key);
    for (size_t i = 0; i + klen + 2 < slen; i++) {
        if (s[i] != '"') continue;
        if (strncmp(s + i + 1, key, klen) != 0) continue;
        if (s[i + 1 + klen] != '"') continue;
        size_t j = i + 2 + klen;
        while (j < slen && (s[j] == ' ' || s[j] == '\t' ||
                            s[j] == '\n' || s[j] == '\r')) j++;
        if (j < slen && s[j] == ':') {
            j++;
            while (j < slen && (s[j] == ' ' || s[j] == '\t' ||
                                s[j] == '\n' || s[j] == '\r')) j++;
            *out_pos = j;
            return true;
        }
    }
    return false;
}

static int
json_get_int(const char *s, size_t slen, const char *key, int fallback)
{
    size_t pos; char buf[32]; size_t n = 0;
    if (!json_find_key(s, slen, key, &pos)) return fallback;
    while (pos < slen && n < sizeof(buf) - 1 &&
           (isdigit((unsigned char) s[pos]) || s[pos] == '-' || s[pos] == '+'))
        buf[n++] = s[pos++];
    buf[n] = '\0';
    return n == 0 ? fallback : atoi(buf);
}

/* Unsigned 64-bit variant, for session_id (the caller's own
 * CONNECTION_ID() by convention: see fractal_search's "session_id"
 * params key and fractal_diversify_*'s explicit session_id argument).
 * No sign handling, since a session key is never negative. */
static unsigned long long
json_get_u64(const char *s, size_t slen, const char *key, unsigned long long fallback)
{
    size_t pos; char buf[32]; size_t n = 0;
    if (!json_find_key(s, slen, key, &pos)) return fallback;
    while (pos < slen && n < sizeof(buf) - 1 && isdigit((unsigned char) s[pos]))
        buf[n++] = s[pos++];
    buf[n] = '\0';
    return n == 0 ? fallback : strtoull(buf, NULL, 10);
}

static double
json_get_double(const char *s, size_t slen, const char *key, double fallback)
{
    size_t pos; char buf[64]; size_t n = 0;
    if (!json_find_key(s, slen, key, &pos)) return fallback;
    while (pos < slen && n < sizeof(buf) - 1 &&
           (isdigit((unsigned char) s[pos]) || s[pos] == '-' || s[pos] == '+' ||
            s[pos] == '.' || s[pos] == 'e' || s[pos] == 'E'))
        buf[n++] = s[pos++];
    buf[n] = '\0';
    return n == 0 ? fallback : strtod(buf, NULL);
}

static bool
json_get_bool(const char *s, size_t slen, const char *key, bool fallback)
{
    size_t pos;
    if (!json_find_key(s, slen, key, &pos)) return fallback;
    if (pos + 4 <= slen && strncmp(s + pos, "true",  4) == 0) return true;
    if (pos + 5 <= slen && strncmp(s + pos, "false", 5) == 0) return false;
    return fallback;
}

/* Extract a quoted string value ("key":"value") into a caller-owned
 * buffer. Returns false (buf left untouched) if the key is absent or
 * the value isn't a quoted string. There is no escape-sequence
 * decoding, since every caller of this helper only ever expects short
 * enum-like spellings (e.g. "gaussian"/"levy"), never arbitrary user
 * text. */
static bool
json_get_str(const char *s, size_t slen, const char *key,
            char *buf, size_t bufcap)
{
    size_t pos, n = 0;
    if (!json_find_key(s, slen, key, &pos)) return false;
    if (pos >= slen || s[pos] != '"') return false;
    pos++;
    while (pos < slen && s[pos] != '"' && n < bufcap - 1)
        buf[n++] = s[pos++];
    buf[n] = '\0';
    return true;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_search                                          */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_search_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_search(vector_csv, query_csv, k, params): "
            "expected 4 arguments, got %u", args->arg_count);
        return true;
    }

    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = STRING_RESULT;

    if (args->args[2] != NULL) {
        long long kv = *(long long *) args->args[2];
        if (kv < 1 || kv > 1000000) {
            SFS_INIT_ERROR(message, "fractal_search: k must be 1..1000000");
            return true;
        }
    }

    /* No fsql_init() call: that symbol wires up the SQL/DB layer and is
     * only present in the Sovereign edition. The MariaDB UDF links
     * against the Minimal edition archive (CORE_VARIANT=community-minimal-c),
     * which doesn't export fsql_init at all, so Minimal/SFS callers reach
     * fsql_new_minimal() directly. Calling fsql_init() here would leave the
     * symbol unresolved on musl (eager binding) or fail at the call site
     * on glibc. */
    sfs_ctx *c = calloc(1, sizeof(*c));
    if (c == NULL) {
        SFS_INIT_ERROR(message, "fractalsql: out of memory");
        return true;
    }
    c->ctx = fsql_new_minimal();
    if (c->ctx == NULL) {
        free(c);
        SFS_INIT_ERROR(message, "fractalsql: fsql_new_minimal failed");
        return true;
    }

    initid->ptr        = (char *) c;
    initid->maybe_null = 1;
    initid->max_length = 64 * 1024 * 1024;
    return false;
}

FRACTAL_EXPORT void
fractal_search_deinit(UDF_INIT *initid)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    if (c == NULL) return;
    if (c->ctx) fsql_free(c->ctx);
    free(c);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_search(UDF_INIT *initid, UDF_ARGS *args, char *result,
               unsigned long *length, char *is_null, char *error)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];

    double *query = NULL;
    double *corpus = NULL;
    size_t  dim = 0, corpus_dim = 0, n_corpus = 0;
    int     k;

    (void) result;

    if (args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1;
        return NULL;
    }

    /* Refuse oversized inputs before they hit the parse loops, which
     * would otherwise grow heap unboundedly. */
    if (args->lengths[1] > MAX_QUERY_BYTES) {
        *error = 1; return NULL;
    }
    if (args->args[0] != NULL && args->lengths[0] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

    /* query (required) */
    if (!parse_vector_csv(args->args[1], args->lengths[1],
                          &query, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    if (dim == 0 || dim > MAX_QUERY_DIM) {
        free(query); *error = 1; return NULL;
    }

    /* corpus (may be empty) */
    if (args->args[0] != NULL && args->lengths[0] > 0) {
        if (!parse_corpus(args->args[0], args->lengths[0], dim,
                          &corpus, &n_corpus, &corpus_dim, errbuf)) {
            free(query); *error = 1; return NULL;
        }
        if (n_corpus > 0 && corpus_dim != dim) {
            free(query); free(corpus); *error = 1; return NULL;
        }
    }

    k = (int) *(long long *) args->args[2];
    if (n_corpus > 0 && (size_t) k > n_corpus) k = (int) n_corpus;

    /* Translate UDF param spelling → core's params_json keys.
     * UDF: iterations / population_size / diffusion_factor / walk / debug
     * Core: max_generation / population_size / maximum_diffusion / walk / debug
     * Names differ for historical reasons; values are identical. */
    const char *params_s = (args->args[3] != NULL) ? args->args[3] : "{}";
    size_t      params_len = (args->args[3] != NULL) ? args->lengths[3] : 2;

    int    iterations  = json_get_int   (params_s, params_len, "iterations",       30);
    int    pop_size    = json_get_int   (params_s, params_len, "population_size",  50);
    int    diff_factor = json_get_int   (params_s, params_len, "diffusion_factor", 2);
    double walk        = json_get_double(params_s, params_len, "walk",             0.5);
    bool   debug_mode  = json_get_bool  (params_s, params_len, "debug",            false);

    /* Optional "session_id": <CONNECTION_ID()-style key, 0 = none>.
     * When present and nonzero, this call uses the caller's persistent,
     * Diversify-aware ctx from the connection registry (see
     * fractalsql_session.h) instead of the fresh per-call ctx `c->ctx`,
     * so a prior fractal_diversify_enable/set_params(session_id, ...)
     * on the SAME session_id actually affects this search, and its
     * rolling D_q/overhead stats keep accumulating across calls. Falls
     * back silently to the ordinary per-call ctx if the registry is at
     * capacity (fractal_session_acquire returns NULL): an administrative
     * cap should degrade a search to stateless behavior, not fail the
     * query. */
    unsigned long long session_id  = json_get_u64(params_s, params_len, "session_id", 0);
    bool                use_session = false;
    fsql_ctx           *search_ctx  = c->ctx;
    if (session_id != 0) {
        fsql_ctx *sc = fractal_session_acquire(session_id);
        if (sc != NULL) { search_ctx = sc; use_session = true; }
    }

    /* Bounds so an adversarial params JSON can't drive a vastly
     * oversized SFS allocation. */
    if (iterations < 1 || iterations > 10000   ||
        pop_size   < 2 || pop_size   > 100000  ||
        diff_factor < 1 || diff_factor > 32) {
        free(query); free(corpus);
        if (use_session) fractal_session_release(session_id);
        *error = 1; return NULL;
    }

    char core_params[256];
    snprintf(core_params, sizeof core_params,
        "{\"max_generation\":%d,\"population_size\":%d,"
        "\"maximum_diffusion\":%d,\"walk\":%.6g,"
        "\"bound_clipping\":true,\"debug\":%s}",
        iterations, pop_size, diff_factor, walk,
        debug_mode ? "true" : "false");

    /* When n_corpus == 0 we still need a corpus pointer for the
     * core; pass query as a 1-row dummy corpus so best_point/best_fit
     * are returned but top_k will be a single trivial entry. */
    const double *core_corpus  = (n_corpus > 0) ? corpus : query;
    size_t        core_n_rows  = (n_corpus > 0) ? n_corpus : 1;
    int           core_k       = (n_corpus > 0) ? k : 1;

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = fsql_search_ptr(search_ctx,
                             core_corpus, core_n_rows, dim,
                             query, dim,
                             core_k,
                             core_params, strlen(core_params),
                             &result_json, &result_len);

    free(query);
    free(corpus);
    /* Release, not close: the ctx (and result_json, which it owns)
     * stays alive in the registry, only its refcount drops. Safe to
     * release before returning result_json to the caller. */
    if (use_session) fractal_session_release(session_id);

    if (rc != 0) { *error = 1; return NULL; }

    /* fsql_search_ptr's result_json is owned by c->ctx and stays
     * valid until the next fsql_search* on the same ctx. The MariaDB
     * UDF protocol requires the returned pointer to stay valid until
     * the next call on the same initid, matching that lifetime exactly,
     * so we return the pointer directly. */
    *length  = (unsigned long) result_len;
    *is_null = 0;
    return (char *) result_json;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_explore (Scout Mode)                            */
/*                                                                    */
/* Sniper (fractal_search) returns best_point + the top-k nearest     */
/* stored vectors. Scout disperses the SFS population across distinct */
/* basins (walk=0 + min-distance-to-corpus fitness) and returns the   */
/* full result JSON including the additive "population" array, one    */
/* inner array per particle. Discover the diverse regions of a corpus */
/* in a single call; JSON_EXTRACT(..., '$.population') to consume.    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_explore_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_explore(corpus_csv, query_csv, params): "
            "expected 3 arguments, got %u", args->arg_count);
        return true;
    }

    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = STRING_RESULT;

    sfs_ctx *c = calloc(1, sizeof(*c));
    if (c == NULL) {
        SFS_INIT_ERROR(message, "fractalsql: out of memory");
        return true;
    }
    c->ctx = fsql_new_minimal();
    if (c->ctx == NULL) {
        free(c);
        SFS_INIT_ERROR(message, "fractalsql: fsql_new_minimal failed");
        return true;
    }

    initid->ptr        = (char *) c;
    initid->maybe_null = 1;
    initid->max_length = 64 * 1024 * 1024;
    return false;
}

FRACTAL_EXPORT void
fractal_explore_deinit(UDF_INIT *initid)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    if (c == NULL) return;
    if (c->ctx) fsql_free(c->ctx);
    free(c);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_explore(UDF_INIT *initid, UDF_ARGS *args, char *result,
                unsigned long *length, char *is_null, char *error)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];

    double *query  = NULL;
    double *corpus = NULL;
    size_t  dim = 0, corpus_dim = 0, n_corpus = 0;

    (void) result;

    /* query (required) */
    if (args->args[1] == NULL) {
        *is_null = 1;
        return NULL;
    }

    /* Refuse oversized inputs before the parse loops, so an adversarial
     * request can't drive an unbounded allocation. */
    if (args->lengths[1] > MAX_QUERY_BYTES) {
        *error = 1; return NULL;
    }
    if (args->args[0] != NULL && args->lengths[0] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

    if (!parse_vector_csv(args->args[1], args->lengths[1],
                          &query, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    if (dim == 0 || dim > MAX_QUERY_DIM) {
        free(query); *error = 1; return NULL;
    }

    /* corpus (required for discovery: there is nothing to explore in
     * an empty corpus). */
    if (args->args[0] != NULL && args->lengths[0] > 0) {
        if (!parse_corpus(args->args[0], args->lengths[0], dim,
                          &corpus, &n_corpus, &corpus_dim, errbuf)) {
            free(query); *error = 1; return NULL;
        }
        if (n_corpus > 0 && corpus_dim != dim) {
            free(query); free(corpus); *error = 1; return NULL;
        }
    }
    if (n_corpus == 0) {
        free(query); *is_null = 1; return NULL;
    }

    const char *params_s   = (args->args[2] != NULL) ? args->args[2] : "{}";
    size_t      params_len = (args->args[2] != NULL) ? args->lengths[2] : 2;

    /* Scout defaults: walk=0 (disperse across basins). Caller may
     * override iterations / population_size / diffusion_factor / walk. */
    int    iterations  = json_get_int   (params_s, params_len, "iterations",       15);
    int    pop_size    = json_get_int   (params_s, params_len, "population_size",  50);
    int    diff_factor = json_get_int   (params_s, params_len, "diffusion_factor", 2);
    double walk        = json_get_double(params_s, params_len, "walk",             0.0);

    /* Optional "session_id", same convention and rationale as
     * fractal_search's own session_id key (see its header comment). */
    unsigned long long session_id  = json_get_u64(params_s, params_len, "session_id", 0);
    bool                use_session = false;
    fsql_ctx           *search_ctx  = c->ctx;
    if (session_id != 0) {
        fsql_ctx *sc = fractal_session_acquire(session_id);
        if (sc != NULL) { search_ctx = sc; use_session = true; }
    }

    if (iterations < 1 || iterations > 10000   ||
        pop_size   < 2 || pop_size   > 100000  ||
        diff_factor < 1 || diff_factor > 32) {
        free(query); free(corpus);
        if (use_session) fractal_session_release(session_id);
        *error = 1; return NULL;
    }

    char core_params[256];
    snprintf(core_params, sizeof core_params,
        "{\"max_generation\":%d,\"population_size\":%d,"
        "\"maximum_diffusion\":%d,\"walk\":%.6g,"
        "\"return_population\":true,\"bound_clipping\":true}",
        iterations, pop_size, diff_factor, walk);

    const char *result_json = NULL;
    size_t      result_len  = 0;
    int rc = fsql_search_ptr(search_ctx,
                             corpus, n_corpus, dim,
                             query, dim,
                             /*k*/ 1,
                             core_params, strlen(core_params),
                             &result_json, &result_len);

    free(query);
    free(corpus);
    if (use_session) fractal_session_release(session_id);

    if (rc != 0) { *error = 1; return NULL; }

    /* result_json (incl. "population") is owned by whichever ctx ran
     * the search (c->ctx, or the session registry's ctx when
     * session_id was used) and stays valid until the next fsql_search*
     * on that same ctx. The registry ctx isn't freed by release(), so
     * this is safe either way: same lifetime contract as fractal_search. */
    *length  = (unsigned long) result_len;
    *is_null = 0;
    return (char *) result_json;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_dimension_dfa                                   */
/*                                                                    */
/* Detrended Fluctuation Analysis scaling exponent (Peng et al. 1994) */
/* for a numeric, time-ordered series. ~0.5 uncorrelated, ~1.0 1/f    */
/* "pink" noise, ~1.5 Brownian motion/random walk. Documented (here   */
/* and in the vendored fractalsql_sql.h) as "Requires >= 16 points",  */
/* but that floor is necessary, not sufficient: fsql_dimension_dfa's  */
/* actual internal validation rejects series shorter than 24 points   */
/* in practice, and it fails silently (FSQL_ERR_INVALID sets          */
/* *error=1 and returns NULL, with no distinguishing message). This   */
/* gap lives in fractalsql-core itself, upstream of this extension.   */
/* The real minimum likely depends on the data's own characteristics  */
/* rather than a fixed constant, so don't treat 24 as authoritative.  */
/* MariaDB has no float8[] array type, so series is a CSV/JSON-array  */
/* string, the same convention as fractal_search's                    */
/* vector_csv/query_csv arguments.                                    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_dimension_dfa_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_dimension_dfa(series_csv): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_dimension_dfa_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT double
fractal_dimension_dfa(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *series = NULL;
    size_t  n = 0;
    double  alpha;
    int     rc;
    (void) initid;

    if (args->args[0] == NULL) { *is_null = 1; return 0.0; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return 0.0; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &series, &n, errbuf)) {
        *error = 1; return 0.0;
    }
    rc = fsql_dimension_dfa(series, n, &alpha);
    free(series);
    if (rc != FSQL_OK) { *error = 1; return 0.0; }  /* series needs >= 16 points */

    *is_null = 0;
    return alpha;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_dimension_boxcount                              */
/*                                                                    */
/* Box-counting (Minkowski-Bouligand) fractal dimension over a point  */
/* cloud in `dim` dimensions. points_csv: flat, row-major n_points *  */
/* dim values (same CSV/JSON-array string convention as above).       */
/* Documented as "Requires >= 8 points and a non-degenerate bounding  */
/* box", the same "necessary, not sufficient" gap as fractal_dimension_ */
/* dfa's comment above: testing found far more than 8 points are      */
/* actually needed in practice (500 uniform-random 2-D points          */
/* succeeded, 64 did not). See that comment for the full account.     */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_dimension_boxcount_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_dimension_boxcount(points_csv, dim): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_dimension_boxcount_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT double
fractal_dimension_boxcount(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *points = NULL;
    size_t  flat_n = 0;
    long long dim;
    double  dimension;
    int     rc;
    (void) initid;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return 0.0; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return 0.0; }

    dim = *(long long *) args->args[1];
    if (dim <= 0) { *error = 1; return 0.0; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &points, &flat_n, errbuf)) {
        *error = 1; return 0.0;
    }
    if (flat_n % (size_t) dim != 0) {
        free(points); *error = 1; return 0.0;
    }

    rc = fsql_dimension_boxcount(points, flat_n / (size_t) dim, (size_t) dim, &dimension);
    free(points);
    if (rc != FSQL_OK) { *error = 1; return 0.0; }  /* need >= 8 pts, non-degenerate bbox */

    *is_null = 0;
    return dimension;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_dimension_drift                                 */
/*                                                                    */
/* DFA drift between a series' recent `win` points and everything     */
/* before them. Positive = increasing complexity/irregularity.        */
/* Requires n >= win + 16, win >= 16. Returns a JSON object as a       */
/* JSON-valid STRING: MariaDB's JSON type is itself just a validated   */
/* LONGTEXT, so this is not a lesser representation, just a            */
/* differently-named one.                                              */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_dimension_drift_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_dimension_drift(series_csv, win): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_dimension_drift_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_dimension_drift(UDF_INIT *initid, UDF_ARGS *args, char *result,
                        unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *series = NULL;
    size_t  n = 0;
    long long win;
    double  drift, recent_alpha, baseline_alpha;
    int     rc, jlen;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    win = *(long long *) args->args[1];
    if (win <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &series, &n, errbuf)) {
        *error = 1; return NULL;
    }
    rc = fsql_dimension_drift(series, n, (size_t) win,
                              &drift, &recent_alpha, &baseline_alpha);
    free(series);
    if (rc != FSQL_OK) { *error = 1; return NULL; }  /* need n >= win+16, win >= 16 */

    /* 1200 bytes is provably safe regardless of value magnitude: %.10f
     * on any finite double is at most ~330 chars (DBL_MAX's ~309-digit
     * integer part + '.' + 10 fraction digits + sign); 3 fields fit
     * with room to spare. snprintf itself never overflows the buffer
     * either way; this sizing (and the truncation check below) exists
     * so *length below is never set larger than what was actually
     * written, which would otherwise have MariaDB read past the
     * written content into unwritten buffer memory. */
    if (!json_out_ensure(jo, 1200)) { *error = 1; return NULL; }
    jlen = snprintf(jo->buf, jo->cap,
        "{\"drift\":%.10f,\"recent_alpha\":%.10f,\"baseline_alpha\":%.10f}",
        drift, recent_alpha, baseline_alpha);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

/* Best-effort audit-chain provenance (ledger kind=2) for a portfolio
 * decision. inputs_hash covers mu+cov so the decision's inputs are
 * verifiable later without duplicating a potentially large covariance
 * matrix into the ledger. Silent no-op when enterprise isn't loaded or
 * the write fails: portfolio optimization is a community feature and
 * must keep working regardless. */
static void
portfolio_audit_log_best_effort(const double *mu, const double *cov,
                                size_t n_assets, size_t k, long long seed,
                                double sharpe, const double *weights)
{
    if (!fractal_enterprise_lib_loaded())
        return;

    uint8_t hash[32];
    {
        size_t   mu_bytes  = n_assets * sizeof(double);
        size_t   cov_bytes = n_assets * n_assets * sizeof(double);
        uint8_t *buf = (uint8_t *) malloc(mu_bytes + cov_bytes);
        if (buf == NULL) return;
        memcpy(buf, mu, mu_bytes);
        memcpy(buf + mu_bytes, cov, cov_bytes);
        fractal_ledger_sha256(buf, mu_bytes + cov_bytes, hash);
        free(buf);
    }
    char hash_hex[65];
    for (int i = 0; i < 32; i++)
        snprintf(hash_hex + i * 2, 3, "%02x", hash[i]);

    size_t cap = 256 + n_assets * 24;
    char  *js  = (char *) malloc(cap);
    if (js == NULL) return;

    int pos = snprintf(js, cap,
        "{\"type\":\"portfolio_optimize\",\"entry\":{"
        "\"seed\":%lld,\"n_assets\":%zu,\"k\":%zu,\"sharpe\":%.10f,"
        "\"inputs_hash\":\"%s\",\"weights\":[",
        seed, n_assets, k, sharpe, hash_hex);
    if (pos < 0 || (size_t) pos >= cap) { free(js); return; }

    for (size_t i = 0; i < n_assets; i++)
    {
        int n = snprintf(js + pos, cap - (size_t) pos, "%s%.10f", i > 0 ? "," : "", weights[i]);
        if (n < 0 || (size_t)(pos + n) >= cap) { free(js); return; }
        pos += n;
    }
    int tail = snprintf(js + pos, cap - (size_t) pos, "]}}");
    if (tail < 0 || (size_t)(pos + tail) >= cap) { free(js); return; }
    pos += tail;

    (void) fractal_ledger_write_kind2(js, (size_t) pos);
    free(js);
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_optimize_portfolio                              */
/*                                                                    */
/* Cardinality-constrained Sharpe-ratio maximization. mu_csv:         */
/* n_assets expected returns. cov_csv: flat, row-major n_assets x     */
/* n_assets covariance matrix. k: at most k of n_assets get nonzero   */
/* weight (1 <= k <= n_assets). params (JSON, all keys optional):     */
/* MariaDB UDFs have no DEFAULT-argument syntax, so the optional        */
/* seed/use_obl/diffusion_mode knobs are bundled into a trailing params */
/* JSON blob instead, the same convention fractal_search already       */
/* established for its own tuning knobs:                                */
/*   {"seed": <int, default 0>, "use_obl": <bool, default false>,    */
/*    "diffusion_mode": <"gaussian"|"levy", default "gaussian">}      */
/* Returns {"sharpe": <double>, "weights": [w1, w2, ...]}.             */
/* Uses fsql_optimize_portfolio_ex, the OBL/Levy-flight-capable         */
/* sibling, not the plain fsql_optimize_portfolio, which has no         */
/* use_obl/diffusion_mode parameters at all.                            */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_optimize_portfolio_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_optimize_portfolio(mu_csv, cov_csv, k, params): "
            "expected 4 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_optimize_portfolio_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_optimize_portfolio(UDF_INIT *initid, UDF_ARGS *args, char *result,
                           unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char      errbuf[MYSQL_ERRMSG_SIZE];
    double   *mu = NULL, *cov = NULL, *weights = NULL;
    size_t    n_assets = 0, cov_n = 0;
    long long k;
    const char *params_s; size_t params_len;
    long long   seed;
    bool        use_obl;
    char        mode_buf[16];
    int         diffusion_mode = 0;
    double      sharpe;
    int         rc;
    size_t      pos, i;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    if (args->lengths[0] > MAX_CORPUS_BYTES || args->lengths[1] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

    k = *(long long *) args->args[2];

    if (!parse_vector_csv(args->args[0], args->lengths[0], &mu, &n_assets, errbuf)) {
        *error = 1; return NULL;
    }
    if (!parse_vector_csv(args->args[1], args->lengths[1], &cov, &cov_n, errbuf)) {
        free(mu); *error = 1; return NULL;
    }
    if (cov_n != n_assets * n_assets) {
        free(mu); free(cov); *error = 1; return NULL;
    }
    if (k <= 0 || (size_t) k > n_assets) {
        free(mu); free(cov); *error = 1; return NULL;
    }

    params_s   = (args->args[3] != NULL) ? args->args[3] : "{}";
    params_len = (args->args[3] != NULL) ? args->lengths[3] : 2;

    seed    = (long long) json_get_int(params_s, params_len, "seed", 0);
    use_obl = json_get_bool(params_s, params_len, "use_obl", false);
    if (json_get_str(params_s, params_len, "diffusion_mode", mode_buf, sizeof mode_buf)) {
        if (!parse_diffusion_mode(mode_buf, &diffusion_mode, errbuf)) {
            free(mu); free(cov); *error = 1; return NULL;
        }
    }

    weights = malloc(n_assets * sizeof(double));
    if (weights == NULL) {
        free(mu); free(cov); *error = 1; return NULL;
    }

    rc = fsql_optimize_portfolio_ex(mu, cov, n_assets, (size_t) k, (uint64_t) seed,
                                    use_obl ? 1 : 0, diffusion_mode,
                                    weights, &sharpe);
    if (rc != FSQL_OK) { free(mu); free(cov); free(weights); *error = 1; return NULL; }

    portfolio_audit_log_best_effort(mu, cov, n_assets, (size_t) k, seed, sharpe, weights);
    free(mu); free(cov);

    /* Safe against any n_assets / any weight magnitude: each element is
     * formatted into a fixed worst-case-sized stack buffer first (356
     * bytes comfortably covers "," + %.10f of any finite double, see
     * the drift/vascular_network/etc. functions' own comment on that
     * bound), checked for truncation, THEN the destination is grown to
     * fit before copying. Unlike a single upfront size estimate
     * (n_assets * small-constant), this can't be defeated by either an
     * unexpectedly large n_assets or an unexpectedly large |weight[i]|.
     */
    if (!json_out_ensure(jo, 64)) { free(weights); *error = 1; return NULL; }
    pos = (size_t) snprintf(jo->buf, jo->cap, "{\"sharpe\":%.10f,\"weights\":[", sharpe);
    for (i = 0; i < n_assets; i++) {
        char field[356];
        int  flen = snprintf(field, sizeof field, "%s%.10f",
                             i > 0 ? "," : "", weights[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) {
            free(weights); *error = 1; return NULL;
        }
        if (!json_out_ensure(jo, pos + (size_t) flen + 8)) {
            free(weights); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    if (!json_out_ensure(jo, pos + 8)) { free(weights); *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "]}");
    free(weights);

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vascular_network                                */
/*                                                                    */
/* Vessel-network tortuosity/branch-density/dimension. node_coords:   */
/* flat n_nodes * 3 (x,y,z). edges: flat n_edges * 2 node-index       */
/* pairs. edge_arc_length: n_edges true centerline arc lengths (from  */
/* an upstream centerline trace, e.g. VMTK). Returns {mean_tortuosity, */
/* branch_density, fractal_dimension}. Scope boundary shared with the  */
/* three functions below: pre-extracted geometry only, not raw        */
/* imaging data.                                                      */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vascular_network_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_vascular_network(node_coords_csv, edges_csv, edge_arc_length_csv): "
            "expected 3 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vascular_network_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_vascular_network(UDF_INIT *initid, UDF_ARGS *args, char *result,
                         unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    double  *node_coords = NULL, *arc_length = NULL;
    size_t  *edges = NULL;
    size_t   nc_n = 0, e_n = 0, al_n = 0;
    double   mean_tortuosity, branch_density, fractal_dimension;
    int      rc, jlen;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    if (args->lengths[0] > MAX_CORPUS_BYTES || args->lengths[2] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &node_coords, &nc_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (!parse_index_csv(args->args[1], args->lengths[1], &edges, &e_n, errbuf)) {
        free(node_coords); *error = 1; return NULL;
    }
    if (!parse_vector_csv(args->args[2], args->lengths[2], &arc_length, &al_n, errbuf)) {
        free(node_coords); free(edges); *error = 1; return NULL;
    }

    if (nc_n % 3 != 0 || e_n % 2 != 0 || al_n != e_n / 2) {
        free(node_coords); free(edges); free(arc_length);
        *error = 1; return NULL;
    }

    rc = fsql_vascular_network(node_coords, nc_n / 3, edges, arc_length, e_n / 2,
                               &mean_tortuosity, &branch_density, &fractal_dimension);
    free(node_coords); free(edges); free(arc_length);
    if (rc != FSQL_OK) { *error = 1; return NULL; }

    /* 1200 bytes: see fractal_dimension_drift's identically-reasoned
     * comment on this bound (3 %.10f fields, provably safe regardless
     * of value magnitude). */
    if (!json_out_ensure(jo, 1200)) { *error = 1; return NULL; }
    jlen = snprintf(jo->buf, jo->cap,
        "{\"mean_tortuosity\":%.10f,\"branch_density\":%.10f,\"fractal_dimension\":%.10f}",
        mean_tortuosity, branch_density, fractal_dimension);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_cortical_folding                                */
/*                                                                    */
/* Gyrification Index (Zilles et al. 1988): mesh surface area /       */
/* convex hull surface area. vertices: flat n_vertices * 3. faces:    */
/* flat n_faces * 3 triangle vertex indices. Requires >= 4            */
/* non-coplanar vertices.                                             */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_cortical_folding_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_cortical_folding(vertices_csv, faces_csv): "
            "expected 2 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_cortical_folding_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_cortical_folding(UDF_INIT *initid, UDF_ARGS *args, char *result,
                         unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *vertices = NULL;
    size_t *faces = NULL;
    size_t  v_n = 0, f_n = 0;
    double  mesh_area, hull_area, gi;
    int     rc, jlen;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &vertices, &v_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (!parse_index_csv(args->args[1], args->lengths[1], &faces, &f_n, errbuf)) {
        free(vertices); *error = 1; return NULL;
    }
    if (v_n % 3 != 0 || f_n % 3 != 0) {
        free(vertices); free(faces); *error = 1; return NULL;
    }

    rc = fsql_cortical_folding(vertices, v_n / 3, faces, f_n / 3,
                               &mesh_area, &hull_area, &gi);
    free(vertices); free(faces);
    if (rc != FSQL_OK) { *error = 1; return NULL; }  /* need >= 4 non-coplanar vertices */

    /* 1200 bytes: see fractal_dimension_drift's identically-reasoned
     * comment on this bound. */
    if (!json_out_ensure(jo, 1200)) { *error = 1; return NULL; }
    jlen = snprintf(jo->buf, jo->cap,
        "{\"mesh_area\":%.10f,\"hull_area\":%.10f,\"gyrification_index\":%.10f}",
        mesh_area, hull_area, gi);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_nerve_plexus_metric                             */
/*                                                                    */
/* Nerve fiber plexus metrics (corneal confocal microscopy            */
/* convention). node_coords: flat n_nodes * dim (dim typically 2).    */
/* edges: flat n_edges * 2 node-index pairs.                          */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_nerve_plexus_metric_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_nerve_plexus_metric(node_coords_csv, dim, edges_csv): "
            "expected 3 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_nerve_plexus_metric_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_nerve_plexus_metric(UDF_INIT *initid, UDF_ARGS *args, char *result,
                            unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char      errbuf[MYSQL_ERRMSG_SIZE];
    double   *node_coords = NULL;
    size_t   *edges = NULL;
    size_t    nc_n = 0, e_n = 0;
    long long dim;
    double    fiber_length_density, branch_density, fractal_dimension;
    int       rc, jlen;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    dim = *(long long *) args->args[1];
    if (dim <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &node_coords, &nc_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (!parse_index_csv(args->args[2], args->lengths[2], &edges, &e_n, errbuf)) {
        free(node_coords); *error = 1; return NULL;
    }
    if (nc_n % (size_t) dim != 0 || e_n % 2 != 0) {
        free(node_coords); free(edges); *error = 1; return NULL;
    }

    rc = fsql_nerve_plexus_metric(node_coords, nc_n / (size_t) dim, (size_t) dim,
                                  edges, e_n / 2,
                                  &fiber_length_density, &branch_density,
                                  &fractal_dimension);
    free(node_coords); free(edges);
    if (rc != FSQL_OK) { *error = 1; return NULL; }

    /* 1200 bytes: see fractal_dimension_drift's identically-reasoned
     * comment on this bound. */
    if (!json_out_ensure(jo, 1200)) { *error = 1; return NULL; }
    jlen = snprintf(jo->buf, jo->cap,
        "{\"fiber_length_density\":%.10f,\"branch_density\":%.10f,"
        "\"fractal_dimension\":%.10f}",
        fiber_length_density, branch_density, fractal_dimension);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_morphological_complexity                       */
/*                                                                    */
/* Morphological complexity of a pre-segmented mask: box-counting     */
/* dimension + fixed-grid lacunarity. points: flat n_points * dim     */
/* occupied mask points.                                              */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_morphological_complexity_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_morphological_complexity(points_csv, dim): "
            "expected 2 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_morphological_complexity_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

FRACTAL_EXPORT char *
fractal_morphological_complexity(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                 unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char      errbuf[MYSQL_ERRMSG_SIZE];
    double   *points = NULL;
    size_t    p_n = 0;
    long long dim;
    double    dimension, lacunarity;
    int       rc, jlen;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    dim = *(long long *) args->args[1];
    if (dim <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &points, &p_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (p_n % (size_t) dim != 0) {
        free(points); *error = 1; return NULL;
    }

    rc = fsql_morphological_complexity(points, p_n / (size_t) dim, (size_t) dim,
                                       &dimension, &lacunarity);
    free(points);
    if (rc != FSQL_OK) { *error = 1; return NULL; }  /* need >= 8 pts, non-degenerate bbox */

    /* 900 bytes: 2 %.10f fields, same worst-case reasoning as
     * fractal_dimension_drift's comment. */
    if (!json_out_ensure(jo, 900)) { *error = 1; return NULL; }
    jlen = snprintf(jo->buf, jo->cap, "{\"dimension\":%.10f,\"lacunarity\":%.10f}",
                    dimension, lacunarity);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractalsql_edition                                      */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractalsql_edition_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message, "fractalsql_edition(): expected 0 arguments");
        return true;
    }
    initid->maybe_null = 0;
    initid->max_length = 32;
    return false;
}

FRACTAL_EXPORT void
fractalsql_edition_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT char *
fractalsql_edition(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    static const char kEdition[] = "Community";
    (void) initid; (void) args; (void) error;
    memcpy(result, kEdition, sizeof(kEdition) - 1);
    *length  = (unsigned long)(sizeof(kEdition) - 1);
    *is_null = 0;
    return result;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractalsql_version                                      */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractalsql_version_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message, "fractalsql_version(): expected 0 arguments");
        return true;
    }
    initid->maybe_null = 0;
    initid->max_length = 32;
    return false;
}

FRACTAL_EXPORT void
fractalsql_version_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT char *
fractalsql_version(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    static const char kVersion[] = FSQL_VERSION;
    (void) initid; (void) args; (void) error;
    memcpy(result, kVersion, sizeof(kVersion) - 1);
    *length  = (unsigned long)(sizeof(kVersion) - 1);
    *is_null = 0;
    return result;
}

/* ------------------------------------------------------------------ */
/* UDF triads: fractal_diversify_enable / _disable / _set_params /    */
/* fractal_detect_collapse / fractal_explain_result /                 */
/* fractal_session_close                                              */
/*                                                                    */
/* MariaDB is one shared multithreaded process for every connection,   */
/* so fsql_diversify_*'s own g_ctx, a plain file-static, cannot be     */
/* used directly here: it would leak one session's Diversify tuning    */
/* (and its rolling D_q / overhead stats) into every other concurrent  */
/* session's queries. Every function below therefore takes an explicit */
/* session_id BIGINT as its first argument and operates through the    */
/* connection-scoped registry in fractalsql_session.c instead. Pass    */
/* CONNECTION_ID() by convention (sql/install_udf.sql documents        */
/* this). fractal_search /                                             */
/* fractal_explore pick up the same session's ctx via an optional      */
/* "session_id" key in their own params JSON, see those functions'     */
/* header comments.                                                    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_diversify_enable_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_diversify_enable(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_diversify_enable_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_diversify_enable(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }
    int rc = fsql_diversify_enable(ctx);
    fractal_session_release(sid);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

FRACTAL_EXPORT bool
fractal_diversify_disable_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_diversify_disable(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_diversify_disable_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_diversify_disable(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }
    int rc = fsql_diversify_disable(ctx);
    fractal_session_release(sid);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

FRACTAL_EXPORT bool
fractal_diversify_set_params_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_diversify_set_params(session_id, params_json): "
            "expected 2 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_diversify_set_params_deinit(UDF_INIT *initid) { (void) initid; }

/* params_json (JSON object, all keys optional; only supplied keys
 * override the session's current value, an omitted key means
 * unchanged):
 *   {"window_n": <uint>, "stall_threshold": <double>,
 *    "repulsion_sigma": <double>, "repulsion_weight": <double>,
 *    "max_shadows_considered": <uint>, "tail_buffer_cap": <uint>} */
FRACTAL_EXPORT long long
fractal_diversify_set_params(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];

    const char *params_s   = (args->args[1] != NULL) ? args->args[1] : "{}";
    size_t      params_len = (args->args[1] != NULL) ? args->lengths[1] : 2;

    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }

    fsql_diversify_params_t p;
    int rc = fsql_diversify_get_params(ctx, &p);
    if (rc != FSQL_OK) {
        fractal_session_release(sid);
        *error = 1; return 0;
    }

    size_t pos;
    if (json_find_key(params_s, params_len, "window_n", &pos))
        p.window_n = (uint32_t) json_get_int(params_s, params_len, "window_n", (int) p.window_n);
    if (json_find_key(params_s, params_len, "stall_threshold", &pos))
        p.stall_threshold = json_get_double(params_s, params_len, "stall_threshold", p.stall_threshold);
    if (json_find_key(params_s, params_len, "repulsion_sigma", &pos))
        p.repulsion_sigma = json_get_double(params_s, params_len, "repulsion_sigma", p.repulsion_sigma);
    if (json_find_key(params_s, params_len, "repulsion_weight", &pos))
        p.repulsion_weight = json_get_double(params_s, params_len, "repulsion_weight", p.repulsion_weight);
    if (json_find_key(params_s, params_len, "max_shadows_considered", &pos))
        p.max_shadows_considered = (uint32_t) json_get_int(params_s, params_len,
                                        "max_shadows_considered", (int) p.max_shadows_considered);
    if (json_find_key(params_s, params_len, "tail_buffer_cap", &pos))
        p.tail_buffer_cap = (uint32_t) json_get_int(params_s, params_len,
                                        "tail_buffer_cap", (int) p.tail_buffer_cap);

    rc = fsql_diversify_set_params(ctx, &p);
    fractal_session_release(sid);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

FRACTAL_EXPORT bool
fractal_detect_collapse_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_detect_collapse(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_detect_collapse_deinit(UDF_INIT *initid) { (void) initid; }

/* Current D_q for the session (see fractal_diversify_set_params).
 * NULL if diversify is disabled or no diversify-aware search (i.e. one
 * passing this same session_id) has run yet on this session. */
FRACTAL_EXPORT double
fractal_detect_collapse(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0.0; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0.0; }
    double dq = fsql_diversify_current_dq(ctx);
    fractal_session_release(sid);
    if (isnan(dq)) { *is_null = 1; return 0.0; }
    *is_null = 0;
    return dq;
}

FRACTAL_EXPORT bool
fractal_explain_result_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_explain_result(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_explain_result_deinit(UDF_INIT *initid)
{
    json_out_generic_deinit(initid);
}

/* Session-level Diversify diagnostics: current D_q, whether the
 * monitor is enabled, and its rolling p99 overhead. Not a per-result
 * "this candidate was penalized by shadow X" trace: the core ABI
 * doesn't surface per-candidate shadow attribution at that
 * granularity. Returns {"dq":..,"diversify_enabled":..,
 * "overhead_p99_us":..}. dq/overhead_p99_us are JSON null until
 * enough diversify-aware search calls (same session_id) have run. */
FRACTAL_EXPORT char *
fractal_explain_result(UDF_INIT *initid, UDF_ARGS *args, char *result,
                       unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];

    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return NULL; }

    fsql_diversify_params_t p;
    bool   enabled  = (fsql_diversify_get_params(ctx, &p) == FSQL_OK);
    double dq       = fsql_diversify_current_dq(ctx);
    double overhead = fsql_diversify_overhead_p99_us(ctx);
    fractal_session_release(sid);

    /* 900 bytes: two %.10f doubles (~330 chars worst case each, see
     * fractal_dimension_drift's identically-reasoned comment) plus a
     * fixed bool literal fit with room to spare. */
    if (!json_out_ensure(jo, 900)) { *error = 1; return NULL; }
    int jlen;
    if (isnan(dq) && isnan(overhead))
        jlen = snprintf(jo->buf, jo->cap,
            "{\"dq\":null,\"diversify_enabled\":%s,\"overhead_p99_us\":null}",
            enabled ? "true" : "false");
    else if (isnan(dq))
        jlen = snprintf(jo->buf, jo->cap,
            "{\"dq\":null,\"diversify_enabled\":%s,\"overhead_p99_us\":%.10f}",
            enabled ? "true" : "false", overhead);
    else if (isnan(overhead))
        jlen = snprintf(jo->buf, jo->cap,
            "{\"dq\":%.10f,\"diversify_enabled\":%s,\"overhead_p99_us\":null}",
            dq, enabled ? "true" : "false");
    else
        jlen = snprintf(jo->buf, jo->cap,
            "{\"dq\":%.10f,\"diversify_enabled\":%s,\"overhead_p99_us\":%.10f}",
            dq, enabled ? "true" : "false", overhead);
    if (jlen < 0 || (size_t) jlen >= jo->cap) { *error = 1; return NULL; }

    *length  = (unsigned long) jlen;
    *is_null = 0;
    return jo->buf;
}

FRACTAL_EXPORT bool
fractal_session_close_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_session_close(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 0;
    return false;
}

FRACTAL_EXPORT void
fractal_session_close_deinit(UDF_INIT *initid) { (void) initid; }

/* Explicit early cleanup for a session's registry entry, freeing it
 * immediately (if not currently pinned by an in-flight call, see
 * fractalsql_session.h) rather than waiting on the idle-TTL sweep.
 * Not required for correctness, just good hygiene for a long-lived
 * connection pool that reuses connections and wants to drop Diversify
 * state deterministically between logical sessions. */
FRACTAL_EXPORT long long
fractal_session_close(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid; (void) error;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fractal_session_registry_close(sid);
    *is_null = 0;
    return 0;
}

/* fractal_feedback_report / fractal_isolate_background: both ship
 * since fractal_agent_feedback_audit needs the latter, and they're
 * one thin wrapper apart around fsql_feedback_report, already in the
 * vendored core ABI (fractalsql_sql.h). Session-scoped via
 * fractal_session_acquire, same reasoning as the Diversify triad
 * above: fsql_feedback_report writes into the SAME per-ctx rolling
 * state fsql_diversify_* reads, so it must operate on the calling
 * session's own ctx, not a shared process-wide one. */

static bool
parse_engagement_kind(const char *s, size_t len, fsql_engagement_kind_t *out)
{
    if (len == 5 && strncasecmp(s, "dwell", 5) == 0)    { *out = FSQL_ENGAGE_DWELL;    return true; }
    if (len == 8 && strncasecmp(s, "positive", 8) == 0) { *out = FSQL_ENGAGE_POSITIVE; return true; }
    if (len == 8 && strncasecmp(s, "negative", 8) == 0) { *out = FSQL_ENGAGE_NEGATIVE; return true; }
    return false;
}

FRACTAL_EXPORT bool
fractal_feedback_report_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3 && args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_feedback_report(session_id, result_handle, kind [, dwell_ms]): "
            "expected 3 or 4 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = STRING_RESULT;
    if (args->arg_count == 4) args->arg_type[3] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_feedback_report_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_feedback_report(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) { *is_null = 1; return 0; }

    long long result_handle = *(long long *) args->args[1];
    if (result_handle < 0) { *error = 1; return 0; }

    fsql_engagement_kind_t kind;
    if (!parse_engagement_kind(args->args[2], args->lengths[2], &kind)) { *error = 1; return 0; }

    long long dwell_ms = (args->arg_count == 4 && args->args[3] != NULL) ? *(long long *) args->args[3] : 0;

    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }
    int rc = fsql_feedback_report(ctx, (uint64_t) result_handle, kind, (uint32_t) dwell_ms);
    fractal_session_release(sid);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}

/* Convenience wrapper: negative-engagement feedback report, no dwell.
 * Inert until fractal_diversify_enable() has been called on this
 * session; documented, not silently misleading. */
FRACTAL_EXPORT bool
fractal_isolate_background_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_isolate_background(session_id, result_handle): "
            "expected 2 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = INT_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_isolate_background_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_isolate_background(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid;
    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return 0; }

    long long result_handle = *(long long *) args->args[1];
    if (result_handle < 0) { *error = 1; return 0; }

    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    fsql_ctx *ctx = fractal_session_acquire(sid);
    if (ctx == NULL) { *error = 1; return 0; }
    int rc = fsql_feedback_report(ctx, (uint64_t) result_handle, FSQL_ENGAGE_NEGATIVE, 0);
    fractal_session_release(sid);
    if (rc != FSQL_OK) { *error = 1; return 0; }
    *is_null = 0;
    return 0;
}
