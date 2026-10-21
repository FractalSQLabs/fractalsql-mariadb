/* tests/review_mode_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic plugin for the text-to-SQL tier's REVIEW-ISOLATION
 * gate. It reports WHICH FSQL_REASONING_HTTP_RESPONSE_MODE its own
 * plugin instance was born with, and nothing else:
 *
 *     FSQL_MODE=<value|(unset)>
 *     FSQL_INSTANCE=<ordinal>
 *
 * Why init-time capture is the whole point. The reasoning VFS ABI
 * (include/fractalsql_sql.h) has no per-dispatch override for the
 * response mode: the plugin reads the mode ONCE, in
 * fsql_reasoning_init, and bakes it into that instance's state for
 * the instance's whole lifetime. The real reasoning-http plugin does
 * exactly that (it copies FSQL_REASONING_HTTP_RESPONSE_MODE into its
 * per-instance http_state at init). A fixture that read the variable
 * at DISPATCH time would therefore measure the live process
 * environment -- which the daemon rewrites on every tier's call --
 * and would report the same value for every tier, hiding the very
 * thing this gate is about.
 *
 * Why per-instance state must hang off vfs->user_ctx. The engine's
 * four reasoning tiers (reason, embed, text-to-SQL generate,
 * text-to-SQL review) are four SEPARATE ctx slots, and the core's
 * loader calls fsql_reasoning_init once per ctx load -- it hands the
 * plugin a STACK-LOCAL vfs, so every ctx gets a fresh user_ctx. But
 * dlopen() of one plugin path returns ONE handle, so the plugin
 * MODULE's own globals are shared by every tier: a mode captured in a
 * plain global would be overwritten by the next tier's init and every
 * tier would report the last value. Hence the per-instance slot pool
 * below, handed out one slot per init and reached through
 * vfs->user_ctx, exactly as a real plugin's per-instance state is.
 *
 * The slot pool is static (no malloc, no exported fsql_reasoning_fini)
 * so the fixture behaves IDENTICALLY on both platforms: a Windows DLL
 * built with cl.exe exports only what its .def lists, and the shared
 * test-plugin .def exports fsql_reasoning_init alone.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/review_mode_reasoning_plugin.c -o <tmp>/review_mode_reasoning.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  include <Windows.h>  /* GetEnvironmentVariableA -- see rmp_env below */
#endif

/* How many plugin instances can be live at once. One per ctx load:
 * four tiers, plus room for the reloads a gate may trigger. The pool
 * never wraps in a single gate's lifetime. */
#define RMP_MAX_INSTANCES 16
#define RMP_MODE_MAX 64

typedef struct {
    char mode[RMP_MODE_MAX];  /* FSQL_REASONING_HTTP_RESPONSE_MODE, captured at INIT time */
    int  seq;                 /* this instance's ordinal */
} rmp_instance;

static rmp_instance g_rmp_instances[RMP_MAX_INSTANCES];
static int          g_rmp_next = 0;

/* On POSIX, getenv() is the one live view of the process environment,
 * so a plain getenv here mirrors what a real plugin reads at init
 * time. On Windows that is NOT true across CRT instances: this fixture
 * is compiled with cl.exe's default /MT (a private static-CRT environ,
 * frozen at THIS DLL's load time), while the daemon is a separate
 * static-CRT image. A getenv() read here would report the
 * environment as of the last DLL load and the gate could never observe
 * the tier-scoped unsetenv() calls (apply_review_env_locked's
 * unsetenv of RESPONSE_MODE, apply_generate_env_locked's setenv of
 * RESPONSE_MODE=code) that happen LATER in the same daemon process.
 * GetEnvironmentVariableA reads the Win32 process environment block
 * live -- the same view the daemon's _putenv_s writes land in (see
 * src/fractalsql_msvc_compat.h's shared-UCRT write), which is also
 * what a real dynamically-linked plugin's ucrtbase environ is updated
 * through. */
#ifdef _WIN32
static const char *
rmp_env(const char *name)
{
    /* Rotating slot-per-call: the value is copied out immediately, but
     * a single static buffer would still be a trap for the next
     * caller. Four slots is far more than the one variable read per
     * init; this fixture is test-only and single-threaded. */
    static char bufs[4][128];
    static unsigned slot = 0;
    char *buf = bufs[slot++ % 4];
    DWORD n = GetEnvironmentVariableA(name, buf, 128);
    return (n > 0 && n < 128) ? buf : NULL;
}
#else
#define rmp_env getenv
#endif

static int
rmp_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
            const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static const char dummy[] = "{}";

    *prompt_out = dummy;
    *prompt_len_out = sizeof(dummy) - 1;
    return 0;
}

static void
rmp_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
rmp_generate(void *u, const char *p, size_t pl,
              char **response_out, size_t *response_len_out,
              void (**response_free_fn_out)(void *))
{
    const rmp_instance *inst = (const rmp_instance *) u;
    char buf[160];
    char *resp;
    int n;

    (void) p; (void) pl;

    /* The mode is the value CAPTURED AT INIT, not the live environment
     * value -- see the file header. "(unset)" is the marker for "this
     * instance was born with no RESPONSE_MODE at all", which is what
     * the review tier must report no matter what the operator set. */
    n = snprintf(buf, sizeof buf, "FSQL_MODE=%s\nFSQL_INSTANCE=%d\n",
                 (inst != NULL && inst->mode[0] != '\0') ? inst->mode : "(unset)",
                 (inst != NULL) ? inst->seq : -1);
    if (n < 0 || (size_t) n >= sizeof buf)
        return -1;

    resp = (char *) malloc((size_t) n + 1);
    if (resp == NULL)
        return -1;
    memcpy(resp, buf, (size_t) n + 1);

    *response_out         = resp;
    *response_len_out     = (size_t) n;
    *response_free_fn_out = rmp_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    rmp_instance *inst;
    const char *mode;

    if (g_rmp_next >= RMP_MAX_INSTANCES)
        g_rmp_next = 0;   /* never reached within one gate's lifetime */
    inst = &g_rmp_instances[g_rmp_next];
    inst->seq = g_rmp_next;
    g_rmp_next++;

    /* THE MEASUREMENT: the mode in the environment at the instant this
     * instance is created -- which is the instant the engine baked it
     * into this ctx's plugin instance for good. */
    mode = rmp_env("FSQL_REASONING_HTTP_RESPONSE_MODE");
    if (mode != NULL)
        snprintf(inst->mode, sizeof inst->mode, "%s", mode);
    else
        inst->mode[0] = '\0';

    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = inst;   /* per-instance, per-ctx */
    vfs->format_prompt = rmp_format;
    vfs->generate      = rmp_generate;
    return 0;
}
