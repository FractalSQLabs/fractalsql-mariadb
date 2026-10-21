/* src/fractalsql_config.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The configuration surface shared by three consumers of this repo:
 *
 *   1. The DAEMON's config file (fractalsqld.conf) -- the process-wide
 *      settings, applied through fractalsql_provider.h and re-applied
 *      live by `fsqlctl reload`.
 *   2. The PER-SESSION overlay -- a connection-scoped set of overrides
 *      on top of (1), addressed by the caller's own session id (the
 *      documented convention is CONNECTION_ID(), the same key every
 *      other session-scoped function in this repo uses).
 *   3. The PATH RULES -- what a plugin/library/ledger path must look
 *      like before anything tries to open it.
 *
 * WHY THE OVERLAY EXISTS: the process-wide config file needs a
 * filesystem edit plus a daemon reload, which is the right shape for
 * an operator and the wrong shape for a session that wants one knob
 * changed for its own work. This module gives a session a live,
 * per-connection override of the TUNING keys, without giving it the
 * keys that decide which code runs, where traffic goes, or what
 * secrets are used.
 *
 * WHAT A SESSION MAY NOT OVERRIDE (and why): the overlay refuses,
 * by name, every key that would let one connection re-point the shared
 * daemon:
 *
 *   reasoning_plugin, enterprise_lib, enterprise_ledger_path
 *       -- which code the daemon loads. A session that could name its
 *          own .so would run attacker-chosen code as the daemon.
 *   reasoning_url, embed_url, think_native_url
 *       -- where the daemon's outbound traffic (and its bearer token)
 *          goes. A session that could re-point the URL could exfiltrate
 *          the operator's token to a host of its choosing.
 *   reasoning_token, enterprise_ledger_key
 *       -- the operator's own credentials; a session never gets to
 *          read or replace them.
 *   reasoning_allow_plaintext, enterprise_require_signature
 *       -- posture flags the operator set deliberately (plaintext
 *          transport, signature enforcement).
 *   think_provider, t2s_allowed_statements
 *       -- routing / capability widening.
 *
 * WHAT A SESSION MAY OVERRIDE: the tuning keys -- the model names,
 * the THINK level, the THINK context size, the text-to-SQL attempt
 * count, and the text-to-SQL review switch. They change what the
 * provider is asked for, not where the request goes.
 *
 * HOW THE OVERRIDE REACHES THE PLUGIN: the reasoning plugin reads its
 * own configuration ONCE, when it is loaded, and bakes it into the
 * loaded instance -- the plugin's ABI has no per-dispatch
 * configuration read. So a session's model/THINK override only reaches
 * the plugin if the tier loads the plugin again with the override in
 * the process environment. The tiers do exactly that: they fingerprint
 * the bridge environment (fractal_config_env_fingerprint) and reload
 * the tier's instance when the fingerprint no longer matches the one
 * the instance was loaded with. t2s_max_attempts and t2s_use_review
 * are read by this repo's own code on every call, so those two take
 * effect immediately.
 *
 * THE COST OF THAT: the four tiers hold ONE plugin instance each, and
 * every session shares it. Two sessions that ask for different models
 * make the tier reload the instance between their calls. A session
 * that overrides nothing pays nothing: the fingerprint then matches
 * the instance the tier already holds, and no reload happens.
 */
