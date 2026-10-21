// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include "tool_registry.h"

namespace fsqlmcp
{
    // Terse constructors so the tool table stays one line per param.
    inline ToolParam Vec( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Array, req, def, d }; }
    // A matrix parameter: an array whose items are themselves arrays (one point per entry).
    inline ToolParam Mat( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Array, req, def, d, false, JsonType::Array }; }
    inline ToolParam Str( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::String, req, def, d }; }
    inline ToolParam Int( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Integer, req, def, d }; }
    inline ToolParam Num( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Number, req, def, d }; }
    inline ToolParam Bool_( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Boolean, req, def, d }; }
    inline ToolParam Obj( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Object, req, def, d }; }
    inline ToolParam NullableNum( std::string_view n, std::string_view d )
    { return ToolParam{ n, JsonType::Number, false, nullptr, d, true }; }
    inline ToolParam NullableStr( std::string_view n, std::string_view d )
    { return ToolParam{ n, JsonType::String, false, nullptr, d, true }; }
    inline ToolParam IntArray( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Array, req, def, d, false, JsonType::Integer }; }
    inline ToolParam StrArray( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::Array, req, def, d, false, JsonType::String }; }
    inline ToolParam StrEnum( std::string_view n, bool req, std::string_view d, Json def = nullptr )
    { return ToolParam{ n, JsonType::String, req, def, d }; }   // allowed values documented in d; handler enforces
    inline ToolParam RowLimit()
    { return ToolParam{ "limit", JsonType::Integer, false, 100,
        "Maximum rows to return (default 100, hard ceiling FSQL_MCP_MAX_ROWS_CEILING, default 1000). "
        "A result that would have exceeded this carries truncated:true and total_scanned." }; }
}