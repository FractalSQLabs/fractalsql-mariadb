/* src/fractalsql.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fractalsql-mariadb v2.0.12: Stochastic Fractal Search for MariaDB (UDF).
 *
 * Compatible with MariaDB 10.6, 10.11, 11.4 LTS, and 12.3 LTS.
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
 *   Statically links include/libfractalsql-community-sovereign-c.a (the
 *   vendored core artifact). No LuaJIT runtime dependency.
 */

#include <mysql.h>

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql.h"
#include "fractalsql_interrupt.h"
#include "fractalsql_sql.h"     /* sovereign-tier additions (v2 Analytics/Portfolio) */
#include "fractalsql_session.h" /* connection-scoped ctx registry for Discovery/Diversify */
#include "fractalsql_parse.h"   /* parse_vector_csv prototype (shared with fractalsql_vector.c) */
#include "fractalsql_enterprise.h" /* fractal_enterprise_lib_loaded/fractal_ledger_write_kind2/_sha256 */

/* A SQL integer argument narrowed to int for a range check. Clamped, not
 * cast: a value past int range must stay out of range for the check that
 * follows, not wrap into it (4294967297 became 1 and passed). */
static int
clamp_to_int(long long v)
{
    return v > INT_MAX ? INT_MAX : (v < INT_MIN ? INT_MIN : (int) v);
}

/* Work bounds, the same as the core's. A single call cannot be interrupted,
 * and each cost is a product no individual limit controls:
 *   search:      iterations x population_size x diffusion_factor x dim (about
 *                30 ns a unit, so 2^31 is roughly a minute);
 *   subset:      items x k (about 3 us a unit, 2^24 is roughly a minute);
 *   periodogram: series length, an FFT (2^20 is a few seconds). */
#define SEARCH_MAX_WORK         (2147483648ULL)
#define SUBSET_MAX_WORK         (16777216ULL)
#define PERIODOGRAM_MAX_SAMPLES ((size_t) 1048576)

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

/* Single source of truth for the shipped version. fractal_version()
 * below returns this, and scripts/package.sh derives the .deb/.rpm
 * VERSION from this same #define via sed. Keeping both readers on one
 * #define avoids the UDF's self-reported version and the package
 * metadata's version silently drifting apart. */
#define FSQL_VERSION "2.0.12"

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
 * multi-GiB allocation and OOM-kill the daemon. The per-row vector
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
    /* Copy-out buffer for session-registry searches (see sfs_copy_result
     * below). NULL/0 until a session-backed call first needs it, then
     * grown to fit and reused across rows for this UDF instance. */
    char  *result_buf;
    size_t result_cap;
} sfs_ctx;

/* Copy a search result into the per-initid buffer. Needed for the
 * session-registry path: there, result_json is owned by the registry's
 * long-lived ctx rather than this UDF instance's per-call ctx, and that
 * ctx can be freed (fractal_session_registry_close, idle/LRU eviction)
 * or have its result buffer overwritten (any later search through the
 * same session_id) independently of this initid. MariaDB's UDF protocol
 * requires the returned pointer to stay valid until the NEXT call on
 * the SAME initid, and the only buffer whose lifetime is guaranteed to
 * match that is this UDF instance's own. Returns NULL (with *error set)
 * on OOM; the buffer content is still undefined until the caller
 * returns it to MariaDB. */
static char *
sfs_copy_result(sfs_ctx *c, const char *json, size_t len, char *error)
{
    char *nb = (char *) realloc(c->result_buf, len + 1);
    if (nb == NULL) { *error = 1; return NULL; }
    c->result_buf = nb;
    c->result_cap = len + 1;
    if (len > 0) memcpy(nb, json, len);
    nb[len] = '\0';
    return nb;
}

/* Same stderr-mirroring SFS_INIT_ERROR as fractalsql_cognition.c
 * (duplicated per translation unit by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* ------------------------------------------------------------------ */
/* Argument parsing                                                   */
/* ------------------------------------------------------------------ */

/* parse_vector_csv / parse_corpus / parse_index_csv moved to
 * fractalsql_parse.c (declared in fractalsql_parse.h, included above):
 * a standalone TU with no <mysql.h> dependency, so tests/fuzz's
 * libFuzzer drivers can link them without a MariaDB dev package. */

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

/* The worst-case size of a stack buffer that holds one JSON number
 * formatted as "%.10f", plus the separator that precedes it in an
 * array. A double's %.10f form is never exponential: the largest
 * finite double (1.7976931348623157e308) prints as 309 integer digits,
 * a '.', and 10 fractional digits -- 320 characters -- and a negative
 * value adds a sign. One more byte covers the ',' that separates two
 * entries.
 *
 * WHY A NAMED CONSTANT AND NOT A HAND-PICKED NUMBER: every emitter
 * here treats a truncated snprintf as a hard UDF error (the check is
 * "did it fit?"), so a buffer sized for "a typical number" (40 bytes,
 * say) turns a large-but-legal value into a failed call instead of
 * returning that value. The 356 the file's "provably safe regardless
 * of magnitude" comments have always claimed is 1 (separator) + 321
 * (sign + 309 digits + '.' + 10 digits), with room to spare. */
#define FSQL_FIELD_MAX 356

/* The output-count cap for a caller-supplied "how many results do you
 * want" argument, and the size of the buffer that goes with it.
 *
 * WHY THIS EXISTS: the count arrives straight from SQL as a 64-bit
 * integer, and the count was multiplied by the element size to size
 * the buffer the core writes into -- with no upper bound on the
 * count. `max_points = 2^61` made `(size_t)max_points * sizeof(size_t)`
 * wrap to 0, so malloc() returned a zero-length block (which is not
 * NULL, so the OOM check passed) and the core then wrote real output
 * into it: a heap overflow inside mariadbd, reachable by any account
 * with EXECUTE on the UDF.
 *
 * The fix has two halves, and both are needed:
 *   - the allocation and the cap handed to the core are the SAME
 *     number, so the core can never be asked for more elements than
 *     the buffer holds (the core's own contract is that it writes at
 *     most the cap it was given);
 *   - the cap is clamped to `hard_max`, the most results the core
 *     could possibly produce from this input, so the clamp does not
 *     change any result. The multiplication is checked regardless.
 *
 * Returns the element count to use, or 0 when there is nothing to
 * allocate (a count of 0, or a size that would overflow). */
