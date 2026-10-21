// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <fstream>
#include <algorithm>
#include <atomic>
#ifdef _WIN32
  #include <io.h>
  #include <fcntl.h>
#endif
#include "jsonrpc_server.h"
#include "transport_stdio.h"
#include "transport_http.h"
#include "schema_lock.h"
#include "safety_lock.h"
#include "logging.h"
#include "lock_paths.h"
#include "policy.h"
#include "config.h"
#include "db.h"
#include "fsqlctl.h"
#include "resources.h"
#include "version.h"

using namespace fsqlmcp;

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAllTools( Db& db, const EngineConfig& ecfg, const RowLimitConfig& rowCfg );
}

static std::vector<std::string> splitCsv( const std::string& s )
{
    std::vector<std::string> out;
    std::string cur;
    for( char c : s )
    {
        if( c == ',' ) { if( !cur.empty() ) out.push_back( cur ); cur.clear(); }
        else cur.push_back( c );
    }
    if( !cur.empty() ) out.push_back( cur );
    return out;
}

// The catalog narrowing: keep only the tools in the enabled categories
// AND (when a whitelist is given) the tools named in it. An empty
// filter on either axis means "no restriction on that axis".
//
// This is applied to EVERY catalog this process serves -- the one the
// schema lock hashes and the one the stdio server serves, and equally
// the one each HTTP session's server serves. Applying it in one place
// and not the other is what lets an operator's narrowing be certified
// by the lock and then ignored on the wire.
static void applyCatalogFilters( std::vector<ToolSpec>& tools,
                                 const std::vector<std::string>& enabledCategories,
                                 const std::vector<std::string>& toolWhitelist )
{
    if( enabledCategories.empty() && toolWhitelist.empty() ) return;
    std::vector<ToolSpec> filtered;
    filtered.reserve( tools.size() );
    for( ToolSpec& t : tools )
    {
        const bool catOk = enabledCategories.empty() ||
            std::find( enabledCategories.begin(), enabledCategories.end(), std::string( t.category ) ) != enabledCategories.end();
        const bool nameOk = toolWhitelist.empty() ||
            std::find( toolWhitelist.begin(), toolWhitelist.end(), std::string( t.name ) ) != toolWhitelist.end();
        if( catOk && nameOk ) filtered.push_back( std::move( t ) );
    }
    tools = std::move( filtered );
}

static void usage()
{
    std::cout
        << "fractalsql-mariadb-mcp " FSQL_MCP_VERSION "\n"
        << "Model Context Protocol server for FractalSQL on MariaDB.\n\n"
        << "Usage: fractalsql-mariadb-mcp [--http PORT] [--bind ADDR] [--tool a,b,c] [--category x,y]\n"
        << "                              [--host ADDR] (alias for --bind)\n"
        << "                              [--write-schema-lock] [--write-safety-annotations-lock]\n"
        << "                              [--write-manifest] [--schema-lock-path P] [--list-tools]\n\n"
        << "Default transport is newline-delimited JSON-RPC over stdio (1.1).\n\n"
        << "Connection: MARIADB_HOST / MARIADB_PORT / MARIADB_USER / MARIADB_PASSWORD / MARIADB_DATABASE\n"
        << "Admin tier: FSQLCTL_SOCKET / FSQLCTL_KEY / FSQLCTL_CONF (fractalsqld daemon, 5.2)\n\n"
        << "Knobs: FSQL_MCP_MAX_ROWS_CEILING, FSQL_MCP_MAX_CONCURRENT_CHEAP, FSQL_MCP_MAX_CONCURRENT_EXPENSIVE,\n"
        << "       FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT, FSQL_MCP_MAX_QUEUE_WAIT_MS,\n"
        << "       FSQL_MCP_SHUTDOWN_DRAIN_MS, FSQL_MCP_LOG_LEVEL=normal|verbose, FSQL_MCP_READ_ONLY,\n"
        << "       FSQL_MCP_TOOL_WHITELIST, FSQL_MCP_ENABLED_CATEGORIES, FSQL_MCP_STRICT_SCHEMA_HASH,\n"
        << "       FSQL_MCP_AGENT_PARTIAL=on|off (per-session agent partial-reasoning opt-in, default on),\n"
        << "       FSQL_MCP_AUTH_TOKEN / FSQL_MCP_AUTH_TOKEN_FILE / FSQL_MCP_TOKEN_POLICY_FILE (--http mode only)\n"
        << "       FSQL_MCP_ALLOWED_ORIGINS (--http mode only, comma-separated)\n"
        << "       FSQL_MCP_PROTOCOL_ERA=dual|modern, FSQL_MCP_CONFIG_WRITES=off|safe|all,\n"
        << "       FSQL_MCP_ALLOW_AUTO_EXECUTE (deployment policy switches)\n"
        << "       FSQL_MCP_HTTP_PATH (--http mode only, default /mcp)\n"
        << "       FSQL_MCP_HTTP_TLS=1 with FSQL_MCP_TLS_CERT / FSQL_MCP_TLS_KEY (--http mode)\n";
}

