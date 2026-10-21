// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include "db.h"
#include "logging.h"        // bootstrapSession's WARN line goes through the
#include "errors.h"         // sanitizer, same posture as the version-skew guard
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <vector>

namespace fsqlmcp
{
    // Seconds to wait for a connection and its handshake, so a database that
    // accepts the socket and never answers cannot hang the server.
    // FSQL_MCP_CONNECT_TIMEOUT overrides the default. No read timeout is set:
    // reasoning calls legitimately run for minutes.
    static unsigned int connectTimeoutSeconds()
    {
        const char* v = std::getenv( "FSQL_MCP_CONNECT_TIMEOUT" );
        const long n = v ? std::strtol( v, nullptr, 10 ) : 0;
        return n > 0 ? static_cast<unsigned int>( n ) : 10u;
    }

    void Db::connect( const std::string& host, int port, const std::string& user,
                       const std::string& password, const std::string& database )
    {
        EngineConfig cfg;
        cfg.host = host; cfg.port = port; cfg.user = user; cfg.password = password; cfg.database = database;
        connect( cfg );
    }

    void Db::connect( const EngineConfig& cfg )
    {
        openDatabase( cfg );
        cfg_ = cfg;
        bootstrapSession( cfg );
        applyDestructiveLatch( cfg );
    }

    // Opens the socket and authenticates. Every parameter reaches the server
    // through the driver's own connect call, never assembled into SQL text.
    void Db::openDatabase( const EngineConfig& cfg )
    {
        std::lock_guard<std::mutex> lk( mu_ );
        conn_ = mysql_init( nullptr );
        if( !conn_ )
            throw ToolError( ErrorClass::ServerInternal, "mysql_init failed" );
        mysql_options( conn_, MYSQL_SET_CHARSET_NAME, "utf8mb4" );
        const unsigned int connectTimeout = connectTimeoutSeconds();
        mysql_options( conn_, MYSQL_OPT_CONNECT_TIMEOUT, &connectTimeout );
        if( !mysql_real_connect( conn_, cfg.host.c_str(),
                                   cfg.user.empty() ? "root" : cfg.user.c_str(), cfg.password.c_str(),
                                   cfg.database.empty() ? nullptr : cfg.database.c_str(),
                                   static_cast<unsigned int>( cfg.port ), nullptr, 0 ) )
        {
            const unsigned int code = mysql_errno( conn_ );
            const std::string msg = sanitizeSecrets( mysql_error( conn_ ) ? mysql_error( conn_ ) : "" );
            mysql_close( conn_ ); conn_ = nullptr;
            throw ToolError( ErrorClass::Connectivity,
                              "cannot connect to MariaDB at " + cfg.host + ":" + std::to_string( cfg.port ),
                              "(error " + std::to_string( code ) + ") " + msg );
        }
    }

    // Version-skew guard: warn, never hard-fail. The engine's
    // fractal_version() is compared against the version this plugin was built
    // against; a mismatch is a startup WARN line, because the SQL surface is
    // stable across the compat matrix (never fatal, same posture as the
    // agent_partial_reasoning_fail bootstrap below).
    void Db::checkVersionSkew( const std::string& engineVersionExpected )
    {
        if( engineVersionExpected.empty() ) return;
        try
        {
            const Json raw = selectScalarJson( "SELECT fractal_version()" );
            std::string engine;
            if( raw.is_object() && raw.contains( "value" ) && raw.at( "value" ).is_string() )
                engine = raw.at( "value" ).get<std::string>();
            else if( raw.is_string() )
                engine = raw.get<std::string>();
            if( !engine.empty() && engine != engineVersionExpected )
                std::cerr << "WARN: version skew: engine fractal_version()=" << engine
                          << " vs plugin " << engineVersionExpected << "\n";
        }
        catch( ... ) { /* non-fatal: never thrown from connect() */ }
    }

