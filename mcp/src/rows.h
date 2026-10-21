// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include "mcp_json.h"
#include "errors.h"
#include <string_view>

namespace fsqlmcp
{
    struct RowLimitConfig
    {
        int maxRowsCeiling = 1000;   // FSQL_MCP_MAX_ROWS_CEILING
    };

    // The ceiling/limit arithmetic and the truncation envelope live in
    // helpers.h (effectiveLimit / truncateResult / RowLimit()) -- the one
    // shared implementation every adapter calls (one shared helper,
    // never per-adapter copies). This header keeps the config type the
    // builders pass around.
}