// All of main()'s command-line state, parsed by parseArgs() below.
struct CliArgs
{
    bool writeLock = false, writeSafetyLock = false, writeManifest = false, listTools = false;
    bool httpMode = false;
    int  httpPort = 8765;
    std::string httpBind, lockPath, safetyLockPath, manifestPath;
    std::vector<std::string> toolWhitelist, enabledCategories;
};

// Parses argv into args. Returns true iff the process must exit right
// now with exitCode (--help, --version, an unknown flag, or a flag
// missing its value exits via std::exit(2) from inside next()); false
// means argument parsing succeeded and the caller should keep going.
static bool parseArgs( int argc, char** argv, CliArgs& args, int& exitCode )
{
    for( int i = 1; i < argc; ++i )
    {
        const std::string arg( argv[ i ] );
        auto next = [ & ]( const char* flagName ) -> std::string {
            if( i + 1 >= argc )
            {
                std::cerr << "missing value for " << flagName << "\n";
                std::exit( 2 );
            }
            return std::string( argv[ ++i ] );
        };
        if( arg == "--write-schema-lock" ) args.writeLock = true;
        else if( arg == "--write-safety-annotations-lock" ) args.writeSafetyLock = true;
        else if( arg == "--write-manifest" ) args.writeManifest = true;
        else if( arg == "--list-tools" ) args.listTools = true;
        else if( arg == "--schema-lock-path" ) args.lockPath = next( "--schema-lock-path" );
        else if( arg == "--tool" ) args.toolWhitelist = splitCsv( next( "--tool" ) );
        else if( arg == "--category" ) args.enabledCategories = splitCsv( next( "--category" ) );
        else if( arg == "--http" )
        {
            args.httpMode = true;
            if( i + 1 < argc && argv[ i + 1 ][ 0 ] != '-' ) args.httpPort = std::atoi( argv[ ++i ] );
        }
        else if( arg == "--bind" || arg == "--host" ) args.httpBind = next( arg.c_str() );
        else if( arg == "--help" || arg == "-h" ) { usage(); exitCode = 0; return true; }
        else if( arg == "--version" )
        {
            std::cout << FSQL_MCP_VERSION << "\n";
            exitCode = 0;
            return true;
        }
        else
        {
            std::cerr << "unknown argument '" << arg << "' (try --help)\n";
            exitCode = 2;
            return true;
        }
    }
    return false;
}

// FSQL_MCP_AGENT_PARTIAL: 'on' (default) opts each session into the
// engine's partial-result honesty mode. A reasoning-endpoint failure
// inside an agent's scalar call returns the computed data half plus
// "reasoning_step_failed" instead of raising. Anything else (e.g.
// 'off') keeps the engine's documented raise behavior.
static bool agentPartialEnabled( const std::string& v )
{
    return v.empty() || v == "on" || v == "true" || v == "1";
}

