/* src/fractalsql_vector.c
 * fractal_vector_* - Discovery tier, Vector group.
 *
 * REPRESENTATION:
 *
 *   A fractal_vector is a JSON-array-of-numbers STRING, e.g. "[1,2,3]",
 *   exactly fractalsql.c's existing parse_vector_csv convention
 *   (used for query_csv and corpus rows), which also accepts bare CSV
 *   ("1,2,3"). This is the PORTABLE path: it works on the full
 *   10.6-12.2 compat floor this extension targets, with no server
 *   feature detection needed. Every function below reads/writes this
 *   representation and does the actual math via fractalsql-core's
 *   fsql_vector_* module (float32, available in every tier, see
 *   fractalsql_sql.h).
 *
 *   The NATIVE path (MariaDB 11.7.1+, GA in 11.8 LTS) is MariaDB's own
 *   VECTOR(n) column type plus its built-in VEC_FROMTEXT/VEC_TOTEXT/
 *   VEC_DISTANCE_EUCLIDEAN/VEC_DISTANCE_COSINE functions, verified
 *   (not assumed) to use the IDENTICAL bracket-comma text grammar this
 *   file emits and accepts (VEC_FROMTEXT('[1,2,3]') is documented
 *   MariaDB syntax). That means no conversion UDF is needed for
 *   interop: a caller on 11.7+ can wrap any fractal_vector_* JSON-
 *   string result in VEC_FROMTEXT() to get a native VECTOR value with
 *   index-accelerated ANN search, and VEC_TOTEXT() on a native column
 *   feeds straight back into these functions. One representation, two
 *   consumers, verified text-format-compatible rather than duplicated
 *   as separate C paths. Documented with a worked example in
 *   sql/install_udf.sql.
 *
 * Storage precision is float4, not float8, matching fsql_vector_*'s own
 * representation.
 */

#include <mysql.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql.h"       /* FSQL_OK */
#include "fractalsql_sql.h"   /* fsql_vector_* */
#include "fractalsql_parse.h" /* parse_vector_csv (shared with fractalsql.c) */

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

#define SFS_INIT_ERROR(msg, ...) \
    (snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__))

/* Same DoS-guard reasoning as fractalsql.c's MAX_QUERY_BYTES/
 * MAX_QUERY_DIM (a caller-controlled JSON string driving a malloc,
 * uncapped would let a multi-GiB argument OOM-kill the server). A
 * fractal_vector is a single embedding, not a corpus, so this is
 * sized like fractalsql.c's per-query caps, not its per-corpus ones. */
#define FSQL_VECTOR_MAX_BYTES ((unsigned long) 4u * 1024u * 1024u) /* 4 MiB */
#define FSQL_VECTOR_MAX_DIM   (1u * 1024u * 1024u)                 /* 1 M elem */

/* ------------------------------------------------------------------ */
/* Growable output buffer (same pattern as fractalsql.c's json_out_ctx, */
/* duplicated locally rather than shared, matching the precedent       */
/* already set by fractalsql_session.c's own local platform shim).     */
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
        SFS_INIT_ERROR(message, "fractal_vector: out of memory");
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

/* Formats a float array as bracket-JSON "[v0,v1,...]" into jo->buf
 * (NUL-terminated, reused across calls per the UDF STRING-result
 * contract). "%.9g" per element is directly consumable by MariaDB
 * 11.7+'s VEC_FROMTEXT(). Returns jo->buf and sets *out_len on
 * success, NULL on OOM. */
static char *
format_vector_json(json_out_ctx *jo, const float *v, size_t dim, unsigned long *out_len)
{
    /* Worst case per element: sign + '.' + 9 significant digits +
     * 'e' + sign + up to 3-digit exponent + comma ~= 17 bytes. */
    size_t need = dim * 17 + 4;
    size_t pos;

    if (!json_out_ensure(jo, need)) return NULL;

    pos = 0;
    jo->buf[pos++] = '[';
    for (size_t i = 0; i < dim; i++) {
        int n;
        if (i > 0) jo->buf[pos++] = ',';
        n = snprintf(jo->buf + pos, jo->cap - pos, "%.9g", (double) v[i]);
        if (n < 0 || (size_t) n >= jo->cap - pos) return NULL;
        pos += (size_t) n;
    }
    jo->buf[pos++] = ']';
    jo->buf[pos]   = '\0';

    *out_len = (unsigned long) pos;
    return jo->buf;
}

