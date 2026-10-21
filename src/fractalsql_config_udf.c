/* src/fractalsql_config_udf.c
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The SQL surface of the per-session configuration overlay (see
 * fractalsql_config.h for the design and the per-key allow/deny
 * rationale).
 *
 *   fractal_config_set(name, value, session_id) -> STRING
 *       'ok' when the session's override was stored; the refusal
 *       reason otherwise. The reason is RETURNED rather than raised:
 *       MariaDB's UDF ABI has no error text on the runtime path (the
 *       *error flag yields a bare "ERROR 1123 (HY000): Can't initialize
 *       function"), so a set that refuses must hand the caller
 *       something it can read.
 *
 *   fractal_config_get(name, session_id) -> STRING
 *       The EFFECTIVE value for this session: the session's own
 *       override when it has one, otherwise the daemon-wide value the
 *       owning tier currently holds. NULL when the key is unknown or
 *       unset. A SECRET key never yields its value: it reports
 *       '<redacted>' when a credential is configured and '<unset>'
 *       when it is not.
 *
 *   fractal_config_reset(session_id) -> INTEGER
 *       Drops every override the session holds; returns how many.
 *
 *   fractal_config_list(session_id) -> STRING
 *       The session's own overrides, as a JSON object.
 *
 *   fractal_config_keys() -> STRING
 *       Every configuration key this build knows, as a JSON array of
 *       {name, type, session_overridable} objects -- so a caller can
 *       discover the surface instead of hard-coding it.
 *
 * The session_id is the caller's own session key, by the documented
 * convention CONNECTION_ID() (see sql/install_udf.sql and
 * fractalsql_session.h for why a UDF cannot ask for it directly).
 *
 * NAMING: the module-level functions in fractalsql_config.c carry a
 * _value / _session suffix (fractal_config_set_value,
 * fractal_config_get_value, fractal_config_reset_session) so that the
 * UDF mains in this file can take the plain SQL names
 * (fractal_config_set, fractal_config_get, fractal_config_reset)
 * without the two translation units exporting the same symbol.
 */

#include <mysql.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fractalsql_config.h"

#if defined(_WIN32) || defined(__CYGWIN__)
#  define FRACTAL_EXPORT __declspec(dllexport)
#else
#  define FRACTAL_EXPORT
#endif

/* Same stderr-mirroring SFS_INIT_ERROR as the other translation units
 * in this repo (duplicated per TU by this repo's established
 * precedent): on the UDF runtime path the formatted buffer would
 * otherwise be dropped, surfacing failures as bare NULLs. */
#define SFS_INIT_ERROR(msg, ...)                                              \
    do {                                                                      \
        snprintf((msg), MYSQL_ERRMSG_SIZE, __VA_ARGS__);                      \
        fprintf(stderr, "fractalsql: %s\n", (msg));                           \
    } while (0)

/* The stderr-only counterpart: for a failure on the RUNTIME path,
 * where there is no message buffer to format into (the ABI's error
 * flag yields a bare "Can't initialize function"), but the reason must
 * still reach the operator's log rather than vanishing. */
#define SFS_LOG(...)                                                          \
    do {                                                                      \
        fprintf(stderr, "fractalsql: ");                                      \
        fprintf(stderr, __VA_ARGS__);                                         \
        fprintf(stderr, "\n");                                                \
    } while (0)

/* fractal_config_list has no fixed output buffer: the renderer sizes
 * the document itself, because the JSON it produces depends on how much
 * the stored values escape to. */

typedef struct cfg_out_ctx {
    char  *buf;
    size_t cap;
} cfg_out_ctx;

static bool
cfg_out_ensure(cfg_out_ctx *jo, size_t need)
{
    size_t ncap;
    char  *nb;
    if (need <= jo->cap) return true;
    ncap = jo->cap ? jo->cap : 256;
    /* The doubling has to be able to stop: past SIZE_MAX/2 the next
     * doubling wraps to zero, and the loop would never reach `need`. */
    while (ncap < need) {
        if (ncap > SIZE_MAX / 2) { ncap = need; break; }
        ncap *= 2;
    }
    nb = (char *) realloc(jo->buf, ncap);
    if (nb == NULL) return false;
    jo->buf = nb; jo->cap = ncap;
    return true;
}

static bool
cfg_out_generic_init(UDF_INIT *initid, char *message)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) calloc(1, sizeof(*jo));
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
cfg_out_generic_deinit(UDF_INIT *initid)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) initid->ptr;
    if (jo == NULL) return;
    free(jo->buf);
    free(jo);
    initid->ptr = NULL;
}

/* The three string-returning functions share one "copy this text out"
 * helper: the MariaDB UDF contract is that the returned pointer stays
 * valid until the NEXT call on the same initid, so one growable
 * buffer per UDF instance satisfies it. */
