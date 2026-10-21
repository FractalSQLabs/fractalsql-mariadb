/* tests/slow_reasoning_plugin.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deterministic, artificially-slow reasoning plugin: generate() sleeps
 * FSQL_MOCK_SLOW_MS milliseconds (default 3000) before returning a
 * canned chat-tier response. Lets a test hold an MCP request "in
 * flight" (the server's activeRequestCount() > 0, the HTTP
 * connection's own thread still live) for a controlled, known duration
 * -- the only way to deterministically exercise the MCP HTTP
 * transport's shutdown drain-wait loop (activeRequestCount()>0 ...
 * sleep_for) and the live-connections grace-wait loop that follows it:
 * both are a no-op unless a real request is still being processed at
 * the exact moment SIGTERM arrives, which is normally a
 * sub-millisecond race.
 *
 * Test-harness use only; never shipped. Build:
 *   cc -shared -fPIC -std=c99 -Iinclude \
 *      tests/slow_reasoning_plugin.c -o <tmp>/slow_reasoning_plugin.so
 */
#define _POSIX_C_SOURCE 200809L

#include "fractalsql_sql.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#  include <Windows.h>  /* Sleep() -- see slow_sleep_ms below */
#endif

/* Sleeps for ms milliseconds, in a way that actually works on both
 * platforms. On Windows, Sleep() takes a DWORD and is a real
 * suspension of the calling thread (the fixture is called from the
 * daemon's own worker thread, so the point is to hold THAT thread
 * busy, not to spin). On POSIX, nanosleep() with the remainder
 * threaded through a loop so a signal (the harness sends SIGTERM to
 * the daemon, and this plugin runs inside it) does not cut the sleep
 * short. */
static void
slow_sleep_ms(long ms)
{
    if (ms <= 0)
        return;
#ifdef _WIN32
    Sleep( (DWORD) ms );
#else
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    while ( nanosleep( &ts, &ts ) == -1 )
        ;   /* errno == EINTR: ts now holds the remaining time */
#endif
}

/* FSQL_MOCK_SLOW_MS: how long generate() sleeps. Read live from the
 * process environment on both platforms -- on Windows a getenv() read
 * from this statically-linked CRT would report the environment as of
 * this DLL's load time, not the live Win32 environment block, so use
 * GetEnvironmentVariableA there (same reasoning as think_env() in
 * tests/think_reasoning_plugin.c). */
static long
slow_env_ms(void)
{
#ifdef _WIN32
    char buf[32];
    DWORD n = GetEnvironmentVariableA( "FSQL_MOCK_SLOW_MS", buf, sizeof( buf ) );
    if ( n == 0 || n >= sizeof( buf ) )
        return 3000;
    buf[ n ] = '\0';
    return atol( buf );
#else
    const char *env = getenv( "FSQL_MOCK_SLOW_MS" );
    if ( env == NULL || env[ 0 ] == '\0' )
        return 3000;
    return atol( env );
#endif
}

static int
slow_format(void *u, const char *q, size_t ql, const char *c, size_t cl,
            const char **prompt_out, size_t *prompt_len_out)
{
    (void) u; (void) q; (void) ql; (void) c; (void) cl;
    static char b[ 2 ] = { 'x', '\0' };
    *prompt_out = b;
    *prompt_len_out = 1;
    return 0;
}

static void
slow_free(void *opaque)
{
    /* The engine hands the free_fn the wrapping fsql_ai_response_t *
     * cast to void * -- the struct is caller-owned, only the summary
     * string inside it is ours to release. */
    fsql_ai_response_t *r = (fsql_ai_response_t *) opaque;
    if ( r != NULL && r->summary != NULL )
        free( r->summary );
}

static int
slow_generate(void *u, const char *p, size_t pl,
              char **response_out, size_t *response_len_out,
              void (**response_free_fn_out)(void *))
{
    (void) u; (void) p; (void) pl;

    slow_sleep_ms( slow_env_ms() );

    static const char kResp[] = "slow-plugin-canary";
    char *resp = malloc( sizeof kResp );
    if ( resp == NULL )
        return -1;
    memcpy( resp, kResp, sizeof kResp );
    *response_out         = resp;
    *response_len_out     = sizeof( kResp ) - 1;
    *response_free_fn_out = slow_free;
    return 0;
}

int
fsql_reasoning_init(fsql_reasoning_vfs_t *vfs)
{
    vfs->abi_version   = FSQL_REASONING_ABI_VERSION;
    vfs->user_ctx      = NULL;
    vfs->format_prompt = slow_format;
    vfs->generate      = slow_generate;
    return 0;
}