/* Parses arg text via the shared parse_vector_csv, narrows the result
 * to float32 (fsql_vector_*'s native width, see fractalsql_sql.h's
 * "Vector Arithmetic" comment on why this module is float32-only),
 * and enforces FSQL_VECTOR_MAX_DIM. *out is malloc'd; caller frees. */
static bool
load_vector(const char *s, size_t slen, float **out, size_t *dim_out, char *errbuf)
{
    double *dv = NULL;
    size_t  n  = 0;
    float  *fv;

    if (!parse_vector_csv(s, slen, &dv, &n, errbuf)) return false;
    if (n > FSQL_VECTOR_MAX_DIM) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: dimension %zu exceeds maximum %u",
                       n, FSQL_VECTOR_MAX_DIM);
        free(dv);
        return false;
    }
    fv = malloc(n * sizeof(float));
    if (fv == NULL) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: oom");
        free(dv);
        return false;
    }
    for (size_t i = 0; i < n; i++) fv[i] = (float) dv[i];
    free(dv);

    *out     = fv;
    *dim_out = n;
    return true;
}

/* Loads args[0]/args[1] as a matched-dimension pair. On dimension
 * mismatch, frees both and fails with a clear message rather than
 * handing fsql_vector_* a shorter-than-expected buffer. */
static bool
load_pair(UDF_ARGS *args, float **a, float **b, size_t *dim, char *errbuf)
{
    size_t da, db;

    if (!load_vector(args->args[0], args->lengths[0], a, &da, errbuf)) return false;
    if (!load_vector(args->args[1], args->lengths[1], b, &db, errbuf)) {
        free(*a);
        return false;
    }
    if (da != db) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: dimension mismatch (%zu vs %zu)", da, db);
        free(*a); free(*b);
        return false;
    }
    *dim = da;
    return true;
}

static bool
compute_pair_scalar(UDF_ARGS *args, char *errbuf,
                    int (*fn)(const float *, const float *, size_t, float *),
                    double *out)
{
    float *a = NULL, *b = NULL;
    size_t dim = 0;
    float  r;
    int    rc;

    if (!load_pair(args, &a, &b, &dim, errbuf)) return false;
    rc = fn(a, b, dim, &r);
    free(a); free(b);
    if (rc != FSQL_OK) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: computation failed");
        return false;
    }
    *out = (double) r;
    return true;
}

/* ==================================================================== */
/* UDF triad: fractal_vector_dims                                        */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_vector_dims_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_dims(vec): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_vector_dims_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_vector_dims(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    double *v = NULL;
    size_t  n = 0;
    (void) initid;

    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0; }
    if (!parse_vector_csv(args->args[0], args->lengths[0], &v, &n, errbuf)) {
        *error = 1; return 0;
    }
    free(v);
    *is_null = 0;
    return (long long) n;
}

/* ==================================================================== */
/* UDF triad: fractal_vector_norm                                        */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_vector_norm_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_norm(vec): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_vector_norm_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT double
fractal_vector_norm(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL;
    size_t  dim = 0;
    float   out;
    int     rc;
    (void) initid;

    if (args->args[0] == NULL) { *is_null = 1; return 0.0; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0.0; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return 0.0;
    }
    rc = fsql_vector_norm(v, dim, &out);
    free(v);
    if (rc != FSQL_OK) { *error = 1; return 0.0; }

    *is_null = 0;
    return (double) out;
}

