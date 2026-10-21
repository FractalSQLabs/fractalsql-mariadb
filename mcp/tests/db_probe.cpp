// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Standalone unit-test probe for mcp/src/db.h's Db class.
//
// MariaDB-shaped: this repo's Db talks to a LIVE MariaDB server through
// the C connector (no vendored engine here), so the probe runs against
// the same scratch cluster every other gate serves from -- the connection
// details come in through the standard MARIADB_* environment variables,
// exactly as the MCP server itself reads them (EngineConfig::fromEnv).
// Every assertion below is about a real round trip to a real server, so
// the probe skips cleanly (exit 0, no failure) when no server is
// reachable -- a missing cluster is not a defect in db.h.
//
// What this covers that the live tools/call round trip does not:
//   * the error-classification table (Db::classify) reached through
//     real server-side failures rather than through a stub,
//   * the OUT-variable merge modes (Single / Fields / None / ResultSet),
//   * the bind path (a NULL bind, a non-ASCII string bind, a big-integer
//     bind) -- every value must reach the engine as a BOUND parameter,
//     never as interpolated SQL text,
//   * the version-skew guard (Db::checkVersionSkew) in its matching and
//     mismatching forms.
#include "../src/db.h"
#include "../src/errors.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

using fsqlmcp::Db;
using fsqlmcp::EngineConfig;
using fsqlmcp::ErrorClass;
using fsqlmcp::Json;
using fsqlmcp::MergeMode;
using fsqlmcp::SqlValue;
using fsqlmcp::ToolError;

static int failed = 0;

static void check( const char* label, bool cond )
{
    std::printf( "%s %s\n", cond ? "OK:" : "FAIL:", label );
    if( !cond ) failed = 1;
}

// The driver layer's text-to-JSON contract, spelled out once: a column
// whose text is NOT itself a JSON document comes back wrapped in a
// {"value": <text>} envelope (Db::parseJsonOrValue). A column whose
// text IS a JSON document comes back as that document, unwrapped. Every
// adapter unwraps the envelope explicitly (see the cognition adapter's
// own unwrap lambda), so the probe asserts the same contract rather
// than assuming a bare scalar.
static bool envelopeText( const Json& v, std::string& out )
{
    if( v.is_object() && v.contains( "value" ) && v.at( "value" ).is_string() )
    {
        out = v.at( "value" ).get<std::string>();
        return true;
    }
    return false;
}

// Runs fn and reports the ErrorClass it threw (or Schema if it threw
// something that is not a ToolError at all).
static ErrorClass errorClassOf( const std::function<void()>& fn )
{
    try { fn(); }
    catch( const ToolError& e ) { return e.errorClass; }
    catch( ... ) { return ErrorClass::Schema; }
    return ErrorClass::Schema;
}

