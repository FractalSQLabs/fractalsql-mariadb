// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Enterprise / ledger tier tools -- all gated.
//
// Dormancy convention: the ledger's write-path/count UDFs are NULL-dormant on
// a Community install (the C UDF ABI can't SIGNAL), so those tools surface a
// clean named condition instead of an empty result -- never silent.
// fractal_ledger_verify and fractal_audit_unpack are pure read-only forensic
// queries that work even with no enterprise library loaded (documented), on
// every tier.
//
// Safety annotations (6): fractal_ledger_reset_hard explicitly empties the
// ledgers' history -> destructive. The enterprise-config admin surface
// (editing enterprise_lib / the ledger HMAC key / signature posture) is
// NOT exposed as tools at all -- that's an operator action taken against
// fractalsqld directly; see the admin tier's own allowlist.

#include "enterprise.h"
#include "helpers.h"
#include "../db.h"
#include "../tool_param_helpers.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildEnterpriseTools( Db& db )
    {
        using namespace adap;
        std::vector<ToolSpec> t;

        auto dormant = []( const Json& result, const char* name ) -> Json
        {
            if( resultIsNull( result ) )
                throw ToolError( ErrorClass::Engine,
                    std::string( name ) + ": enterprise tier not loaded (engine returned "
                    "NULL-dormant; see docs/enterprise.md)" );
            return result;
        };

        // The int-returning write-path family: SELECT name(session_id); NULL ->
        // the clean dormant condition; otherwise {"rc": value}.
        auto intFamily = [ &db, dormant ]( const char* name ) -> Json
        {
            Json raw = db.callScalarBind( ( std::string( "SELECT " ) + name + "(?)" ).c_str(),
                                           { SqlValue( sessionId( db ) ) } );
            return Json{ { "rc", dormant( std::move( raw ), name ) } };
        };

        t.push_back( mkTool( "fractal_ledger_flush", "enterprise", "stateful", ToolClass::Cheap,
            "Encode the truth + shadow ledgers into a QTL blob and append it to the "
            "ledger file-backed hash chain (kind=1). Writes the chain; resets the "
            "in-memory staging. Enterprise tier.",
            {},
            [ &db, intFamily ]( const Json&, CallCtx& ) { return intFamily( "fractal_ledger_flush" ); },
            false, true ) );   // destructiveHint: writes the chain (6: ledger write-path tools)

        t.push_back( mkTool( "fractal_ledger_load", "enterprise", "stateful", ToolClass::Cheap,
            "Hydrate the in-memory ledgers from the chain's LATEST entry (verifies only "
            "the tip, O(1)). Enterprise tier.",
            {},
            [ &db, intFamily ]( const Json&, CallCtx& ) { return intFamily( "fractal_ledger_load" ); } ) );

        t.push_back( mkTool( "fractal_ledger_compact", "enterprise", "stateful", ToolClass::Cheap,
            "Defragment / re-pack the in-memory QTL representation. Enterprise tier.",
            {},
            [ &db, intFamily ]( const Json&, CallCtx& ) { return intFamily( "fractal_ledger_compact" ); },
            false, true ) );

        t.push_back( mkTool( "fractal_ledger_reset_soft", "enterprise", "stateful", ToolClass::Cheap,
            "Soft-reset the ledger counters WITHOUT dropping chain history. Enterprise tier.",
            {},
            [ &db, intFamily ]( const Json&, CallCtx& ) { return intFamily( "fractal_ledger_reset_soft" ); },
            false, true ) );

        t.push_back( mkTool( "fractal_ledger_reset_hard", "enterprise", "stateful", ToolClass::Cheap,
            "Hard-reset the ledgers to EMPTY -- explicitly loses history; the chain "
            "history on disk is untouched but in-memory counters/entries are zeroed. "
            "A client UI honoring the destructiveHint annotation will ask a human first.",
            {},
            [ &db, intFamily ]( const Json&, CallCtx& ) { return intFamily( "fractal_ledger_reset_hard" ); },
            false, true ) );

        const std::pair<const char*, const char*> counts[] =
        {
            { "fractal_ledger_truth_count", "Truth-side entry count of the in-memory ledger." },
            { "fractal_ledger_shadow_count", "Shadow-side entry count of the in-memory ledger." },
        };
        for( const auto& c : counts )
        {
            t.push_back( mkTool( c.first, "enterprise", "pure", ToolClass::Cheap, c.second, {},
                [ &db, dormant, name = c.first ]( const Json&, CallCtx& )
                {
                    Json raw = db.callScalarBind( ( std::string( "SELECT " ) + name + "(?)" ).c_str(),
                                                   { SqlValue( sessionId( db ) ) } );
                    return Json{ { "count", dormant( std::move( raw ), name ) } };
                }, true ) );
        }

        t.push_back( mkTool( "fractal_ledger_verify", "enterprise", "pure", ToolClass::Cheap,
            "Walk the ENTIRE hash chain for a given kind (O(n)) -> {ok, rows_verified} or "
            "{ok:false, first_failure_id, reason}. Pure READ-ONLY forensic query: works even "
            "with NO enterprise library loaded, on every tier -- this is the CISO audit check "
            "(kind=1 QTL chain, kind=2 general decision-audit chain), not the count tools above.",
            { Int( "kind", false, "1 = QTL chain, 2 = general decision-audit chain", 1 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                const int kind = a.contains( "kind" ) && a.at( "kind" ).is_number_integer()
                                   ? a.at( "kind" ).get<int>() : 1;
                return db.callScalarBind( "SELECT fractal_ledger_verify(?, ?)",
                    { SqlValue( sessionId( db ) ), SqlValue( static_cast<std::int64_t>( kind ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_audit_log", "enterprise", "stateful", ToolClass::Cheap,
            "General decision-audit append (kind=2 chain). Every decision-making agent already "
            "logs to this chain automatically when enterprise is active; exposed here directly "
            "for custom provenance records. Enterprise tier (dormant NULL -> clean condition "
            "otherwise); community deployments silently skip agent-side logging, which is why "
            "the MCP layer keeps its OWN per-call log independent of this ledger.",
            { Str( "entry_type", true, "provenance kind tag, e.g. 'custom_check'" ),
              Str( "payload", true, "the provenance record, as a JSON document string" ) },
            [ &db, dormant ]( const Json& a, CallCtx& ctx )
            {
                // Pass the session (so the destructive latch applies) and an actor
                // naming the authenticated database account and the MCP client key.
                Json raw = db.callScalarBind(
                    "SELECT fractal_audit_log(?, ?, CONNECTION_ID(), CONCAT(CURRENT_USER(), ' via ', ?))",
                    { SqlValue( a.at( "entry_type" ).get<std::string>() ),
                      SqlValue( a.contains( "payload" ) && !a.at( "payload" ).is_null()
                                  ? a.at( "payload" ).get<std::string>() : std::string( "{}" ) ),
                      SqlValue( ctx.clientKey ) } );
                return Json{ { "rc", dormant( std::move( raw ), "fractal_audit_log" ) } };
            } ) );

        t.push_back( mkTool( "fractal_audit_unpack", "enterprise", "pure", ToolClass::Cheap,
            "Decode a persisted QTL blob into its audit JSON (the reverse of what the chain "
            "encoded). Pure forensic query.",
            { Str( "blob", true, "a QTL blob (e.g. an entry's blob value from the audit chain)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_audit_unpack(?)",
                    { SqlValue( a.at( "blob" ).get<std::string>() ) } );
            }, true ) );

        return t;
    }
}