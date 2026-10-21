// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include "mcp_json.h"

namespace fsqlmcp
{
    class Db;
    struct EngineConfig;

    // MCP resources (section 3): read-only, URI-addressable context. The URIs
    // are identical across the plugin suite (each plugin serves only its own
    // engine) so an operator registering several engines sees one same-named
    // resource per server, as MCP's per-server resource namespacing expects.
    class Resources
    {
    public:
        // stdio/engine-wide binding. HTTP sessions bind per thread instead
        // (bindThreadDb), one dedicated Db per Mcp-Session-Id, never shared.
        static void setEngineDb( Db* db );
        static void setEngineConfig( const EngineConfig& cfg );
        static void bindThreadDb( Db* db );

        static Json list();
        static Json templates();
        static Json read( const std::string& uri );
    };
}