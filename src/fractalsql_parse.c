/* src/fractalsql_parse.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Hand-rolled vector/index text parsers, factored out of fractalsql.c so
 * they can be linked and fuzzed standalone (no <mysql.h>, no UDF_INIT/
 * UDF_ARGS, no MariaDB server needed) -- see the tests/fuzz/ drivers.
 *
 * parse_vector_csv is the highest-value fuzz target here: it runs on
 * fractal_embed()'s raw, unvalidated HTTP response body (whatever text
 * the configured embeddings endpoint returned), the one genuinely
 * externally-adversarial input in this codebase, before any allowlist or
 * schema check has a chance to run. parse_corpus and parse_index_csv
 * only ever see SQL-caller-supplied text (fractal_sfs_converge's corpus
 * argument, the Analytics-tier edge/face index arguments) -- a
 * different, lower-privilege threat model, but built in the same style
 * and on top of the same buffer-growth logic, so fuzzed too as
 * defense-in-depth.
 */

#include <errno.h>
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql_interrupt.h"
#include "fractalsql_parse.h"

/* Same cap as MAX_QUERY_DIM in fractalsql.c. Bounds the growth buffer
 * so a large CSV can't amplify into a much larger allocation. */
#define PARSE_MAX_ELEMS ((size_t) 1u * 1024u * 1024u)

/* Overflow guard for the growth buffers below. Their sizes are
 * products of data-controlled operands -- a row count and a
 * dimension, or an element count -- and the callers' own input caps
 * live in a different translation unit (fractalsql.c's MAX_CORPUS_BYTES
 * and MAX_QUERY_DIM), so this file cannot rely on them: these
 * functions are exported public API (fractalsql_parse.h), and a
 * caller that omits its cap -- or a 32-bit build -- would wrap the
 * product and the realloc would hand back a buffer too small for the
 * copy that follows it. Returns false when the product cannot be
 * represented in a size_t. */
static bool
mul_ok(size_t a, size_t b, size_t c)
{
    if (a != 0 && b > SIZE_MAX / a) return false;
    if (c != 0 && a * b > SIZE_MAX / c) return false;
    return true;
}

/* Matches mysql.h's MYSQL_ERRMSG_SIZE (512), a long-stable MySQL/MariaDB
 * client-library ABI constant. Kept as this TU's own copy rather than
 * including <mysql.h> for it, so this file (and the fuzz drivers linking
 * it) never depend on a MariaDB/MySQL dev package being installed. Every
 * caller of these functions already passes an errmsg buffer sized
 * MYSQL_ERRMSG_SIZE (see fractalsql.c/fractalsql_cognition.c), so this
 * must stay in sync with mysql.h's real definition, not be treated as a
 * freely-tunable local knob. */
#define FSQL_PARSE_ERRMSG_SIZE 512

