/* src/fractalsql_vector.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fractal_vector_* - Discovery tier, Vector group.
 *
 * REPRESENTATION:
 *
 *   A fractal_vector is a JSON-array-of-numbers STRING, e.g. "[1,2,3]",
 *   exactly fractalsql.c's existing parse_vector_csv convention
 *   (used for query_csv and corpus rows), which also accepts bare CSV
 *   ("1,2,3"). This is the PORTABLE path: it works on the full
 *   10.6-12.3 compat floor this extension targets, with no server
 *   feature detection needed. Every function below reads/writes this
 *   representation and does the actual math via the vendored
 *   core's fsql_vector_* module (float32, available in every tier, see
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
#include <stdint.h>
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

/* Same stderr-mirroring SFS_INIT_ERROR as fractalsql_cognition.c
 * (duplicated per translation unit by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* Same DoS-guard reasoning as fractalsql.c's MAX_QUERY_BYTES/
 * MAX_QUERY_DIM (a caller-controlled JSON string driving a malloc,
 * uncapped would let a multi-GiB argument OOM-kill the daemon). A
 * fractal_vector is a single embedding, not a corpus, so this is
 * sized like fractalsql.c's per-query caps, not its per-corpus ones. */
#define FSQL_VECTOR_MAX_BYTES ((unsigned long) 4u * 1024u * 1024u) /* 4 MiB */

/* The canonical vector format's header carries the dimension in a
 * u16, so a canonical vector cannot describe more than 65535
 * dimensions; this module caps at 32767, which is also the largest
 * dimension a signed 16-bit field can hold.
 *
 * The TEXT form is capped at the same number: a text vector the
 * canonical form cannot encode is a vector this module cannot
 * round-trip, and two caps that disagree are a trap for the caller
 * (the text form accepts it, the canonical form then refuses to
 * encode it, and the failure surfaces far from the cause). */
#define FSQL_VEC_MAX_DIM 32767u
#define FSQL_VEC_HDRSZ  4u    /* u16 dim LE + u16 reserved */

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
    while (ncap < need)
    {
        /* The doubling has to be able to stop: past SIZE_MAX/2 the next
         * doubling wraps to 0, and "0 < need" is then true for ever --
         * an infinite loop inside a statement, with the connection
         * held. Sizing straight to the requirement is the honest
         * answer: if that cannot be allocated either, the realloc
         * below says so. */
        if (ncap > SIZE_MAX / 2) { ncap = need; break; }
        ncap *= 2;
    }
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
     * 'e' + sign + up to 3-digit exponent + comma ~= 18 bytes; budget
     * 32 so the arithmetic stays right for any future double-range
     * caller, not just the float[] values passed today. The bounded
     * snprintf below is still the real guard. */
    size_t need = dim * 32 + 8;
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

/* The canonical-format helpers live further down this file (the
 * canonical vector format section), but load_vector below has to try
 * the canonical form before the text form, so they are declared
 * here. */
static bool decode_canonical_hex(const char *s, size_t slen,
                                 float **out, size_t *dim_out, char *errbuf);
static bool looks_like_canonical_hex(const char *s, size_t slen);

/* True when the text has the LENGTH a canonical vector must have:
 * 8 hex characters of header plus 8 per dimension, with at least one
 * dimension. A string of that shape that fails to decode is a
 * malformed canonical vector, not a text vector. */
static bool
canonical_hex_shape(size_t slen)
{
    return slen >= 16 && (slen % 8) == 0;
}

/* Parses a vector argument: the CANONICAL form (see the canonical
 * vector format section below) or the JSON/CSV text form, narrowing
 * the result to float32 (fsql_vector_*'s native width, see
 * fractalsql_sql.h's "Vector Arithmetic" comment on why this module
 * is float32-only), and enforcing FSQL_VEC_MAX_DIM. *out is
 * malloc'd; caller frees. */
