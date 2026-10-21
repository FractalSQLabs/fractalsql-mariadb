// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <cctype>
#include <cerrno>
#include <string>
#include <cstdlib>

namespace fsqlmcp
{
    static inline std::string envOr( const char* name, const std::string& def )
    {
        const char* v = std::getenv( name );
        return v ? std::string( v ) : def;
    }

    // Case-insensitive boolean env reader: true/1/on/yes (any case). Every
    // security-relevant switch (FSQL_MCP_READ_ONLY, HTTP_TLS, ...) goes
    // through this so "True" / "TRUE" / "1" cannot silently leave a
    // protection off.
    static inline bool envBoolOr( const char* name, bool def )
    {
        const char* v = std::getenv( name );
        if( !v || !*v ) return def;
        std::string s( v );
        for( char& c : s ) c = static_cast<char>( ::tolower( static_cast<unsigned char>( c ) ) );
        return s == "true" || s == "1" || s == "on" || s == "yes";
    }
    static inline int envIntOr( const char* name, int def )
    {
        const char* v = std::getenv( name );
        return v ? std::atoi( v ) : def;
    }

    // A knob that must be a whole number of at least `minValue`. Returns false, naming the variable,
    // when it is set to anything else (text, a fraction, a negative, zero where zero would admit nobody).
    // envIntOr's atoi turns "abc" into 0, and a concurrency limit of 0 makes every call wait out the
    // whole queue timeout, so those knobs are checked here instead of silently becoming a hang.
    static inline bool envIntAtLeast( const char* name, int def, int minValue, int* out, std::string* err )
    {
        const char* v = std::getenv( name );
        if( !v ) { *out = def; return true; }
        char* end = nullptr;
        errno = 0;
        const long n = std::strtol( v, &end, 10 );
        if( end == v || *end != '\0' || errno == ERANGE || n < minValue || n > 2147483647L )
        {
            *err = std::string( name ) + " must be a whole number of at least " + std::to_string( minValue )
                   + " (got '" + v + "')";
            return false;
        }
        *out = static_cast<int>( n );
        return true;
    }

    // the env-var configuration convention, MariaDB shape.
    struct EngineConfig
    {
        std::string host = "127.0.0.1";
        int         port = 3306;
        std::string user = "root";
        std::string password;
        std::string database;

        // Partial-result mode ('on', default): each session opts into the
        // engine's agent_partial_reasoning_fail mode at connect. A
        // reasoning-endpoint failure inside an agent's procedure then returns the
        // computed data half plus "reasoning_step_failed" instead of raising.
        // Anything else (e.g. 'off') keeps the engine's raise behavior.
        bool agentPartialReasoningFail = true;   // FSQL_MCP_AGENT_PARTIAL

        // FSQL_MCP_READ_ONLY=true: each session also latches the engine's
        // destructive ledger UDFs (fractal_lock_destructive) on its own
        // connection id, on top of the server's refusal of the destructiveHint
        // tools. One-way for the life of the daemon process.
        bool lockDestructive = false;            // FSQL_MCP_READ_ONLY

        // fractalsqld daemon access for the admin tier, the one place a
        // tool talks to a process OTHER than the MariaDB connection.
        std::string daemonSocket;      // FSQLCTL_SOCKET (Unix socket path or \\.\pipe\<name>)
        std::string daemonKeyPath;     // FSQLCTL_KEY (path to the hex HMAC key file)
        std::string daemonConfPath;    // FSQLCTL_CONF (fractalsqld's key=value conf file)

        static EngineConfig fromEnv()
        {
            EngineConfig c;
            c.host     = envOr( "MARIADB_HOST", "127.0.0.1" );
            c.port     = envIntOr( "MARIADB_PORT", 3306 );
            c.user     = envOr( "MARIADB_USER", "root" );
            c.password = envOr( "MARIADB_PASSWORD", "" );
            c.database = envOr( "MARIADB_DATABASE", "" );
            c.agentPartialReasoningFail =
                []( const std::string& v ) { return v.empty() || v == "on" || v == "true" || v == "1"; }(
                    envOr( "FSQL_MCP_AGENT_PARTIAL", "on" ) );
            c.lockDestructive = envBoolOr( "FSQL_MCP_READ_ONLY", false );   // same predicate as ServerConfig::readOnlyMode
            c.daemonSocket  = envOr( "FSQLCTL_SOCKET", "" );
            c.daemonKeyPath = envOr( "FSQLCTL_KEY", "" );

#ifdef _WIN32
            const std::string kDefaultConf = "C:\\ProgramData\\FractalSQL\\fractalsqld.conf";
#else
            const std::string kDefaultConf = "/etc/fractalsql/fractalsqld.conf";
#endif
            c.daemonConfPath = envOr( "FSQLCTL_CONF", kDefaultConf );
            return c;
        }
    };
}