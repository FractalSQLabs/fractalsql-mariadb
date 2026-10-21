// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <string_view>
#include <vector>
#include <functional>
#include <optional>
#include <chrono>
#include <exception>
#include "mcp_json.h"
#include "errors.h"
#include "logging.h"

namespace fsqlmcp
{
    enum class ToolClass { Cheap, Expensive };

    struct ToolParam
    {
        std::string_view name;
        JsonType         type;
        bool             required;
        Json             defaultValue = nullptr;   // used when !required and absent
        std::string_view description;
        bool             nullable = false;          // JSON-Schema anyOf [type, "null"]
        JsonType         itemType = JsonType::Number;   // element kind of an Array param (advertised AND enforced)
    };

    struct CallCtx
    {
        std::string clientKey;     // "stdio" or a per-session/per-token key (concurrency.h)
        bool        cancelled = false;
        // Which protocol era the call arrived in: "legacy" (an initialize
        // handshake and a protocol session) or "modern" (stateless, per-request
        // metadata). The operator's log says so on every call, so a client
        // that silently falls back from one era to the other is visible.
        std::string era;
    };

    struct ToolSpec
    {
        std::string_view name, category, description;
        ToolClass         toolClass;
        std::vector<ToolParam> params;
        std::optional<std::string_view> retryTier;   // MariaDB only; unset => omitted from tools/list
        bool destructiveHint = true;    // fail-safe: a tool nobody classified is destructive (read-only mode refuses it)
        bool readOnlyHint    = false;
        bool idempotentHint  = false;   // repeat calls with the same args produce no additional effect
        bool openWorldHint   = false;   // the call reaches an entity outside this DB connection -- a chat-LLM or an embedding provider
        bool secretHint      = false;   // args/result may carry sensitive content a client shouldn't echo/log casually
        std::function<Json( const Json& args, CallCtx& )> handler;
    };

    // Non-recursive argument checker.
    inline void validateArgs( const ToolSpec& spec, const Json& args )
    {
        if( !args.is_object() )
            throw ToolError( ErrorClass::Schema, "arguments must be a JSON object" );

        for( const ToolParam& p : spec.params )
        {
            const std::string key( p.name );
            const bool present = args.contains( key ) && !args.at( key ).is_null();

            if( !present )
            {
                if( p.required )
                    throw ToolError( ErrorClass::Schema, "missing required argument: " + key );
                continue;    // handler applies p.defaultValue itself
            }
            const Json& v = args.at( key );
            if( p.nullable && v.is_null() )
                continue;
            if( !jsonTypeMatches( p.type, v ) )
                throw ToolError( ErrorClass::Schema, key + " has the wrong type" );
            // Element-kind check, so the advertised items.type is a promise the server keeps.
            if( p.type == JsonType::Array )
                for( const Json& e : v )
                    if( !jsonTypeMatches( p.itemType, e ) )
                        throw ToolError( ErrorClass::Schema, key + " elements must be " + jsonTypeName( p.itemType ) );
        }
    }

    // An explicit JSON null on an OPTIONAL, non-nullable parameter is "absent" to
    // validateArgs (it is skipped), but handlers read optionals with
    // Json::value(key, default), which THROWS type_error.302 on a null that is
    // present -- surfacing as "internal server error". Hand the handler a copy
    // with those nulls removed so the contract the validator promises is true.
    // Nullable parameters keep their null (it is a meaningful value for them).
    inline Json withoutNullDefaults( const ToolSpec& spec, const Json& args )
    {
        Json out = args;
        for( const ToolParam& p : spec.params )
        {
            if( p.nullable ) continue;
            const std::string key( p.name );
            if( out.contains( key ) && out.at( key ).is_null() ) out.erase( key );
        }
        return out;
    }