static bool
load_vector(const char *s, size_t slen, float **out, size_t *dim_out, char *errbuf)
{
    double *dv = NULL;
    size_t  n  = 0;
    float  *fv;

    if (errbuf != NULL) errbuf[0] = '\0';

    /* The canonical form first. It is unambiguous -- a canonical
     * vector's byte length and its declared dimension must agree
     * exactly -- so a text vector that merely looks like hex is never
     * mistaken for one. */
    if (looks_like_canonical_hex(s, slen)) {
        if (decode_canonical_hex(s, slen, out, dim_out, errbuf)) return true;
        /* A string that has the SHAPE of a canonical vector but does
         * not decode is a malformed canonical vector. Falling through
         * to the text parser would reinterpret it instead of
         * rejecting it: a canonical vector whose bytes happen to be
         * decimal digits would come back as a one-element text
         * vector, which is a wrong answer rather than an error. */
        if (canonical_hex_shape(slen)) {
            if (errbuf != NULL && errbuf[0] == '\0')
                SFS_INIT_ERROR(errbuf,
                    "fractal_vector: malformed canonical vector (the header's "
                    "dimension does not agree with the payload length)");
            return false;
        }
    }

    if (!parse_vector_csv(s, slen, &dv, &n, errbuf)) return false;
    if (n > FSQL_VEC_MAX_DIM) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: dimension %zu exceeds maximum %u",
                       n, FSQL_VEC_MAX_DIM);
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

    /* A NaN or an infinity is refused here rather than carried into
     * the results: it poisons every distance computed from the
     * vector, and it has no JSON spelling at all, so a vector
     * carrying one would turn a JSON answer into a document no
     * parser will accept. */
    for (size_t i = 0; i < n; i++) {
        if (!isfinite(fv[i])) {
            SFS_INIT_ERROR(errbuf,
                "fractal_vector: element %zu is not a finite number (NaN or infinity)",
                i);
            free(fv);
            return false;
        }
    }

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
    float  *v = NULL;
    size_t  n = 0;
    (void) initid;

    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_dims: the argument exceeds the 4 MiB limit"); *error = 1; return 0; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &n, errbuf)) {
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
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_norm: the argument exceeds the 4 MiB limit"); *error = 1; return 0.0; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return 0.0;
    }
    rc = fsql_vector_norm(v, dim, &out);
    free(v);
    if (rc != FSQL_OK) { SFS_INIT_ERROR(errbuf, "fractal_vector_norm: the computation failed"); *error = 1; return 0.0; }

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
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_normalize: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    out = malloc(dim * sizeof(float));
    if (out == NULL) { free(v); SFS_INIT_ERROR(errbuf, "fractal_vector_normalize: out of memory"); *error = 1; return NULL; }
    rc = fsql_vector_normalize(v, dim, out);
    free(v);
    if (rc != FSQL_OK) { free(out); SFS_INIT_ERROR(errbuf, "fractal_vector_normalize: the computation failed"); *error = 1; return NULL; }

    s = format_vector_json(jo, out, dim, length);
    free(out);
    if (s == NULL) { SFS_INIT_ERROR(errbuf, "fractal_vector_normalize: out of memory formatting the result"); *error = 1; return NULL; }
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
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_scale: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }
    scalar = *(double *) args->args[1];
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    out = malloc(dim * sizeof(float));
    if (out == NULL) { free(v); SFS_INIT_ERROR(errbuf, "fractal_vector_scale: out of memory"); *error = 1; return NULL; }
    rc = fsql_vector_scale(v, dim, (float) scalar, out);
    free(v);
    if (rc != FSQL_OK) { free(out); SFS_INIT_ERROR(errbuf, "fractal_vector_scale: the computation failed"); *error = 1; return NULL; }

    s = format_vector_json(jo, out, dim, length);
    free(out);
    if (s == NULL) { SFS_INIT_ERROR(errbuf, "fractal_vector_scale: out of memory formatting the result"); *error = 1; return NULL; }
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