    // Partial-result mode: opt THIS session into the engine's
    // agent_partial_reasoning_fail mode so a reasoning-endpoint failure inside
    // an agent's procedure comes back as the computed data half plus
    // "reasoning_step_failed" instead of raising. Off by default in the
    // engine's own SQL surface; the plugin turns it on for every session
    // (EngineConfig::agentPartialReasoningFail reads FSQL_MCP_AGENT_PARTIAL,
    // default on, 'off' keeps the engine's raise behavior). Never fatal: an
    // engine build without the session-flag UDF just keeps raising, recorded
    // as a WARN line (same posture as the version-skew guard).
    void Db::bootstrapSession( const EngineConfig& cfg )
    {
        if( !conn_ || !cfg.agentPartialReasoningFail ) return;
        try
        {
            const std::int64_t sid = static_cast<std::int64_t>( threadId() );
            if( sid == 0 ) return;
            MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
            if( !stmt ) return;
            const char* sql = "SELECT fractal_agent_partial_fail(?, 'on')";
            if( mysql_stmt_prepare( stmt, sql, static_cast<unsigned long>( strlen( sql ) ) ) != 0 )
            {
                std::cerr << "WARN: agent_partial_reasoning_fail not applied: "
                          << sanitizeSecrets( mysql_stmt_error( stmt ) )
                          << " (an engine build without the session flag keeps the"
                          << " engine's raise behavior)\n";
                mysql_stmt_close( stmt );
                return;
            }
            MYSQL_BIND bind{};
            bind.buffer_type  = MYSQL_TYPE_LONGLONG;
            bind.buffer       = const_cast< std::int64_t* >( &sid );
            bind.is_unsigned  = 1;
            if( mysql_stmt_bind_param( stmt, &bind ) != 0 || mysql_stmt_execute( stmt ) != 0 )
            {
                std::cerr << "WARN: agent_partial_reasoning_fail not applied: "
                          << sanitizeSecrets( mysql_stmt_error( stmt ) )
                          << " (an engine build without the session flag keeps the"
                          << " engine's raise behavior)\n";
                mysql_stmt_close( stmt );
                return;
            }
            do { } while( mysql_stmt_next_result( stmt ) == 0 );
            mysql_stmt_close( stmt );
        }
        catch( ... ) { /* never fatal; same posture as the version-skew guard */ }
    }

    // FSQL_MCP_READ_ONLY=true: latch the engine's destructive ledger UDFs
    // (flush / compact / reset_soft / reset_hard) for THIS connection's id.
    // The server already refuses the destructiveHint tools before they reach the
    // engine; this is the second line, so a mis-annotated tool cannot wipe the
    // ledger either. The latch is keyed by session id (the id the UDFs are
    // called with), so it covers every call this server makes, and nothing
    // that passes a different id. Never fatal; a failure is a WARN line.
    void Db::applyDestructiveLatch( const EngineConfig& cfg )
    {
        if( !conn_ || !cfg.lockDestructive ) return;
        const char* what = "FSQL_MCP_READ_ONLY: engine-side destructive latch not applied "
                           "(server-side refusal still active): ";
        try
        {
            const std::int64_t sid = static_cast<std::int64_t>( threadId() );
            if( sid == 0 ) return;
            MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
            if( !stmt ) return;
            const char* sql = "SELECT fractal_lock_destructive(?)";
            if( mysql_stmt_prepare( stmt, sql, static_cast<unsigned long>( strlen( sql ) ) ) != 0 )
            {
                std::cerr << "WARN: " << what << sanitizeSecrets( mysql_stmt_error( stmt ) ) << "\n";
                mysql_stmt_close( stmt );
                return;
            }
            MYSQL_BIND bind{};
            bind.buffer_type  = MYSQL_TYPE_LONGLONG;
            bind.buffer       = const_cast< std::int64_t* >( &sid );
            bind.is_unsigned  = 1;
            if( mysql_stmt_bind_param( stmt, &bind ) != 0 || mysql_stmt_execute( stmt ) != 0 )
            {
                std::cerr << "WARN: " << what << sanitizeSecrets( mysql_stmt_error( stmt ) ) << "\n";
                mysql_stmt_close( stmt );
                return;
            }
            do { } while( mysql_stmt_next_result( stmt ) == 0 );
            mysql_stmt_close( stmt );
        }
        catch( ... ) { /* never fatal */ }
    }

