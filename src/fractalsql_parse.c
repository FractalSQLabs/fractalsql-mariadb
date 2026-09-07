/* src/fractalsql_parse.c
 * Hand-rolled vector/index text parsers, factored out of fractalsql.c so
 * they can be linked and fuzzed standalone (no <mysql.h>, no UDF_INIT/
 * UDF_ARGS, no MariaDB server needed) -- see tests/fuzz/ drivers and
 * build_test.sh --fuzz.
 *
 * parse_vector_csv is the highest-value fuzz target here: it runs on
 * fractal_embed()'s raw, unvalidated HTTP response body (whatever text
 * the configured embeddings endpoint returned), the one genuinely
 * externally-adversarial input in this codebase, before any allowlist or
 * schema check has a chance to run. parse_corpus and parse_index_csv
 * only ever see SQL-caller-supplied text (fractal_search's corpus
 * argument, the Analytics-tier edge/face index arguments) -- a
 * different, lower-privilege threat model, but built in the same style
 * and on top of the same buffer-growth logic, so fuzzed too as
 * defense-in-depth.
 */

#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql_parse.h"

/* Matches mysql.h's MYSQL_ERRMSG_SIZE (512), a long-stable MySQL/MariaDB
 * client-library ABI constant. Kept as this TU's own copy rather than
 * including <mysql.h> for it, so this file (and the fuzz drivers linking
 * it) never depend on a MariaDB/MySQL dev package being installed. Every
 * caller of these functions already passes an errmsg buffer sized
 * MYSQL_ERRMSG_SIZE (see fractalsql.c/fractalsql_cognition.c), so this
 * must stay in sync with mysql.h's real definition, not be treated as a
 * freely-tunable local knob. */
#define FSQL_PARSE_ERRMSG_SIZE 512

#define SFS_INIT_ERROR(msg, ...) \
    (snprintf((msg), FSQL_PARSE_ERRMSG_SIZE, __VA_ARGS__))

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
        /* strtod parses "inf"/"nan" without setting ERANGE. Reject them:
         * they would flow through the vector math and out the other side
         * as "[inf,nan]" -- neither JSON nor valid VEC_FROMTEXT input. */
        if (!isfinite(d)) {
            SFS_INIT_ERROR(errmsg, "fractalsql: non-finite vector element");
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

bool
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
bool
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
