/* tests/windows/retry_reasoning_plugin_win.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Windows port of tests/retry_reasoning_plugin.c -- same deterministic
 * retry-with-feedback behavior (returns a rejected DDL statement on
 * GENERATE call 1, "SELECT 1" on call 2, exercising fractal_text_to_sql()'s
 * retry loop / `last_sql != NULL` prompt-rebuild branch) with the same
 * 2nd-call-prompt-dump-to-file mechanism the harness reads back to prove
 * the attempt-1 rejection reason was threaded into the attempt-2 prompt.
 *
 * The only difference from the Linux original is the prompt dump path:
 * the Linux file's hardcoded "/tmp/fractalsql_bt_retry_prompt.txt" does
 * not resolve to anything real on Windows (fopen("/tmp/...") targets the
 * current drive's C:\tmp, which does not exist, and fopen() fails
 * silently -- confirmed on the first real Windows run: the retry gate's
 * SQL retry itself succeeded but the harness's feedback-threading
 * assertion saw an empty file). A bare relative filename resolved
 * against the server's CWD does not work either: mariadbd.exe
 * CHDIRS TO THE DATADIR at startup (confirmed in-process: an fopen()
 * from a UDF landed at <datadir>\fractalsql_diag_log.txt while
 * Start-Process was launched from the repo root), so a relative name
 * resolves into the per-run temp datadir build_test.ps1 wipes at
 * teardown, not the repo root. So this fixture instead takes the dump
 * path from the FRACTALSQL_BT_RETRY_PROMPT_FILE environment variable,
 * which build_test.ps1's Gate-14-Retry exports (ABSOLUTE, "$Here\fractalsql_bt_retry_prompt.txt")
 * before the Swap-ReasoningPlugin restart that swaps this DLL in. getenv
 * here sees it regardless of CRT flavor and CWD. Falls back to the
 * bare relative name if unset (dev use without the harness). Must match
 * build_test.ps1's Gate-14-Retry read path exactly.
 *
 * Build (via build_test.ps1 -- do not invoke directly):
 *   cl /LD /Fe<out>\retry_reasoning.dll /I<repo>\include\windows-x86_64
 *      /I<repo>\include tests\windows\retry_reasoning_plugin_win.c
 *      /link /DEF:tests\windows\fractalsql-test-plugin.def
 */
#include "fractalsql_sql.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Fallback when the harness's env var is absent (see header). Bare
 * relative, resolved against mariadbd's CWD (the datadir). */
#define RETRY_PROMPT_FILE "fractalsql_bt_retry_prompt.txt"

/* Unlike the other test plugins' format_prompt (which return a fixed
 * dummy string since they don't care about prompt content), this one
 * passes `query` straight through -- retry_generate needs the REAL
 * GENERATE prompt fractalsql.c built (including the "Your previous
 * attempt was..." feedback text on attempt 2) to prove the retry
 * loop's feedback threading actually happened. */
static int
retry_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
             const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) c; (void) cl;
    *prompt_out = q;
    *prompt_len_out = ql;
    return 0;
}

static void
retry_free(void *opaque)
{
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if (r != NULL && r->summary != NULL)
        free(r->summary);
}

static int call_count = 0;

static int
retry_generate(void *u, const char *p, size_t pl,
               char **response_out, size_t *response_len_out,
               void (**response_free_fn_out)(void *))
{
    (void) u;
    call_count++;

    if (call_count >= 2)
    {
        const char *path = getenv("FRACTALSQL_BT_RETRY_PROMPT_FILE");
        if (path == NULL || *path == '\0')
            path = RETRY_PROMPT_FILE;
        FILE *f = fopen(path, "w");
        if (f != NULL)
        {
            fwrite(p, 1, pl, f);
            fclose(f);
        }
    }

    const char *sql = (call_count == 1) ? "DROP TABLE bt_orders" : "SELECT 1";
    size_t      len = strlen(sql);
    char       *resp = malloc(len + 16);
    if (resp == NULL)
        return -1;
    /* fractal_text_to_sql()'s GENERATE step runs under
     * FSQL_REASONING_HTTP_RESPONSE_MODE=code, where a real plugin already
     * strips the fence before generate() returns -- this mock must match
     * that contract or the retry loop's own rebuilt prompt (which echoes
     * attempt 1's candidate back verbatim) ends up double-fenced and
     * unparseable. */
    const char *response_mode = getenv("FSQL_REASONING_HTTP_RESPONSE_MODE");
    if (response_mode != NULL && strcmp(response_mode, "code") == 0)
        strcpy(resp, sql);
    else
        snprintf(resp, len + 16, "```sql\n%s\n```", sql);
    *response_out         = resp;
    *response_len_out     = strlen(resp);
    *response_free_fn_out = retry_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = retry_format;
    vfs->generate      = retry_generate;
    return 0;
}