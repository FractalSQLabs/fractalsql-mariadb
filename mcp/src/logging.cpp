// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include <string>
#include <functional>
#include "logging.h"
#include <openssl/evp.h>
#include <cstdio>
#include <chrono>
#include <algorithm>
#include <cctype>
#include <string_view>

namespace fsqlmcp::logging
{
    static Config g_cfg;

    void init( const Config& cfg ) { g_cfg = cfg; }

    static std::string sha256_8( const std::string& s )
    {
        unsigned char digest[ EVP_MAX_MD_SIZE ];
        unsigned int  len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        if( !ctx ) return "unavailable";   // allocation failed: this only labels a log line
        const bool ok = EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr ) == 1
                     && EVP_DigestUpdate( ctx, s.data(), s.size() ) == 1
                     && EVP_DigestFinal_ex( ctx, digest, &len ) == 1;
        EVP_MD_CTX_free( ctx );
        if( !ok ) return "unavailable";
        static const char* const kHex = "0123456789abcdef";
        std::string out;
        for( int i = 0; i < 4 && static_cast<unsigned>( i ) < len; ++i )
        {
            out.push_back( kHex[ digest[ i ] >> 4 ] );
            out.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return out;
    }

    static bool looksSecretKey( const std::string& key )
    {
        std::string lower = key;
        std::transform( lower.begin(), lower.end(), lower.begin(),
                         []( unsigned char c ) { return std::tolower( c ); } );
        for( const char* needle : { "token", "password", "key", "secret" } )
            if( lower.find( needle ) != std::string::npos )
                return true;
        return false;
    }

    Json redactAndCap( const Json& v, int depth )
    {
        if( v.is_object() )
        {
            if( depth >= 2 )
                return Json( "<object>" );
            Json out = Json::object();
            for( auto it = v.begin(); it != v.end(); ++it )
                out[ it.key() ] = looksSecretKey( it.key() ) ? Json( "***" )
                                                              : redactAndCap( it.value(), depth + 1 );
            return out;
        }
        if( v.is_array() )
        {
            const std::string dump = v.dump();
            return Json( "<array len=" + std::to_string( v.size() ) + " sha256_8=" + sha256_8( dump ) + ">" );
        }
        if( v.is_string() )
        {
            const std::string& s = v.get_ref<const std::string&>();
            if( s.size() > 256 )
                return Json( "<str len=" + std::to_string( s.size() ) + " sha256_8=" + sha256_8( s ) + ">" );
            return v;
        }
        return v;
    }

    static void emitLine( const Json& line )
    {
        std::fputs( line.dump().c_str(), stderr );
        std::fputc( '\n', stderr );
        std::fflush( stderr );
    }

    void toolCall( std::string_view toolName, const Json& argsRedactedCapped,
                    double latencyMs, const char* errorClassOrNull,
                    const std::string& clientKey, const std::string& era )
    {
        if( static_cast<int>( g_cfg.level ) < static_cast<int>( Level::Info ) )
            return;
        Json line{
            { "event", "tool_call" },
            { "tool", std::string( toolName ) },
            { "latency_ms", latencyMs }
        };
        // Who ran it: a short digest of the client key (session id or token
        // prefix), never the key itself -- enough to tell clients apart in an
        // incident without writing a bearer-token prefix into the log.
        if( !clientKey.empty() )
        {
            char buf[ 24 ];
            std::snprintf( buf, sizeof buf, "c-%08zx", std::hash<std::string>{}( clientKey ) & 0xffffffffu );
            line[ "client" ] = buf;
        }
        // Which protocol era the call arrived in: "legacy" (a session and an
        // initialize handshake) or "modern" (stateless, per-request
        // metadata). An operator reading the log needs to know which one a
        // given client is actually using.
        if( !era.empty() )
            line[ "era" ] = era;
        if( errorClassOrNull )
            line[ "error_class" ] = errorClassOrNull;
        // Level::Debug IS the "verbose" level (main.cpp maps
        // FSQL_MCP_LOG_LEVEL=verbose -> Debug), and THIS predicate is the
        // wiring, verbose (and schema errors at info level) include the
        // redacted args in the log line, other cases omit them.
        if( g_cfg.level == Level::Debug || ( errorClassOrNull && std::string_view( errorClassOrNull ) == "schema" ) )
            line[ "args" ] = argsRedactedCapped;   // schema errors show args even at info level
        emitLine( line );
    }

    void configChange( std::string_view key, std::string_view oldValueRedacted, std::string_view newValueRedacted )
    {
        emitLine( Json{
            { "event", "config_change" }, { "key", std::string( key ) },
            { "old", std::string( oldValueRedacted ) }, { "new", std::string( newValueRedacted ) }
        } );
    }

    void exceptionDetail( std::string_view where, std::string_view sanitizedDetail )
    {
        emitLine( Json{ { "event", "exception" }, { "where", std::string( where ) },
                         { "detail", std::string( sanitizedDetail ) }, { "level", "error" } } );
    }

    void logInfo( std::string_view message )
    {
        emitLine( Json{ { "event", "info" }, { "message", std::string( message ) } } );
    }

    void event( std::string_view name, const Json& fields )
    {
        Json line{ { "event", std::string( name ) } };
        if( fields.is_object() )
            for( auto it = fields.begin(); it != fields.end(); ++it )
                line[ it.key() ] = it.value();
        emitLine( line );
    }
}