    inline Json buildInputSchema( const ToolSpec& spec )
    {
        Json props = Json::object();
        std::vector<std::string> required;
        for( const ToolParam& p : spec.params )
        {
            Json prop;
            switch( p.type )
            {
                case JsonType::String:  prop[ "type" ] = "string";  break;
                case JsonType::Integer: prop[ "type" ] = "integer"; break;
                case JsonType::Number:  prop[ "type" ] = "number";  break;
                case JsonType::Boolean: prop[ "type" ] = "boolean"; break;
                case JsonType::Object:  prop[ "type" ] = "object";  break;
                case JsonType::Array:   prop[ "type" ] = "array";   prop[ "items" ][ "type" ] = jsonTypeName( p.itemType ); break;
                case JsonType::Null:    prop[ "type" ] = "null";    break;
            }
            if( p.nullable )
                prop[ "type" ] = Json::array( { prop[ "type" ], "null" } );
            prop[ "description" ] = std::string( p.description );
            if( !p.required && !p.defaultValue.is_null() )
                prop[ "default" ] = p.defaultValue;
            props[ std::string( p.name ) ] = prop;
            if( p.required )
                required.push_back( std::string( p.name ) );
        }
        Json schema{ { "type", "object" }, { "properties", props }, { "additionalProperties", false } };
        if( !required.empty() )
            schema[ "required" ] = required;
        if( props.empty() )
            schema[ "x-fractalsql-no-arguments" ] = true;       // marks a tool that takes no arguments
        return schema;
    }

    // The annotation object a client sees in tools/list, and the one the schema
    // hash covers (one definition, so the two cannot drift). The four standard
    // hints are always sent, true or false: in the MCP spec an omitted
    // destructiveHint or openWorldHint defaults to TRUE, so leaving a false one
    // out makes a spec-following client treat a closed-world, non-destructive
    // tool as destructive and open-world. secretHint is not a spec hint and is
    // only sent when set.
    // The retry tier (MariaDB only) rides along inside the same object.
    inline Json buildAnnotations( const ToolSpec& t )
    {
        Json a{ { "readOnlyHint", t.readOnlyHint },
                { "destructiveHint", t.destructiveHint },
                { "idempotentHint", t.idempotentHint },
                { "openWorldHint", t.openWorldHint } };
        if( t.secretHint ) a[ "secretHint" ] = true;
        if( t.retryTier ) a[ "x-fractalsql-retry-tier" ] = std::string( *t.retryTier );
        return a;
    }

    // the derived hints, in exactly one place.
    //
    // idempotentHint follows readOnlyHint: a pure read touches nothing, so
    // repeating it has no additional effect. It is deliberately not derived
    // from the retry tier: a "no-retry" tool (one that dispatches a chat-LLM
    // or an embedding call) is the one a client must NOT blindly re-issue,
    // so it must never advertise idempotent=1.
    //
    // ...plus the two session-state tools that are idempotent WITHOUT
    // being read-only: enabling Diversify twice leaves the same state on,
    // and disabling it twice leaves it off.
    inline void applyDerivedHints( std::vector<ToolSpec>& tools )
    {
        for( ToolSpec& t : tools )
            if( t.readOnlyHint ) t.idempotentHint = true;
        for( ToolSpec& t : tools )
            if( t.name == "fractal_diversify_enable" || t.name == "fractal_diversify_disable" )
                t.idempotentHint = true;
    }

    // validate -> handler -> classify -> always log. The RAII pattern below is
    // C++'s "finally": logging happens on every exit path via the destructor.
    inline Json runTool( const ToolSpec& spec, const Json& args, CallCtx& ctx )
    {
        const auto t0 = std::chrono::steady_clock::now();
        const char* errClass = nullptr;
        Json result;
        struct LogGuard
        {
            const ToolSpec& spec; const Json& args; const char*& errClass;
            std::chrono::steady_clock::time_point t0;
            const std::string& clientKey;
            const std::string& era;
            ~LogGuard()
            {
                const double ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t0 ).count();
                logging::toolCall( spec.name, logging::redactAndCap( args ), ms, errClass, clientKey, era );
            }
        } guard{ spec, args, errClass, t0, ctx.clientKey, ctx.era };