// The --write-schema-lock / --write-safety-annotations-lock /
// --write-manifest / --list-tools one-shot paths: at most one applies
// (checked in this exact order, matching the original inline chain),
// each prints its own thing and the process exits immediately after.
// Returns the exit code, or -1 if none of the flags were set (meaning:
// keep going and actually serve).
static int maybeRunOneShot( const CliArgs& args, const std::vector<ToolSpec>& tools,
                            const std::string& hash )
{
    if( args.writeLock )
    {
        writeSchemaLock( args.lockPath, hash );
        std::cout << "wrote " << args.lockPath << "\n";
        return 0;
    }
    if( args.writeSafetyLock )
    {
        writeSafetyAnnotations( args.safetyLockPath, renderSafetyAnnotations( tools ) );
        std::cout << "wrote " << args.safetyLockPath << "\n";
        return 0;
    }
    if( args.writeManifest )
    {
        Json toolsJson = Json::array();
        for( const ToolSpec& t : tools )
            toolsJson.push_back( Json{ { "name", std::string( t.name ) },
                                        { "description", std::string( t.description ) } } );
        Json manifest{
            { "name", FSQL_MCP_PROTOCOL_NAME }, { "version", FSQL_MCP_VERSION },
            { "server", { { "type", "binary" }, { "entry_point", FSQL_MCP_PROTOCOL_NAME } } },
            { "tools", toolsJson }
        };
        std::ofstream( args.manifestPath ) << manifest.dump( 2 ) << "\n";
        std::cout << "wrote " << args.manifestPath << "\n";
        return 0;
    }
    if( args.listTools )
    {
        for( const ToolSpec& t : tools )
            std::cout << t.name << " (" << ( t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" ) << ","
                      << ( t.retryTier ? *t.retryTier : "-" ) << ")\n";
        return 0;
    }
    return -1;
}

// the safety-annotation check is a HARD mismatch (exit 3),
// regardless of FSQL_MCP_STRICT_SCHEMA_HASH. Returns 0 to continue
// serving, 3 on a hard mismatch.
static int checkSafetyGate( const std::string& safetyLockPath, const std::vector<ToolSpec>& tools )
{
    if( !lockFileExists( safetyLockPath ) )
    {
        if( requireLocks() )
        {
            std::cerr << "ERROR: safety-annotation lock '" << safetyLockPath << "' is missing; refusing to start without "
                      << "the tool-annotation drift check (generate it with --write-safety-annotations-lock, or set "
                      << "FSQL_MCP_ALLOW_MISSING_LOCKS=true to run without it)\n";
            return 3;
        }
        std::cerr << "WARN: safety-annotation lock '" << safetyLockPath << "' not found; the tool-annotation drift check is skipped\n";
    }
    std::string diff;
    if( !checkSafetyAnnotations( safetyLockPath, renderSafetyAnnotations( tools ), &diff ) )
    {
        std::cerr << "ERROR: safety-annotation regression: this build's destructive/readOnly/idempotent "
                  << "hints differ from the committed " << safetyLockPath
                  << "; review the diff and regenerate with --write-safety-annotations-lock:\n" << diff;
        return 3;
    }
    return 0;
}

// the schema-lock check warns by default and hard-fails (exit 2)
// when strict. Returns 0 to continue serving, 2 on a strict-mode hard
// fail.
static int checkSchemaGate( const std::string& lockPath, const std::string& hash )
{
    std::string expected;
    const LockCheckResult lockResult = checkSchemaLock( lockPath, hash, &expected );
    if( lockResult == LockCheckResult::Absent )
    {
        if( requireLocks() )
        {
            std::cerr << "ERROR: schema lock '" << lockPath << "' is missing; refusing to start without the tool-surface "
                      << "drift check (generate it with --write-schema-lock, or set FSQL_MCP_ALLOW_MISSING_LOCKS=true to run without it)\n";
            return 2;
        }
        std::cerr << "WARN: schema lock '" << lockPath << "' not found; the tool-surface drift check is skipped\n";
    }
    const bool strict = envBoolOr( "FSQL_MCP_STRICT_SCHEMA_HASH", true );
    if( lockResult == LockCheckResult::Warn )
    {
        std::cerr << "WARN: schema hash mismatch: lock file has " << expected << ", this build computes "
                  << hash << " (regenerate with --write-schema-lock; see 10.5)\n";
        if( strict ) return 2;
    }
    return 0;
}

// Builds the HttpConfig from CliArgs/env and runs the HTTP transport
// (this call does not return until shutdown). Returns 2 on a config
// error (missing auth token), matching the original inline behavior.
static int runHttpMode( JsonRpcServer& server, const CliArgs& args, const EngineConfig& ecfg,
                        const RowLimitConfig& rowCfg, const ServerConfig& sessionCfg,
                        const ConcurrencyConfig& concCfg )
{
    HttpConfig httpCfg;
    // The resources tier reads the daemon's socket/key/conf paths from the
    // engine config (the fractalsql://config resource reports the daemon's
    // own protocol string and its non-secret config surface). The stdio
    // and HTTP paths both publish that config to Resources so the resource
    // reads the right conf file and reports the daemon's real state.
    Resources::setEngineConfig( ecfg );
    httpCfg.host = args.httpBind;
    httpCfg.port = args.httpPort;
    httpCfg.path = envOr( "FSQL_MCP_HTTP_PATH", "/mcp" );
    httpCfg.authToken    = envOr( "FSQL_MCP_AUTH_TOKEN", "" );
    httpCfg.authTokenFile = envOr( "FSQL_MCP_AUTH_TOKEN_FILE", "" );
    httpCfg.tokenPolicyFile = envOr( "FSQL_MCP_TOKEN_POLICY_FILE", "" );
    httpCfg.allowedOrigins = splitCsv( envOr( "FSQL_MCP_ALLOWED_ORIGINS", "" ) );
    httpCfg.tlsEnabled   = envBoolOr( "FSQL_MCP_HTTP_TLS", false );
    httpCfg.tlsCertPath  = envOr( "FSQL_MCP_TLS_CERT", "" );
    httpCfg.tlsKeyPath   = envOr( "FSQL_MCP_TLS_KEY", "" );
    httpCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
    if( httpCfg.authToken.empty() && httpCfg.authTokenFile.empty() && httpCfg.tokenPolicyFile.empty() )
    {
        std::cerr << "the HTTP transport requires FSQL_MCP_AUTH_TOKEN, "
                     "FSQL_MCP_AUTH_TOKEN_FILE or FSQL_MCP_TOKEN_POLICY_FILE\n";
        return 2;
    }
    // A per-client credential file that cannot be read or parsed is a
    // STARTUP failure, never a silent "no authentication": the operator
    // asked for named clients and would otherwise get an open server.
    {
        const std::string policyErr = tokenPolicyError( httpCfg );
        if( !policyErr.empty() )
        {
            std::cerr << "ERROR: " << policyErr << "\n";
            return 2;
        }
    }
    if( httpCfg.tlsEnabled && ( httpCfg.tlsCertPath.empty() || httpCfg.tlsKeyPath.empty() ) )
    {
        std::cerr << "the HTTP transport with TLS requires FSQL_MCP_TLS_CERT and "
                     "FSQL_MCP_TLS_KEY\n";
        return 2;
    }
    // one dedicated DB connection per HTTP session, never reused across
    // sessions, each new Mcp-Session-Id gets a fresh Db + fresh tool set, and
    // the server's statePin frees the Db (closing that session's socket) on
    // session teardown. The requestHook binds the session's Db to the
    // dispatching thread so resources read through the right connection.
    //
    // The session's catalog gets the SAME narrowing the process-wide
    // catalog got. An operator who restricted the tool set must not find
    // the whole set back on the wire just because the client speaks HTTP:
    // the schema lock certifies the NARROWED catalog, so a session that
    // serves the full one contradicts it.
    const std::vector<std::string> sessionCategories = args.enabledCategories;
    const std::vector<std::string> sessionWhitelist = args.toolWhitelist;
    httpCfg.sessionFactory = [ ecfg, rowCfg, sessionCfg, concCfg,
                               sessionCategories, sessionWhitelist ]() -> std::unique_ptr<JsonRpcServer>
    {
        std::shared_ptr<Db> db2 = std::make_shared<Db>();
        db2->connect( ecfg );    // Connectivity raises through with its clean message
        auto tools2 = buildAllTools( *db2, ecfg, rowCfg );
        applyDerivedHints( tools2 );      // the derived hints, one rule, one place
        applyCatalogFilters( tools2, sessionCategories, sessionWhitelist );
        Db* rawDb = db2.get();
        ServerConfig sc = sessionCfg;   // per-session copy; captured-by-value cfg is const
        sc.requestHook = [ rawDb ] { Resources::bindThreadDb( rawDb ); };
        // $/cancel's DB-side abort: KILL QUERY against THIS session's
        // own connection id, one-shot control connection (db.cpp killQuery);
        // the server object is the session, so no client-key routing needed.
        sc.cancelHook = [ rawDb ] { rawDb->cancelInflight( rawDb->threadId() ); };
        JsonRpcServer* srv = new JsonRpcServer( sc, std::move( tools2 ), concCfg );
        srv->statePin = db2;    // session teardown closes THIS session's connection
        return std::unique_ptr<JsonRpcServer>( srv );
    };
    // A TLS misconfiguration (an unloadable cert, a key that doesn't
    // parse, a cert and key that don't belong to each other) is a HARD
    // startup failure: this process must exit nonzero having listened on
    // nothing, never fall back to plaintext, and never leave a half-open
    // listener behind. The transport throws a ToolError for exactly that
    // case; catch it here so the operator gets one clean line of
    // actionable text on stderr and a defined exit code, rather than an
    // unhandled-exception abort.
    try
    {
        return runHttpTransport( server, httpCfg, [ &ecfg ]() -> bool
        {
            Db probe;                       // fresh probe connection, never a session's
            try { probe.connect( ecfg ); }
            catch( ... ) { return false; }
            return probe.probeAlive();
        } );
    }
    catch( const ToolError& e )
    {
        std::cerr << "ERROR: " << e.message << "\n";
        return 1;
    }
}

int main( int argc, char** argv )
{
    const EngineConfig ecfg = EngineConfig::fromEnv();

    CliArgs args;
    args.httpPort     = envIntOr( "FSQL_MCP_HTTP_PORT", 8765 );
    args.httpBind     = envOr( "FSQL_MCP_BIND", "127.0.0.1" );
    args.lockPath     = envOr( "FSQL_MCP_SCHEMA_LOCK", "mcp/.mcp-schema-lock" );
    args.safetyLockPath = envOr( "FSQL_MCP_SAFETY_LOCK", "mcp/.mcp-safety-annotations-lock" );
    args.manifestPath = envOr( "FSQL_MCP_MANIFEST", "mcp/manifest.json" );

    int earlyExitCode = 0;
    if( parseArgs( argc, argv, args, earlyExitCode ) ) return earlyExitCode;
    args.lockPath       = resolveLockPath( args.lockPath );          // CWD first, then next to the executable
    args.safetyLockPath = resolveLockPath( args.safetyLockPath );

    if( args.toolWhitelist.empty() ) args.toolWhitelist = splitCsv( envOr( "FSQL_MCP_TOOL_WHITELIST", "" ) );
    if( args.enabledCategories.empty() ) args.enabledCategories = splitCsv( envOr( "FSQL_MCP_ENABLED_CATEGORIES", "" ) );

    Db db;
    RowLimitConfig rowCfg;
    rowCfg.maxRowsCeiling = envIntOr( "FSQL_MCP_MAX_ROWS_CEILING", 1000 );

    // --write-* / --list-tools run without ever touching a database: they hash
    // / list whatever THIS build's tool table registers (the workflow).
    std::vector<ToolSpec> tools = buildAllTools( db, ecfg, rowCfg );

    // the derived hints, post-pass in exactly one place (the rule itself
    // lives in tool_registry.h's applyDerivedHints, shared with the
    // per-session catalog above).
    applyDerivedHints( tools );

    // the catalog narrowing: category filter and tool whitelist, env or CLI.
    applyCatalogFilters( tools, args.enabledCategories, args.toolWhitelist );

    const std::string hash = computeSchemaHash( tools );
    const int oneShotExit = maybeRunOneShot( args, tools, hash );
    if( oneShotExit >= 0 ) return oneShotExit;

    // Order preserved from the original inline chain: the schema-lock check
    // runs first (exit 2 under strict mode), the safety-annotation check
    // second (exit 3, always hard).
    if( const int schemaExit = checkSchemaGate( args.lockPath, hash ) ) return schemaExit;
    if( const int safetyExit = checkSafetyGate( args.safetyLockPath, tools ) ) return safetyExit;

    logging::init( { envOr( "FSQL_MCP_LOG_LEVEL", "normal" ) == "verbose" ? logging::Level::Debug
                                                                          : logging::Level::Info } );

    ConcurrencyConfig concCfg;
    {
        std::string concErr;
        if( !envIntAtLeast( "FSQL_MCP_MAX_CONCURRENT_CHEAP", 50, 1, &concCfg.cheapLimit, &concErr )
            || !envIntAtLeast( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE", 5, 1, &concCfg.expensiveLimit, &concErr )
            || !envIntAtLeast( "FSQL_MCP_MAX_CONCURRENT_EXPENSIVE_PER_CLIENT", 2, 1, &concCfg.expensivePerClient, &concErr )
            || !envIntAtLeast( "FSQL_MCP_MAX_QUEUE_WAIT_MS", 900'000, 1, &concCfg.maxQueueWaitMs, &concErr ) )
        {
            std::cerr << concErr << "\n";
            return 2;
        }
    }

    ServerConfig serverCfg;
    serverCfg.serverName = FSQL_MCP_PROTOCOL_NAME;
    serverCfg.serverVersion = FSQL_MCP_VERSION;
    serverCfg.rowLimits = rowCfg;
    serverCfg.readOnlyMode = envBoolOr( "FSQL_MCP_READ_ONLY", false );
    serverCfg.modernOnly = modernEraOnly();

    if( args.httpMode )
    {
        // The HTTP transport spawns a detached thread per connection, and
        // those threads can outlive the transport's bounded drain. main's
        // locals (server, db) must therefore stay alive through process
        // teardown: std::exit() runs atexit handlers (coverage flush) but
        // does not unwind main's stack objects.
        serverCfg.sharedConcurrency = new ConcurrencyManager( concCfg );   // process-lifetime, shared by every HTTP session
        JsonRpcServer server( serverCfg, std::move( tools ), concCfg );
        std::exit( runHttpMode( server, args, ecfg, rowCfg, serverCfg, concCfg ) );
    }

    try
    {
        if( !db.raw() ) db.connect( ecfg );
        Resources::setEngineDb( &db );
        Resources::setEngineConfig( ecfg );
        // Version-skew guard: plugin version is version-locked to the
        // engine version it ships with; a mismatch is a WARN, never a hard fail.
        db.checkVersionSkew( FSQL_MCP_VERSION );
    }
    catch( const ToolError& e )
    {
        std::cerr << "ERROR: " << e.message << ( e.detail.empty() ? "" : ( " (" + e.detail + ")" ) ) << "\n";
        return 1;
    }

    // $/cancel's DB-side abort: the stdio server's whole client
    // base is this one connection, KILL QUERY against its own id from a
    // one-shot control connection (db.cpp killQuery), only while a request
    // is actually in flight (jsonrpc_server.cpp's in-flight check).
    serverCfg.cancelHook = [ &db ] { db.cancelInflight( db.threadId() ); };
    JsonRpcServer server( serverCfg, std::move( tools ), concCfg );

    StdioConfig stdioCfg;
    stdioCfg.shutdownDrainMs = envIntOr( "FSQL_MCP_SHUTDOWN_DRAIN_MS", 5000 );
    return runStdioTransport( server, stdioCfg );
}