static char *
cfg_return(cfg_out_ctx *jo, const char *s, unsigned long *length,
           char *is_null, char *error)
{
    size_t n = strlen(s);
    if (!cfg_out_ensure(jo, n + 1)) { *error = 1; return NULL; }
    memcpy(jo->buf, s, n + 1);
    *length  = (unsigned long) n;
    *is_null = 0;
    return jo->buf;
}

/* ==================================================================== */
/* fractal_config_set(name, value, session_id) -> STRING               */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_config_set_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 3) {
        SFS_INIT_ERROR(message,
            "fractal_config_set(name, value, session_id): expected 3 "
            "arguments, got %u", args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = STRING_RESULT;
    args->arg_type[2] = INT_RESULT;
    return cfg_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_config_set_deinit(UDF_INIT *initid) { cfg_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_config_set(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) initid->ptr;
    char   errbuf[MYSQL_ERRMSG_SIZE];
    char   name[256];
    char  *value;
    size_t vlen;
    unsigned long long sid;
    int    rc;

    (void) result;
    if (jo == NULL) { *error = 1; return NULL; }
    if (args->args[0] == NULL || args->args[1] == NULL || args->args[2] == NULL) {
        *is_null = 1; return NULL;
    }
    /* Both an over-long name and an over-long value are REFUSALS, not
     * errors: this function's contract is to hand the caller a reason
     * it can read, and a bare NULL (or the ABI's "Can't initialize
     * function") would tell the caller nothing. */
    if (args->lengths[0] >= sizeof name) {
        return cfg_return(jo, "refused: the configuration key name is too long",
                          length, is_null, error);
    }
    memcpy(name, args->args[0], args->lengths[0]);
    name[args->lengths[0]] = '\0';

    vlen = args->lengths[1];
    /* The limit is the whole buffer, terminator included: a value of
     * 8192 bytes does not fit in an 8192-byte buffer with its NUL, and
     * the read path would hand back a truncated value. */
    if (vlen >= FSQL_CFG_MAX_VALUE) {
        return cfg_return(jo,
            "refused: the configuration value is too long (the limit is "
            "8191 bytes)", length, is_null, error);
    }
    value = (char *) malloc(vlen + 1);
    if (value == NULL) {
        SFS_INIT_ERROR(errbuf, "fractal_config_set: out of memory");
        *error = 1; return NULL;
    }
    memcpy(value, args->args[1], vlen);
    value[vlen] = '\0';

    sid = (unsigned long long) *(long long *) args->args[2];

    errbuf[0] = '\0';
    rc = fractal_config_set_value(sid, name, value, errbuf, sizeof errbuf);
    free(value);

    if (rc != 0) {
        /* A refusal is a RESULT, not an error: the caller needs the
         * reason, and the UDF ABI cannot carry one on the error path. */
        return cfg_return(jo, errbuf[0] ? errbuf : "refused",
                          length, is_null, error);
    }
    return cfg_return(jo, "ok", length, is_null, error);
}

/* ==================================================================== */
/* fractal_config_get(name, session_id) -> STRING                      */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_config_get_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 2) {
        SFS_INIT_ERROR(message,
            "fractal_config_get(name, session_id): expected 2 arguments, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    return cfg_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_config_get_deinit(UDF_INIT *initid) { cfg_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_config_get(UDF_INIT *initid, UDF_ARGS *args, char *result,
                   unsigned long *length, char *is_null, char *error)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) initid->ptr;
    char   name[256];
    char   value[FSQL_CFG_MAX_VALUE];
    unsigned long long sid;

    (void) result;
    if (jo == NULL) { *error = 1; return NULL; }
    if (args->args[0] == NULL || args->args[1] == NULL) { *is_null = 1; return NULL; }
    /* A name longer than any key this build knows is simply an
     * unknown key: NULL is the documented answer for that, and an
     * error here would report a failure for a query that simply
     * matched nothing. */
    if (args->lengths[0] >= sizeof name) {
        SFS_LOG("fractal_config_get: the key name is too long to be a known key");
        *is_null = 1;
        *length  = 0;
        return NULL;
    }
    memcpy(name, args->args[0], args->lengths[0]);
    name[args->lengths[0]] = '\0';

    sid = (unsigned long long) *(long long *) args->args[1];

    value[0] = '\0';
    if (fractal_config_get_value(sid, name, value, sizeof value) != 0) {
        /* Unknown key or unset: NULL, not an empty string, so a caller
         * can tell "not set" from "set to the empty string". */
        *is_null = 1;
        *length  = 0;
        return NULL;
    }
    return cfg_return(jo, value, length, is_null, error);
}

/* ==================================================================== */
/* fractal_config_reset(session_id) -> INTEGER                         */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_config_reset_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_config_reset(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    initid->maybe_null = 0;
    return false;
}

FRACTAL_EXPORT void
fractal_config_reset_deinit(UDF_INIT *initid) { (void) initid; }

