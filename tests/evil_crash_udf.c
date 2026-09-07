/* tests/evil_crash_udf.c
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Deliberately self-crashing MariaDB UDF. Its main function writes
 * through a NULL pointer -- an unrecoverable SIGSEGV, not a bug we can
 * guard against. This matters because of MariaDB's architecture: MariaDB
 * serves every connection from one shared multithreaded server process,
 * so a single UDF call crashing mariadbd crashes the
 * WHOLE server process -- mariadbd has no built-in self-restart. The
 * goal here is to verify the server survives and comes back cleanly
 * after a UDF crash: the
 * platform-level "crash recovery contract" being tested is
 * InnoDB's own crash recovery (redo-log replay on next startup, so
 * committed data survives) PLUS whatever outer supervisor actually
 * restarts the process (mysqld_safe, systemd Restart=on-failure, or a
 * manual loop -- build_test.sh picks one; see its gate_06 comment).
 *
 * Used by build_test.sh's gate 06 (crash_recovery) to turn that
 * platform claim into something CI actually checks, rather than
 * something asserted from documentation.
 *
 * Build: cc -shared -fPIC -std=c99 tests/evil_crash_udf.c -o <tmp>/evil_crash.so
 */
#include <mysql.h>
#include <stdbool.h>
#include <string.h>

bool bt_evil_crash_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    (void) args;
    initid->maybe_null = 0;
    (void) message;
    return false;
}

void bt_evil_crash_deinit(UDF_INIT *initid)
{
    (void) initid;
}

long long bt_evil_crash(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error)
{
    (void) initid; (void) args; (void) is_null; (void) error;
    volatile long long *bad = NULL;
    *bad = 1;               /* SIGSEGV, on purpose */
    return 0;                /* unreachable */
}
