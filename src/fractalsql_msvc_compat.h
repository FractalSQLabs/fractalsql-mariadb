/* src/fractalsql_msvc_compat.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Minimal MSVC compatibility shims for the POSIX names this extension's
 * own translation units call directly. Included by every src\*.c TU that
 * uses the shimmed names (fractalsql_cognition.c, fractalsql_textsql.c,
 * fractalsql_session.c, fractalsql_enterprise.c) -- one definition here
 * instead of duplicated blocks per TU, following src\'s existing
 * shared-header pattern (fractalsql_session.h, fractalsql_parse.h).
 *
 * MSVC has no POSIX setenv()/unsetenv(), and neither the UCRT nor the
 * vendored community-sovereign-c.lib carries them (confirmed directly:
 * LNK2001 on both at link time on the first real Windows run). Wrap the
 * CRT's _putenv_s(), which updates BOTH the CRT environment and the Win32
 * process environment block -- exactly what the call sites need, since
 * the reasoning plugin (fractalsql-reasoning-http.dll, loaded into this
 * same process) reads every FSQL_REASONING_HTTP_* variable back with
 * getenv() at its own load time. _putenv_s(name, "") deletes the
 * variable, matching unsetenv()'s effect.
 *
 * THE DYNAMIC-CRT READER PROBLEM, confirmed in-process on the first real
 * Windows gate run (11.4): mariadbd.exe is dynamically linked to the UCRT
 * (dumpbin /DEPENDENTS: VCRUNTIME140.dll + api-ms-win-crt-*), so
 * ucrtbase.dll initializes at PROCESS START and seeds its environment
 * block from the process env as of that instant. A plain _putenv_s() call
 * from THIS DLL's /MT-static CRT updates the static CRT's private environ
 * and (UCRT's one-way sync) the Win32 process block -- but ucrtbase's
 * ALREADY-INITIALIZED environ never re-reads the Win32 block, so
 * getenv() in any module linked against the DYNAMIC UCRT -- the vendored
 * fractalsql-reasoning-http.dll is exactly such a module (its import
 * table lists the ucrt api-sets) -- sees only the stale at-start values.
 * Net effect with _putenv_s alone: the bridge ran, the plugin loaded,
 * and fsql_reasoning_init() returned -2 ("FSQL_REASONING_HTTP_URL not
 * set", per the plugin's own stderr string) with no HTTP request ever
 * attempted -- the whole FRACTALSQL_HTTP_* -> FSQL_REASONING_HTTP_*
 * bridge was dead inside mariadbd while every /MT fixture (cl.exe's
 * default /MT, whose private CRT environ is seeded at ITS DLL load time,
 * i.e. after the bridge) still saw the bridged values, which is why the
 * fixture-swap gates (29 think) kept passing while the real-plugin gates
 * (04/13/15/17/18/23/24 route/29c) returned NULL.
 *
 * Fix: after the static-CRT write, ALSO write the same variable through
 * ucrtbase.dll's OWN exported _putenv_s (resolved via GetProcAddress),
 * when ucrtbase is loaded into this process. That updates the shared
 * UCRT environ the dynamic-CRT plugin's getenv() reads -- and ucrtbase's
 * _putenv_s keeps its own Win32-sync behavior, so the two writes agree
 * on the process block too. GetModuleHandleW (not LoadLibrary) so a
 * fully-static process never pulls ucrtbase in merely by bridging; when
 * it returns NULL there is no dynamic-CRT reader to serve. Resolved per
 * call (no init-once caching): GetProcAddress is ~tens of ns and the
 * bridge runs under the load lock anyway (see the race note below), so
 * the extra indirection is not worth a static-state dance in a header.
 *
 * Guarded on _MSC_VER only, so a MinGW gcc build keeps the real POSIX
 * functions. Call sites already serialize the whole
 * setenv+fsql_load_reasoning step under the process-wide lock (see
 * fractalsql_cognition.c's "THE setenv() RACE" comment), so the shims
 * introduce no new race.
 */

#ifndef FRACTALSQL_MSVC_COMPAT_H
#define FRACTALSQL_MSVC_COMPAT_H

#include <stdlib.h>  /* getenv, _putenv_s -- idempotent; don't rely on the includer */
#include <string.h>  /* strdup/_strdup declarations for the macro below */

/* GetModuleHandleW / GetProcAddress for the shared-UCRT write below.
 * Every includer of this header already includes <windows.h> first
 * (fractalsql_cognition.c / fractalsql_textsql.c / fractalsql_session.c
 * all do, under the same _WIN32 guard); this is idempotent armor, not a
 * new dependency, so the header stays safe standalone. */
#if defined(_WIN32)
#  include <windows.h>
#endif

#if defined(_MSC_VER)

/* strdup: the POSIX name exists in the UCRT but is marked deprecated
 * (_CRT_NONSTDC_DEPRECATE), which clang-cl surfaces as
 * -Wdeprecated-declarations on every call site. _strdup is the same
 * CRT function under its ISO-conformant spelling, so a macro rename
 * changes nothing at runtime. POSIX spellings stay on MinGW (no
 * _MSC_VER) and everywhere else. */
#define strdup _strdup

#endif /* _MSC_VER */

#if defined(_MSC_VER) && !defined(HAVE_SETENV)

/* ucrtbase.dll's own _putenv_s -- the one that updates the environ block
 * shared by every DYNAMICALLY-linked UCRT module in this process, i.e.
 * the view the vendored reasoning plugin's getenv() reads. Not declared
 * in any header we ship; resolved dynamically below. static inline
 * rather than plain static so a TU that includes this header for one
 * shim but calls neither setenv() nor unsetenv() (fractalsql_enterprise.c
 * wants only the strdup rename) doesn't earn -Wunused-function for the
 * other two. */
typedef int (__cdecl *fsql_ucrt_putenv_s_fn)(const char *, const char *);

static inline void
fsql_putenv_shared_ucrt(const char *name, const char *value)
{
    HMODULE ucrt;
    fsql_ucrt_putenv_s_fn putenv_s;

    ucrt = GetModuleHandleW(L"ucrtbase.dll");
    if (ucrt == NULL) return;  /* no dynamic-CRT reader in this process */
    putenv_s = (fsql_ucrt_putenv_s_fn) (void *) GetProcAddress(ucrt, "_putenv_s");
    if (putenv_s != NULL) putenv_s(name, value);
}

static inline int
setenv(const char *name, const char *value, int overwrite)
{
    if (!overwrite && getenv(name) != NULL) return 0;
    if (_putenv_s(name, value) != 0) return -1;
    fsql_putenv_shared_ucrt(name, value);
    return 0;
}

static inline int
unsetenv(const char *name)
{
    if (_putenv_s(name, "") != 0) return -1;
    fsql_putenv_shared_ucrt(name, "");
    return 0;
}

#endif /* _MSC_VER && !HAVE_SETENV */

#endif /* FRACTALSQL_MSVC_COMPAT_H */