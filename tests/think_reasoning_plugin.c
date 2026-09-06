/* tests/think_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic plugin for build_test.sh's THINK-bridge gate. Doesn't
 * talk to a real reasoning-http plugin at all -- generate() reads back
 * whatever FSQL_REASONING_HTTP_THINK/THINK_PROVIDER/NATIVE_URL/NUM_CTX
 * actually landed in its own process environment and echoes them into
 * the response, one KEY=value pair per line, "(unset)" for any that
 * didn't. This proves the FRACTALSQL_HTTP_THINK* -> FSQL_REASONING_
 * HTTP_THINK* bridge in fractalsql_cognition.c/fractalsql_textsql.c
 * actually reaches the plugin, without depending on a live LLM.
 *
 * fractal_embed() and fractal_reason() share this same generate()
 * hook (fractal_embed() dispatches to whatever reasoning plugin is
 * loaded, same as fractal_reason() -- see ensure_embed_loaded() in
 * fractalsql_cognition.c), but fractal_embed() additionally runs the
 * response through parse_vector_csv() and rejects anything that isn't
 * a bare numeric CSV/JSON-array vector. So the embed-tier isolation
 * check (gate 29c) calls this plugin with the query text
 * "EMBED_PROBE"; format_prompt() below latches that into a static
 * flag generate() reads to switch its output to a 4-element numeric
 * vector (1=set, 0=unset per THINK/THINK_PROVIDER/NATIVE_URL/NUM_CTX,
 * in that order) instead of the human-readable KEY=value form the
 * fractal_reason() cases (gate 29a/29b) grep for.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/think_reasoning_plugin.c -o <tmp>/think_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_embed_probe = 0;

static int
think_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
             const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) c; (void) cl;
    static const char dummy[] = "{}";
    static const char probe_marker[] = "EMBED_PROBE";

    g_embed_probe = (ql == sizeof(probe_marker) - 1 &&
                      memcmp(q, probe_marker, ql) == 0);

    *prompt_out = dummy;
    *prompt_len_out = sizeof(dummy) - 1;
    return 0;
}

static void
think_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static const char *
env_or_unset(const char *name)
{
    const char *v = getenv(name);
    return (v != NULL) ? v : "(unset)";
}

static int
think_generate(void *u, const char *p, size_t pl,
               char **response_out, size_t *response_len_out,
               void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    char buf[512];
    int n;
    if (g_embed_probe) {
        n = snprintf(buf, sizeof buf, "%d,%d,%d,%d",
            getenv("FSQL_REASONING_HTTP_THINK")          != NULL,
            getenv("FSQL_REASONING_HTTP_THINK_PROVIDER")  != NULL,
            getenv("FSQL_REASONING_HTTP_NATIVE_URL")      != NULL,
            getenv("FSQL_REASONING_HTTP_NUM_CTX")         != NULL);
    } else {
        n = snprintf(buf, sizeof buf,
            "THINK=%s\nTHINK_PROVIDER=%s\nNATIVE_URL=%s\nNUM_CTX=%s\n",
            env_or_unset("FSQL_REASONING_HTTP_THINK"),
            env_or_unset("FSQL_REASONING_HTTP_THINK_PROVIDER"),
            env_or_unset("FSQL_REASONING_HTTP_NATIVE_URL"),
            env_or_unset("FSQL_REASONING_HTTP_NUM_CTX"));
    }
    if (n < 0 || (size_t) n >= sizeof buf)
        return -1;

    char *resp = malloc((size_t) n + 1);
    if (resp == NULL)
        return -1;
    memcpy(resp, buf, (size_t) n + 1);

    *response_out         = resp;
    *response_len_out     = (size_t) n;
    *response_free_fn_out = think_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = think_format;
    vfs->generate      = think_generate;
    return 0;
}
