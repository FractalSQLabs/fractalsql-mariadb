// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
// MariaDB adapter helpers: the engine's argument grammars and the row-ceiling
// machinery, shared by all seven adapters/*.cpp. The argument-packing and coercion
// rules live only here, so every adapter applies them identically.

#include "../tool_registry.h"
#include "../rows.h"
#include "../vectors.h"
#include "../db.h"
#include <cmath>
#include <initializer_list>

namespace fsqlmcp::adap
{
    // Table-construction helper: keeps the 93-tool catalog one call per tool
    // with named, checkable argument meanings, avoiding brace-order mistakes in
    // the ToolSpec aggregate.
    using ToolHandler = std::function<Json( const Json& args, CallCtx& ctx )>;

    inline ToolSpec mkTool( const char* name, const char* tier, const char* retryTier,
                             ToolClass cls, const char* desc, std::vector<ToolParam> params,
                             ToolHandler handler,
                             bool readOnly = false, int destructive = -1,
                             bool openWorld = false, bool secret = false )
    {
        ToolSpec t;
        t.name = name; t.category = tier; t.description = desc; t.toolClass = cls;
        t.params = std::move( params );
        if( retryTier ) t.retryTier = std::string_view( retryTier );
        // Fail-safe default: a tool that is not declared read-only and
        // whose author did not state destructive=false explicitly is destructive.
        // destructive == -1 means "not stated".
        t.destructiveHint = ( destructive < 0 ) ? !readOnly : ( destructive != 0 );
        t.readOnlyHint = readOnly;
        t.openWorldHint = openWorld; t.secretHint = secret;
        t.handler = std::move( handler );
        return t;
    }

    // ---- argument grammars ----
    // One-dimensional numeric array -> the engine's JSON-array-string grammar,
    // e.g. "[0.1,0.2,0.3]". Lenient string->number coercion applies to elements
    // ONLY here (bools never coerced); non-numeric elements are a Schema error
    // naming up to 3 offenders.
    inline std::string packVector( const Json& v, std::string_view name )
    {
        if( v.is_null() )   throw ToolError( ErrorClass::Schema, std::string( name ) + " must not be null" );
        if( !v.is_array() ) throw ToolError( ErrorClass::Schema, std::string( name ) + " must be a JSON array of numbers" );
        if( v.empty() )     throw ToolError( ErrorClass::Schema, std::string( name ) + " must not be an empty array" );
        std::string out = "[";
        std::vector<std::string> bad;
        bool first = true;
        for( const Json& rawElem : v )
        {
            const Json elem = vectors::coerceNumber( rawElem );
            if( !elem.is_number() || elem.is_boolean() || !std::isfinite( elem.get<double>() ) )
            { if( bad.size() < 3 ) bad.push_back( rawElem.dump() ); continue; }
            if( !first ) out += ',';
            first = false;
            out += elem.dump();     // shortest round-trippable float, like to_chars
        }
        if( !bad.empty() )
        {
            std::string msg = std::string( name ) + " contains non-numeric element(s): ";
            for( std::size_t i = 0; i < bad.size(); ++i ) msg += ( i ? ", " : "" ) + bad[ i ];
            throw ToolError( ErrorClass::Schema, msg );
        }
        return out + "]";
    }

    // Nested 2-D matrix (corpus / point cloud) -> nested-array string; inner
    // rows may also be flat arrays of arrays-of-numbers.
    inline std::string packMatrix( const Json& m, std::string_view name )
    {
        if( m.is_null() )   throw ToolError( ErrorClass::Schema, std::string( name ) + " must not be null" );
        if( !m.is_array() ) throw ToolError( ErrorClass::Schema, std::string( name ) + " must be an array of row vectors" );
        std::string out = "[";
        bool firstRow = true;
        for( const Json& row : m )
        {
            if( !row.is_array() )
                throw ToolError( ErrorClass::Schema, std::string( name ) + " rows must each be a JSON array of numbers" );
            if( !firstRow ) out += ',';
            firstRow = false;
            out += packVector( row, name );
        }
        return out + "]";
    }