FRACTAL_EXPORT long long
fractal_config_reset(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    unsigned long long sid;

    (void) initid;
    if (args->args[0] == NULL) { *is_null = 1; return 0; }
    sid = (unsigned long long) *(long long *) args->args[0];
    *is_null = 0;
    (void) error;
    return (long long) fractal_config_reset_session(sid);
}

/* ==================================================================== */
/* fractal_config_list(session_id) -> STRING                            */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_config_list_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        SFS_INIT_ERROR(message,
            "fractal_config_list(session_id): expected 1 argument, got %u",
            args->arg_count);
        return true;
    }
    args->arg_type[0] = INT_RESULT;
    return cfg_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_config_list_deinit(UDF_INIT *initid) { cfg_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_config_list(UDF_INIT *initid, UDF_ARGS *args, char *result,
                    unsigned long *length, char *is_null, char *error)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) initid->ptr;
    char   errbuf[MYSQL_ERRMSG_SIZE];
    char *json;
    unsigned long long sid;
    char *ret;

    (void) result;
    if (jo == NULL) { *error = 1; return NULL; }
    if (args->args[0] == NULL) { *is_null = 1; return NULL; }
    sid = (unsigned long long) *(long long *) args->args[0];

    /* The renderer sizes the document itself: the JSON it produces
     * depends on how much the stored values escape to, so a caller
     * cannot know the length in advance. */
    json = fractal_config_session_json(sid);
    if (json == NULL) {
        SFS_INIT_ERROR(errbuf, "fractal_config_list: out of memory");
        *error = 1;
        return NULL;
    }
    ret = cfg_return(jo, json, length, is_null, error);
    free(json);
    return ret;
}

/* ==================================================================== */
/* fractal_config_keys() -> STRING                                     */
/* ==================================================================== */

FRACTAL_EXPORT bool
fractal_config_keys_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 0) {
        SFS_INIT_ERROR(message,
            "fractal_config_keys(): expected 0 arguments, got %u",
            args->arg_count);
        return true;
    }
    return cfg_out_generic_init(initid, message);
}

FRACTAL_EXPORT void
fractal_config_keys_deinit(UDF_INIT *initid) { cfg_out_generic_deinit(initid); }

FRACTAL_EXPORT char *
fractal_config_keys(UDF_INIT *initid, UDF_ARGS *args, char *result,
                    unsigned long *length, char *is_null, char *error)
{
    cfg_out_ctx *jo = (cfg_out_ctx *) initid->ptr;
    const fsq_cfg_key *keys = fractal_config_key_table();
    char *json;
    size_t cap = 4096, used = 0;
    int i;
    const char *type_name;

    (void) args;
    (void) result;
    if (jo == NULL) { *error = 1; return NULL; }

    json = (char *) malloc(cap);
    if (json == NULL) {
        SFS_LOG("fractal_config_keys: out of memory");
        *error = 1; return NULL;
    }

    used = (size_t) snprintf(json, cap, "[");
    for (i = 0; i < FSQL_CFG_KEY_COUNT; i++) {
        int n;
        switch (keys[i].type) {
        case FSQL_CFG_TYPE_STR:   type_name = "string"; break;
        case FSQL_CFG_TYPE_PATH:  type_name = "path";   break;
        case FSQL_CFG_TYPE_INT:   type_name = "int";    break;
        case FSQL_CFG_TYPE_BOOL:  type_name = "bool";   break;
        case FSQL_CFG_TYPE_ENUM:  type_name = "enum";   break;
        default:                  type_name = "string"; break;
        }
        if (used + 256 > cap) {
            /* The growth has to be able to stop: past SIZE_MAX/2 the
             * doubling wraps to zero and the new size is smaller than the
             * old one. */
            if (cap > SIZE_MAX / 2) {
                free(json);
                SFS_LOG("fractal_config_keys: the key list does not fit the buffer");
                *error = 1; return NULL;
            }
            size_t ncap = cap * 2;
            char *nb = (char *) realloc(json, ncap);
            if (nb == NULL) {
                free(json);
                SFS_LOG("fractal_config_keys: out of memory");
                *error = 1; return NULL;
            }
            json = nb; cap = ncap;
        }
        n = snprintf(json + used, cap - used,
                     "%s{\"name\":\"%s\",\"type\":\"%s\",\"session_overridable\":%s}",
                     used > 1 ? "," : "", keys[i].key, type_name,
                     keys[i].session_ok ? "true" : "false");
        if (n < 0 || (size_t) n >= cap - used) {
            free(json);
            SFS_LOG("fractal_config_keys: the key list does not fit the buffer");
            *error = 1; return NULL;
        }
        used += (size_t) n;
    }
    if (used + 2 >= cap) {
        free(json);
        SFS_LOG("fractal_config_keys: the key list does not fit the buffer");
        *error = 1; return NULL;
    }
    json[used++] = ']';
    json[used] = '\0';

    {
        char *ret = cfg_return(jo, json, length, is_null, error);
        free(json);
        return ret;
    }
}