    ToolError Db::classify( const std::string& msg, unsigned int code ) const
    {
        const std::string sanitized = sanitizeSecrets( msg );
        // SQLSTATE '45000' surfaces as error 1644: the engine's own documented,
        // actionable SIGNAL text, pass it through verbatim as an engine error.
        if( code == 1644 )
            return ToolError( ErrorClass::Engine, sanitized );
        if( code == 1317 )                                  // Query execution was interrupted (KILL QUERY)
            return ToolError( ErrorClass::Cancelled, "call was cancelled" );
        if( code == 2006 || code == 2013 || code == 2002 || code == 2005 || code == 2003 )
            return ToolError( ErrorClass::Connectivity, sanitized );
        return ToolError( ErrorClass::Engine, sanitized );
    }

    // The CANONICAL VECTOR FORM: a uint16 dimension (little-endian), a
    // uint16 reserved field (zero), then one float32 per dimension --
    // carried as lowercase hex, so it is byte-stable and charset-safe.
    //
    // Its hex can be entirely decimal digits: a zero vector of dimension
    // 16 is "1000" followed by 64 zeros, every character of it a digit.
    // A run of digits IS a JSON number, so parsing the value as JSON
    // turns the vector into a number -- and a 72-digit number does not
    // survive the round trip, so the vector comes back as a rounded,
    // meaningless magnitude. The shape is therefore recognised BEFORE
    // the parse, and the value is kept as the string it is.
    //
    // The check is exact, not a heuristic: the header's dimension must
    // agree with the payload length, and the reserved field must be
    // zero. A number that happens to satisfy it would be returned as a
    // string rather than a number, which is the harmless direction of
    // the mistake.
    static bool looksLikeCanonicalVectorHex( const std::string& s )
    {
        // An 8-char header plus 8 chars per dimension; the smallest
        // possible vector is one dimension, so 16 chars.
        if( s.size() < 16 || ( s.size() % 8 ) != 0 ) return false;
        for( char c : s )
            if( !( ( c >= '0' && c <= '9' ) || ( c >= 'a' && c <= 'f' ) ) ) return false;
        auto nib = []( char c ) -> int { return ( c <= '9' ) ? ( c - '0' ) : ( c - 'a' + 10 ); };
        auto hexByte = [&]( std::size_t i ) -> int
        { return ( nib( s[ i ] ) << 4 ) | nib( s[ i + 1 ] ); };
        const int dim = hexByte( 0 ) | ( hexByte( 2 ) << 8 );      // little-endian uint16
        if( dim < 1 ) return false;
        if( hexByte( 4 ) != 0 || hexByte( 6 ) != 0 ) return false;  // reserved must be zero
        return s.size() == 8u + 8u * static_cast<std::size_t>( dim );
    }

    Json Db::parseJsonOrValue( const char* text ) const
    {
        if( !text ) return Json( nullptr );
        const std::string s( text );
        if( looksLikeCanonicalVectorHex( s ) ) return Json( s );
        try { return Json::parse( s ); }
        catch( ... ) { return Json{ { "value", s } }; }
    }

    // Fixed OUT-variable token BODY (compile-time; never caller input).
    // The caller's CALL/SELECT text adds the leading '@' -- keeping the '@'
    // in the token itself double-prefixed it at every use
    // ("@@fsq_out_0" -> MariaDB "Unknown system variable 'fsq_out_0'",
    // caught live: every callProc-backed tool failed on a stock install).
    static std::string outVarToken( std::size_t i ) { return "fsq_out_" + std::to_string( i ); }

