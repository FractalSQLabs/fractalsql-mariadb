/* src/fractalsql_provider.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Provider/reasoning/embedding/think/text-to-sql/enterprise settings
 * carried from fractalsqld's config file into the translation units that
 * consume them (fractalsql_cognition.c, fractalsql_textsql.c,
 * fractalsql_enterprise.c).
 *
 * WHY THIS EXISTS: every consumer used to read its own process
 * environment variables once, lazily, on first use, cached for the
 * process lifetime -- so changing a provider token, endpoint or plugin
 * path required restarting fractalsqld. The daemon's config file
 * (fractalsqld.conf) already has a live-reload channel (FSQ_OP_RELOAD --
 * `fsqlctl reload`), so the config file is now the preferred source and
 * the daemon pushes values through the *apply_provider entry points
 * below, under each consumer's existing dispatch locks. The environment
 * variables keep working as a boot-time fallback for installs that never
 * put the keys in the config file; nothing changed for them.
 *
 * PRECEDENCE (per key, evaluated on every apply):
 *   1. A key present in fractalsqld.conf wins.
 *   2. A key absent from the config file reverts to the boot-environment
 *      fallback (the daemon's own process environment, captured once),
 *      and if the environment was silent too, the setting is unset --
 *      i.e. deleting a key from the config file and reloading takes its
 *      value back out. This is what makes token/endpoint rotation
 *      complete: no sticky last-applied value.
 *
 * WHO VALIDATES WHAT: the daemon parses and range-validates every config
 * file value LOUDLY (a bad t2s_max_attempts or think_num_ctx refuses the
 * reload with a specific message), because a file edit is a deliberate
 * act; the environment path keeps today's silent clamp defaults, because
 * that is legacy behavior. The consumers' check_provider entry points do
 * only the cross-state checks the daemon cannot know (e.g. an
 * enterprise library that is already loaded cannot be swapped --
 * restart the daemon to change it).
 *
 * APPLY CONTRACT: apply_provider runs under the consumer's own dispatch
 * lock (g_load_lock / g_ent_lock), swaps each key's value (absent keys
 * to the boot-env fallback), rolls every string back on allocation
 * failure (return -1, nothing half-applied), and clears the affected
 * tier's plugin-loaded flags so the next call in that tier re-loads the
 * plugin from the new settings. A reload NEVER attempts a plugin load
 * itself: a changed or failing plugin/lib path surfaces on the tier's
 * next UDF call, which names the path in its error, not inside the
 * reload.
 *
 * SECRETS: reasoning_token and enterprise_ledger_key are plaintext
 * credentials and must never be logged; the daemon logs only whether a
 * key is set or unset.
 */
#ifndef FRACTALSQL_PROVIDER_H
#define FRACTALSQL_PROVIDER_H

#include <stdbool.h>
#include <stdint.h>

/* Presence bits: exactly the keys the fractalsqld.conf snapshot carried.
 * A bit set but its value empty is a daemon-side parse/validation error
 * and never reaches apply. Consumers apply only the bits they own. */
#define FSQL_PROV_REASONING_PLUGIN    (1u << 0)
#define FSQL_PROV_REASONING_URL       (1u << 1)
#define FSQL_PROV_REASONING_TOKEN     (1u << 2)
#define FSQL_PROV_REASONING_MODEL     (1u << 3)
#define FSQL_PROV_REASONING_PLAINTEXT (1u << 4)
#define FSQL_PROV_EMBED_URL           (1u << 5)
#define FSQL_PROV_EMBED_MODEL         (1u << 6)
#define FSQL_PROV_THINK               (1u << 7)
#define FSQL_PROV_THINK_PROVIDER      (1u << 8)
#define FSQL_PROV_NATIVE_URL          (1u << 9)
#define FSQL_PROV_NUM_CTX             (1u << 10)
#define FSQL_PROV_T2S_MAX_ATTEMPTS    (1u << 11)
#define FSQL_PROV_T2S_ALLOWED         (1u << 12)
#define FSQL_PROV_T2S_USE_REVIEW      (1u << 13)
#define FSQL_PROV_ENT_LIB             (1u << 14)
#define FSQL_PROV_ENT_LEDGER_PATH     (1u << 15)
#define FSQL_PROV_ENT_LEDGER_KEY      (1u << 16)
#define FSQL_PROV_ENT_REQUIRE_SIG     (1u << 17)

struct fsq_provider_cfg {
    uint32_t present;   /* FSQL_PROV_* bits for keys present in the conf */

    const char *reasoning_plugin;
    const char *reasoning_url;
    const char *reasoning_token;
    const char *reasoning_model;
    bool        reasoning_allow_plaintext;
    const char *embed_url;
    const char *embed_model;

    const char *think;              /* THINK level: low|medium|high (free-form by design) */
    const char *think_provider;
    const char *think_native_url;
    const char *think_num_ctx_str;  /* decimal form of think_num_ctx: the bridge setenv()s a string */
    long        think_num_ctx;      /* daemon-validated (>= 1) */

    long        t2s_max_attempts;   /* daemon-validated [1,10] */
    const char *t2s_allowed_statements;  /* "select" | "select_insert_update" (daemon-validated) */
    bool        t2s_use_review;

    const char *enterprise_lib;
    const char *enterprise_ledger_path;
    const char *enterprise_ledger_key;
    bool        enterprise_require_signature;
};

/* check_provider: validation + cross-state refusal, read-only (no config
 * mutation). Returns 0 (apply-safe), or -1 after logging a one-line
 * reason to stderr; a -1 must refuse the whole reload. The enterprise
 * check refuses an enterprise_lib change while an enterprise library is
 * loaded (its 8 resolved symbols have no replace path); consumers with
 * no cross-state to check return 0 unconditionally. */
int fractalsql_cognition_check_provider(const struct fsq_provider_cfg *c);
int fractalsql_textsql_check_provider(const struct fsq_provider_cfg *c);
int fractalsql_enterprise_check_provider(const struct fsq_provider_cfg *c);

/* apply_provider: swap this consumer's effective settings from `c`
 * (present bits -> c's values; absent bits -> the boot-env fallback,
 * which the consumer captures from its own environment on first apply).
 * Runs under the consumer's dispatch lock, with full rollback on
 * allocation failure. Returns 0, or -1 (nothing changed; the caller must
 * refuse the reload). Never dlopens anything and never performs I/O:
 * it cannot hang the reload, and a new plugin/lib path surfaces on the
 * tier's next UDF call instead. */
int fractalsql_cognition_apply_provider(const struct fsq_provider_cfg *c);
int fractalsql_textsql_apply_provider(const struct fsq_provider_cfg *c);
int fractalsql_enterprise_apply_provider(const struct fsq_provider_cfg *c);

#endif /* FRACTALSQL_PROVIDER_H */