/* Same stderr-mirroring SFS_INIT_ERROR as fractalsql_cognition.c
 * (duplicated per translation unit by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), FSQL_PARSE_ERRMSG_SIZE, __VA_ARGS__);                 \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

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
    double *v;
    if (!mul_ok(count, sizeof(double), 1)) {
        SFS_INIT_ERROR(errmsg, "fractalsql: VECTOR is too large");
        return false;
    }
    v = malloc(count * sizeof(double));
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
        /* Cooperative cancellation boundary: one poll per element, never
         * per byte -- stops only if the host installed a hook and it
         * fired (fractalsql_interrupt.h). */
        if (fractalsql_interrupt_poll()) {
            SFS_INIT_ERROR(errmsg, "fractalsql: interrupted");
            free(buf); free(v); return false;
        }
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

        if (n == PARSE_MAX_ELEMS) {
            SFS_INIT_ERROR(errmsg, "fractalsql: vector exceeds %u elements",
                           (unsigned) PARSE_MAX_ELEMS);
            free(buf); free(v); return false;
        }
        if (n == cap) {
            size_t ncap = cap * 2;
            if (ncap < cap || !mul_ok(ncap, sizeof(double), 1)) {
                SFS_INIT_ERROR(errmsg, "fractalsql: vector is too large");
                free(buf); free(v); return false;
            }
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
        /* Cooperative cancellation boundary: one poll per row separator
         * (at_sep), never per byte. */
        if (at_sep && fractalsql_interrupt_poll()) {
            SFS_INIT_ERROR(errmsg, "fractalsql: interrupted");
            free(store); return false;
        }
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
                if (ncap < cap_rows || !mul_ok(ncap, dim, sizeof(double))) {
                    SFS_INIT_ERROR(errmsg,
                        "fractalsql: corpus is too large to index");
                    free(row); free(store); return false;
                }
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
        /* Same cancellation boundary as parse_vector_csv: one poll per
         * element, never per byte. */
        if (fractalsql_interrupt_poll()) {
            SFS_INIT_ERROR(errmsg, "fractalsql: interrupted");
            free(buf); free(v); return false;
        }
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

        if (n == PARSE_MAX_ELEMS) {
            SFS_INIT_ERROR(errmsg, "fractalsql: too many indices (max %u)", (unsigned) PARSE_MAX_ELEMS);
            free(buf); free(v); return false;
        }
        if (n == cap) {
            size_t ncap = cap * 2;
            /* The element count is bounded by the input's own length
             * (each element needs at least one character), so the
             * buffer cannot be grown without bound -- but the product
             * below is still computed and checked here, because this
             * file's contract is that a caller cannot make the size
             * arithmetic wrap. */
            if (ncap < cap || !mul_ok(ncap, sizeof(size_t), 1)) {
                SFS_INIT_ERROR(errmsg, "fractalsql: index array is too large");
                free(buf); free(v); return false;
            }
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

/* ------------------------------------------------------------------ chunking */

/* the whole JSON result is capped: a 20 KB text with a large overlap would otherwise expand to gigabytes (size x chunks) */
#define FSQL_CHUNK_MAX_OUT ((size_t) 64 * 1024 * 1024)
typedef struct { char *b; size_t n, cap; int oom; int big; } ChunkBuf;

static void cb_put(ChunkBuf *o, const char *s, size_t len)
{
    if (o->oom || o->big) return;
    if (len > FSQL_CHUNK_MAX_OUT || o->n > FSQL_CHUNK_MAX_OUT - len) { o->big = 1; return; }
    if (o->n + len + 1 > o->cap) {
        size_t nc = o->cap ? o->cap : 256;
        char *nb;
        while (nc < o->n + len + 1) nc *= 2;
        nb = (char *) realloc(o->b, nc);
        if (!nb) { o->oom = 1; return; }
        o->b = nb; o->cap = nc;
    }
    memcpy(o->b + o->n, s, len); o->n += len; o->b[o->n] = '\0';
}

typedef struct { size_t *cp; size_t n; const unsigned char *t; size_t blen; } ChunkCps;

static int cps_build(ChunkCps *c, const unsigned char *t, size_t blen)
{
    size_t i = 0;
    c->t = t; c->blen = blen; c->n = 0;
    c->cp = (size_t *) malloc((blen + 1) * sizeof(size_t));
    if (!c->cp) return -1;
    while (i < blen) {
        unsigned char b = t[i];
        size_t len = b < 0x80 ? 1 : (b >= 0xF0 && b <= 0xF4) ? 4 : (b >= 0xE0) ? 3 : (b >= 0xC2) ? 2 : 1, k = 1;
        c->cp[c->n++] = i;
        if (b >= 0xF5) len = 1;
        while (k < len && i + k < blen && (t[i + k] & 0xC0) == 0x80) k++;
        i += (k == len) ? len : 1;       /* a truncated or invalid sequence is one character per byte */
    }
    c->cp[c->n] = blen;
    return 0;
}

static int chunk_is_ws(unsigned char b) { return b == ' ' || b == '\t' || b == '\r' || b == '\n'; }

/* the character at index i as a single byte when it is ASCII, else 0xFF */
static unsigned char cps_ascii(const ChunkCps *c, size_t i)
{
    size_t b = c->cp[i];
    return c->t[b] < 0x80 ? c->t[b] : 0xFF;
}

static void chunk_emit(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b)
{
    char tmp[96];
    int l = snprintf(tmp, sizeof tmp, "%s{\"no\":%lld,\"start\":%lld,\"end\":%lld,\"text\":\"", no ? "," : "", (long long) no, (long long) a, (long long) b);
    cb_put(o, tmp, (size_t) l);
    for (size_t i = c->cp[a]; i < c->cp[b]; i++) {
        unsigned char ch = c->t[i];
        if (ch >= 0x80) {
            /* a byte that does not belong to a well-formed UTF-8 character is written as U+FFFD, so the JSON stays valid UTF-8 */
            size_t need = ch >= 0xF0 ? 4 : ch >= 0xE0 ? 3 : 2, ln = 1;
            while (i + ln < c->cp[b] && (c->t[i + ln] & 0xC0) == 0x80 && ln < need) ln++;
            int okc = 0;
            if (ch >= 0xC2 && ch <= 0xDF) okc = ln == 2;
            else if (ch >= 0xE0 && ch <= 0xEF) okc = ln == 3 && !(ch == 0xE0 && c->t[i + 1] < 0xA0) && !(ch == 0xED && c->t[i + 1] >= 0xA0);
            else if (ch >= 0xF0 && ch <= 0xF4) okc = ln == 4 && !(ch == 0xF0 && c->t[i + 1] < 0x90) && !(ch == 0xF4 && c->t[i + 1] >= 0x90);
            if (!okc) { cb_put(o, "\\ufffd", 6); continue; }
            cb_put(o, (const char *) &c->t[i], ln);
            i += ln - 1;
            continue;
        }
        if (ch == '"') cb_put(o, "\\\"", 2);
        else if (ch == '\\') cb_put(o, "\\\\", 2);
        else if (ch == '\n') cb_put(o, "\\n", 2);
        else if (ch == '\r') cb_put(o, "\\r", 2);
        else if (ch == '\t') cb_put(o, "\\t", 2);
        else if (ch < 0x20) { l = snprintf(tmp, sizeof tmp, "\\u%04x", ch); cb_put(o, tmp, (size_t) l); }
        else cb_put(o, (const char *) &c->t[i], 1);   /* a raw byte: UTF-8 passes through unchanged */
    }
    cb_put(o, "\"}", 2);
}

/* the span [a,b) split into pieces of at most size characters, overlap shared; the new chunk count, or (size_t)-1 over the cap */
static size_t chunk_split(ChunkBuf *o, const ChunkCps *c, size_t no, size_t a, size_t b, size_t size, size_t overlap)
{
    size_t pos = a;
    for (;;) {
        size_t e = pos + size < b ? pos + size : b;
        if (no >= FSQL_CHUNK_MAX_CHUNKS || o->big) return (size_t) -1;
        chunk_emit(o, c, no++, pos, e);
        if (e >= b) break;
        pos = e - overlap;
    }
    return no;
}

int fsql_chunk_text(const unsigned char *t, size_t blen, long size, long overlap, int mode, char **out)
{
    ChunkCps c;
    ChunkBuf o = { NULL, 0, 0, 0, 0 };
    size_t no = 0, S = (size_t) size, V = (size_t) overlap, n;
    int over = 0;
    *out = NULL;
    if (cps_build(&c, t, blen) != 0) return -1;
    n = c.n;
    cb_put(&o, "[", 1);
    if (mode == 0) {
        if (n > 0) { no = chunk_split(&o, &c, 0, 0, n, S, V); over = no == (size_t) -1; }
    } else {
        size_t cur_a = 0, cur_b = 0, i = 0;
        int have = 0;
        while (i < n && !over) {
            size_t ua, ub;
            while (i < n && chunk_is_ws(cps_ascii(&c, i))) i++;
            if (i >= n) break;
            ua = i;
            for (;;) {                       /* extend to the end of the unit */
                unsigned char ch;
                if (i >= n) { ub = n; break; }
                ch = cps_ascii(&c, i);
                if (chunk_is_ws(ch)) {       /* whitespace: a paragraph break, or (sentence mode) just a separator? */
                    size_t j = i; int lf = 0;
                    while (j < n && chunk_is_ws(cps_ascii(&c, j))) { if (cps_ascii(&c, j) == '\n') lf++; j++; }
                    if (lf >= 2) { ub = i; i = j; break; }
                    i = j;
                    continue;
                }
                i++;
                if (mode == 2 && (ch == '.' || ch == '!' || ch == '?')) {
                    while (i < n && (cps_ascii(&c, i) == '.' || cps_ascii(&c, i) == '!' || cps_ascii(&c, i) == '?')) i++;
                    if (i >= n || chunk_is_ws(cps_ascii(&c, i))) { ub = i; break; }
                }
            }
            while (ub > ua && chunk_is_ws(cps_ascii(&c, ub - 1))) ub--;
            if (ub == ua) continue;
            if (ub - ua > S) {               /* longer than a chunk: flush, then split it */
                if (have) { chunk_emit(&o, &c, no++, cur_a, cur_b); have = 0; }
                no = chunk_split(&o, &c, no, ua, ub, S, V);
                if (no == (size_t) -1) over = 1;
            } else if (!have) { cur_a = ua; cur_b = ub; have = 1; }
            else if (ub - cur_a <= S) { cur_b = ub; }
            else { chunk_emit(&o, &c, no++, cur_a, cur_b); cur_a = ua; cur_b = ub; }
            if (!over && (no >= FSQL_CHUNK_MAX_CHUNKS || o.big)) over = 1;
        }
        if (have && !over) chunk_emit(&o, &c, no++, cur_a, cur_b);
    }
    free(c.cp);
    cb_put(&o, "]", 1);
    if (o.oom) { free(o.b); return -1; }
    if (over || o.big) { free(o.b); return 1; }
    *out = o.b;
    return 0;
}