/* ==================================================================== */
/* The canonical vector format                                          */
/*                                                                      */
/* The JSON-array-of-numbers convention above is the PORTABLE path: it */
/* works everywhere, but it is a text format -- it costs bytes, it    */
/* rounds, and two callers that mean the same vector can spell it     */
/* differently. The canonical form is a fixed binary layout:          */
/*                                                                      */
/*   uint16 dim         little-endian; 1..32767                       */
/*   uint16 _reserved   always 0 (reserved for a future mode flag)   */
/*   float   x[dim]     contiguous float32 payload, little-endian     */
/*                                                                      */
/* The layout is byte-stable across architectures (every field is    */
/* written little-endian, the float payload included, so the same    */
/* vector encodes to the same bytes on any host).                     */
/*                                                                      */
/* HOW THE BYTES TRAVEL: MariaDB has no dedicated vector type on the */
/* supported server floor, and this repo's daemon protocol carries    */
/* strings, not blobs. The canonical bytes are therefore carried as  */
/* LOWERCASE HEX: byte-stable, charset-safe, storable in a VARCHAR   */
/* or a BLOB column, and convertible back to the binary form with    */
/* UNHEX(). The three functions below are the constructor / parser / */
/* renderer of that form.                                             */
/*                                                                      */
/* Every other fractal_vector_* function in this file accepts the   */
/* canonical form as input as well as the JSON/CSV text, so a        */
/* canonical vector can be stored once and used everywhere without a  */
/* conversion step.                                                  */
/* ==================================================================== */

/* FSQL_VEC_MAX_DIM and FSQL_VEC_HDRSZ are defined at the top of this
 * file: the text loader enforces the same dimension cap the canonical
 * form does, so it needs them before the canonical section. */

static void
le16_put(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t) (v & 0xff);
    p[1] = (uint8_t) ((v >> 8) & 0xff);
}

static uint16_t
le16_get(const uint8_t *p)
{
    return (uint16_t) ((uint16_t) p[0] | ((uint16_t) p[1] << 8));
}

/* True when this host stores scalars little-endian. The canonical
 * encoding is little-endian regardless, so a big-endian host has to
 * swap the float payload on the way in and out. */
static bool
host_is_little_endian(void)
{
    uint16_t probe = 1;
    return *(const uint8_t *) &probe == 1;
}

static void
le_float_put(uint8_t *p, float f)
{
    uint32_t bits;
    memcpy(&bits, &f, sizeof bits);
    if (!host_is_little_endian())
        bits = ((bits & 0x000000ffu) << 24) | ((bits & 0x0000ff00u) << 8) |
               ((bits & 0x00ff0000u) >> 8)  | ((bits & 0xff000000u) >> 24);
    p[0] = (uint8_t) (bits & 0xff);
    p[1] = (uint8_t) ((bits >> 8) & 0xff);
    p[2] = (uint8_t) ((bits >> 16) & 0xff);
    p[3] = (uint8_t) ((bits >> 24) & 0xff);
}

