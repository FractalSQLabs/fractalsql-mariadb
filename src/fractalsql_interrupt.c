/* src/fractalsql_interrupt.c - implementation of the cooperative
 * cancellation seam, see fractalsql_interrupt.h.
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 */
#include "fractalsql_interrupt.h"

static fractalsql_interrupt_fn g_hook;

void fractalsql_interrupt_hook_set(fractalsql_interrupt_fn fn) {
    g_hook = fn;
}

int fractalsql_interrupt_poll(void) {
    return g_hook && g_hook();
}