static size_t
fsq_out_cap(long long requested, size_t hard_max, size_t elem_size, size_t *bytes_out)
{
    size_t cap;

    if (requested <= 0 || hard_max == 0) return 0;
    cap = ((unsigned long long) requested < (unsigned long long) hard_max)
              ? (size_t) requested
              : hard_max;
    if (cap == 0) return 0;
    if (cap > SIZE_MAX / elem_size) return 0;
    if (bytes_out) *bytes_out = cap * elem_size;
    return cap;
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

/* Finds `key` in the params object and returns the position of its
 * VALUE.
 *
 * THE SCAN IS STRING-AWARE, and it has to be: the old scan looked for
 * the first '"key":' ANYWHERE in the buffer, so a params object whose
 * VALUE mentioned the key -- {"note":"\"iterations\":99","iterations":3}
 * -- resolved to the text inside the string, and a key nested in a
 * sub-object was found before the top-level one. This scan walks the
 * document's string tokens properly (a backslash-escaped quote does
 * not end the token), tells a key from a value by what follows it (a
 * key is followed by ':'), and only considers a key at the object's own
 * depth -- a key inside a nested object is not this object's key. */
static bool
json_find_key(const char *s, size_t slen, const char *key, size_t *out_pos)
{
    size_t klen = strlen(key);
    size_t i = 0;
    int    depth = 0;   /* brace/bracket nesting outside strings */

    while (i < slen)
    {
        if (s[i] == '"')
        {
            /* A string token: find its end, honouring backslash
             * escapes (an escaped quote does not close it). */
            size_t start = i + 1;
            size_t j = start;
            while (j < slen) {
                if (s[j] == '\\') { j += 2; continue; }
                if (s[j] == '"') break;
                j++;
            }
            if (j >= slen) return false;   /* unterminated string */

            /* A key is followed by ':' (after whitespace). */
            size_t k = j + 1;
            while (k < slen && (s[k] == ' ' || s[k] == '\t' ||
                                s[k] == '\n' || s[k] == '\r')) k++;
            if (k < slen && s[k] == ':' && depth <= 1)
            {
                if (j - start == klen && strncmp(s + start, key, klen) == 0) {
                    k++;
                    while (k < slen && (s[k] == ' ' || s[k] == '\t' ||
                                        s[k] == '\n' || s[k] == '\r')) k++;
                    *out_pos = k;
                    return true;
                }
                /* A different key at this depth: continue after its
                 * colon. Its value is skipped by the same rules (a
                 * string token is skipped whole; a number or a
                 * literal is skipped by the character scan). */
                i = k + 1;
                continue;
            }
            /* A string VALUE: skip it whole. */
            i = j + 1;
            continue;
        }
        if (s[i] == '{' || s[i] == '[') { depth++; i++; continue; }
        if (s[i] == '}' || s[i] == ']') { depth--; i++; continue; }
        i++;
    }
    return false;
}

/* The end of the number token at `pos`, or `pos` when there is no
 * well-formed number there. A JSON number is
 *   -? ( 0 | [1-9][0-9]* ) ( . [0-9]+ )? ( [eE] [+-]? [0-9]+ )?
 * The leading '+' is not JSON, but a caller who writes one plainly
 * means a positive number, so it is accepted. Anything the scanner
 * cannot make sense of simply ends the token where it stopped making
 * sense -- the caller's delimiter check then rejects the value. */
static size_t
json_number_end(const char *s, size_t slen, size_t pos)
{
    size_t j = pos;
    if (j < slen && (s[j] == '-' || s[j] == '+')) j++;
    size_t int_digits = j;
    while (j < slen && isdigit((unsigned char) s[j])) j++;
    if (j == int_digits) return pos;          /* no integer part */
    size_t int_end = j;
    if (j < slen && s[j] == '.') {
        j++;
        size_t frac = j;
        while (j < slen && isdigit((unsigned char) s[j])) j++;
        if (j == frac) return int_end;        /* a trailing '.' */
    }
    if (j < slen && (s[j] == 'e' || s[j] == 'E')) {
        size_t k = j + 1;
        if (k < slen && (s[k] == '-' || s[k] == '+')) k++;
        size_t exp = k;
        while (k < slen && isdigit((unsigned char) s[k])) k++;
        if (k > exp) j = k;                    /* a valid exponent */
    }
    return j;
}

/* True when the character at `pos` can follow a JSON value: the end of
 * the buffer, whitespace, or one of the structural characters. A value
 * that runs straight into a letter ("30x") is not a number, and the
 * old readers accepted it as one. */
static bool
json_value_delim(const char *s, size_t slen, size_t pos)
{
    if (pos >= slen) return true;
    char c = s[pos];
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
           c == ',' || c == '}' || c == ']';
}

static int
json_get_int(const char *s, size_t slen, const char *key, int fallback)
{
    size_t pos;
    if (!json_find_key(s, slen, key, &pos)) return fallback;

    size_t end = json_number_end(s, slen, pos);
    if (end == pos) return fallback;                 /* not a number */
    if (!json_value_delim(s, slen, end)) return fallback;   /* "30x" */

    char buf[32];
    size_t n = end - pos;
    if (n >= sizeof buf) return fallback;            /* absurdly long */
    memcpy(buf, s + pos, n);
    buf[n] = '\0';

    /* A value that does not fit an int is not a value this knob can
     * use: the fallback (the default) is the safe answer, and it keeps
     * the old atoi()'s undefined behaviour on overflow out of the
     * path entirely.
     *
     * The bounds are spelled INT_MAX/INT_MIN rather than as the
     * literals 2147483647L / -2147483648L: 2147483648 does not fit in
     * a 32-bit long, so on a compiler that types an out-of-range
     * decimal constant with an L suffix as unsigned long (MSVC), the
     * negated literal is 2147483648UL and the comparison below runs in
     * unsigned arithmetic -- where every non-negative value is
     * "less than" it, and every parsed number was thrown away in favour
     * of the default. */
    errno = 0;
    long v = strtol(buf, NULL, 10);
    if (errno == ERANGE || v > (long) INT_MAX || v < (long) INT_MIN)
        return fallback;
    return (int) v;
}

/* Unsigned 64-bit variant, for session_id (the caller's own
 * CONNECTION_ID() by convention: see fractal_search's "session_id"
 * params key and fractal_diversify_*'s explicit session_id argument).
 * No sign handling, since a session key is never negative, and no
 * fraction or exponent either: a session key is a plain integer. */
static unsigned long long
json_get_u64(const char *s, size_t slen, const char *key, unsigned long long fallback)
{
    size_t pos;
    if (!json_find_key(s, slen, key, &pos)) return fallback;

    size_t j = pos;
    while (j < slen && isdigit((unsigned char) s[j])) j++;
    if (j == pos) return fallback;                   /* not a number */
    if (!json_value_delim(s, slen, j)) return fallback;

    char buf[32];
    size_t n = j - pos;
    if (n >= sizeof buf) return fallback;
    memcpy(buf, s + pos, n);
    buf[n] = '\0';

    errno = 0;
    unsigned long long v = strtoull(buf, NULL, 10);
    if (errno == ERANGE) return fallback;
    return v;
}

static double
json_get_double(const char *s, size_t slen, const char *key, double fallback)
{
    size_t pos;
    if (!json_find_key(s, slen, key, &pos)) return fallback;

    size_t end = json_number_end(s, slen, pos);
    if (end == pos) return fallback;
    if (!json_value_delim(s, slen, end)) return fallback;

    char buf[64];
    size_t n = end - pos;
    if (n >= sizeof buf) return fallback;
    memcpy(buf, s + pos, n);
    buf[n] = '\0';

    errno = 0;
    double v = strtod(buf, NULL);
    if (errno == ERANGE) return fallback;
    /* An overflow (1e999) parses to an infinity, and a value that is
     * not a number at all parses to a NaN: neither is a number the
     * caller can have meant, and both would sail through the range
     * checks the callers apply ("is it positive?"). The default
     * stands instead. */
    if (!isfinite(v)) return fallback;
    return v;
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

/* True when the params object carries the key at all. Used for the
 * core's "seed", where "absent" and "present but zero" mean different
 * things: an absent seed leaves the core's own non-deterministic
 * default in place, while a present one (even 0) is a value the core
 * is told about explicitly. */
static bool
json_has_key(const char *s, size_t slen, const char *key)
{
    size_t pos;
    return json_find_key(s, slen, key, &pos);
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

    /* The type of k as the caller wrote it, taken before it is forced to
     * INT_RESULT below: forcing the type does not convert a constant's
     * value, so a constant k written as a string ('5') or a decimal is
     * still that many bytes of text here, not an 8-byte integer. */
    const int k_is_int = (args->arg_type[2] == INT_RESULT);

    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = STRING_RESULT;

    /* Only an integer constant can be checked here; any other k is
     * coerced after init and checked again in fractal_search itself. */
    if (k_is_int && args->args[2] != NULL) {
        long long kv = *(long long *) args->args[2];
        if (kv < 1 || kv > 1000000) {
            SFS_INIT_ERROR(message, "fractal_search: k must be 1..1000000");
            return true;
        }
    }

    /* No fsql_init() call: that symbol wires up the SQL/DB layer, which
     * the SFS search surface never needs -- its ctx comes from
     * fsql_new_minimal() below. Keeping the call out leaves the
     * executable's symbol needs to what this surface actually
     * references, so an eager-binding libc (musl) never trips over an
     * entry point the search path doesn't use. */
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
    free(c->result_buf);
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

    /* Re-validate k here, not just in _init: args->args[2] is NULL at
     * init time for any non-constant argument (column, expression), so
     * the init-time 1..1000000 check never saw per-row values. */
    long long kv = *(long long *) args->args[2];
    if (kv < 1 || kv > 1000000) {
        free(query); free(corpus); *error = 1; return NULL;
    }
    k = (int) kv;
    if (n_corpus > 0 && (size_t) k > n_corpus) k = (int) n_corpus;

    /* Translate UDF param spelling → core's params_json keys. The core's
     * own spelling is used verbatim: "iterations", "population_size",
     * "diffusion_factor", "walk", "debug" (and "seed"). An unrecognised
     * key is silently ignored by the core, so a translated name would
     * tune nothing at all. */
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
        bool busy = false;
        fsql_ctx *sc = fractal_session_acquire_exclusive(session_id, &busy);
        if (sc != NULL) { search_ctx = sc; use_session = true; }
        else if (busy) {
            /* Another connection is mid-search on this same (shared)
             * session_id. Fail the row rather than race the core or
             * silently drop the session's Diversify state. */
            free(query); free(corpus);
            *error = 1; return NULL;
        }
        /* else: registry at capacity or OOM -- fall back silently to
         * the ordinary per-call ctx, per the convention above. */
    }

    /* Bounds so an adversarial params JSON can't drive a vastly
     * oversized SFS allocation. The population bound is the CORE's
     * own (2..10000): a larger one is rejected by the core with a
     * generic "params out of range", so the same value is refused
     * here, with a reason, instead of travelling that far to fail. */
    if (iterations < 1 || iterations > 10000   ||
        pop_size   < 2 || pop_size   > 10000   ||
        diff_factor < 1 || diff_factor > 32) {
        free(query); free(corpus);
        if (use_session) fractal_session_release_exclusive(session_id);
        SFS_INIT_ERROR(errbuf,
            "fractal_search: params out of range (iterations %d..10000, "
            "population_size %d..10000, diffusion_factor %d..32)",
            iterations, pop_size, diff_factor);
        *error = 1; return NULL;
    }
    /* Each factor is in range, but the cost is their product. */
    if ((unsigned long long) iterations * (unsigned long long) pop_size *
        (unsigned long long) diff_factor * (unsigned long long) dim > SEARCH_MAX_WORK) {
        free(query); free(corpus);
        if (use_session) fractal_session_release_exclusive(session_id);
        SFS_INIT_ERROR(errbuf,
            "fractal_search: search too large (iterations x population_size x "
            "diffusion_factor x dim exceeds %llu)", SEARCH_MAX_WORK);
        *error = 1; return NULL;
    }

    char core_params[320];
    /* The core's "seed" is its only determinism control: a non-zero
     * seed makes the walk byte-stable across calls (see the vendored
     * header). An absent seed leaves the core's own non-deterministic
     * default in place, so the key is forwarded only when the caller
     * supplied one. */
    bool has_seed = json_has_key(params_s, params_len, "seed");
    unsigned long long seed = json_get_u64(params_s, params_len, "seed", 0);
    snprintf(core_params, sizeof core_params,
        "{\"iterations\":%d,\"population_size\":%d,"
        "\"diffusion_factor\":%d,\"walk\":%.6g,"
        "\"debug\":%s%s%llu}",
        iterations, pop_size, diff_factor, walk,
        debug_mode ? "true" : "false",
        has_seed ? ",\"seed\":" : "", has_seed ? seed : 0ULL);

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

    if (rc != 0) {
        /* Release, not close: the ctx stays alive in the registry, only
         * its refcount drops. Never freed while another caller holds a
         * reference. */
        if (use_session) fractal_session_release_exclusive(session_id);
        *error = 1; return NULL;
    }

    if (use_session) {
        /* Copy out while the entry is still pinned: result_json is
         * owned by the registry's long-lived ctx, whose lifetime
         * (registry_close, idle/LRU eviction, a later search
         * overwriting its result buffer through the same session_id)
         * is independent of this initid. The per-initid copy satisfies
         * MariaDB's "valid until the next call on the same initid"
         * contract exactly; only after the copy is the pin released. */
        char *out = sfs_copy_result(c, result_json, result_len, error);
        fractal_session_release_exclusive(session_id);
        if (out == NULL) return NULL;
        *length  = (unsigned long) result_len;
        *is_null = 0;
        return out;
    }

    /* Non-session path: fsql_search_ptr's result_json is owned by the
     * per-call ctx c->ctx and stays valid until the next fsql_search*
     * on that ctx. The MariaDB UDF protocol requires the returned
     * pointer to stay valid until the next call on the same initid,
     * matching that lifetime exactly, so we return the pointer
     * directly. */
    *length  = (unsigned long) result_len;
    *is_null = 0;
    return (char *) result_json;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_search_debug                                     */
/*   fractal_search_debug(query_csv [, iterations [, population_size  */
/*                              [, diffusion_factor [, seed]]]])        */
/*     -> JSON STRING                                                  */
/*                                                                    */
/* The convergence view of the Stochastic Fractal Search: no corpus, */
/* no top-k -- just the walk's own trace on one query point, so an   */
/* operator can see where the search landed and how well it fit.     */
/*                                                                    */
/* The core's "no_corpus" mode is what makes this a pure convergence */
/* run: the search has no stored vectors to match against, so it    */
/* optimises the single query point and reports best_point/best_fit  */
/* plus the debug trace. Without it the call would degenerate into  */
/* the ordinary one-row-corpus search (a trivial top_k of the query */
/* itself) and carry no trace at all.                                */
/*                                                                    */
/* "seed" is optional: left out, the core's own non-deterministic    */
/* default applies (two calls may differ). Pin it for a             */
/* byte-stable, reproducible trace.                                  */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_search_debug_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    unsigned int i;
    if (args->arg_count < 1 || args->arg_count > 5) {
        SFS_INIT_ERROR(message,
            "fractal_search_debug(query_csv [, iterations [, population_size "
            "[, diffusion_factor [, seed]]]]): expected 1 to 5 arguments, got %u",
            args->arg_count);
        return true;
    }

    args->arg_type[0] = STRING_RESULT;
    for (i = 1; i < args->arg_count; i++) args->arg_type[i] = INT_RESULT;

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
fractal_search_debug_deinit(UDF_INIT *initid)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    if (c == NULL) return;
    if (c->ctx) fsql_free(c->ctx);
    free(c->result_buf);
    free(c);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_search_debug(UDF_INIT *initid, UDF_ARGS *args, char *result,
                     unsigned long *length, char *is_null, char *error)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];

    double *query = NULL;
    size_t  dim = 0;
    int     iterations = 60;
    int     pop_size = 50;
    int     diff_factor = 2;
    bool    has_seed = false;
    unsigned long long seed = 0;

    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_QUERY_BYTES) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0],
                          &query, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    if (dim == 0 || dim > MAX_QUERY_DIM) {
        free(query); *error = 1; return NULL;
    }

    /* Optional trailing tuning arguments. A SQL NULL in one of them
     * falls back to the default rather than failing the call, so a
     * caller can pass a nullable column through. */
    if (args->arg_count > 1 && args->args[1] != NULL)
        iterations = clamp_to_int(*(long long *) args->args[1]);
    if (args->arg_count > 2 && args->args[2] != NULL)
        pop_size = clamp_to_int(*(long long *) args->args[2]);
    if (args->arg_count > 3 && args->args[3] != NULL)
        diff_factor = clamp_to_int(*(long long *) args->args[3]);
    if (args->arg_count > 4 && args->args[4] != NULL) {
        /* Clamp instead of casting: the core's seed is a uint64_t, so a
         * plain cast of a negative argument turned -1 into
         * 18446744073709551615 -- a value the caller never asked for,
         * and a different one on every call that used a different
         * negative. A negative seed is not a seed the core documents,
         * so it falls back to the default instead. */
        long long s = *(long long *) args->args[4];
        seed = (s < 0) ? 0ULL : (unsigned long long) s;
        has_seed = true;
    }

    /* Same bounds fractal_search applies, so an adversarial argument
     * cannot drive a vastly oversized SFS allocation. The population
     * bound is the CORE's own (2..10000): a larger one is rejected by
     * the core with a generic "params out of range", so the same value
     * is refused here, with a reason, instead of travelling that far to
     * fail. */
    if (iterations < 1 || iterations > 10000   ||
        pop_size   < 2 || pop_size   > 10000   ||
        diff_factor < 1 || diff_factor > 32) {
        free(query);
        SFS_INIT_ERROR(errbuf,
            "fractal_search_debug: params out of range (iterations %d..10000, "
            "population_size %d..10000, diffusion_factor %d..32)",
            iterations, pop_size, diff_factor);
        *error = 1; return NULL;
    }
    /* Each factor is in range, but the cost is their product. */
    if ((unsigned long long) iterations * (unsigned long long) pop_size *
        (unsigned long long) diff_factor * (unsigned long long) dim > SEARCH_MAX_WORK) {
        free(query);
        SFS_INIT_ERROR(errbuf,
            "fractal_search_debug: search too large (iterations x population_size x "
            "diffusion_factor x dim exceeds %llu)", SEARCH_MAX_WORK);
        *error = 1; return NULL;
    }

    char core_params[320];
    snprintf(core_params, sizeof core_params,
        "{\"iterations\":%d,\"population_size\":%d,"
        "\"diffusion_factor\":%d,\"walk\":0.5,"
        "\"no_corpus\":true,\"debug\":true%s%llu}",
        iterations, pop_size, diff_factor,
        has_seed ? ",\"seed\":" : "", has_seed ? seed : 0ULL);

    const char *result_json = NULL;
    size_t      result_len  = 0;
    /* n_rows = 0 with "no_corpus": the core has no corpus to match
     * against, and optimises the query point on its own. */
    int rc = fsql_search_ptr(c->ctx,
                             query, 0, dim,
                             query, dim,
                             /*k*/ 1,
                             core_params, strlen(core_params),
                             &result_json, &result_len);

    free(query);

    if (rc != 0) { *error = 1; return NULL; }

    /* result_json is owned by this initid's own ctx and stays valid
     * until the next fsql_search* on that ctx, which is exactly the
     * UDF protocol's "valid until the next call on the same initid"
     * lifetime. */
    *length  = (unsigned long) result_len;
    *is_null = 0;
    return (char *) result_json;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_search_explore (Scout Mode)                            */