#ifndef FRACTALSQL_CONFIG_H
#define FRACTALSQL_CONFIG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The configuration keys, in the same order and with the same names as
 * fractalsqld.conf (see service/daemon/fractalsqld.c's parser and
 * fractalsql_provider.h's presence bits). */
enum {
    FSQL_CFG_REASONING_PLUGIN = 0,
    FSQL_CFG_REASONING_URL,
    FSQL_CFG_REASONING_TOKEN,
    FSQL_CFG_REASONING_MODEL,
    FSQL_CFG_REASONING_ALLOW_PLAINTEXT,
    FSQL_CFG_EMBED_URL,
    FSQL_CFG_EMBED_MODEL,
    FSQL_CFG_THINK,
    FSQL_CFG_THINK_PROVIDER,
    FSQL_CFG_THINK_NATIVE_URL,
    FSQL_CFG_THINK_NUM_CTX,
    FSQL_CFG_T2S_MAX_ATTEMPTS,
    FSQL_CFG_T2S_ALLOWED_STATEMENTS,
    FSQL_CFG_T2S_USE_REVIEW,
    FSQL_CFG_ENTERPRISE_LIB,
    FSQL_CFG_ENTERPRISE_LEDGER_PATH,
    FSQL_CFG_ENTERPRISE_LEDGER_KEY,
    FSQL_CFG_ENTERPRISE_REQUIRE_SIGNATURE,
    FSQL_CFG_KEY_COUNT
};

/* Value kinds, mirroring the validation each key gets. */
typedef enum {
    FSQL_CFG_TYPE_STR = 0,   /* free string, length-capped */
    FSQL_CFG_TYPE_PATH,      /* absolute path, no traversal segments */
    FSQL_CFG_TYPE_INT,       /* integer in [min,max] */
    FSQL_CFG_TYPE_BOOL,      /* true/on/1/yes vs false/off/0/no */
    FSQL_CFG_TYPE_ENUM       /* one of a '|'-separated member list */
} fsq_cfg_type;

#define FSQL_CFG_MAX_SESSIONS 256u
#define FSQL_CFG_MAX_VALUE    8192u

/* Which dispatch tier a bridge-env override applies to. The model
 * override is per-tier on purpose: the reason tier and the embed tier
 * publish their model on the SAME bridge variable, so a session's
 * reasoning_model must not silently become the embed tier's model
 * (and the other way round). */
#define FSQL_CFG_TIER_REASON 0x1u
#define FSQL_CFG_TIER_EMBED  0x2u
#define FSQL_CFG_TIER_T2S    0x4u

/* The key table: name, kind, range/member list, whether a session may
 * override it, whether the value is a secret, the bridge env var the
 * cognition/text-to-sql tiers publish it under (NULL for keys that are
 * not env-bridged), and the tiers that env variable belongs to. */
typedef struct {
    const char *key;
    fsq_cfg_type type;
    long        min;
    long        max;
    const char *enum_vals;
    bool        session_ok;
    bool        secret;
    const char *env_var;
    unsigned    env_tiers;
} fsq_cfg_key;

/* The whole table, in enum order. Read-only. */
const fsq_cfg_key *fractal_config_key_table(void);

/* Look a key up by its fractalsqld.conf name. The "fractalsql."
 * prefixed spelling is accepted too and stripped. Returns -1 when the
 * name is not a configuration key. */
int fractal_config_key_by_name(const char *name);

/* The key's bare name (no prefix), or NULL for an out-of-range id. */
const char *fractal_config_key_name(int key_id);

/* True when a session is allowed to override this key. */
bool fractal_config_key_session_ok(int key_id);

/* PATH VALIDATION (shared by the daemon's config loader and the
 * session overlay): a path key must be absolute and must contain no
 * ".." traversal segment. Returns 0 when the path is acceptable, -1
 * otherwise, with a one-line reason in `err` when `err` is non-NULL
 * and `errcap` > 0. An empty path is NOT acceptable here: a path key
 * that is present must name something (the config loader treats an
 * empty value as unset before it gets here). */
int fractal_config_validate_path(const char *path, char *err, size_t errcap);

/* SESSION OVERLAY: set one key for one session. `name` is the config
 * key name; `value` is the new value (an empty string unsets the
 * session's override). Returns 0 on success, -1 on failure with a
 * one-line reason in `err`. Refuses: an unknown key, a key a session
 * may not override, a value that fails the key's own validation, and
 * a path value that fails fractal_config_validate_path. */
int fractal_config_set_value(unsigned long long session_id, const char *name,
                       const char *value, char *err, size_t errcap);

/* Read one key's EFFECTIVE value for a session: the session's own
 * override when it has one, otherwise the process-wide value the
 * owning tier currently holds. Returns 0 and fills `out` when a value
 * was found, -1 when the key is unknown or unset. A SECRET key's value
 * is never returned: `out` receives "<redacted>" when one is set and
 * "<unset>" when it is not, so a session can see that a credential is
 * configured without ever reading it. */
int fractal_config_get_value(unsigned long long session_id, const char *name,
                       char *out, size_t outcap);

/* The session's own overrides, as a JSON object string. Returns a
 * malloc'd string the CALLER owns and must free, or NULL when the
 * render failed. The empty object "{}" means the session holds no
 * overrides, so a caller can tell "no overrides" from "render
 * failed" (NULL) -- which a fixed-size buffer could not express, since
 * the rendered length depends on how much the values escape to. */
char *fractal_config_session_json(unsigned long long session_id);

/* Drop every override one session holds. Returns the number of
 * overrides dropped. */
int fractal_config_reset_session(unsigned long long session_id);

/* CONSUMER SIDE: the session's override for `name`, if any. Returns
 * true and fills `out` when the session has one. Used by the
 * cognition and text-to-SQL tiers to layer a session's tuning over
 * the process-wide configuration. */
bool fractal_config_lookup_str(unsigned long long session_id, const char *name,
                                char *out, size_t outcap);
bool fractal_config_lookup_long(unsigned long long session_id, const char *name,
                                long *out);

/* Apply the session's overrides for the env-bridged keys onto the
 * process environment the reasoning plugin reads (the FSQL_REASONING_*
 * names). Only the keys this session actually overrides AND whose
 * `tiers` mask includes the calling tier are touched; every other
 * bridge variable is left exactly as the tier's own apply_*_env_locked
 * left it. The tier mask matters because the reason tier and the embed
 * tier publish their model on the SAME variable: without it a
 * session's reasoning_model would silently become the embed tier's
 * model.
 *
 * PRECONDITION: the caller MUST hold fractal_config_env_lock(). This
 * function WRITES to the process environment, and the environment is
 * shared by all four tiers; the env lock is what keeps another tier
 * from re-bracketing the bridge variables halfway through this
 * function's own writes. (The tier's own dispatch lock is a different
 * lock, held OUTSIDE this one -- see fractal_config_env_lock's own
 * comment for the order.) The per-session table is read through
 * fractal_config_lookup_str, which takes the overlay's own lock; that
 * happens while the env lock is held, so the order is always
 * environment-then-overlay. */
void fractal_config_apply_env_overrides(unsigned long long session_id,
                                        unsigned tiers);

/* ------------------------------------------------------------------ */
/* THE BRIDGE ENVIRONMENT                                              */
/* ------------------------------------------------------------------ */

/* The process-wide variables the reasoning plugin reads. The plugin
 * reads them ONCE, when it is loaded, and bakes them into the loaded
 * instance -- the plugin's ABI has no per-dispatch configuration
 * read, and the vendored core never reads the environment at all. So
 * the environment is a LOAD-TIME input, and every tier that loads the
 * plugin publishes its own settings into it first.
 *
 * The list is shared so the tiers cannot drift apart: the embed tier
 * brackets its own settings (save, apply, load, restore) and the
 * fingerprint below has to see exactly the same set of names. */
extern const char *const fsq_cfg_bridge_vars[];
#define FSQ_CFG_BRIDGE_VAR_COUNT 11

/* Serialises the "publish the bridge environment, then load the
 * plugin" window ACROSS ALL FOUR TIERS. The four tiers publish into
 * one process-wide environment, so without this lock a tier could load
 * the plugin with another tier's endpoint or mode baked into it. The
 * lock is a leaf: it is taken inside a tier's own dispatch lock and is
 * never held while waiting for one, so the tiers cannot deadlock
 * against each other.
 *
 * It is deliberately NOT the overlay's own lock: the overlay lock
 * guards the per-session table, this one guards the process
 * environment, and the two are always taken in that order (environment
 * first, then the overlay): a caller takes this lock, then calls
 * fractal_config_apply_env_overrides, which reads the per-session table
 * under the overlay lock. */
void fractal_config_env_lock(void);
void fractal_config_env_unlock(void);

/* A fingerprint of the bridge environment as it stands right now: an
 * FNV-1a hash over the name and value of every bridge variable. Two
 * fingerprints are equal exactly when the plugin would read the same
 * configuration from the two environments.
 *
 * SYSTEM_TAG is deliberately NOT part of the fingerprint: the
 * text-to-SQL generate tier takes it as a per-call argument, so
 * including it would reload the plugin on every call that passes a
 * different tag. The tag baked into an instance is therefore the one
 * it was loaded with -- the same behaviour the tier had before the
 * fingerprint existed, and it is refreshed whenever the tier reloads
 * for any other reason.
 *
 * PRECONDITION: the caller MUST hold fractal_config_env_lock(). The
 * fingerprint reads the process environment, and the environment is
 * shared by all four tiers: reading it without the lock can catch a
 * half-published bridge and produce a fingerprint that matches no
 * actual configuration. */
uint64_t fractal_config_env_fingerprint(void);

#ifdef __cplusplus
}
#endif

#endif /* FRACTALSQL_CONFIG_H */