static float
le_float_get(const uint8_t *p)
{
    uint32_t bits = (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
                    ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
    float f;
    if (!host_is_little_endian())
        bits = ((bits & 0x000000ffu) << 24) | ((bits & 0x0000ff00u) << 8) |
               ((bits & 0x00ff0000u) >> 8)  | ((bits & 0xff000000u) >> 24);
    memcpy(&f, &bits, sizeof f);
    return f;
}

static int
hex_nibble(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Encodes a float vector into the canonical bytes, then into their
 * lowercase-hex rendering, into jo->buf. Returns the buffer and sets
 * *out_len on success, NULL on OOM. */
static char *
format_canonical_hex(json_out_ctx *jo, const float *v, size_t dim,
                     unsigned long *out_len)
{
    static const char hexd[] = "0123456789abcdef";
    size_t   nbytes = FSQL_VEC_HDRSZ + dim * 4;
    size_t   need   = nbytes * 2 + 1;
    uint8_t  hdr[FSQL_VEC_HDRSZ];
    size_t   pos = 0;
    size_t   i;

    if (dim < 1 || dim > FSQL_VEC_MAX_DIM) return NULL;
    if (!json_out_ensure(jo, need)) return NULL;

    le16_put(hdr, (uint16_t) dim);
    le16_put(hdr + 2, 0);

    for (i = 0; i < FSQL_VEC_HDRSZ; i++) {
        jo->buf[pos++] = hexd[(hdr[i] >> 4) & 0xf];
        jo->buf[pos++] = hexd[hdr[i] & 0xf];
    }
    for (i = 0; i < dim; i++) {
        uint8_t fb[4];
        le_float_put(fb, v[i]);
        jo->buf[pos++] = hexd[(fb[0] >> 4) & 0xf];
        jo->buf[pos++] = hexd[fb[0] & 0xf];
        jo->buf[pos++] = hexd[(fb[1] >> 4) & 0xf];
        jo->buf[pos++] = hexd[fb[1] & 0xf];
        jo->buf[pos++] = hexd[(fb[2] >> 4) & 0xf];
        jo->buf[pos++] = hexd[fb[2] & 0xf];
        jo->buf[pos++] = hexd[(fb[3] >> 4) & 0xf];
        jo->buf[pos++] = hexd[fb[3] & 0xf];
    }
    jo->buf[pos] = '\0';

    *out_len = (unsigned long) pos;
    return jo->buf;
}

/* Decodes a canonical hex string into a malloc'd float32 vector.
 * Returns true on success (*out is malloc'd, caller frees; *dim_out
 * holds the dimension), false when the text is not a well-formed
 * canonical vector. The checks are strict on purpose: a text that
 * merely LOOKS like hex ("12345678") must not be mistaken for a
 * canonical vector, so the decoded length has to agree exactly with
 * the dimension the header declares. */
static bool
decode_canonical_hex(const char *s, size_t slen, float **out, size_t *dim_out,
                     char *errbuf)
{
    uint8_t *bytes;
    size_t   nbytes, dim, i;

    if (slen == 0 || (slen % 2) != 0) return false;
    nbytes = slen / 2;
    if (nbytes < FSQL_VEC_HDRSZ) return false;

    bytes = malloc(nbytes);
    if (bytes == NULL) return false;
    for (i = 0; i < nbytes; i++) {
        int hi = hex_nibble((unsigned char) s[2 * i]);
        int lo = hex_nibble((unsigned char) s[2 * i + 1]);
        if (hi < 0 || lo < 0) { free(bytes); return false; }
        bytes[i] = (uint8_t) ((hi << 4) | lo);
    }

    dim = le16_get(bytes);
    if (dim < 1 || dim > FSQL_VEC_MAX_DIM ||
        le16_get(bytes + 2) != 0 ||
        nbytes != FSQL_VEC_HDRSZ + dim * 4) {
        free(bytes);
        return false;
    }

    {
        float *fv = malloc(dim * sizeof(float));
        if (fv == NULL) { free(bytes); return false; }
        for (i = 0; i < dim; i++) {
            fv[i] = le_float_get(bytes + FSQL_VEC_HDRSZ + i * 4);
            /* A non-finite element is refused here, with the element's
             * own index, rather than carried into the results: it
             * poisons every distance computed from the vector and has
             * no JSON spelling at all. */
            if (!isfinite(fv[i])) {
                SFS_INIT_ERROR(errbuf,
                    "fractal_vector: canonical vector element %zu is not a "
                    "finite number (NaN or infinity)", i);
                free(fv);
                free(bytes);
                return false;
            }
        }
        free(bytes);
        *out     = fv;
        *dim_out = dim;
    }
    return true;
}

/* True when the text could be a canonical vector: every character is
 * a hex digit and the length is one a canonical vector can have. The
 * length check alone rules out most decimal text; the full decode
 * (which checks the header against the length) is what actually
 * decides. */
static bool
looks_like_canonical_hex(const char *s, size_t slen)
{
    size_t i;
    if (slen < (FSQL_VEC_HDRSZ * 2) || (slen % 2) != 0) return false;
    for (i = 0; i < slen; i++)
        if (hex_nibble((unsigned char) s[i]) < 0) return false;
    return true;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector(dim) -> STRING (canonical hex)            */
/*                                                                    */
/* The zero vector of the given dimension, in the canonical form.     */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector(dim): expected 1 argument, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector(UDF_INIT *initid, UDF_ARGS *args, char *result,
               unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float   *v = NULL;
    size_t   dim;
    long long dim_arg;
    char    *s;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }

    dim_arg = *(long long *) args->args[0];
    if (dim_arg < 1 || dim_arg > (long long) FSQL_VEC_MAX_DIM) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: dimension %lld is out of range 1..%u",
                       dim_arg, FSQL_VEC_MAX_DIM);
        *error = 1; return NULL;
    }
    dim = (size_t) dim_arg;

    v = calloc(dim, sizeof(float));
    if (v == NULL) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: out of memory");
        *error = 1; return NULL;
    }

    s = format_canonical_hex(jo, v, dim, length);
    free(v);
    if (s == NULL) { SFS_INIT_ERROR(errbuf, "fractal_vector: out of memory formatting the result"); *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_from_text(text) -> STRING (canonical hex) */
/*                                                                    */
/* Accepts the canonical hex form OR the JSON/CSV text form and      */
/* returns the canonical hex form.                                    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_from_text_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_from_text(text): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_from_text_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_from_text(UDF_INIT *initid, UDF_ARGS *args, char *result,
                         unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL;
    size_t  dim = 0;
    char   *s;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_from_text: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }

    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    s = format_canonical_hex(jo, v, dim, length);
    free(v);
    if (s == NULL) { SFS_INIT_ERROR(errbuf, "fractal_vector_from_text: out of memory formatting the result"); *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_to_json(v) -> STRING (JSON array)         */
/*                                                                    */
/* Renders a vector -- canonical hex OR the JSON/CSV text form -- as  */
/* a JSON array of numbers.                                            */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_to_json_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_to_json(vec): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_to_json_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_to_json(UDF_INIT *initid, UDF_ARGS *args, char *result,
                       unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL;
    size_t  dim = 0;
    char   *s;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_to_json: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }

    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    s = format_vector_json(jo, v, dim, length);
    free(v);
    if (s == NULL) { SFS_INIT_ERROR(errbuf, "fractal_vector_to_json: out of memory formatting the result"); *error = 1; return NULL; }
    *is_null = 0;
    return s;
}

