// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include "mcp_json.h"
#include "errors.h"

namespace fsqlmcp::logging
{
    enum class Level { Error = 10, Info = 5, Debug = 20 };

    struct Config
    {
        Level level = Level::Info;    // FSQL_MCP_LOG_LEVEL=normal|verbose -> Info|Debug
    };

    void init( const Config& cfg );

    // One JSON-line to stderr per tool call. argsRedacted is the already-
    // capped/redacted copy (see redactAndCap below), callers must not pass
    // raw caller-supplied arguments here.
    //
    // era names the protocol era the call arrived in ("legacy" or "modern");
    // an empty era is left out of the line.
    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                    double latencyMs, const char* errorClassOrNull,
                    const std::string& clientKey = std::string(),
                    const std::string& era = std::string() );

    // Admin-tool config changes: logs old+new value explicitly.
    void configChange( std::string_view key, std::string_view oldValueRedacted,
                        std::string_view newValueRedacted );

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail );

    // Free-form server-side event line: one {"event":"info",...}, stderr.
    void logInfo( std::string_view message );

    // A named server-side event: one JSON line whose "event" field is the
    // given name, with the given fields merged in. Used for the refusals and
    // the lifecycle events an operator reads the trail for.
    void event( std::string_view name, const Json& fields = Json() );

    // the capping/redaction rules: arrays -> "<array len=N sha256_8=XXXXXXXX>",
    // long strings -> "<str len=N sha256_8=XXXXXXXX>", any key ending in
    // token/password/key/secret (case-insensitive) -> "***", recursing at
    // most 2 levels. Returns a NEW json value; never mutates the input.
    Json redactAndCap( const Json& args, int depth = 0 );
}