    Json Db::callProc( const std::string& proc, const std::vector<SqlValue>& params,
                        const std::vector<std::string>& outVars, MergeMode mode )
    {
        std::lock_guard<std::mutex> lk( mu_ );

        std::string placeholders;
        for( std::size_t i = 0; i < params.size(); ++i ) placeholders += ( i ? ",?" : "?" );
        for( std::size_t i = 0; i < outVars.size(); ++i )
            placeholders += ( placeholders.empty() ? "@" : ",@" ) + outVarToken( i );
        // The template is constant except for the procedure name (tool code) and
        // the fixed @fsq_out_N tokens, every parameter is bound below.
        const std::string sql = "CALL " + proc + "(" + placeholders + ")";

        MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
        if( !stmt ) throw ToolError( ErrorClass::ServerInternal, "mysql_stmt_init failed" );
        if( mysql_stmt_prepare( stmt, sql.c_str(), static_cast<unsigned long>( sql.size() ) ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        std::vector<MYSQL_BIND> binds( params.size() );
        std::vector<std::string> strStorage( params.size() );
        std::vector<long long> intStorage( params.size() );
        std::vector<double> dblStorage( params.size() );
        for( std::size_t i = 0; i < params.size(); ++i )
        {
            const SqlValue& v = params[ i ];
            if( std::holds_alternative<std::nullptr_t>( v ) )
            { binds[ i ].buffer_type = MYSQL_TYPE_NULL; }
            else if( std::holds_alternative<std::int64_t>( v ) )
            { intStorage[ i ] = std::get<std::int64_t>( v );
              binds[ i ].buffer_type = MYSQL_TYPE_LONGLONG; binds[ i ].buffer = &intStorage[ i ];
              binds[ i ].is_unsigned = 1; }
            else if( std::holds_alternative<double>( v ) )
            { dblStorage[ i ] = std::get<double>( v );
              binds[ i ].buffer_type = MYSQL_TYPE_DOUBLE; binds[ i ].buffer = &dblStorage[ i ]; }
            else
            { strStorage[ i ] = std::get<std::string>( v );
              binds[ i ].buffer_type = MYSQL_TYPE_STRING;
              binds[ i ].buffer = &strStorage[ i ][ 0 ];
              binds[ i ].buffer_length = static_cast<unsigned long>( strStorage[ i ].size() ); }
        }
        if( !binds.empty() && mysql_stmt_bind_param( stmt, binds.data() ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        if( mysql_stmt_execute( stmt ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        // Drain every intermediate result set a PROCEDURE may emit before its OK
        // packet, leaves the connection usable for the SELECT of the OUT vars.
        do { } while( mysql_stmt_next_result( stmt ) == 0 );
        const unsigned int drainErr = mysql_stmt_errno( stmt );
        mysql_stmt_close( stmt );
        if( drainErr != 0 )
            throw classify( std::string( "procedure " ) + proc + " failed while producing results", drainErr );

        if( mode == MergeMode::None )
            return Json{ { "ok", true } };

        return decodeOutVars( outVars, mode );
    }

    // CALLER CONTRACT: mu_ is already held -- decodeOutVars runs at the tail
    // of callProc under the same lock, and locking again here self-deadlocks
    // ("resource deadlock would occur", error 35 from the Windows critical
    // section; caught live once the CALL itself started succeeding).
    Json Db::decodeOutVars( const std::vector<std::string>& outVars, MergeMode mode )
    {
        std::string selectSql = "SELECT ";
        for( std::size_t i = 0; i < outVars.size(); ++i )
            selectSql += ( i ? ",@" : "@" ) + outVarToken( i );
        if( mysql_real_query( conn_, selectSql.c_str(), static_cast<unsigned long>( selectSql.size() ) ) != 0 )
        { const unsigned int c = mysql_errno( conn_ ); const std::string e = mysql_error( conn_ );
          throw classify( e, c ); }
        MYSQL_RES* res = mysql_store_result( conn_ );
        if( !res )
            throw ToolError( ErrorClass::ServerInternal, "procedure's OUT-variable SELECT returned no row" );
        MYSQL_ROW row = mysql_fetch_row( res );
        const unsigned n = mysql_num_fields( res );

        std::vector<Json> parsed;
        if( row )
            for( unsigned i = 0; i < n && i < outVars.size(); ++i )
            {
                const char* raw = row[ i ];
                if( !raw ) parsed.push_back( Json( nullptr ) );
                else parsed.push_back( parseJsonOrValue( raw ) );
            }
        mysql_free_result( res );

        if( mode == MergeMode::Single )
            return parsed.empty() ? Json( nullptr ) : parsed[ 0 ];
        Json out = Json::object();
        for( std::size_t i = 0; i < outVars.size() && i < parsed.size(); ++i )
            out[ outVars[ i ] ] = parsed[ i ];
        return out;
    }

    // Dynamic text fetch of one row of the statement's CURRENT stored result set:
    // first bind grabs the per-column lengths (1-byte dummy buffers, so a
    // MYSQL_DATA_TRUNCATED return is expected), then fetch_column copies the real
    // bytes per column. Works for numeric columns too (STRING conversion).
    static bool fetchTextRow( MYSQL_STMT* stmt, unsigned nfields, std::vector<Json>& out )
    {
        static char kDummy = 0;
        std::vector<MYSQL_BIND> bind( nfields );
        std::vector<unsigned long> lens( nfields, 0 );
        for( unsigned i = 0; i < nfields; ++i )
        {
            std::memset( &bind[ i ], 0, sizeof( MYSQL_BIND ) );
            bind[ i ].buffer_type = MYSQL_TYPE_STRING;
            bind[ i ].buffer = &kDummy;
            bind[ i ].buffer_length = 1;
            bind[ i ].length = &lens[ i ];
        }
        if( mysql_stmt_bind_result( stmt, bind.data() ) != 0 ) return false;
        const int rc = mysql_stmt_fetch( stmt );
        if( rc == MYSQL_NO_DATA ) return false;
        if( rc == 1 ) return false;    // real error; callers surface stmt error separately

        out.assign( nfields, Json( nullptr ) );
        for( unsigned i = 0; i < nfields; ++i )
        {
            if( lens[ i ] == 0 ) continue;    // NULL (or the empty string's zero length, both decode harmlessly)
            std::string v( lens[ i ], '\0' );
            MYSQL_BIND one{};
            one.buffer_type = MYSQL_TYPE_STRING;
            one.buffer = &v[ 0 ];
            one.buffer_length = static_cast<unsigned long>( lens[ i ] ) + 1;
            if( mysql_stmt_fetch_column( stmt, &one, i, 0 ) != 0 ) continue;
            v.resize( lens[ i ] );
            out[ i ] = Json( v );
        }
        return true;
    }

    Json Db::callProcResultSet( const std::string& proc, const std::vector<SqlValue>& params, const std::string& column )
    {
        std::lock_guard<std::mutex> lk( mu_ );

        std::string placeholders;
        for( std::size_t i = 0; i < params.size(); ++i ) placeholders += ( i ? ",?" : "?" );
        const std::string sql = "CALL " + proc + "(" + placeholders + ")";

        MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
        if( !stmt ) throw ToolError( ErrorClass::ServerInternal, "mysql_stmt_init failed" );
        if( mysql_stmt_prepare( stmt, sql.c_str(), static_cast<unsigned long>( sql.size() ) ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }
        // The bind buffers must still exist when mysql_stmt_execute runs below:
        // the driver keeps pointers to them and reads them at that point, so
        // they cannot live inside the block that fills them in.
        std::vector<MYSQL_BIND> binds( params.size() );
        std::vector<std::string> strStorage( params.size() );
        std::vector<long long> intStorage( params.size() );
        std::vector<std::int32_t> int32Storage( params.size() );
        std::vector<double> dblStorage( params.size() );
        if( !params.empty() )
        {
            for( std::size_t i = 0; i < params.size(); ++i )
            {
                const SqlValue& v = params[ i ];
                if( std::holds_alternative<std::nullptr_t>( v ) )
                { binds[ i ].buffer_type = MYSQL_TYPE_NULL; }
                else if( std::holds_alternative<std::int64_t>( v ) )
                // Integers travel as binary integers. A value that fits 32 bits goes out
                // as a 4-byte LONG, the width of the procedure's own INT parameter
                // (fractal_vectorizer_process_queue declares p_batch_size INT), so
                // the server needs no widening; a wider value goes out as an 8-byte
                // LONGLONG rather than being truncated. Both carry the value intact
                // for an INT and for a BIGINT parameter alike, which the db probe's
                // echo procedure asserts.
                { const std::int64_t n = std::get<std::int64_t>( v );
                  if( n >= INT32_MIN && n <= INT32_MAX )
                  { int32Storage[ i ] = static_cast<std::int32_t>( n );
                    binds[ i ].buffer_type = MYSQL_TYPE_LONG;
                    binds[ i ].buffer = &int32Storage[ i ]; }
                  else
                  { intStorage[ i ] = n;
                    binds[ i ].buffer_type = MYSQL_TYPE_LONGLONG;
                    binds[ i ].buffer = &intStorage[ i ]; } }
                else if( std::holds_alternative<double>( v ) )
                { dblStorage[ i ] = std::get<double>( v );
                  binds[ i ].buffer_type = MYSQL_TYPE_DOUBLE; binds[ i ].buffer = &dblStorage[ i ]; }
                else
                { strStorage[ i ] = std::get<std::string>( v );
                  binds[ i ].buffer_type = MYSQL_TYPE_STRING;
                  binds[ i ].buffer = &strStorage[ i ][ 0 ];
                  binds[ i ].buffer_length = static_cast<unsigned long>( strStorage[ i ].size() ); }
            }
            if( mysql_stmt_bind_param( stmt, binds.data() ) != 0 )
            { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
              mysql_stmt_close( stmt ); throw classify( e, c ); }
        }

        if( mysql_stmt_execute( stmt ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        // CAPTURE the procedure's FIRST result set (a bound fetch) before draining
        // the rest; the usual OUT-variable pattern would discard it, and
        // fractal_vectorizer_process_queue needs it.
        Json out{ { column, Json( nullptr ) } };
        if( mysql_stmt_field_count( stmt ) > 0 )
        {
            if( mysql_stmt_store_result( stmt ) != 0 )
            { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
              mysql_stmt_close( stmt ); throw classify( e, c ); }
            MYSQL_RES* meta = mysql_stmt_result_metadata( stmt );
            const unsigned n = meta ? mysql_num_fields( meta ) : 0;
            if( meta ) mysql_free_result( meta );
            std::vector<Json> row;
            if( n > 0 && fetchTextRow( stmt, n, row ) && !row.empty() )
                out[ column ] = parseJsonOrValue( row[ 0 ].is_string()
                                                    ? row[ 0 ].get<std::string>().c_str() : nullptr );
        }
        do { } while( mysql_stmt_next_result( stmt ) == 0 );
        const unsigned int drainErr = mysql_stmt_errno( stmt );
        mysql_stmt_close( stmt );
        if( drainErr != 0 )
            throw classify( std::string( "procedure " ) + proc + " failed while producing results", drainErr );
        return out;
    }

    Json Db::selectScalarJson( const std::string& expr )   // constant SQL text only
    {
        std::lock_guard<std::mutex> lk( mu_ );
        if( mysql_real_query( conn_, expr.c_str(), static_cast<unsigned long>( expr.size() ) ) != 0 )
        { const unsigned int c = mysql_errno( conn_ ); const std::string e = mysql_error( conn_ );
          throw classify( e, c ); }
        MYSQL_RES* res = mysql_store_result( conn_ );
        if( !res ) return Json( nullptr );
        MYSQL_ROW row = mysql_fetch_row( res );
        Json out = ( row && row[ 0 ] ) ? parseJsonOrValue( row[ 0 ] ) : Json( nullptr );
        mysql_free_result( res );
        return out;
    }

    Json Db::callScalarBind( const std::string& sql, const std::vector<SqlValue>& binds )
    {
        std::lock_guard<std::mutex> lk( mu_ );
        std::string text;
        if( !scalarTextLocked( sql, binds, text ) ) return Json( nullptr );
        return parseJsonOrValue( text.c_str() );
    }

    // The bound single-value read, shared by callScalarBind (which
    // interprets the result as JSON) and callScalarBindText (which does
    // not). Returns false when the query produced no row or the first
    // column was SQL NULL.
    //
    // CALLER CONTRACT: mu_ already held.
    bool Db::scalarTextLocked( const std::string& sql, const std::vector<SqlValue>& binds,
                               std::string& out )
    {
        MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
        if( !stmt ) throw ToolError( ErrorClass::ServerInternal, "mysql_stmt_init failed" );
        if( mysql_stmt_prepare( stmt, sql.c_str(), static_cast<unsigned long>( sql.size() ) ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        std::vector<MYSQL_BIND> bind( binds.size() );
        std::vector<std::string> strStorage( binds.size() );
        std::vector<long long> intStorage( binds.size() );
        std::vector<double> dblStorage( binds.size() );
        for( std::size_t i = 0; i < binds.size(); ++i )
        {
            const SqlValue& v = binds[ i ];
            if( std::holds_alternative<std::nullptr_t>( v ) )
            { bind[ i ].buffer_type = MYSQL_TYPE_NULL; }
            else if( std::holds_alternative<std::int64_t>( v ) )
            { intStorage[ i ] = std::get<std::int64_t>( v );
              bind[ i ].buffer_type = MYSQL_TYPE_LONGLONG; bind[ i ].buffer = &intStorage[ i ];
              bind[ i ].is_unsigned = 1; }
            else if( std::holds_alternative<double>( v ) )
            { dblStorage[ i ] = std::get<double>( v );
              bind[ i ].buffer_type = MYSQL_TYPE_DOUBLE; bind[ i ].buffer = &dblStorage[ i ]; }
            else
            { strStorage[ i ] = std::get<std::string>( v );
              bind[ i ].buffer_type = MYSQL_TYPE_STRING;
              bind[ i ].buffer = &strStorage[ i ][ 0 ];
              bind[ i ].buffer_length = static_cast<unsigned long>( strStorage[ i ].size() ); }
        }
        if( !bind.empty() && mysql_stmt_bind_param( stmt, bind.data() ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }
        if( mysql_stmt_execute( stmt ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }
        if( mysql_stmt_store_result( stmt ) != 0 )
        { const unsigned int c = mysql_stmt_errno( stmt ); const std::string e = mysql_stmt_error( stmt );
          mysql_stmt_close( stmt ); throw classify( e, c ); }

        MYSQL_RES* meta = mysql_stmt_result_metadata( stmt );
        const unsigned n = meta ? mysql_num_fields( meta ) : 0;
        if( meta ) mysql_free_result( meta );
        bool got = false;
        if( n > 0 )
        {
            std::vector<Json> row;
            if( fetchTextRow( stmt, n, row ) && !row.empty() && row[ 0 ].is_string() )
            { out = row[ 0 ].get<std::string>(); got = true; }
        }
        mysql_stmt_close( stmt );
        return got;
    }

    std::optional<std::string> Db::callScalarBindText( const std::string& sql,
                                                       const std::vector<SqlValue>& binds )
    {
        std::lock_guard<std::mutex> lk( mu_ );
        std::string text;
        if( !scalarTextLocked( sql, binds, text ) ) return std::nullopt;
        return text;
    }

    Json Db::selectRowsRaw( const std::string& sql )   // constant SQL, no binds
    {
        Json out = Json::array();
        MYSQL_RES* res = nullptr;
        try
        {
            std::lock_guard<std::mutex> lk( mu_ );
            if( mysql_real_query( conn_, sql.c_str(), static_cast<unsigned long>( sql.size() ) ) != 0 )
            { const unsigned int c = mysql_errno( conn_ ); const std::string e = mysql_error( conn_ );
              throw classify( e, c ); }
            res = mysql_store_result( conn_ );
            if( !res ) return out;
            const unsigned n = mysql_num_fields( res );
            MYSQL_FIELD* fields = mysql_fetch_fields( res );
            std::vector<std::string> names( n );
            for( unsigned i = 0; i < n; ++i ) names[ i ] = fields[ i ].name ? fields[ i ].name : "";
            MYSQL_ROW row;
            while( ( row = mysql_fetch_row( res ) ) != nullptr )
            {
                Json rec = Json::object();
                for( unsigned i = 0; i < n; ++i )
                {
                    unsigned long* lens = mysql_fetch_lengths( res );
                    if( !row[ i ] || ( lens && lens[ i ] == 0 ) ) rec[ names[ i ] ] = Json( nullptr );
                    else
                    {
                        std::string v( row[ i ], lens[ i ] );
                        try { rec[ names[ i ] ] = Json::parse( v ); }
                        catch( ... ) { rec[ names[ i ] ] = v; }
                    }
                }
                out.push_back( std::move( rec ) );
            }
        }
        catch( ... ) { if( res ) mysql_free_result( res ); throw; }
        mysql_free_result( res );
        return out;
    }

    bool Db::probeAlive()
    {
        try
        {
            std::lock_guard<std::mutex> lk( mu_ );
            if( !conn_ ) return false;
            if( mysql_real_query( conn_, "SELECT 1", 8 ) != 0 )
            { if( mysql_ping( conn_ ) != 0 ) return false;
              if( mysql_real_query( conn_, "SELECT 1", 8 ) != 0 ) return false; }
            MYSQL_RES* res = mysql_store_result( conn_ );
            if( res ) mysql_free_result( res );
            return true;
        }
        catch( ... ) { return false; }
    }

    void Db::sessionClose()
    {
        if( !conn_ ) return;
        try
        {
            MYSQL_STMT* stmt = mysql_stmt_init( conn_ );
            if( !stmt ) return;
            const char* sql = "SELECT fractal_session_close(?)";
            if( mysql_stmt_prepare( stmt, sql, static_cast<unsigned long>( strlen( sql ) ) ) != 0 )
            { mysql_stmt_close( stmt ); return; }
            const unsigned long cid = mysql_thread_id( conn_ );
            MYSQL_BIND b{}; b.buffer_type = MYSQL_TYPE_LONGLONG; b.buffer = const_cast<unsigned long*>( &cid );
            b.is_unsigned = 1;
            if( mysql_stmt_bind_param( stmt, &b ) != 0 )
            { mysql_stmt_close( stmt ); return; }
            if( mysql_stmt_execute( stmt ) == 0 )
                do { } while( mysql_stmt_next_result( stmt ) == 0 );
            mysql_stmt_close( stmt );
        }
        catch( ... ) {}    // never blocks shutdown
    }

    void Db::close()
    {
        sessionClose();
        std::lock_guard<std::mutex> lk( mu_ );
        if( conn_ ) { mysql_close( conn_ ); conn_ = nullptr; }
    }

    // The one-shot control connection lives in killQuery below; cancelInflight
    // only routes this session's own thread id at it (server-driven via
    // ServerConfig::cancelHook, see jsonrpc_server.h).
    void Db::cancelInflight( unsigned long connectionIdToKill )
    {
        if( !conn_ || connectionIdToKill == 0 ) return;
        killQuery( cfg_, connectionIdToKill );
    }

    void killQuery( const EngineConfig& cfg, unsigned long connectionId )
    {
        MYSQL* ctrl = mysql_init( nullptr );
        if( !ctrl ) return;
        const unsigned int connectTimeout = connectTimeoutSeconds();
        mysql_options( ctrl, MYSQL_OPT_CONNECT_TIMEOUT, &connectTimeout );
        // The control connection must authenticate EXACTLY like the session
        // connection it is aborting (openDatabase): an empty user means
        // "root" there, so the same default has to apply here. Passing the
        // empty string instead made the control connection fail to
        // authenticate, and the KILL QUERY that follows it silently never
        // happened -- the abort the client asked for was simply dropped.
        if( !mysql_real_connect( ctrl, cfg.host.c_str(),
                                   cfg.user.empty() ? "root" : cfg.user.c_str(), cfg.password.c_str(),
                                   cfg.database.empty() ? nullptr : cfg.database.c_str(),
                                   static_cast<unsigned int>( cfg.port ), nullptr, 0 ) )
        { mysql_close( ctrl ); return; }
        // "KILL QUERY <id>", the id is the server's own CONNECTION_ID for this
        // worker, never caller-supplied text.
        const std::string sql = "KILL QUERY " + std::to_string( connectionId );
        mysql_real_query( ctrl, sql.c_str(), static_cast<unsigned long>( sql.size() ) );
        mysql_close( ctrl );
    }
}