/* ==================================================================== */
/* v2.0.25 additions: Lp distance, int8/binary quantization, Hamming    */
/* distance. Same conventions as the rest of this file -- ships         */
/* unconditionally, no gating.                                          */
/* ==================================================================== */
/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_lp_distance(a, b, p)                     */
/*                                                                    */
/* (sum(|a[i]-b[i]|^p))^(1/p), p > 0. Real caveat, not a stability     */
/* one: for 0 < p < 1 this does not satisfy the triangle inequality   */
/* (a mathematical property of Lp spaces themselves, true of ANY      */
/* correct implementation, not something this codebase gets wrong).   */
/* Ships as an explicit, separately-named function -- never a silent  */
/* default in place of fractal_vector_l2_distance/cosine_distance.    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_lp_distance_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_vector_lp_distance(a, b, p): expected 3 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = REAL_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_vector_lp_distance_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT double
fractal_vector_lp_distance(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char   errbuf[MYSQL_ERRMSG_SIZE];
    float *a = NULL, *b = NULL;
    size_t dim = 0;
    double p;
    float  out;
    int    rc;
    (void) initid;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return 0.0;
    }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES ||
        args->lengths[1] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0.0; }

    p = *(double *) args->args[2];
    /* p must be a finite number above zero. A NaN p is not caught by
     * the "p <= 0" test (NaN compares false against everything), and
     * it would otherwise turn every term of the sum into a NaN. */
    if (!isfinite(p) || p <= 0.0) {
        SFS_INIT_ERROR(errbuf,
            "fractal_vector_lp_distance: p must be a finite number greater than 0");
        *error = 1; return 0.0;
    }

    if (!load_pair(args, &a, &b, &dim, errbuf)) { *error = 1; return 0.0; }
    rc = fsql_vector_lp_distance(a, b, dim, (float) p, &out);
    free(a); free(b);
    if (rc != FSQL_OK) {
        SFS_INIT_ERROR(errbuf, "fractal_vector_lp_distance: computation failed");
        *error = 1; return 0.0;
    }

    *is_null = 0;
    return (double) out;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_quantize_int8(vec)                       */