/* ==================================================================== */
/* UDF triad: fractal_vector_normalize                                   */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_vector_normalize_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_normalize(vec): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_normalize_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_normalize(UDF_INIT *initid, UDF_ARGS *args, char *result,
                         unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL, *out;
    size_t  dim = 0;
    char   *s;
    int     rc;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return NULL; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    out = malloc(dim * sizeof(float));
    if (out == NULL) { free(v); *error = 1; return NULL; }
    rc = fsql_vector_normalize(v, dim, out);
    free(v);
    if (rc != FSQL_OK) { free(out); *error = 1; return NULL; }

    s = format_vector_json(jo, out, dim, length);
    free(out);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* UDF triads: fractal_vector_add / fractal_vector_sub                   */
/* Elementwise sum / difference. Requires matching dimensions.           */
/* ==================================================================== */

#define FRACTAL_VECTOR_BINOP(NAME, FSQL_FN, DOC)                                    \
FRACTAL_EXPORT bool                                                                 \
NAME##_init(UDF_INIT *initid, UDF_ARGS *args, char *message)                        \
{                                                                                    \
    if (args->arg_count != 2) {                                                     \
        SFS_INIT_ERROR(message,                                                     \
            #NAME "(a, b): expected 2 arguments, got %u", args->arg_count);         \
        return true;                                                                \
    }                                                                               \
    args->arg_type[0] = STRING_RESULT;                                             \
    args->arg_type[1] = STRING_RESULT;                                             \
    return json_out_generic_init(initid, message);                                 \
}                                                                                    \
FRACTAL_EXPORT void                                                                 \
NAME##_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }                \
/* DOC */                                                                            \
FRACTAL_EXPORT char *                                                               \
NAME(UDF_INIT *initid, UDF_ARGS *args, char *result,                               \
    unsigned long *length, char *is_null, char *error)                             \
{                                                                                    \
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;                               \
    char    errbuf[MYSQL_ERRMSG_SIZE];                                             \
    float  *a = NULL, *b = NULL, *out;                                             \
    size_t  dim = 0;                                                               \
    char   *s;                                                                     \
    int     rc;                                                                    \
    (void) result;                                                                 \
    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; } \
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES ||                                \
        args->lengths[1] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return NULL; }     \
    if (!load_pair(args, &a, &b, &dim, errbuf)) { *error = 1; return NULL; }       \
    out = malloc(dim * sizeof(float));                                            \
    if (out == NULL) { free(a); free(b); *error = 1; return NULL; }               \
    rc = FSQL_FN(a, b, dim, out);                                                  \
    free(a); free(b);                                                             \
    if (rc != FSQL_OK) { free(out); *error = 1; return NULL; }                    \
    s = format_vector_json(jo, out, dim, length);                                  \
    free(out);                                                                     \
    if (s == NULL) { *error = 1; return NULL; }                                    \
    *is_null = 0;                                                                  \
    return s;                                                                      \
}

FRACTAL_VECTOR_BINOP(fractal_vector_add, fsql_vector_add, "Elementwise sum.")
FRACTAL_VECTOR_BINOP(fractal_vector_sub, fsql_vector_sub, "Elementwise difference.")

#undef FRACTAL_VECTOR_BINOP

/* ==================================================================== */
/* UDF triad: fractal_vector_scale(vec, scalar)                          */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_vector_scale_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_vector_scale(vec, scalar): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = REAL_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_scale_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_scale(UDF_INIT *initid, UDF_ARGS *args, char *result,
                     unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL, *out;
    size_t  dim = 0;
    double  scalar;
    char   *s;
    int     rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return NULL; }
    scalar = *(double *) args->args[1];
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    out = malloc(dim * sizeof(float));
    if (out == NULL) { free(v); *error = 1; return NULL; }
    rc = fsql_vector_scale(v, dim, (float) scalar, out);
    free(v);
    if (rc != FSQL_OK) { free(out); *error = 1; return NULL; }

    s = format_vector_json(jo, out, dim, length);
    free(out);
    if (s == NULL) { *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* UDF triads: pairwise scalar distances/similarity                      */
/*   fractal_vector_l2_distance, fractal_vector_l2_squared,               */
/*   fractal_vector_cosine_distance, fractal_vector_cosine_similarity     */
/* ==================================================================== */

#define FRACTAL_VECTOR_DISTANCE(NAME, FSQL_FN)                                      \
FRACTAL_EXPORT bool                                                                 \
NAME##_init(UDF_INIT *initid, UDF_ARGS *args, char *message)                        \
{                                                                                    \
    if (args->arg_count != 2) {                                                     \
        SFS_INIT_ERROR(message,                                                     \
            #NAME "(a, b): expected 2 arguments, got %u", args->arg_count);         \
        return true;                                                                \
    }                                                                               \
    args->arg_type[0] = STRING_RESULT;                                             \
    args->arg_type[1] = STRING_RESULT;                                             \
    initid->maybe_null = 1;                                                        \
    return false;                                                                   \
}                                                                                    \
FRACTAL_EXPORT void                                                                 \
NAME##_deinit(UDF_INIT *initid) { (void) initid; }                                  \
FRACTAL_EXPORT double                                                               \
NAME(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)                  \
{                                                                                    \
    char   errbuf[MYSQL_ERRMSG_SIZE];                                              \
    double out;                                                                     \
    (void) initid;                                                                  \
    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return 0.0; } \
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES ||                                \
        args->lengths[1] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0.0; }      \
    if (!compute_pair_scalar(args, errbuf, FSQL_FN, &out)) { *error = 1; return 0.0; } \
    *is_null = 0;                                                                  \
    return out;                                                                     \
}

