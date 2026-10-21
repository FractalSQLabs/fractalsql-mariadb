// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "jsonrpc_server.h"
#include "resources.h"
#include "prompts.h"
#include "policy.h"
#include <algorithm>
#include <exception>

namespace fsqlmcp
{
    // Every revision this server speaks. The first three are the legacy era
    // (initialize handshake + Mcp-Session-Id); the last two are the modern
    // era (stateless requests, per-request _meta).
    static const std::unordered_set<std::string> kSupportedProtocolVersions{
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    };
    static const char* const kDefaultProtocolVersion = "2025-06-18";

    // The tools that take the model's auto_execute flag. The flag is
    // controlled by the same actor the control protects against, so the
    // operator's switch (FSQL_MCP_ALLOW_AUTO_EXECUTE) decides, not the model.
    static bool takesAutoExecute( std::string_view name )
    {
        return name == "fractal_sql_agent" || name == "fractal_agent_data_analyst";
    }

    JsonRpcServer::JsonRpcServer( ServerConfig cfg, std::vector<ToolSpec> tools, ConcurrencyConfig concCfg )
        : cfg_( std::move( cfg ) ), tools_( std::move( tools ) )
    {
        if( cfg_.sharedConcurrency ) conc_ = cfg_.sharedConcurrency;
        else { ownedConc_ = std::make_unique<ConcurrencyManager>( concCfg ); conc_ = ownedConc_.get(); }
        for( const ToolSpec& t : tools_ )
            byName_[ std::string( t.name ) ] = &t;
    }