/*                                                                    */
/* Sniper (fractal_search) returns best_point + the top-k nearest     */
/* stored vectors. Scout disperses the SFS population across distinct */
/* basins (walk=0 + min-distance-to-corpus fitness) and returns the   */
/* full result JSON including the additive "population" array, one    */
/* inner array per particle. Discover the diverse regions of a corpus */
/* in a single call; JSON_EXTRACT(..., '$.population') to consume.    */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_search_explore_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_search_explore(corpus_csv, query_csv, params): "
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
fractal_search_explore_deinit(UDF_INIT *initid)
{
    sfs_ctx *c = (sfs_ctx *) initid->ptr;
    if (c == NULL) return;
    if (c->ctx) fsql_free(c->ctx);
    free(c->result_buf);
    free(c);
    initid->ptr = NULL;
}

FRACTAL_EXPORT char *
fractal_search_explore(UDF_INIT *initid, UDF_ARGS *args, char *result,
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
        bool busy = false;
        fsql_ctx *sc = fractal_session_acquire_exclusive(session_id, &busy);
        if (sc != NULL) { search_ctx = sc; use_session = true; }
        else if (busy) {
            /* Another connection is mid-search on this same (shared)
             * session_id. Fail the row rather than race the core or
             * silently drop the session's Diversify state. */
            free(query); free(corpus);
            *error = 1; return NULL;
        }
        /* else: registry at capacity or OOM -- fall back silently to
         * the ordinary per-call ctx, per the convention above. */
    }

    /* Same bounds fractal_search applies, and the same CORE population
     * cap (2..10000): a larger one is rejected by the core with a
     * generic "params out of range", so the same value is refused here,
     * with a reason, instead of travelling that far to fail. */
    if (iterations < 1 || iterations > 10000   ||
        pop_size   < 2 || pop_size   > 10000   ||
        diff_factor < 1 || diff_factor > 32) {
        free(query); free(corpus);
        if (use_session) fractal_session_release_exclusive(session_id);
        SFS_INIT_ERROR(errbuf,
            "fractal_search_explore: params out of range (iterations %d..10000, "
            "population_size %d..10000, diffusion_factor %d..32)",
            iterations, pop_size, diff_factor);
        *error = 1; return NULL;
    }

    char core_params[320];
    /* "seed" is forwarded for the same reason as in fractal_search: an
     * absent seed leaves the core's own non-deterministic default in
     * place, and a pinned seed makes the scout population byte-stable
     * across calls. */
    bool has_seed = json_has_key(params_s, params_len, "seed");
    unsigned long long seed = json_get_u64(params_s, params_len, "seed", 0);
    snprintf(core_params, sizeof core_params,
        "{\"iterations\":%d,\"population_size\":%d,"
        "\"diffusion_factor\":%d,\"walk\":%.6g,"
        "\"return_population\":true%s%llu}",
        iterations, pop_size, diff_factor, walk,
        has_seed ? ",\"seed\":" : "", has_seed ? seed : 0ULL);

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

    if (rc != 0) {
        if (use_session) fractal_session_release_exclusive(session_id);
        *error = 1; return NULL;
    }

    if (use_session) {
        /* Copy out while the entry is still pinned: same lifetime
         * reasoning as fractal_search's session path: the registry's
         * long-lived ctx (and the result buffer it owns) can be freed
         * or overwritten independently of this initid, so return this
         * UDF instance's own copy. */
        char *out = sfs_copy_result(c, result_json, result_len, error);
        fractal_session_release_exclusive(session_id);
        if (out == NULL) return NULL;
        *length  = (unsigned long) result_len;
        *is_null = 0;
        return out;
    }

    /* Non-session path: result_json (incl. "population") is owned by
     * the per-call ctx c->ctx and stays valid until the next
     * fsql_search* on that ctx, matching the UDF protocol's
     * "valid until the next call on the same initid" lifetime exactly. */
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
/* gap lives in the vendored core itself, upstream of this extension. */
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
    if (rc != FSQL_OK) { *error = 1; return 0.0; }  /* need >= 8 finite pts, non-degenerate bbox, points x dim <= 2^22 */

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
                                size_t n_assets, size_t k, unsigned long long seed,
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

    /* The record's head: everything up to (and including) the opening
     * bracket of the weights array. 1024 bytes covers it with room to
     * spare -- the widest field is the Sharpe ratio's "%.10f" (321
     * characters at the extreme), and the rest is a decimal integer, a
     * size, a size and the 64-character hash. */
    char head[1024];
    int  hn = snprintf(head, sizeof head,
        "{\"type\":\"portfolio_optimize\",\"entry\":{"
        "\"seed\":%llu,\"n_assets\":%zu,\"k\":%zu,\"sharpe\":%.10f,"
        "\"inputs_hash\":\"%s\",\"weights\":[",
        seed, n_assets, k, sharpe, hash_hex);
    if (hn < 0 || (size_t) hn >= sizeof head) return;

    /* The exact record length, computed rather than ESTIMATED. The old
     * budget was 24 bytes per asset plus a fixed 256 -- but one legal
     * weight is a "%.10f" of up to 321 characters, and the Sharpe
     * ratio is one too, so the snprintf truncated and the whole audit
     * record was SILENTLY DROPPED for any portfolio whose weights or
     * Sharpe ratio were above roughly 1e10: the decision's provenance
     * went missing exactly when the numbers got interesting. Every
     * weight is now formatted into a worst-case-sized buffer first, so
     * its length is known before anything is allocated, and the record
     * is assembled into a buffer that provably fits. */
    size_t cap = (size_t) hn + 5;   /* head + "]}}" + the NUL */
    for (size_t i = 0; i < n_assets; i++)
    {
        char w[FSQL_FIELD_MAX];
        int  wn = snprintf(w, sizeof w, "%s%.10f", i > 0 ? "," : "", weights[i]);
        if (wn < 0 || (size_t) wn >= sizeof w) return;
        if (cap > SIZE_MAX - (size_t) wn) return;
        cap += (size_t) wn;
    }

    char *js = (char *) malloc(cap);
    if (js == NULL) return;

    memcpy(js, head, (size_t) hn);
    size_t pos = (size_t) hn;
    for (size_t i = 0; i < n_assets; i++)
    {
        char w[FSQL_FIELD_MAX];
        int  wn = snprintf(w, sizeof w, "%s%.10f", i > 0 ? "," : "", weights[i]);
        if (wn < 0 || (size_t) wn >= sizeof w) { free(js); return; }
        memcpy(js + pos, w, (size_t) wn);
        pos += (size_t) wn;
    }
    memcpy(js + pos, "]}}", 4);   /* includes the NUL */
    pos += 3;

    (void) fractal_ledger_write_kind2(js, pos);
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
    unsigned long long seed;
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

    /* The seed is read as UNSIGNED, like every other params-JSON seed in
     * this file (fractal_search, fractal_search_explore). The core's
     * seed is a uint64_t, and json_get_int accepts a leading '-', so a
     * signed read turned {"seed":-1} into 18446744073709551615 -- a
     * silently widened value the caller never asked for. json_get_u64
     * rejects the sign outright and falls back to the documented
     * default (0), which is what an absent or unusable seed means. */
    seed    = json_get_u64(params_s, params_len, "seed", 0);
    use_obl = json_get_bool(params_s, params_len, "use_obl", false);
    if (json_get_str(params_s, params_len, "diffusion_mode", mode_buf, sizeof mode_buf) &&
        !parse_diffusion_mode(mode_buf, &diffusion_mode, errbuf)) {
        free(mu); free(cov); *error = 1; return NULL;
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
    /* The head's own room: "{\"sharpe\":" + a "%.10f" of up to 321
     * characters + ",\"weights\":[". A fixed 64 bytes would not be enough for
     * a Sharpe ratio above roughly 1e240, and a truncated snprintf is a hard
     * error here, so the head is sized for the worst case. */
    if (!json_out_ensure(jo, FSQL_FIELD_MAX + 64)) { free(weights); *error = 1; return NULL; }
    /* Truncation check, same contract as every other emitter here: a
     * truncated snprintf's return value is the length it WANTED, not the
     * length it wrote -- using it as a write offset without this check
     * leaves the tail of the buffer never-written and ships uninitialized
     * heap bytes to the client. */
    {
        int hlen = snprintf(jo->buf, jo->cap,
                            "{\"sharpe\":%.10f,\"weights\":[", sharpe);
        if (hlen < 0 || (size_t) hlen >= jo->cap) {
            free(weights); *error = 1; return NULL;
        }
        pos = (size_t) hlen;
    }
    for (i = 0; i < n_assets; i++) {
        char field[FSQL_FIELD_MAX];
        if (fractalsql_interrupt_poll()) {  /* cancel boundary, per asset */
            SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
            free(weights); *error = 1; return NULL;
        }
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
    if (args->lengths[0] > MAX_CORPUS_BYTES || args->lengths[1] > MAX_CORPUS_BYTES ||
        args->lengths[2] > MAX_CORPUS_BYTES) {
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

    /* Bounds-check every node index here, before the core sees them:
     * an out-of-range index would otherwise be an out-of-bounds read
     * inside the core's node_coords array rather than a clean failure. */
    {
        size_t n_nodes = nc_n / 3, j;
        for (j = 0; j < e_n; j++) {
            if (fractalsql_interrupt_poll()) {  /* cancel boundary, per edge */
                SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
                free(node_coords); free(edges); free(arc_length);
                *error = 1; return NULL;
            }
            if (edges[j] >= n_nodes) {
                free(node_coords); free(edges); free(arc_length);
                *error = 1; return NULL;
            }
        }
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
    if (args->lengths[0] > MAX_CORPUS_BYTES || args->lengths[1] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &vertices, &v_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (!parse_index_csv(args->args[1], args->lengths[1], &faces, &f_n, errbuf)) {
        free(vertices); *error = 1; return NULL;
    }
    if (v_n % 3 != 0 || f_n % 3 != 0) {
        free(vertices); free(faces); *error = 1; return NULL;
    }

    /* Bounds-check every vertex index here, before the core sees them:
     * an out-of-range index would otherwise be an out-of-bounds read
     * inside the core's vertex array rather than a clean failure. */
    {
        size_t n_vertices = v_n / 3, j;
        for (j = 0; j < f_n; j++) {
            if (fractalsql_interrupt_poll()) {  /* cancel boundary, per face */
                SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
                free(vertices); free(faces); *error = 1; return NULL;
            }
            if (faces[j] >= n_vertices) {
                free(vertices); free(faces); *error = 1; return NULL;
            }
        }
    }

    rc = fsql_cortical_folding(vertices, v_n / 3, faces, f_n / 3,
                               &mesh_area, &hull_area, &gi);
    free(vertices); free(faces);
    if (rc != FSQL_OK) { *error = 1; return NULL; }  /* need >= 4 finite, non-coplanar vertices, at most 2^22 */

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
    if (args->lengths[0] > MAX_CORPUS_BYTES || args->lengths[2] > MAX_CORPUS_BYTES) {
        *error = 1; return NULL;
    }

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

    /* Bounds-check every node index here, before the core sees them:
     * an out-of-range index would otherwise be an out-of-bounds read
     * inside the core's node_coords array rather than a clean failure. */
    {
        size_t n_nodes = nc_n / (size_t) dim, j;
        for (j = 0; j < e_n; j++) {
            if (fractalsql_interrupt_poll()) {  /* cancel boundary, per edge */
                SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
                free(node_coords); free(edges); *error = 1; return NULL;
            }
            if (edges[j] >= n_nodes) {
                free(node_coords); free(edges); *error = 1; return NULL;
            }
        }
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
    if (rc != FSQL_OK) { *error = 1; return NULL; }  /* need >= 8 finite pts, non-degenerate bbox, points x dim <= 2^22 */

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
/* UDF triad: fractal_edition                                      */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_edition_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message, "fractal_edition(): expected 0 arguments");
        return true;
    }
    initid->maybe_null = 0;
    initid->max_length = 32;
    return false;
}

FRACTAL_EXPORT void
fractal_edition_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT char *
fractal_edition(UDF_INIT *initid, UDF_ARGS *args, char *result,
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
/* UDF triad: fractal_version                                      */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_version_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message, "fractal_version(): expected 0 arguments");
        return true;
    }
    initid->maybe_null = 0;
    initid->max_length = 32;
    return false;
}

FRACTAL_EXPORT void
fractal_version_deinit(UDF_INIT *initid)
{
    (void) initid;
}

FRACTAL_EXPORT char *
fractal_version(UDF_INIT *initid, UDF_ARGS *args, char *result,
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
/* Every UDF body runs inside the fractalsqld daemon, one shared       */
/* multithreaded process serving every connection's forwarded calls,   */
/* so fsql_diversify_*'s own g_ctx, a plain file-static, cannot be     */
/* used directly here: it would leak one session's Diversify tuning    */
/* (and its rolling D_q / overhead stats) into every other concurrent  */
/* session's queries. Every function below therefore takes an explicit */
/* session_id BIGINT as its first argument and operates through the    */
/* connection-scoped registry in fractalsql_session.c instead. Pass    */
/* CONNECTION_ID() by convention (sql/install_udf.sql documents        */
/* this). fractal_search /                                             */
/* fractal_search_explore pick up the same session's ctx via an optional      */
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
    if (rc == FSQL_OK) fractal_session_set_diversify_enabled(sid, true);
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
    if (rc == FSQL_OK) fractal_session_set_diversify_enabled(sid, false);
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
    /* Negative values are ignored (the current default stands) rather
     * than widened: a plain cast of -1 to uint32_t reaches the core as
     * 4294967295. */
    if (json_find_key(params_s, params_len, "window_n", &pos)) {
        int v = json_get_int(params_s, params_len, "window_n", (int) p.window_n);
        if (v >= 0) p.window_n = (uint32_t) v;
    }
    if (json_find_key(params_s, params_len, "stall_threshold", &pos))
        p.stall_threshold = json_get_double(params_s, params_len, "stall_threshold", p.stall_threshold);
    if (json_find_key(params_s, params_len, "repulsion_sigma", &pos))
        p.repulsion_sigma = json_get_double(params_s, params_len, "repulsion_sigma", p.repulsion_sigma);
    if (json_find_key(params_s, params_len, "repulsion_weight", &pos))
        p.repulsion_weight = json_get_double(params_s, params_len, "repulsion_weight", p.repulsion_weight);
    if (json_find_key(params_s, params_len, "max_shadows_considered", &pos)) {
        int v = json_get_int(params_s, params_len,
                             "max_shadows_considered", (int) p.max_shadows_considered);
        if (v >= 0) p.max_shadows_considered = (uint32_t) v;
    }
    if (json_find_key(params_s, params_len, "tail_buffer_cap", &pos)) {
        int v = json_get_int(params_s, params_len,
                             "tail_buffer_cap", (int) p.tail_buffer_cap);
        if (v >= 0) p.tail_buffer_cap = (uint32_t) v;
    }

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

    /* The monitor's state comes from the session registry, not from
     * fsql_diversify_get_params: the core's get_params returns the
     * tunables whether or not the monitor is running, so deriving
     * "enabled" from it reported true for a session that never called
     * fractal_diversify_enable -- the field was never able to say
     * "off". The registry knows, because it is where the enable and
     * disable calls land. */
    bool   enabled  = fractal_session_get_diversify_enabled(sid);
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
    /* NULLABLE: the body answers NULL when the session_id argument is
     * NULL, so telling the server "this is never NULL" makes its
     * nullability model for the expression wrong (a NOT NULL
     * comparison on the result is then unsound). Every other UDF in
     * this file that can answer NULL says so here. */
    initid->maybe_null = 1;
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

/* fractal_agent_partial_fail: per-session opt-in for the
 * partial-result mode (sql/install_udf.sql documents the
 * call). mode is 'on'/'off', case-insensitive; the UDF returns the
 * applied state. Off (the documented default) leaves every agent
 * procedure's behavior bit-for-bit unchanged, so the flag is strictly
 * additive: nothing reads it except fractal_reason's endpoint-failure
 * paths (src/fractalsql_cognition.c) and the agents' own sentinel
 * handling (sql/install_agents.sql). Session-scoped through the same
 * registry the Diversify triad above uses, for the same reason. */
FRACTAL_EXPORT bool
fractal_agent_partial_fail_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_agent_partial_fail(session_id, mode): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    args->arg_type[1] = STRING_RESULT;
    /* args->args[1] holds the literal mode value here (NULL for a
     * non-constant expression, which the body's silent NULL covers) --
     * the one chance the UDF ABI offers to reject a bad mode with
     * real error text instead of *error = 1's silent NULL. */
    if (args->args[1] != NULL && !(
            (args->lengths[1] == 2 && strncasecmp(args->args[1], "on", 2) == 0) ||
            (args->lengths[1] == 3 && strncasecmp(args->args[1], "off", 3) == 0))) {
        SFS_INIT_ERROR(message,
            "fractal_agent_partial_fail(session_id, mode): mode must be 'on' or 'off'");
        return true;
    }
    /* NULLABLE: the body answers NULL when either argument is NULL
     * (the init-time check above deliberately lets a NULL mode
     * through, because the mode may be a non-constant expression), so
     * the server must be told the result can be NULL. */
    initid->maybe_null = 1;
    initid->max_length = 4; /* 'off\0' at most */
    return false;
}

FRACTAL_EXPORT void
fractal_agent_partial_fail_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT char *
fractal_agent_partial_fail(UDF_INIT *initid, UDF_ARGS *args, char *result,
                           unsigned long *length, char *is_null, char *error)
{
    (void) initid; (void) error;
    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    char errbuf[MYSQL_ERRMSG_SIZE];
    unsigned long long sid = (unsigned long long) *(long long *) args->args[0];
    bool on;
    if (args->lengths[1] == 2 && strncasecmp(args->args[1], "on", 2) == 0) {
        on = true;
    } else if (args->lengths[1] == 3 && strncasecmp(args->args[1], "off", 3) == 0) {
        on = false;
    } else {
        SFS_INIT_ERROR(errbuf,
            "fractal_agent_partial_fail(session_id, mode): mode must be 'on' or 'off'");
        *error = 1; return NULL;
    }
    fractal_session_set_agent_partial(sid, on);
    *is_null = 0;
    /* The result buffer is initid->max_length bytes (4: 'off' plus the
     * NUL). MariaDB's UDF ABI does not require a terminator, but every
     * other string-returning UDF in this repo hands back a C string,
     * and a caller that reads the buffer as one would otherwise run
     * past the 'off' into whatever the buffer held before. The write
     * fits exactly: 3 characters plus the NUL in a 4-byte buffer. */
    const char *state = on ? "on" : "off";
    size_t n = strlen(state);
    if (n + 1 > 4) { *error = 1; return NULL; }   /* unreachable */
    memcpy(result, state, n);
    result[n] = '\0';
    *length = (unsigned long) n;
    return result;
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
    /* Clamp instead of casting: a plain (uint32_t) of -1 reaches the
     * core as 4294967295. */
    if (dwell_ms < 0) dwell_ms = 0;

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

/* ==================================================================== */
/* v2.0.25 Analytics additions -- change-point detection, periodogram,  */
/* subset optimizer, state fingerprinting, cycle detection, TDA         */
/* persistence diagrams. Same conventions as the Analytics/Portfolio    */
/* UDFs above: series/point-cloud args are CSV/JSON-array STRINGs       */
/* (parse_vector_csv), multi-value results are a JSON-valid STRING      */
/* (json_out_ctx), optional tuning knobs ride in a trailing params      */
/* JSON blob (json_get_*), matching fractal_optimize_portfolio's        */
/* precedent exactly. No experimental gating on any of these --         */
/* shipped as regular first-class functions like everything above,      */
/* real caveats (noted per-function below where one exists) documented  */
/* in comments, not hidden behind a flag.                               */
/* ==================================================================== */

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_change_point_detect                             */
/*                                                                    */
/* Sliding two-sample test over adjacent windows of `window` samples; */
/* flags a boundary where the mean differs by more than `threshold`   */
/* pooled-stddev units or the variance ratio exceeds threshold^2.     */
/* Returns a JSON array of ascending 0-indexed boundary positions,    */
/* e.g. "[12,47]". Requires n >= 2*window, window >= 1, threshold > 0,*/
/* max_points >= 1.                                                   */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_change_point_detect_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_change_point_detect(series_csv, window, threshold, max_points): "
            "expected 4 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = REAL_RESULT;
    args->arg_type[3] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_change_point_detect_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_change_point_detect(UDF_INIT *initid, UDF_ARGS *args, char *result,
                            unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    double  *series = NULL;
    size_t  *idx = NULL;
    size_t   n = 0, n_found = 0, pos;
    size_t   idx_cap = 0, idx_bytes = 0;
    long long window, max_points;
    double   threshold;
    int      rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL ||
        args->args[2] == NULL || args->args[3] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    window     = *(long long *) args->args[1];
    threshold  = *(double *) args->args[2];
    max_points = *(long long *) args->args[3];
    if (window <= 0 || threshold <= 0.0 || max_points <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &series, &n, errbuf)) {
        *error = 1; return NULL;
    }
    /* The core writes at most one boundary index per sample, so n is
     * the most it can produce; the cap and the allocation agree from
     * here on. */
    idx_cap = fsq_out_cap(max_points, n, sizeof(size_t), &idx_bytes);
    if (idx_cap == 0) { free(series); *error = 1; return NULL; }
    idx = malloc(idx_bytes);
    if (idx == NULL) { free(series); *error = 1; return NULL; }

    rc = fsql_change_point_detect(series, n, (size_t) window, threshold,
                                  idx, idx_cap, &n_found);
    free(series);
    if (rc != FSQL_OK) { free(idx); *error = 1; return NULL; }  /* n >= 2*window required */

    if (!json_out_ensure(jo, 8)) { free(idx); *error = 1; return NULL; }
    jo->buf[0] = '['; pos = 1;
    for (size_t i = 0; i < n_found; i++) {
        char field[40];
        if (fractalsql_interrupt_poll()) {  /* cancel boundary, per point */
            SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
            free(idx); *error = 1; return NULL;
        }
        int  flen = snprintf(field, sizeof field, "%s%zu", i > 0 ? "," : "", idx[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) { free(idx); *error = 1; return NULL; }
        if (!json_out_ensure(jo, pos + (size_t) flen + 4)) { free(idx); *error = 1; return NULL; }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    free(idx);
    jo->buf[pos++] = ']';
    jo->buf[pos]   = '\0';

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_periodogram                                     */
/*                                                                    */
/* Classical periodogram (direct O(n^2) DFT -- exact values, no FFT   */
/* dependency), returning only the max_peaks highest-power bins,      */
/* sorted descending. Returns {"freqs":[...],"power":[...]}. Requires */
/* n >= 4, max_peaks >= 1.                                            */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_periodogram_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_periodogram(series_csv, max_peaks): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_periodogram_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_periodogram(UDF_INIT *initid, UDF_ARGS *args, char *result,
                    unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    double  *series = NULL;
    double  *freqs = NULL, *power = NULL;
    size_t   n = 0, n_peaks = 0, pos;
    size_t   peaks_cap = 0, peaks_bytes = 0;
    long long max_peaks;
    int      rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    max_peaks = *(long long *) args->args[1];
    if (max_peaks <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &series, &n, errbuf)) {
        *error = 1; return NULL;
    }
    if (n > PERIODOGRAM_MAX_SAMPLES) { free(series); *error = 1; return NULL; }
    /* The core's own bound: *out_n_peaks = min(max_peaks, floor(n/2)),
     * so clamping the cap to n/2 changes no result. The allocation and
     * the cap the core is given are the same number. */
    peaks_cap = fsq_out_cap(max_peaks, n / 2, sizeof(double), &peaks_bytes);
    if (peaks_cap == 0) { free(series); *error = 1; return NULL; }
    freqs = malloc(peaks_bytes);
    power = malloc(peaks_bytes);
    if (freqs == NULL || power == NULL) {
        free(series); free(freqs); free(power); *error = 1; return NULL;
    }

    rc = fsql_periodogram(series, n, freqs, power, peaks_cap, &n_peaks);
    free(series);
    if (rc != FSQL_OK) { free(freqs); free(power); *error = 1; return NULL; }  /* n >= 4 */

    if (!json_out_ensure(jo, 16)) { free(freqs); free(power); *error = 1; return NULL; }
    pos = (size_t) snprintf(jo->buf, jo->cap, "{\"freqs\":[");
    for (size_t i = 0; i < n_peaks; i++) {
        char field[FSQL_FIELD_MAX];
        if (fractalsql_interrupt_poll()) {  /* cancel boundary, per bin */
            SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
            free(freqs); free(power); *error = 1; return NULL;
        }
        int  flen = snprintf(field, sizeof field, "%s%.10f", i > 0 ? "," : "", freqs[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) {
            free(freqs); free(power); *error = 1; return NULL;
        }
        if (!json_out_ensure(jo, pos + (size_t) flen + 32)) {
            free(freqs); free(power); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    if (!json_out_ensure(jo, pos + 16)) { free(freqs); free(power); *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "],\"power\":[");
    for (size_t i = 0; i < n_peaks; i++) {
        char field[FSQL_FIELD_MAX];
        if (fractalsql_interrupt_poll()) {  /* cancel boundary, per bin */
            SFS_INIT_ERROR(errbuf, "fractalsql: interrupted");
            free(freqs); free(power); *error = 1; return NULL;
        }
        int  flen = snprintf(field, sizeof field, "%s%.10f", i > 0 ? "," : "", power[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) {
            free(freqs); free(power); *error = 1; return NULL;
        }
        if (!json_out_ensure(jo, pos + (size_t) flen + 8)) {
            free(freqs); free(power); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    free(freqs); free(power);
    if (!json_out_ensure(jo, pos + 4)) { *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "]}");

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_spectrogram_entropy                             */
/*                                                                    */
/* fractal_spectrogram_entropy(series_csv [, window [, hop            */
/* [, max_frames]]]) -> bare JSON array of per-frame normalized       */
/* spectral entropy in [0,1] (mean removed, Hann tapered, direct DFT).*/
/* Defaults: window 64, hop 32, max_frames 4096. A bare array, not an */
/* object, so it can be fed to fractal_change_point_detect as-is.     */
/* Requires window in [8,512], hop >= 1, max_frames in [1,4096],      */
/* n >= window. A constant frame reports 0.0, never NaN.              */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_spectrogram_entropy_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    unsigned int i;
    if (args->arg_count < 1 || args->arg_count > 4) {
        SFS_INIT_ERROR(message,
            "fractal_spectrogram_entropy(series_csv [, window [, hop "
            "[, max_frames]]]): expected 1 to 4 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    for (i = 1; i < args->arg_count; i++) args->arg_type[i] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_spectrogram_entropy_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_spectrogram_entropy(UDF_INIT *initid, UDF_ARGS *args, char *result,
                            unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char      errbuf[MYSQL_ERRMSG_SIZE];
    double   *series = NULL, *entropy = NULL;
    size_t    n = 0, n_frames = 0, avail, pos, frames_cap = 0, frames_bytes = 0;
    long long window = 64, hop = 32, max_frames = 4096;
    int       rc;
    (void) result;

    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }
    if (args->arg_count > 1 && args->args[1] != NULL) window     = *(long long *) args->args[1];
    if (args->arg_count > 2 && args->args[2] != NULL) hop        = *(long long *) args->args[2];
    if (args->arg_count > 3 && args->args[3] != NULL) max_frames = *(long long *) args->args[3];
    if (window < 8 || window > 512 || hop < 1 ||
        max_frames < 1 || max_frames > 4096) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &series, &n, errbuf)) {
        *error = 1; return NULL;
    }
    if (n < (size_t) window) { free(series); *error = 1; return NULL; }

    /* The core writes min(available, max_frames) frames, so capping the
     * allocation at the available frame count changes no result. */
    avail = (n - (size_t) window) / (size_t) hop + 1;
    frames_cap = fsq_out_cap(max_frames, avail, sizeof(double), &frames_bytes);
    if (frames_cap == 0) { free(series); *error = 1; return NULL; }
    entropy = malloc(frames_bytes);
    if (entropy == NULL) { free(series); *error = 1; return NULL; }

    rc = fsql_spectrogram_entropy(series, n, (size_t) window, (size_t) hop,
                                  entropy, frames_cap, &n_frames);
    free(series);
    if (rc != FSQL_OK) { free(entropy); *error = 1; return NULL; }

    if (!json_out_ensure(jo, 16)) { free(entropy); *error = 1; return NULL; }
    pos = (size_t) snprintf(jo->buf, jo->cap, "[");
    for (size_t i = 0; i < n_frames; i++) {
        char field[FSQL_FIELD_MAX];
        int  flen;
        if (fractalsql_interrupt_poll()) {  /* cancel boundary, per frame */
            free(entropy); *error = 1; return NULL;
        }
        flen = snprintf(field, sizeof field, "%s%.10f", i > 0 ? "," : "", entropy[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) {
            free(entropy); *error = 1; return NULL;
        }
        if (!json_out_ensure(jo, pos + (size_t) flen + 8)) {
            free(entropy); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    free(entropy);
    if (!json_out_ensure(jo, pos + 4)) { *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "]");

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_state_fingerprint                               */
/*                                                                    */
/* Random-hyperplane SimHash: projects a state vector onto n_bits     */
/* random hyperplanes (deterministic from seed), packs the sign of    */
/* each projection MSB-first. Returns a JSON array of the (n_bits+7)/8*/
/* output bytes, e.g. "[145,3,201]" -- same byte-array-as-JSON-ints   */
/* convention fractal_vector_quantize_binary uses, so a fingerprint   */
/* can be fed straight into fractal_cycle_detect below.               */
/* ------------------------------------------------------------------ */

/* The largest fingerprint that can be REPORTED: the result is a JSON
 * array of the fingerprint's bytes, at most four characters each (three
 * digits and a separator), and the document has to fit the 16 MiB this
 * UDF declares as its result length. 32 Mi bits is the ceiling. */
#define FINGERPRINT_MAX_BYTES ((16u * 1024u * 1024u - 4u) / 4u)
#define FINGERPRINT_MAX_BITS  ((long long) FINGERPRINT_MAX_BYTES * 8LL)
/* Most random draws one fingerprint (n_bits x vector length) may cost: about
 * 4 ns each, so 2^28 is roughly a second, and the loop cannot be interrupted.
 * The same bound as the core's. */
#define FINGERPRINT_MAX_WORK  (268435456LL)

FRACTAL_EXPORT bool
fractal_state_fingerprint_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_state_fingerprint(vec_csv, n_bits, seed): expected 3 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = REAL_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_state_fingerprint_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_state_fingerprint(UDF_INIT *initid, UDF_ARGS *args, char *result,
                          unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char     errbuf[MYSQL_ERRMSG_SIZE];
    double  *v = NULL;
    uint8_t *out = NULL;
    size_t   dim = 0, n_bytes, pos;
    long long n_bits;
    double   seed;
    int      rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    if (args->lengths[0] > MAX_QUERY_BYTES) { *error = 1; return NULL; }

    n_bits = *(long long *) args->args[1];
    seed   = *(double *) args->args[2];
    if (n_bits <= 0) { *error = 1; return NULL; }
    /* The output is a JSON array of the fingerprint's bytes: at most
     * three digits and a separator each, so four characters per byte,
     * and the whole document has to fit the 16 MiB this UDF declares as
     * its result length. n_bits was bounded only from below, so a
     * caller could ask for a 2^60-bit fingerprint -- a petabyte
     * allocation, refused only because malloc said no. The largest
     * fingerprint that can be reported at all is the one whose JSON
     * fits, and that is the bound applied here. */
    if (n_bits > (long long) FINGERPRINT_MAX_BITS) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &v, &dim, errbuf)) {
        *error = 1; return NULL;
    }
    if (dim > 0 && n_bits > FINGERPRINT_MAX_WORK / (long long) dim) { free(v); *error = 1; return NULL; }
    n_bytes = ((size_t) n_bits + 7) / 8;
    out = malloc(n_bytes);
    if (out == NULL) { free(v); *error = 1; return NULL; }

    rc = fsql_state_fingerprint(v, dim, (size_t) n_bits, seed, out);
    free(v);
    if (rc != FSQL_OK) { free(out); *error = 1; return NULL; }

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
 * a caller-owned uint8_t buffer -- shared by fractal_cycle_detect
 * (fingerprint bytes) below. Reuses parse_vector_csv, then narrows
 * with a range check rather than silently truncating out-of-range
 * values (which would corrupt fingerprint bytes without any error). */
static bool
parse_byte_array(const char *s, size_t slen, uint8_t **out, size_t *n_out, char *errbuf)
{
    double *dv = NULL;
    size_t  n = 0;
    uint8_t *bv;

    if (!parse_vector_csv(s, slen, &dv, &n, errbuf)) return false;
    bv = malloc(n > 0 ? n : 1);
    if (bv == NULL) {
        SFS_INIT_ERROR(errbuf, "fractalsql: oom");
        free(dv);
        return false;
    }
    for (size_t i = 0; i < n; i++) {
        if (dv[i] < 0.0 || dv[i] > 255.0 || dv[i] != (double) (int) dv[i]) {
            SFS_INIT_ERROR(errbuf, "fractalsql: byte array element %zu out of range [0,255]", i);
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
/* UDF triad: fractal_cycle_detect                                    */
/*                                                                    */
/* Single-call wrapper over the stateful fsql_cycle_detect_init/_feed/*/
/* _free streaming Brent's-algorithm API: takes a flat JSON/CSV array */
/* of concatenated fingerprint bytes (n_fingerprints * n_bytes long,  */
/* each n_bytes-byte chunk one fingerprint, e.g. successive            */
/* fractal_state_fingerprint outputs concatenated by the caller) plus */
/* the per-fingerprint byte width and a Hamming-distance tolerance,   */
/* feeds them one at a time, and returns the FIRST cycle found:       */
/* {"detected":true,"cycle_len":<int>,"at_index":<int>} or             */
/* {"detected":false} if the stream never closed a cycle. Loses the   */
/* ability to keep streaming across calls (a true incremental wrapper */
/* would need a session-scoped handle, out of scope for this pass --  */
/* see fractal_diversify_enable's session_id convention for the        */
/* precedent a future incremental version could follow).              */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_cycle_detect_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_cycle_detect(fingerprints_csv, n_bytes, hamming_threshold): "
            "expected 3 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_cycle_detect_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_cycle_detect(UDF_INIT *initid, UDF_ARGS *args, char *result,
                     unsigned long *length, char *is_null, char *error)
{
    json_out_ctx    *jo = (json_out_ctx *) initid->ptr;
    char             errbuf[MYSQL_ERRMSG_SIZE];
    uint8_t         *flat = NULL;
    size_t           flat_n = 0, n_fp, pos;
    long long        n_bytes, hamming_threshold;
    fsql_cycle_state_t cs;
    int              rc, detected = 0;
    size_t           cycle_len = 0, at_index = 0;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    n_bytes           = *(long long *) args->args[1];
    hamming_threshold = *(long long *) args->args[2];
    if (n_bytes <= 0 || hamming_threshold < 0) { *error = 1; return NULL; }

    if (!parse_byte_array(args->args[0], args->lengths[0], &flat, &flat_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (flat_n % (size_t) n_bytes != 0) {
        free(flat); *error = 1; return NULL;
    }
    n_fp = flat_n / (size_t) n_bytes;

    rc = fsql_cycle_detect_init(&cs, (size_t) n_bytes, (size_t) hamming_threshold);
    if (rc != FSQL_OK) { free(flat); *error = 1; return NULL; }

    for (size_t i = 0; i < n_fp; i++) {
        int out_detected = 0;
        size_t out_cycle_len = 0;
        rc = fsql_cycle_detect_feed(&cs, flat + i * (size_t) n_bytes,
                                    &out_detected, &out_cycle_len);
        if (rc != FSQL_OK) { fsql_cycle_detect_free(&cs); free(flat); *error = 1; return NULL; }
        if (out_detected) { detected = 1; cycle_len = out_cycle_len; at_index = i; break; }
    }
    fsql_cycle_detect_free(&cs);
    free(flat);

    if (!json_out_ensure(jo, 96)) { *error = 1; return NULL; }
    if (detected) {
        pos = (size_t) snprintf(jo->buf, jo->cap,
            "{\"detected\":true,\"cycle_len\":%zu,\"at_index\":%zu}", cycle_len, at_index);
    } else {
        pos = (size_t) snprintf(jo->buf, jo->cap, "{\"detected\":false}");
    }

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_tda_persistence_diagram                         */
/*                                                                    */
/* Size-capped 0-dim persistence diagram plus a graph-theoretic       */
/* Betti-1 count over a point cloud's Vietoris-Rips filtration.       */
/*                                                                    */
/* SCOPE NOTE (real, not a stability caveat -- read before            */
/* interpreting betti1): the 0-dim diagram (h0_bars, birth/death) is  */
/* an EXACT, complete persistence computation -- single-linkage       */
/* clustering is mathematically equivalent to 0-dim persistent        */
/* homology of the Vietoris-Rips filtration. The betti1 number is a   */
/* real, correctly-computed, different invariant: the bare 1-skeleton */
/* GRAPH's cycle rank (|E| - |V| + components), NOT full simplicial   */
/* H1 of the Vietoris-Rips complex. It over-counts true H1 whenever a */
/* filled triangle exists in the data. A full TDA library (Ripser/    */
/* GUDHI) would compute true H1 via boundary-matrix reduction; this   */
/* module deliberately doesn't attempt that (no reference oracle      */
/* exists in this codebase to validate a from-scratch implementation  */
/* against). Not gated behind any flag -- both numbers are correct    */
/* for what they actually measure, this is a documentation obligation */
/* on the caller, not a runtime restriction.                          */
/*                                                                    */
/* points_csv: flat, row-major n_points x dim. max_dim: 0 (h0_bars    */
/* only) or 1 (also computes betti1). Returns {"h0_bars":             */
/* [{"birth":..,"death":..},...],"n_h0_bars":<int>,"betti1":<int or   */
/* null>}. 2 <= n_points <= 512 (FSQL_TDA_MAX_POINTS).                */
/* ------------------------------------------------------------------ */

FRACTAL_EXPORT bool
fractal_tda_persistence_diagram_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 5) {
        SFS_INIT_ERROR(message,
            "fractal_tda_persistence_diagram(points_csv, dim, max_dim, max_thresh, "
            "max_h0_bars): expected 5 arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = INT_RESULT;
    args->arg_type[3] = REAL_RESULT;
    args->arg_type[4] = INT_RESULT;
    return json_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_tda_persistence_diagram_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_tda_persistence_diagram(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                unsigned long *length, char *is_null, char *error)
{
    json_out_ctx    *jo = (json_out_ctx *) initid->ptr;
    char             errbuf[MYSQL_ERRMSG_SIZE];
    double          *points = NULL;
    fsql_tda_bar_t  *bars = NULL;
    size_t           flat_n = 0, n_h0_bars = 0, betti1 = 0, pos;
    size_t           bars_cap = 0, bars_bytes = 0;
    long long        dim, max_dim, max_h0_bars;
    double           max_thresh;
    int              rc;
    (void) result;

    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL ||
        args->args[3] == NULL || args->args[4] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }

    dim         = *(long long *) args->args[1];
    max_dim     = *(long long *) args->args[2];
    max_thresh  = *(double *) args->args[3];
    max_h0_bars = *(long long *) args->args[4];
    if (dim <= 0 || (max_dim != 0 && max_dim != 1) ||
        max_thresh <= 0.0 || max_h0_bars <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &points, &flat_n, errbuf)) {
        *error = 1; return NULL;
    }
    if (flat_n % (size_t) dim != 0) { free(points); *error = 1; return NULL; }

    /* The H0 barcode of n points has at most n bars, so n_points is the
     * most the core can produce; the cap and the allocation agree. */
    bars_cap = fsq_out_cap(max_h0_bars, flat_n / (size_t) dim, sizeof(fsql_tda_bar_t), &bars_bytes);
    if (bars_cap == 0) { free(points); *error = 1; return NULL; }
    bars = malloc(bars_bytes);
    if (bars == NULL) { free(points); *error = 1; return NULL; }

    rc = fsql_tda_persistence_diagram(points, flat_n / (size_t) dim, (size_t) dim,
                                      (int) max_dim, max_thresh,
                                      bars, bars_cap, &n_h0_bars,
                                      max_dim == 1 ? &betti1 : NULL);
    free(points);
    if (rc != FSQL_OK) { free(bars); *error = 1; return NULL; }

    if (!json_out_ensure(jo, 32)) { free(bars); *error = 1; return NULL; }
    pos = (size_t) snprintf(jo->buf, jo->cap, "{\"h0_bars\":[");
    for (size_t i = 0; i < n_h0_bars; i++) {
        /* TWO numbers plus their keys: a separator, '{"birth":', the
         * birth value, ',"death":', the death value and '}'. Two
         * FSQL_FIELD_MAX-sized numbers with room for the keys between
         * them. */
        char field[FSQL_FIELD_MAX * 2];
        int  flen = snprintf(field, sizeof field, "%s{\"birth\":%.10f,\"death\":%.10f}",
                             i > 0 ? "," : "", bars[i].birth, bars[i].death);
        if (flen < 0 || (size_t) flen >= sizeof field) { free(bars); *error = 1; return NULL; }
        if (!json_out_ensure(jo, pos + (size_t) flen + 64)) {
            free(bars); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    free(bars);
    if (!json_out_ensure(jo, pos + 64)) { *error = 1; return NULL; }
    if (max_dim == 1) {
        pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos,
            "],\"n_h0_bars\":%zu,\"betti1\":%zu}", n_h0_bars, betti1);
    } else {
        pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos,
            "],\"n_h0_bars\":%zu,\"betti1\":null}", n_h0_bars);
    }

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}

/* ------------------------------------------------------------------ */
/* UDF triad: fractal_optimize_subset                                 */
/*                                                                    */
/* fsql_optimize_subset generalizes portfolio optimization behind a   */
/* caller-supplied objective callback, but SQL can't pass a function  */
/* pointer -- same situation fractal_optimize_portfolio already       */
/* solves by hardcoding Sharpe ratio. This hardcodes VALUE-WEIGHTED   */
/* ALLOCATION: maximize sum(weight[i] * item_value[i]) subject to     */
/* upper_bounds[i], the k-cardinality constraint, and (fixed off in   */
/* this pass -- see below) an optional turnover penalty.              */
/*                                                                    */
/* item_values_csv/upper_bounds_csv: n_items doubles each.            */
/* upper_bounds_csv may be '' for the core's default [0,1] per item.  */
/* Turnover penalty (prev_weights) is not exposed here -- it needs a  */
/* second n_items-length array threaded through the params JSON as a  */
/* nested CSV string, which this pass keeps out of scope; every call  */
/* here runs with turnover disabled (prev_weights=NULL,               */
/* turnover_penalty=0.0), same as calling fsql_optimize_subset         */
/* directly with turnover off. Returns {"score":<f>,"weights":[...]}. */
/* params (all optional): {"seed": <int, default 0>}.                 */
/* ------------------------------------------------------------------ */

typedef struct subset_value_ctx {
    const double *item_values;
    size_t        n;
} subset_value_ctx;

/* fsql_subset_objective_fn: lower is better, so negate the quantity
 * we actually want to maximize. */
static double
subset_value_objective(const double *weights, size_t n, void *ctx_void)
{
    subset_value_ctx *ctx = (subset_value_ctx *) ctx_void;
    double sum = 0.0;
    (void) n;  /* == ctx->n, guaranteed by the caller */
    for (size_t i = 0; i < ctx->n; i++) sum += weights[i] * ctx->item_values[i];
    return -sum;
}

FRACTAL_EXPORT bool
fractal_optimize_subset_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 4) {
        SFS_INIT_ERROR(message,
            "fractal_optimize_subset(item_values_csv, upper_bounds_csv, k, params): "
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
fractal_optimize_subset_deinit(UDF_INIT *initid) { json_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_optimize_subset(UDF_INIT *initid, UDF_ARGS *args, char *result,
                        unsigned long *length, char *is_null, char *error)
{
    json_out_ctx *jo = (json_out_ctx *) initid->ptr;
    char      errbuf[MYSQL_ERRMSG_SIZE];
    double   *item_values = NULL, *upper_bounds = NULL, *weights = NULL;
    size_t    n_items = 0, ub_n = 0, pos;
    long long k;
    const char *params_s; size_t params_len;
    unsigned long long seed;
    double      score;
    subset_value_ctx ctx;
    int         rc;
    (void) result;

    if (args->args[0] == NULL || args->args[2] == NULL) { *is_null = 1; return NULL; }
    if (args->lengths[0] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }
    /* The upper bounds and the params are bounded like every other
     * string argument in this file: the bounds CSV reaches the parser
     * (which grows an array from the text it is handed) and the params
     * reach the JSON scanner. Neither had a cap of its own here, which
     * made this the one UDF whose memory use was set by
     * max_allowed_packet alone. */
    if (args->args[1] != NULL && args->lengths[1] > MAX_CORPUS_BYTES) { *error = 1; return NULL; }
    if (args->args[3] != NULL && args->lengths[3] > MAX_QUERY_BYTES) { *error = 1; return NULL; }

    k = *(long long *) args->args[2];
    if (k <= 0) { *error = 1; return NULL; }

    if (!parse_vector_csv(args->args[0], args->lengths[0], &item_values, &n_items, errbuf)) {
        *error = 1; return NULL;
    }
    if (args->args[1] != NULL && args->lengths[1] > 0) {
        if (!parse_vector_csv(args->args[1], args->lengths[1], &upper_bounds, &ub_n, errbuf)) {
            free(item_values); *error = 1; return NULL;
        }
        if (ub_n != n_items) {
            free(item_values); free(upper_bounds); *error = 1; return NULL;
        }
    }
    if ((size_t) k > n_items) {
        free(item_values); free(upper_bounds); *error = 1; return NULL;
    }
    if ((unsigned long long) n_items * (unsigned long long) k > SUBSET_MAX_WORK) {
        free(item_values); free(upper_bounds); *error = 1; return NULL;
    }

    params_s   = (args->args[3] != NULL) ? args->args[3] : "{}";
    params_len = (args->args[3] != NULL) ? args->lengths[3] : 2;
    /* Unsigned, for the same reason as the portfolio optimizer's seed
     * above: the core's seed is a uint64_t, and a signed read turned
     * {"seed":-1} into 18446744073709551615 instead of the documented
     * default. */
    seed       = json_get_u64(params_s, params_len, "seed", 0);

    weights = malloc(n_items * sizeof(double));
    if (weights == NULL) {
        free(item_values); free(upper_bounds); *error = 1; return NULL;
    }

    ctx.item_values = item_values;
    ctx.n           = n_items;
    rc = fsql_optimize_subset(subset_value_objective, &ctx, n_items, (size_t) k,
                              NULL, upper_bounds, NULL, 0.0, (uint64_t) seed,
                              weights, &score);
    free(item_values); free(upper_bounds);
    if (rc != FSQL_OK) { free(weights); *error = 1; return NULL; }

    /* score is -sum(weight*value) per subset_value_objective's sign
     * convention (fsql_optimize_subset always minimizes); negate back
     * to report the actual maximized value-weighted allocation. */
    /* The head's own room: "{\"score\":" + a "%.10f" of up to 321
     * characters + ",\"weights\":[". A fixed 64 bytes would not be enough for
     * a score above roughly 1e240, and a truncated snprintf is a hard
     * error here, so the head is sized for the worst case. */
    if (!json_out_ensure(jo, FSQL_FIELD_MAX + 64)) { free(weights); *error = 1; return NULL; }
    {
        int hlen = snprintf(jo->buf, jo->cap, "{\"score\":%.10f,\"weights\":[", -score);
        if (hlen < 0 || (size_t) hlen >= jo->cap) { free(weights); *error = 1; return NULL; }
        pos = (size_t) hlen;
    }
    for (size_t i = 0; i < n_items; i++) {
        char field[FSQL_FIELD_MAX];
        int  flen = snprintf(field, sizeof field, "%s%.10f",
                             i > 0 ? "," : "", weights[i]);
        if (flen < 0 || (size_t) flen >= sizeof field) { free(weights); *error = 1; return NULL; }
        if (!json_out_ensure(jo, pos + (size_t) flen + 8)) {
            free(weights); *error = 1; return NULL;
        }
        memcpy(jo->buf + pos, field, (size_t) flen);
        pos += (size_t) flen;
    }
    free(weights);
    if (!json_out_ensure(jo, pos + 8)) { *error = 1; return NULL; }
    pos += (size_t) snprintf(jo->buf + pos, jo->cap - pos, "]}");

    *length  = (unsigned long) pos;
    *is_null = 0;
    return jo->buf;
}