static int runChecks()
{
    EngineConfig cfg = EngineConfig::fromEnv();
    if( cfg.host.empty() || cfg.database.empty() )
    {
        std::printf( "SKIP: db_probe (no MARIADB_HOST/MARIADB_DATABASE in the environment)\n" );
        return 0;
    }

    Db db;
    try
    {
        db.connect( cfg );
    }
    catch( const ToolError& e )
    {
        std::printf( "SKIP: db_probe (no reachable MariaDB server at %s:%d: %s)\n",
                     cfg.host.c_str(), cfg.port, e.message.c_str() );
        return 0;
    }
    catch( ... )
    {
        std::printf( "SKIP: db_probe (no reachable MariaDB server at %s:%d)\n",
                     cfg.host.c_str(), cfg.port );
        return 0;
    }

    // --- the connection itself
    check( "connect: the session has a live connection id", db.threadId() != 0 );
    check( "connect: probeAlive() reports the connection is up", db.probeAlive() );

    // --- selectScalarJson: a constant expression and a bound one.
    {
        const Json v = db.selectScalarJson( "SELECT fractal_version()" );
        check( "selectScalarJson: fractal_version() comes back as a value envelope",
               v.is_object() && v.contains( "value" ) );
    }
    {
        // A constant SQL text only -- no user data in it. The value is
        // returned as a plain (non-JSON) string, which parseJsonOrValue
        // wraps into {"value": ...} rather than failing to parse.
        const Json v = db.selectScalarJson( "SELECT 'not json at all'" );
        check( "selectScalarJson: a non-JSON scalar is wrapped, not dropped",
               v.is_object() && v.contains( "value" ) );
    }

    // --- callScalarBind: every value must arrive as a BOUND parameter.
    {
        const std::vector<SqlValue> binds = { SqlValue( std::int64_t( 42 ) ) };
        const Json v = db.callScalarBind( "SELECT ?", binds );
        check( "callScalarBind: a bound integer round-trips", v.dump() == "42" );
    }
    {
        // A bound string that is NOT itself JSON text comes back in the
        // driver's {"value": ...} envelope (see envelopeText above) --
        // the value is the string, unchanged, and it arrived as a BOUND
        // parameter (the quote and the semicolon are data, never SQL).
        const std::vector<SqlValue> binds = { SqlValue( std::string( "a'b;c" ) ) };
        const Json v = db.callScalarBind( "SELECT ?", binds );
        std::string text;
        check( "callScalarBind: a bound string with quotes and a semicolon is "
               "carried as DATA, not as SQL text",
               envelopeText( v, text ) && text == "a'b;c" );
    }
    {
        const std::vector<SqlValue> binds = { SqlValue( nullptr ) };
        const Json v = db.callScalarBind( "SELECT ?", binds );
        check( "callScalarBind: a NULL bind arrives as NULL", v.is_null() );
    }
    {
        // A non-ASCII value: the connection's character set must carry it
        // through intact, not mangle it into a replacement character.
        // The comparison is on the RAW BYTES, not on the JSON escape
        // form: the driver hands back the UTF-8 bytes it received, and
        // the JSON layer's own escaping of them is a serialization
        // detail, not part of what the round trip preserved.
        const std::vector<SqlValue> binds = { SqlValue( std::string( "caf\xc3\xa9" ) ) };
        const Json v = db.callScalarBind( "SELECT ?", binds );
        std::string text;
        const bool ok = envelopeText( v, text ) && text == "caf\xc3\xa9";
        check( "callScalarBind: a non-ASCII bound string survives the round trip", ok );
        if( !ok )
            std::printf( "      (got %s)\n", v.dump().c_str() );
    }

    // --- callProc: a real stored procedure, Single merge mode.
    {
        // fractal_schema_context(table_names_json, out_context) -- a
        // two-argument procedure with one OUT var.
        //
        // NULL, not "[]": an EMPTY array is a positive request for
        // zero tables, and the engine answers it with its own "no
        // visible tables found" error -- while NULL means "every table
        // visible to me". The two are different requests and only the
        // second one is what this call is for (confirmed live: '[]'
        // raises SQLSTATE 45000 with "no visible tables found" while
        // NULL returns the full schema description). The MCP's own
        // schema-context adapter makes exactly this distinction --
        // it sends NULL when table_names is omitted.
        const std::vector<SqlValue> params = { SqlValue( nullptr ) };
        const std::vector<std::string> outs = { "fsq_out_0" };
        const Json v = db.callProc( "fractal_schema_context", params, outs, MergeMode::Single );
        std::string text;
        check( "callProc: fractal_schema_context returns its OUT var",
               envelopeText( v, text ) && text.find( "Table:" ) != std::string::npos );
    }
    {
        // The empty-array form is the documented error path: an empty
        // list of tables is a request for nothing, and the engine's own
        // SIGNAL must reach the caller VERBATIM (classified Engine --
        // the 45000 SQLSTATE, not a crash).
        const std::vector<SqlValue> params = { SqlValue( std::string( "[]" ) ) };
        const std::vector<std::string> outs = { "fsq_out_0" };
        std::string msg;
        ErrorClass ec = ErrorClass::Schema;
        try
        {
            db.callProc( "fractal_schema_context", params, outs, MergeMode::Single );
        }
        catch( const ToolError& e )
        {
            ec = e.errorClass;
            msg = e.message;
        }
        check( "callProc: a 45000 SIGNAL from fractal_schema_context is an "
               "Engine-class error",
               ec == ErrorClass::Engine );
        check( "callProc: fractal_schema_context's own message reaches the "
               "caller verbatim",
               msg.find( "no visible tables found" ) != std::string::npos );
    }

    // --- callProc: the merge mode that returns several OUT vars as a
    // keyed object (the text_to_sql shape: out_sql / out_error).
    {
        // table_names is NULL (auto-discover), for the same reason as
        // the schema_context call above: '[]' is a request for zero
        // tables, and the engine refuses it with its own SIGNAL.
        const std::vector<SqlValue> params = {
            SqlValue( std::string( "how many customers are there?" ) ),
            SqlValue( nullptr )
        };
        const std::vector<std::string> outs = { "fsq_out_0", "fsq_out_1" };
        Json v;
        bool threw = false;
        std::string msg;
        try
        {
            v = db.callProc( "fractal_text_to_sql", params, outs, MergeMode::Fields );
        }
        catch( const ToolError& e )
        {
            threw = true;
            msg = e.message;
        }
        if( threw )
        {
            check( "callProc: a two-OUT procedure merges into a keyed object", false );
            std::printf( "      (threw: %s)\n", msg.c_str() );
        }
        else
        {
            check( "callProc: a two-OUT procedure merges into a keyed object",
                   v.is_object() && v.contains( "fsq_out_0" ) && v.contains( "fsq_out_1" ) );
            // The procedure's own contract: exactly ONE of out_sql /
            // out_error is set on return -- both NULL is not a possible
            // outcome, and neither is a defect (the MCP's own cognition
            // adapter asserts exactly this before it trusts the pair).
            // This holds whether or not the engine has a reasoning
            // plugin: with one, out_sql carries the statement; without
            // one, out_error carries the failure reason. Both OUT vars
            // are TEXT, so each arrives in the {"value": ...} envelope.
            std::string sqlText, errText;
            const bool haveSql = envelopeText( v.value( "fsq_out_0", Json( nullptr ) ), sqlText );
            const bool haveErr = envelopeText( v.value( "fsq_out_1", Json( nullptr ) ), errText );
            check( "callProc: exactly one of the two OUT vars carries a result",
                   haveSql != haveErr );
        }
    }

    // --- callProc on a procedure that does not exist: a real server-side
    // failure, classified rather than crashed on.
    {
        const std::vector<SqlValue> params = {};
        const std::vector<std::string> outs = { "fsq_out_0" };
        const ErrorClass ec = errorClassOf( [&] {
            db.callProc( "fractal_no_such_procedure_at_all", params, outs, MergeMode::Single );
        } );
        check( "callProc: a nonexistent procedure is an Engine-class error, not a crash",
               ec == ErrorClass::Engine );
    }

    // --- callProc on a procedure whose SIGNAL is SQLSTATE 45000: the
    // engine's own documented, actionable text must reach the caller
    // VERBATIM (classified as Engine, message preserved).
    {
        const std::vector<SqlValue> params = {
            SqlValue( std::string( "definitely_no_such_table_zz" ) ),
            SqlValue( std::string( "body" ) ),
            SqlValue( std::string( "emb" ) ),
            SqlValue( nullptr )
        };
        const std::vector<std::string> outs = { "fsq_out_0" };
        std::string msg;
        ErrorClass ec = ErrorClass::Schema;
        try
        {
            db.callProc( "fractal_vectorizer_create", params, outs, MergeMode::Single );
        }
        catch( const ToolError& e )
        {
            ec = e.errorClass;
            msg = e.message;
        }
        check( "callProc: a 45000 SIGNAL is an Engine-class error", ec == ErrorClass::Engine );
        check( "callProc: a 45000 SIGNAL's own message reaches the caller verbatim",
               msg.find( "source_table not found" ) != std::string::npos );
    }

    // --- callProcResultSet: the one procedure whose result arrives as an
    // ordinary result set rather than an OUT variable.
    {
        const std::vector<SqlValue> params = {
            SqlValue( std::int64_t( 10 ) ),
            SqlValue( std::int64_t( 600 ) )
        };
        const Json v = db.callProcResultSet( "fractal_vectorizer_process_queue", params );
        check( "callProcResultSet: the first result set's first row is captured, "
               "not discarded",
               v.is_object() && v.contains( "n_processed" ) );
    }

    // --- callProcResultSet with INTEGER parameters: the values must reach
    // the procedure's own parameters INTACT.
    //
    // The check above proves the result set is captured, but it cannot
    // prove the PARAMETER arrived: fractal_vectorizer_process_queue returns
    // a count that does not depend on the batch size it was handed, so a
    // bind that reached the server as the wrong bytes still "passes" that
    // check. This probe-owned procedure returns its parameters instead, so a
    // bind that arrives as the wrong type, or as the wrong bytes, shows up
    // as a wrong number instead of as a silent success.
    //
    // The two parameters have DIFFERENT declared widths on purpose (an INT
    // and a BIGINT): a bind that the server reads at a width other than the
    // one the client wrote -- the failure that a single-width procedure
    // would hide -- desynchronizes the parameter stream here and shows up
    // as a wrong number or as a malformed-packet error.
    //
    // The procedure is created and dropped by the probe itself; it lives
    // only for the duration of this check.
    {
        mysql_query( db.raw(), "DROP PROCEDURE IF EXISTS fsq_probe_int_echo" );
        mysql_query( db.raw(),
            "CREATE PROCEDURE fsq_probe_int_echo(IN p_v INT, IN p_w BIGINT) "
            "SELECT CONCAT(p_v, '/', p_w) AS v" );
        const std::vector<SqlValue> params = {
            SqlValue( std::int64_t( 4242 ) ),
            SqlValue( std::int64_t( 4243 ) )
        };
        const Json v = db.callProcResultSet( "fsq_probe_int_echo", params, "v" );
        // The captured value is the driver's {"value": <text>} envelope for
        // non-JSON text (see envelopeText above), nested under the column key.
        const Json inner = ( v.is_object() && v.contains( "v" ) ) ? v.at( "v" ) : Json( nullptr );
        std::string text;
        check( "callProcResultSet: bound integers reach an INT and a BIGINT "
               "procedure parameter intact",
               envelopeText( inner, text ) && text == "4242/4243" );
        if( !envelopeText( inner, text ) )
            std::printf( "      (got %s)\n", v.dump().c_str() );
        else if( text != "4242/4243" )
            std::printf( "      (got %s)\n", text.c_str() );
        mysql_query( db.raw(), "DROP PROCEDURE IF EXISTS fsq_probe_int_echo" );
    }

    // --- the OUT-var decode of a JSON-document column: a column whose
    // text IS a JSON document comes back as that document, UNWRAPPED.
    // This is the other half of the driver's text-to-JSON contract (the
    // first half is the {"value": ...} envelope for non-JSON text, see
    // envelopeText above), and it is what every adapter relies on when
    // it hands an engine's JSON result straight to the client.
    {
        // _fractalsql_telemetry_topk's OUT var is a JSON array of
        // {"doc_id":..,"dist":..} objects -- a real JSON document, not
        // plain text. Its first argument is the corpus, so a one-row
        // corpus is enough to make it produce a result.
        const std::vector<SqlValue> params = {
            SqlValue( std::string( "[[1.0,2.0,3.0]]" ) ),   // corpus
            SqlValue( std::string( "[1]" ) ),                // doc ids
            SqlValue( std::string( "[1.0,2.0,3.0]" ) ),     // query vector
            SqlValue( std::int64_t( 1 ) )                   // k
        };
        const std::vector<std::string> outs = { "fsq_out_0" };
        const Json v = db.callProc( "_fractalsql_telemetry_topk", params, outs, MergeMode::Single );
        check( "callProc: a JSON-document OUT var is decoded unwrapped, not "
               "wrapped in a value envelope",
               v.is_array() && v.size() == 1 && v[ 0 ].is_object()
                 && v[ 0 ].contains( "doc_id" ) && v[ 0 ].contains( "dist" ) );
    }

    // --- the version-skew guard: matching and mismatching forms. It is a
    // WARN line, never a throw, so both calls must simply return.
    {
        bool threw = false;
        try { db.checkVersionSkew( "2.0.0" ); }   // deliberately mismatched
        catch( ... ) { threw = true; }
        check( "checkVersionSkew: a mismatch warns and never throws", !threw );
    }
    {
        bool threw = false;
        try { db.checkVersionSkew( "" ); }        // empty -> no-op
        catch( ... ) { threw = true; }
        check( "checkVersionSkew: an empty expectation is a no-op", !threw );
    }

    // --- sessionClose and close: both must be safe, and the connection
    // must be gone afterwards.
    db.sessionClose();
    db.close();
    check( "close: the connection is released", db.threadId() == 0 );

    return failed ? 1 : 0;
}

int main()
{
    // stdout is block-buffered when it is redirected (the harness captures
    // the probe's output into a pipe), so a probe that dies part-way
    // through would swallow every check that had already passed -- the
    // harness would then see "no output at all" and no clue where the
    // probe stopped. Unbuffered, the checks that ran are visible even
    // when the probe dies.
    std::setvbuf( stdout, nullptr, _IONBF, 0 );

    // A probe is a test, not a server: an escaping exception is a FAILED
    // check, not a crashed process. Letting it escape terminated the
    // probe with 0xC0000409 and, because stdout was still buffered, the
    // whole run reported nothing at all.
    try
    {
        return runChecks();
    }
    catch( const ToolError& e )
    {
        std::printf( "FAIL: an unexpected error escaped a check: %s\n", e.message.c_str() );
        return 1;
    }
    catch( const std::exception& e )
    {
        std::printf( "FAIL: an unexpected exception escaped a check: %s\n", e.what() );
        return 1;
    }
    catch( ... )
    {
        std::printf( "FAIL: an unexpected exception escaped a check\n" );
        return 1;
    }
}