    // Nested n x dim arrays -> flat row-major bracketed array (box-count / mesh
    // / edge CSVs and flattened covariance/point-cloud grammars).
    inline std::string flattenMatrix( const Json& m, std::string_view name )
    {
        if( m.is_null() )   throw ToolError( ErrorClass::Schema, std::string( name ) + " must not be null" );
        if( !m.is_array() ) throw ToolError( ErrorClass::Schema, std::string( name ) + " must be an array of row vectors" );
        Json flat = Json::array();
        for( const Json& row : m )
        {
            if( !row.is_array() )
                throw ToolError( ErrorClass::Schema, std::string( name ) + " rows must each be a JSON array of numbers" );
            for( const Json& e : row ) flat.push_back( vectors::coerceNumber( e ) );
        }
        return packVector( flat, name );
    }

    inline std::string packFlat( const Json& a, std::string_view name ) { return packVector( a, name ); }

    // The trailing JSON 'params' objects several functions take.
    inline std::string packParams( const Json& p )
    {
        return ( p.is_object() ? p : Json::object() ).dump();
    }

    // ---- row-ceiling machinery ----
    inline int effectiveLimit( const Json& args, const RowLimitConfig& cfg )
    {
        int limit = 100;
        if( args.contains( "limit" ) && !args.at( "limit" ).is_null() )
        {
            if( !args.at( "limit" ).is_number_integer() )
                throw ToolError( ErrorClass::Schema, "limit must be an integer" );
            limit = args.at( "limit" ).get<int>();
            if( limit < 1 ) limit = 1;
        }
        return std::min( limit, cfg.maxRowsCeiling );
    }

    inline void limitKCheck( const Json& args, const RowLimitConfig& cfg )
    {
        if( args.contains( "k" ) && !args.at( "k" ).is_null() && args.at( "k" ).is_number_integer()
            && args.at( "k" ).get<int>() > cfg.maxRowsCeiling )
            throw ToolError( ErrorClass::Schema,
                "k must be <= the server row ceiling (" + std::to_string( cfg.maxRowsCeiling ) +
                "); raise FSQL_MCP_MAX_ROWS_CEILING if you really need more" );
    }

    constexpr const char* kTruncateFields[] = { "top_k", "population", "candidates", "cohort_matches", "rows" };

    inline Json truncateResult( Json result, int limit )
    {
        if( result.is_array() )
        {
            if( static_cast<int>( result.size() ) > limit )
            {
                const int total = static_cast<int>( result.size() );
                Json cut = Json::array();
                for( int i = 0; i < limit; ++i ) cut.push_back( result[ i ] );
                return Json{ { "rows", std::move( cut ) }, { "truncated", true },
                              { "total_scanned", total },
                              { "_note", "result truncated at the MCP row ceiling; re-call with search-level "
                                         "filtering (smaller k / a cohort restriction) rather than just a higher limit" } };
            }
            return result;
        }
        if( result.is_object() )
        {
            for( const char* field : kTruncateFields )
            {
                const auto it = result.find( field );
                if( it != result.end() && it->is_array() && static_cast<int>( it->size() ) > limit )
                {
                    const int total = static_cast<int>( it->size() );
                    Json cut = Json::array();
                    for( int i = 0; i < limit; ++i ) cut.push_back( ( *it )[ i ] );
                    result[ field ] = std::move( cut );
                    result[ "truncated" ] = true;
                    result[ "total_scanned" ] = total;
                    return result;
                }
            }
        }
        return result;
    }

    // Enterprise-dormant UDF behavior: NULL-family results on Community builds
    // surface as the tier's own documented condition, clean and typed.
    inline bool resultIsNull( const Json& result )
    {
        if( result.is_null() ) return true;
        if( result.is_object() && result.size() == 1 )
        {
            auto it = result.begin();
            return ( it.key() == "value" || it.key() == "result" ) && it.value().is_null();
        }
        return false;
    }

    // This connection IS the session: every session-keyed UDF receives this
    // server's own CONNECTION_ID(), never exposed in any schema.
    inline std::int64_t sessionId( Db& db ) { return static_cast<std::int64_t>( db.threadId() ); }

    // Compact JSON for an optional params argument, minus any adapter-reserved keys.
    inline std::string dumpParamsNo( const Json& p, std::initializer_list<const char*> drop )
    {
        Json out = p.is_object() ? p : Json::object();
        for( const char* k : drop ) out.erase( k );
        return out.dump();
    }
}