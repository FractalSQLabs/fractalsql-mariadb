/* tests/scripted_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Reasoning plugin whose every reply is scripted by the test. generate()
 * reads the file named by FSQL_SCRIPTED_REPLY each time it is called, so one
 * running daemon can be walked through many replies by rewriting that file
 * between calls. The file is the reply, byte for byte, unless its first line
 * is a directive:
 *
 *     @rc=N       generate() fails with return code N
 *     @null       generate() succeeds but returns no summary at all
 *     @size=N     the reply is N bytes of 'a' (for the response size limit)
 *
 * A missing or unreadable file is an empty reply. format_prompt() returns a
 * fixed short prompt: the tests are about what the engine does with the
 * reply, not about the prompt.
 *
 * Test-harness use only; never shipped.
 *
 * Build: cc -shared -fPIC -std=c99 -Iinclude \
 *          tests/scripted_reasoning_plugin.c -o <tmp>/scripted_reasoning.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int
srp_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
           const char **prompt_out, size_t *prompt_len_out)
{
    static const char prompt[] = "{}";
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    *prompt_out = prompt;
    *prompt_len_out = sizeof(prompt) - 1;
    return 0;
}

/* The engine hands back the response record it built around the reply,
 * not the reply buffer itself. */
static void
srp_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int
srp_generate(void *u, const char *p, size_t pl,
             char **response_out, size_t *response_len_out,
             void (**response_free_fn_out)(void *))
{
    const char *path = getenv("FSQL_SCRIPTED_REPLY");
    char *buf = NULL;
    size_t len = 0;
    FILE *f;

    (void) u; (void) p; (void) pl;

    if (path != NULL && (f = fopen(path, "rb")) != NULL) {
        size_t cap = 4096;
        buf = (char *) malloc(cap);
        if (buf == NULL) { fclose(f); return -1; }
        for (;;) {
            size_t n = fread(buf + len, 1, cap - len, f);
            len += n;
            if (len < cap) break;
            cap *= 2;
            {
                char *nb = (char *) realloc(buf, cap);
                if (nb == NULL) { free(buf); fclose(f); return -1; }
                buf = nb;
            }
        }
        fclose(f);
        /* The @rc= and @size= parsers below read past the digits. */
        if (len == cap) {
            char *nb = (char *) realloc(buf, cap + 1);
            if (nb == NULL) { free(buf); return -1; }
            buf = nb;
        }
        buf[len] = '\0';
    } else {
        buf = (char *) malloc(1);
        if (buf == NULL) return -1;
    }

    if (len >= 4 && strncmp(buf, "@rc=", 4) == 0) {
        int rc = atoi(buf + 4);
        free(buf);
        return rc;
    }
    if (len >= 5 && strncmp(buf, "@null", 5) == 0) {
        free(buf);
        *response_out = NULL;
        *response_len_out = 0;
        *response_free_fn_out = srp_free;
        return 0;
    }
    if (len >= 6 && strncmp(buf, "@size=", 6) == 0) {
        size_t want = (size_t) strtoull(buf + 6, NULL, 10);
        char *big = (char *) malloc(want + 1);
        free(buf);
        if (big == NULL) return -1;
        memset(big, 'a', want);
        big[want] = '\0';
        *response_out = big;
        *response_len_out = want;
        *response_free_fn_out = srp_free;
        return 0;
    }

    buf = (char *) realloc(buf, len + 1);
    if (buf == NULL) return -1;
    buf[len] = '\0';
    *response_out = buf;
    *response_len_out = len;
    *response_free_fn_out = srp_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = srp_format;
    vfs->generate      = srp_generate;
    return 0;
}