/*                                                                    */
/* Per-vector symmetric int8 quantization (4x compression). Returns   */
/* {"scale":<f>,"values":[i1,i2,...]}; dequantize via                 */
/* v[i] ~= values[i] * scale.                                         */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_quantize_int8_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_quantize_int8(vec): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_quantize_int8_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_quantize_int8(UDF_INIT *initid, UDF_ARGS *args, char *result,
                             unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char    errbuf[MYSQL_ERRMSG_SIZE];
    float  *v = NULL;
    int8_t *out = NULL;
    float   scale;
    size_t  dim = 0, pos;
    int     rc;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_int8: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    out = malloc(dim > 0 ? dim : 1);
    if (out == NULL) { free(v); SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_int8: out of memory"); *error = 1; return NULL; }

    rc = fsql_vector_quantize_int8(v, dim, out, &scale);
    free(v);
    if (rc != FSQL_OK) { free(out); SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_int8: the computation failed"); *error = 1; return NULL; }

    if (!json_out_ensure(jo, dim * 8 + 32)) { free(out); *error = 1; return NULL; }
    {
        int hlen = snprintf(jo->buf, jo->cap, "{\"scale\":%.10g,\"values\":[", (double) scale);
        if (hlen < 0 || (size_t) hlen >= jo->cap) {
            free(out);
            SFS_INIT_ERROR(errbuf, "fractal_vector: out of memory formatting the quantized vector");
            *error = 1; return NULL;
        }
        pos = (size_t) hlen;
    }
    for (size_t i = 0; i < dim; i++) {
        int flen = snprintf(jo->buf + pos, jo->cap - pos, "%s%d",
                            i > 0 ? "," : "", (int) out[i]);
        if (flen < 0 || (size_t) flen >= jo->cap - pos) {
            free(out);
            SFS_INIT_ERROR(errbuf, "fractal_vector: out of memory formatting the quantized vector");
            *error = 1; return NULL;
        }
        pos += (size_t) flen;
    }
    free(out);
    if (!json_out_ensure(jo, pos + 4)) { *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "]}");

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_quantize_binary(vec)                     */
/*                                                                    */
/* Binary (1-bit) quantization (32x compression), MSB-first. A bit is */
/* set when v[i] is NOT negative -- so 0.0 sets its bit, and -0.0    */
/* does too (the test is v[i] >= 0, and -0.0 compares equal to 0).   */
/* Returns a JSON array of the (dim+7)/8 output bytes, e.g. "[145,3]" */
/* -- pairs with fractal_vector_hamming_distance for cheap candidate */
/* filtering.                                                         */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_quantize_binary_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_vector_quantize_binary(vec): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_vector_quantize_binary_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_vector_quantize_binary(UDF_INIT *initid, UDF_ARGS *args, char *result,
                               unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    float   *v = NULL;
    uint8_t *out = NULL;
    size_t   dim = 0, n_bytes, pos;
    int      rc;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES) { SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_binary: the argument exceeds the 4 MiB limit"); *error = 1; return NULL; }
    if (!load_vector(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    n_bytes = (dim + 7) / 8;
    out = malloc(n_bytes > 0 ? n_bytes : 1);
    if (out == NULL) { free(v); SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_binary: out of memory"); *error = 1; return NULL; }

    rc = fsql_vector_quantize_binary(v, dim, out);
    free(v);
    if (rc != FSQL_OK) { free(out); SFS_INIT_ERROR(errbuf, "fractal_vector_quantize_binary: the computation failed"); *error = 1; return NULL; }

    if (!json_out_ensure(jo, n_bytes * 4 + 4)) { free(out); *error = 1; return NULL; }
    jo->buf[0] = '['; pos = 1;
    for (size_t i = 0; i < n_bytes; i++) {
        int flen = snprintf(jo->buf + pos, jo->cap - pos, "%s%u",
                            i > 0 ? "," : "", (unsigned) out[i]);
        if (flen < 0 || (size_t) flen >= jo->cap - pos) { free(out); *error = 1; return NULL; }
        pos += (size_t) flen;
    }
    free(out);
    jo->buf[pos++] = ']';
    jo->buf[pos]   = '\0';

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* Parses a JSON/CSV array of small non-negative integers (0-255) into
 * a caller-owned uint8_t buffer -- local to this TU, mirroring
 * fractalsql.c's own parse_byte_array (this repo's established
 * per-TU-duplication convention for small shared helpers). */
static bool
parse_byte_array(const char *s, size_t slen, uint8_t **out, size_t *n_out, char *errbuf)
{
    double  *dv = NULL;
    size_t   n = 0;
    uint8_t *bv;

    if (!parse_vector_csv(s, slen, &dv, &n, errbuf)) return false;
    bv = malloc(n > 0 ? n : 1);
    if (bv == NULL) {
        SFS_INIT_ERROR(errbuf, "fractal_vector: oom");
        free(dv);
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        if (dv[i] < 0.0 || dv[i] > 255.0 || dv[i] != (double) (int) dv[i]) {
            SFS_INIT_ERROR(errbuf, "fractal_vector: byte array element %zu out of range [0,255]", i);
            free(dv); free(bv);
            return false;
        }
        bv[i] = (uint8_t) dv[i];
    }
    free(dv);
    *out   = bv;
    *n_out = n;
    return true;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_vector_hamming_distance(a_bytes_json, b_bytes_json) */
/*                                                                    */
/* Hamming distance between two binary-quantized vectors, as packed   */
/* by fractal_vector_quantize_binary (JSON array of bytes). Requires  */
/* equal byte length.                                                 */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_vector_hamming_distance_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_vector_hamming_distance(a_bytes, b_bytes): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    initid->maybe_null = 1;
    return false;
}

FRACTAL_EXPORT void
fractal_vector_hamming_distance_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_vector_hamming_distance(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    char     errbuf[MYSQL_ERRMSG_SIZE];
    uint8_t *a = NULL, *b = NULL;
    size_t   na = 0, nb = 0, out;
    int      rc;
    (void) initid;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return 0; }
    if (args->lengths[0] > FSQL_VECTOR_MAX_BYTES ||
        args->lengths[1] > FSQL_VECTOR_MAX_BYTES) { *error = 1; return 0; }

    if (!parse_byte_array(args->args[0], args->lengths[0], &a, &na, errbuf)) {
        *error = 1; return 0;
    }
    if (!parse_byte_array(args->args[1], args->lengths[1], &b, &nb, errbuf)) {
        free(a); *error = 1; return 0;
    }
    if (na != nb) { free(a); free(b); *error = 1; return 0; }

    rc = fsql_vector_hamming_distance(a, b, na, &out);
    free(a); free(b);
    if (rc != FSQL_OK) { SFS_INIT_ERROR(errbuf, "fractal_vector_hamming_distance: the computation failed"); *error = 1; return 0; }

    *is_null = 0;
    return (long long) out;
}