FRACTAL_VECTOR_DISTANCE(fractal_vector_l2_distance,        fsql_vector_l2)
FRACTAL_VECTOR_DISTANCE(fractal_vector_l2_squared,          fsql_vector_l2_sq)
FRACTAL_VECTOR_DISTANCE(fractal_vector_cosine_distance,     fsql_vector_cosine_distance)
FRACTAL_VECTOR_DISTANCE(fractal_vector_cosine_similarity,   fsql_vector_cosine_similarity)

#undef FRACTAL_VECTOR_DISTANCE

/* ==================================================================== */
/* UDF triad: fractal_vector_negative_inner_product(a, b)                */
/* Dot product, negated, so ORDER BY ... ASC ranks it like a distance   */
/* (highest similarity first). Reuses the                                */
/* raw dot product (fsql_vector_dot) rather than a dedicated core         */
/* symbol, since negation is a one-line caller-side transform.           */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_vector_negative_inner_product_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_vector_negative_inner_product(a, b): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_vector_negative_inner_product_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT double
fractal_vector_negative_inner_product(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char   errbuf[MYSQL_ERRMSG_SIZE];
    double dot;
    (void) initid;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return 0.0; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES ||
        args->lengths[1] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0.0; }
    if (!compute_pair_scalar(args, errbuf, fsql_vector_dot, &dot)) { *error = 1; return 0.0; }

    *is_null = 0;
    return -dot;
}

/* ==================================================================== */
/* UDF triads: fractal_vector_from_float8_array / _to_float8_array        */
/*                                                                        */
/* These name a conversion between a float8[]-shaped array and the       */
/* fractal_vector type. MariaDB has no float8[] array type distinct      */
/* from the JSON-array-string convention this whole module already       */
/* uses, so both names collapse to the same operation here: parse,       */
/* narrow through float32 (the same precision fractal_vector actually    */
/* stores at, in every binding), and re-emit canonical "%.9g" JSON.       */
/* Kept as two separate names (not one aliased to the other) so the      */
/* call site still documents which direction the conversion runs.        */
/* ==================================================================== */

#define FRACTAL_VECTOR_CANONICALIZE(NAME, DOC)                                      \
FRACTAL_EXPORT bool                                                                 \
NAME##_init(UDF_INIT *initid, UDF_ARGS *args, char *message)                        \
{                                                                                    \
    if (args->arg_count != 1) {                                                     \
        SFS_INIT_ERROR(message,                                                     \
            #NAME "(vec): expected 1 argument, got %u", args->arg_count);           \
        return true;                                                                \
    }                                                                               \
    args->arg_type[0] = STRING_RESULT;                                             \
    return json_out_generic_init(initid, message);                                 \
}                                                                                    \
FRACTAL_EXPORT void                                                                 \
NAME##_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }                \
/* DOC */                                                                            \
FRACTAL_EXPORT char *                                                               \
NAME(UDF_INIT *initid, UDF_ARGS *args, char *result,                               \
    unsigned long *length, char *is_null, char *error)                             \
{                                                                                    \
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;                               \
    char    errbuf[MYSQL_ERRMSG_SIZE];                                             \
    float  *v = NULL;                                                              \
    size_t  dim = 0;                                                               \
    char   *s;                                                                     \
    (void) result;                                                                 \
    if (args->args[0] == NULL) { *is_null = 1; return NULL; }                      \
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return NULL; }     \
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {         \
        *error = 1; return NULL;                                                   \
    }                                                                              \
    s = format_vector_json(jo, v, dim, length);                                    \
    free(v);                                                                       \
    if (s == NULL) { *error = 1; return NULL; }                                    \
    *is_null = 0;                                                                  \
    return s;                                                                      \
}

FRACTAL_VECTOR_CANONICALIZE(fractal_vector_from_float8_array,
    "Validates + canonicalizes a JSON-array-of-numbers as a fractal_vector.")
FRACTAL_VECTOR_CANONICALIZE(fractal_vector_to_float8_array,
    "Same operation as fractal_vector_from_float8_array (see file comment); "
    "kept as a distinct name to document conversion direction at the call site.")

#undef FRACTAL_VECTOR_CANONICALIZE