    static Json makeError( const Json& id, int code, const std::string& message )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "error", { { "code", code }, { "message", message } } } };
    }
    static Json makeResult( const Json& id, Json result )
    {
        return Json{ { "jsonrpc", "2.0" }, { "id", id }, { "result", std::move( result ) } };
    }

    std::optional<std::string> JsonRpcServer::handleLine( std::string_view line, const std::string& clientKey )
    {
        return handleLine( line, clientKey, CallOptions{} );
    }

    std::optional<std::string> JsonRpcServer::handleLine( std::string_view line, const std::string& clientKey,
                                                          const CallOptions& opts )
    {
        // NOTHING may escape this function. The stdio transport dispatches
        // on a worker thread, and an exception that reaches a thread
        // function is std::terminate: the whole MCP server dies, with no
        // log line. The backstop below turns any escaping exception into
        // a JSON-RPC error; the shape checks in the implementation make
        // the ordinary cases (a non-object request, a non-string method)
        // plain protocol errors rather than exceptions at all.
        try
        {
            return handleLineImpl( line, clientKey, opts );
        }
        catch( const std::exception& e )
        {
            logging::exceptionDetail( "handleLine", e.what() );
            return makeError( nullptr, -32603, "internal error handling the request" ).dump();
        }
        catch( ... )
        {
            logging::exceptionDetail( "handleLine", "unknown exception" );
            return makeError( nullptr, -32603, "internal error handling the request" ).dump();
        }
    }

    std::optional<std::string> JsonRpcServer::handleLineImpl( std::string_view line, const std::string& clientKey,
                                                              const CallOptions& opts )
    {
        Json req;
        if( jsonNestsTooDeep( line ) )
            return makeError( nullptr, -32700, "parse error: nesting too deep" ).dump();
        try { req = Json::parse( line ); }
        catch( ... ) { return makeError( nullptr, -32700, "parse error" ).dump(); }   // framing error: id is null

        // The shape check and the extraction of id/method belong together.
        // nlohmann's value() THROWS when it is called on a non-object
        // (type_error 305) and when the key exists but holds another type
        // (type_error 302) -- and the old code called it on a request that
        // had not been proven to be an object, and read "method" with a
        // std::string default. A line of "5", "[]", "null" or a
        // {"method": 5} request therefore threw out of handleLine and
        // took the whole server down with it.
        if( !req.is_object() )
            return makeError( nullptr, -32600, "invalid request (not a JSON object)" ).dump();
        if( !req.contains( "jsonrpc" ) || !req.contains( "method" ) )
            return makeError( req.value( "id", Json( nullptr ) ), -32600, "invalid request" ).dump();
        if( !req[ "method" ].is_string() )
            return makeError( req.value( "id", Json( nullptr ) ), -32600, "invalid request (method must be a string)" ).dump();
        if( req.contains( "params" ) && !req[ "params" ].is_object() )
            return makeError( req.value( "id", Json( nullptr ) ), -32602, "invalid params (must be a JSON object)" ).dump();

        const bool isNotification = !req.contains( "id" );
        const std::string method = req[ "method" ].get<std::string>();

        if( method == "notifications/cancelled" )
        {
            if( req.contains( "params" ) && req[ "params" ].contains( "requestId" ) )
                cancel( req[ "params" ][ "requestId" ].dump() );
            return std::nullopt;             // never reply to a notification
        }
        if( isNotification )
            return std::nullopt;             // e.g. notifications/initialized

        const Json& id = req[ "id" ];
        if( shuttingDown_ )
            return makeError( id, -32000, "server shutting down" ).dump();

        const bool modern = ( opts.era == ProtocolEra::Modern );

        try
        {
            Json result;
            bool listResult = false;
            if( method == "initialize" )
            {
                if( cfg_.modernOnly )
                    return makeError( id, -32000,
                        "this server speaks the modern protocol era only (FSQL_MCP_PROTOCOL_ERA=modern); "
                        "the initialize handshake is part of the legacy era and is refused. "
                        "Supported versions: 2025-11-25, 2026-07-28" ).dump();
                result = handleInitialize( req.value( "params", Json::object() ) );
            }
            else if( method == "server/discover" ) result = handleServerDiscover();
            else if( method == "ping" )           result = Json::object();
            else if( method == "tools/list" )     { result = handleToolsList( opts ); listResult = true; }
            else if( method == "tools/call" )     result = handleToolsCall( req.value( "params", Json::object() ), clientKey, id.dump(), opts );
            else if( method == "resources/list" ) { result = handleResourcesList(); listResult = true; }
            else if( method == "resources/read" ) { result = handleResourcesRead( req.value( "params", Json::object() ) ); listResult = true; }
            else if( method == "resources/templates/list" ) { result = Resources::templates(); listResult = true; }
            else if( method == "prompts/list" )   { result = handlePromptsList(); listResult = true; }
            else if( method == "prompts/get" )    result = handlePromptsGet( req.value( "params", Json::object() ) );
            else return makeError( id, -32601, "method not found: " + method ).dump();

            if( modern )
            {
                // The modern era's result envelope: every result says what
                // kind of result it is, and a list result says how long it
                // may be cached and in which scope.
                result[ "resultType" ] = "complete";
                if( listResult )
                {
                    result[ "ttlMs" ] = 0;              // this catalog is not cacheable
                    result[ "cacheScope" ] = "session"; // ...and it is scoped to the caller's session
                }
            }
            return makeResult( id, std::move( result ) ).dump();
        }
        catch( const ToolError& e )
        {
            // tools/call's own error-shaped result (isError:true) is built inside
            // handleToolsCall; a ToolError escaping here means some OTHER handler
            // (resources/read's bad-kind, etc.) hit the same typed-error path.
            // Schema-class => -32602 per JSON-RPC convention; everything else
            // -32000.
            const int code = ( e.errorClass == ErrorClass::Schema ) ? -32602 : -32000;
            return makeError( id, code, e.message ).dump();
        }
        catch( const std::exception& e )
        {
            // A non-ToolError exception escaping a stdio worker thread would
            // terminate the whole process WITHOUT a single log line (caught
            // live: the schema resource read died the server silently).
            // ServerInternal's client-facing text stays generic; the
            // detail lands in this server's own stderr JSON trail only.
            logging::exceptionDetail( method, e.what() );
            return makeError( id, -32000, "internal server error (server-side log "
                                          "carries the detail); retry later" ).dump();
        }
        catch( ... )
        {
            logging::exceptionDetail( method, "unknown exception" );
            return makeError( id, -32000, "internal server error (server-side log "
                                          "carries the detail); retry later" ).dump();
        }
    }

    Json JsonRpcServer::handleInitialize( const Json& params )
    {
        std::string proto = kDefaultProtocolVersion;
        if( params.contains( "protocolVersion" ) && params[ "protocolVersion" ].is_string() )
        {
            const std::string requested = params[ "protocolVersion" ].get<std::string>();
            if( kSupportedProtocolVersions.count( requested ) )
                proto = requested;      // echo back if recognized; else fall back silently
        }
        return Json{
            { "protocolVersion", proto },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() }, { "resources", Json::object() }, { "prompts", Json::object() } } }
        };
    }

    // The modern era's discovery RPC: which revisions this server speaks, what
    // it can do and who it is. A modern client reads the supported versions
    // from here instead of guessing.
    Json JsonRpcServer::handleServerDiscover()
    {
        Json versions = Json::array();
        for( const std::string& v : { "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28" } )
            versions.push_back( v );
        return Json{
            { "protocolVersions", versions },
            { "serverInfo", { { "name", cfg_.serverName }, { "version", cfg_.serverVersion } } },
            { "capabilities", { { "tools", Json::object() },
                                { "resources", Json::object() },
                                { "prompts", Json::object() } } }
        };
    }

    Json JsonRpcServer::handleToolsList( const CallOptions& opts )
    {
        // A deterministic order (by name) in BOTH eras: the spec asks for it,
        // and a client that compares two listings must see the same order
        // whichever era it asked in.
        std::vector<const ToolSpec*> sorted;
        sorted.reserve( tools_.size() );
        for( const ToolSpec& t : tools_ ) sorted.push_back( &t );
        std::sort( sorted.begin(), sorted.end(),
                   []( const ToolSpec* a, const ToolSpec* b ) { return a->name < b->name; } );

        Json arr = Json::array();
        for( const ToolSpec* tp : sorted )
        {
            const ToolSpec& t = *tp;
            // A per-client credential may be limited to a subset of the
            // catalog; the tools it may not call are not even listed.
            if( opts.toolAllow && opts.toolAllow->count( std::string( t.name ) ) == 0 ) continue;
            Json entry{
                { "name", std::string( t.name ) },
                { "description", std::string( t.description ) },
                { "inputSchema", buildInputSchema( t ) },
                { "_meta", { { "x-fractalsql-tier", std::string( t.category ) },
                             { "x-fractalsql-class", t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" } } }
            };
            if( t.retryTier )
                entry[ "_meta" ][ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );   // MariaDB only; omitted elsewhere
            const Json annotations = buildAnnotations( t );   // includes idempotent/openWorld/secret hints
            entry[ "annotations" ] = annotations;
            arr.push_back( entry );
        }
        return Json{ { "tools", arr } };
    }

    Json JsonRpcServer::handleToolsCall( const Json& params, const std::string& clientKey, const std::string& requestId,
                                         const CallOptions& opts )
    {
        const std::string name = valueOr<std::string>( params, "name", "" );
        auto it = byName_.find( name );
        if( it == byName_.end() )
            throw ToolError( ErrorClass::Schema, "unknown tool '" + name + "' (see tools/list)" );
        const ToolSpec& spec = *it->second;
        if( cfg_.requestHook ) cfg_.requestHook();

        // the global read-only kill switch: checked before concurrency or DB
        // touch, so a refused call never counts against any cap and never reaches
        // the adapter layer. Schema-class: the caller's own deployment config is
        // the thing to fix, not the engine.
        if( cfg_.readOnlyMode && spec.destructiveHint )
            throw ToolError( ErrorClass::Schema,
                "server is running in read-only mode (FSQL_MCP_READ_ONLY=true); '" + name + "' is destructive and was refused before reaching the engine" );

        // A per-client credential restricted to a subset of the catalog may
        // not call outside it, even by guessing the name.
        if( opts.toolAllow && opts.toolAllow->count( name ) == 0 )
        {
            std::string allowed;
            for( const std::string& n : *opts.toolAllow )
            {
                if( !allowed.empty() ) allowed += ", ";
                allowed += n;
            }
            throw ToolError( ErrorClass::Schema,
                "tool '" + name + "' is not in this client's tool allowlist; the credential that made "
                "this request may only call: " + allowed );
        }

        Json args = params.value( "arguments", Json::object() );
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        // The context handle is the transport's, not the engine's: it selects
        // which connection the call runs on and never reaches the adapter.
        args.erase( "context_id" );

        // The model's auto_execute flag only counts when the operator turned
        // it on: the parameter is set by the same actor the control protects
        // against, so a flag is not a control.
        if( takesAutoExecute( spec.name ) && args.contains( "auto_execute" ) &&
            args[ "auto_execute" ].is_boolean() && args[ "auto_execute" ].get<bool>() &&
            !autoExecuteAllowed() )
            throw ToolError( ErrorClass::Schema,
                "auto_execute is refused: this server runs with FSQL_MCP_ALLOW_AUTO_EXECUTE unset, so a "
                "generated statement is never executed without an operator turning that switch on "
                "(FSQL_MCP_ALLOW_AUTO_EXECUTE=true). Generate the SQL and run it yourself instead." );

        { std::lock_guard<std::mutex> lk( inflightMu_ ); inflightIds_.insert( requestId ); }
        ++active_;
        struct ActiveGuard { std::atomic<std::size_t>& a; ~ActiveGuard() { --a; } } activeGuard{ active_ };

        ConcurrencyManager::Token token;
        std::exception_ptr acquireFailure;
        try
        {
            token = conc_->acquire( spec.toolClass, clientKey );
        }
        catch( ... )
        {
            // The concurrency gate refuses the call when the server is
            // busy. The in-flight id is dropped on that path too: leaving
            // it behind grew the set without bound (one entry per refused
            // call) and made a later cancel() believe the request was
            // still running, so it fired a KILL QUERY at a session that
            // had already gone.
            { std::lock_guard<std::mutex> lk( inflightMu_ ); inflightIds_.erase( requestId ); }
            // The refusal is rethrown after this block, never from inside one:
            // a throw from a catch block miscompiles under clang on Windows
            // (MSVC unwinder crash).
            acquireFailure = std::current_exception();
        }
        if( acquireFailure )
            std::rethrow_exception( acquireFailure );

        CallCtx ctx; ctx.clientKey = clientKey;
        // Which protocol era this call arrived in: the operator's log says so
        // on every call, so a client that silently falls back from the modern
        // era to the legacy one is visible.
        ctx.era = ( opts.era == ProtocolEra::Modern ) ? "modern" : "legacy";
        { std::lock_guard<std::mutex> lk( inflightMu_ ); ctx.cancelled = cancelledIds_.count( requestId ) != 0; }

        Json result;
        bool isError = false;
        Json errorPayload;
        try
        {
            result = runTool( spec, args, ctx );
        }
        catch( const ToolError& e )
        {
            isError = true;
            errorPayload = e.clientPayload();
            result = Json{ { "message", e.errorClass == ErrorClass::ServerInternal ? errorPayload["message"].get<std::string>() : e.message } };
        }

        bool cancelledAfter;
        { std::lock_guard<std::mutex> lk( inflightMu_ ); cancelledAfter = cancelledIds_.count( requestId ) != 0; inflightIds_.erase( requestId ); cancelledIds_.erase( requestId ); }
        if( cancelledAfter )
            throw ToolError( ErrorClass::Cancelled, "call was cancelled; result discarded" );   // never deliver a late result
        (void)token;    // released by Token's destructor on scope exit

        Json out;
        if( isError )
            out = Json{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result[ "message" ] } } } ) },
                        { "isError", true }, { "structuredContent", errorPayload } };
        else
            out = Json{ { "content", Json::array( { Json{ { "type", "text" }, { "text", result.dump() } } } ) },
                        { "isError", false }, { "structuredContent", result } };
        // The context handle the caller may pass back to keep using the same
        // engine state.
        if( !opts.contextId.empty() )
            out[ "context_id" ] = opts.contextId;
        return out;
    }

    Json JsonRpcServer::handleResourcesList() { return Resources::list(); }
    Json JsonRpcServer::handleResourcesRead( const Json& params )
    {
        if( cfg_.requestHook ) cfg_.requestHook();
        return Resources::read( valueOr<std::string>( params, "uri", "" ) );
    }
    Json JsonRpcServer::handlePromptsList()   { return Prompts::list(); }
    Json JsonRpcServer::handlePromptsGet( const Json& params )
    {
        const Json name = params.value( "name", Json( nullptr ) );
        if( !name.is_string() )
            throw ToolError( ErrorClass::Schema, "prompts/get requires a string \"name\"" );
        const Json args = params.value( "arguments", Json::object() );
        return Prompts::get( name.get<std::string>(), args.is_object() ? args : Json::object() );
    }

    void JsonRpcServer::cancel( const std::string& requestId )
    {
        bool inFlight = false;
        {
            std::lock_guard<std::mutex> lk( inflightMu_ );
            cancelledIds_.insert( requestId );
            inFlight = inflightIds_.count( requestId ) != 0;
        }
        // Race-safe by construction: a cancel racing an already-finished call
        // still records the id (the post-handler check in handleToolsCall
        // discards the late result either way), only a request actually
        // in flight gets the DB-side interrupt (KILL QUERY against this
        // session's own connection id, from a one-shot control connection,
        // db.cpp's killQuery; never the busy connection itself).
        if( inFlight && cfg_.cancelHook )
            cfg_.cancelHook();
        logging::logInfo( "cancel propagated for request " + requestId );
    }

    void JsonRpcServer::beginShutdown() { shuttingDown_ = true; }

    std::size_t JsonRpcServer::activeRequestCount() { return active_.load(); }
}