        // The error is rethrown after the handlers, never from inside one: a throw
        // from a catch block miscompiles under clang on Windows (MSVC unwinder crash).
        std::exception_ptr pending;
        try
        {
            validateArgs( spec, args );
            result = spec.handler( withoutNullDefaults( spec, args ), ctx );
            if( ctx.cancelled )
                throw ToolError( ErrorClass::Cancelled, "call was cancelled by the client" );
            return result;
        }
        catch( const ToolError& e )
        {
            errClass = errorClassName( e.errorClass );
            pending = std::current_exception();
        }
        catch( const std::exception& e )
        {
            errClass = errorClassName( ErrorClass::ServerInternal );
            logging::exceptionDetail( spec.name, sanitizeSecrets( e.what() ) );
            pending = std::make_exception_ptr( ToolError( ErrorClass::ServerInternal, "internal error",
                                                          sanitizeSecrets( e.what() ) ) );
        }
        std::rethrow_exception( pending );
    }

    // ---------------------------------------------------------------------
    // State-mutating tool classification (read-only gate backstop).
    //
    // FSQL_MCP_READ_ONLY refuses tools whose destructiveHint is true. A tool
    // that writes (audit chain, ledger hydration, vectorizer DDL/queue,
    // feature store, session shadow state, LLM-generated SQL execution) but
    // was registered with destructive=false would slip through, and the
    // committed safety-annotations lock used to ratify exactly that. This is
    // the single authoritative list: every name here is forced to
    // destructive=true / readOnly=false no matter how its
    // adapter registered it, so the registry cannot disagree with the gate.
    // Add a new writer here (or register it destructive) -- never rely on the
    // adapter default.
    // ---------------------------------------------------------------------
    inline bool isStateMutatingTool( std::string_view n )
    {
        static const char* const kNames[] = {
            "fractal_audit_log",
            "fractal_ledger_load",
            "fractal_vectorizer_create",
            "fractal_vectorizer_pause",
            "fractal_vectorizer_resume",
            "fractal_vectorizer_process_queue",
            "fractal_vectorizer_enqueue",
            "fractal_vectorizer_drop",
            "fractal_store_morphology",
            "fractal_diversify_enable",
            "fractal_diversify_disable",
            "fractal_diversify_set_params",
            "fractal_diversify_params",
            "fractal_feedback_report",
            "fractal_isolate_background",
            "fractal_agent_data_analyst",
            "fractal_sql_agent",
            "fractal_agent_feedback_audit",
            "fractal_agent_recommend_diverse",
            "fractal_session_close",
            "fractalsql_session_config_reset",
            "fractal_lock_destructive",
            "fractal_store_vectors",
            "fractal_store_series",
            "fractal_store_hash",
            "fractal_delete_key"
        };
        for( const char* k : kNames ) if( n == k ) return true;

        return false;
    }

    inline void classifyStateMutatingTools( std::vector<ToolSpec>& tools )
    {
        for( ToolSpec& t : tools )
            if( isStateMutatingTool( t.name ) )
            {
                t.destructiveHint = true;
                t.readOnlyHint    = false;
            }
    }

    // ---------------------------------------------------------------------
    // Context-scoped tools.
    //
    // These tools read or change ENGINE SESSION STATE: the Diversify
    // settings, the feedback/audit trail, the background-isolation flag, the
    // vectorizer's own registry, the telemetry counters and the session
    // itself. Their state lives in the engine under the connection's own
    // session id, so "the same state" means "the same connection".
    //
    // The modern protocol era has no protocol session, so the handle that
    // names the connection is passed explicitly as context_id. This list is
    // the single place that says which tools those are.
    // ---------------------------------------------------------------------
    inline bool isContextScopedTool( std::string_view n )
    {
        static const char* const kNames[] = {
            "fractal_diversify_enable",
            "fractal_diversify_disable",
            "fractal_diversify_set_params",
            "fractal_feedback_report",
            "fractal_agent_feedback_audit",
            "fractal_isolate_background",
            "fractal_agent_recommend_diverse",
            "fractal_search_telemetry",
            "fractal_vectorizer_create",
            "fractal_vectorizer_pause",
            "fractal_vectorizer_resume",
            "fractal_vectorizer_process_queue",
            "fractal_vectorizer_enqueue",
            "fractal_vectorizer_drop",
            "fractal_session_close",
            // The two read-only Diversify state readers: they report THIS
            // session's Diversify state, so they belong to the same context
            // as the tools that change it.
            "fractal_explain_result",
            "fractal_detect_collapse",
            // The per-connection configuration overlay: its overrides live
            // under the connection's own session id.
            "fractalsql_session_config_set",
            "fractalsql_session_config_get",
            "fractalsql_session_config_reset",
            "fractalsql_session_config_list"
        };
        for( const char* k : kNames ) if( n == k ) return true;
        return false;
    }

    // The context_id argument every context-scoped tool carries. Added in one
    // place (the tool table builder) so the schema, the manifest and the
    // locks all describe the same argument.
    inline ToolParam contextIdParam()
    {
        return ToolParam{ "context_id", JsonType::String, false, nullptr,
            "Optional state handle (the modern protocol era's explicit context): omit it and the "
            "server mints one and returns it with the result; pass it back to keep using the same "
            "engine state. In the legacy era the protocol session supplies the context instead.",
            false };
    }
}