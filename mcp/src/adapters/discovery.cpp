// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Discovery tier tools, against the documented MariaDB surface.
//
// Call-shape notes:
//   - fractal_search / fractal_search_explore are plain UDFs (SELECT fn(...)).
//   - the table-backed searches are stored PROCEDUREs with a trailing OUT
//     result (CALL fn(..., @fsq_out_0); SELECT @fsq_out_0).
//   - every session-keyed UDF below receives this connection's own
//     CONNECTION_ID() from the adapter; the tool schemas don't expose it.

#include "discovery.h"
#include "helpers.h"
#include "../db.h"
#include "../tool_param_helpers.h"
#include <cmath>
#include <cctype>

namespace fsqlmcp
{
    std::vector<ToolSpec> buildDiscoveryTools( Db& db, const RowLimitConfig& rowCfg )
    {
        using namespace adap;
        std::vector<ToolSpec> t;

        const ToolParam kSfsParams = Obj( "params", false,
            "SFS tuning knobs (defaults: iterations=30 in 1-10000, population_size=50 in "
            "1-100000, diffusion_factor=2 in 1-32, walk=0.5, debug=false; session_id is "
            "supplied by the adapter). Out-of-range values make the whole call return NULL." );

        const char* telemDocId =
            "the target table's own real single-column primary-key value (stable under UPDATE) - "
            "give it back to fractal_feedback_report as result_handle";

        auto kOf = []( const Json& a, const RowLimitConfig& cfg ) -> std::int64_t
        {
            limitKCheck( a, cfg );
            // k carries a documented default (5) in every tool's
            // inputSchema -- honor it when omitted instead of the
            // out_of_range throw (caught live: pure-convergence
            // fractal_search omits k by design).
            return std::min<int>( a.contains( "k" ) && a.at( "k" ).is_number_integer()
                                      ? a.at( "k" ).get<int>() : 5,
                                  effectiveLimit( a, cfg ) );
        };

        // fractal_search: plain UDF, SELECT with driver-bound text params.
        t.push_back( mkTool( "fractal_search", "discovery", "pure", ToolClass::Cheap,
            "Sniper-mode SFS convergence to the single best point (or inline-corpus top-k) "
            "minimizing cosine distance to a query. One function covers both modes: pass an "
            "inline corpus for top-k search, omit `corpus` (or pass the empty corpus) for pure "
            "convergence. It never reads tables - corpus points are given inline. Set "
            "{\"debug\":true} in params for the full trajectory trace (best_point/best_fit per "
            "generation); for a convergence run that reports the trace with no corpus at all, "
            "use fractal_search_debug. Returns "
            "{dim, n_corpus, best_fit, best_point, top_k:[{idx,dist}]}.",
            { Vec( "query", true, "the query vector" ),
              Mat( "corpus", false, "inline corpus, one point per entry ('[[v11,v12],[v21,v22]]' grammar at "
                                    "the SQL layer); omit or empty for pure Sniper-mode convergence only" ),
              Int( "k", false, "top-k count over the given corpus", 5 ),
              kSfsParams },
            [ &db, &rowCfg, kOf ]( const Json& a, CallCtx& )
            {
                const Json empty = Json::object();
                const Json& params = a.contains( "params" ) && a.at( "params" ).is_object()
                                       ? a.at( "params" ) : empty;
                const bool hasCorpus = a.contains( "corpus" ) && !a.at( "corpus" ).is_null()
                                        && a.at( "corpus" ).is_array() && !a.at( "corpus" ).empty();
                Json result = db.callScalarBind( "SELECT fractal_search(?, ?, ?, ?)",
                    { SqlValue( hasCorpus ? packMatrix( a.at( "corpus" ), "corpus" ) : std::string( "" ) ),
                      SqlValue( packVector( a.at( "query" ), "query" ) ),
                      SqlValue( kOf( a, rowCfg ) ),
                      SqlValue( dumpParamsNo( params, { "session_id" } ) ) } );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        // fractal_search_debug: plain UDF, the convergence view of the SFS.
        t.push_back( mkTool( "fractal_search_debug", "discovery", "pure", ToolClass::Cheap,
            "Convergence view of the Stochastic Fractal Search: no corpus, no top-k - the walk's "
            "own trace on one query point, so you can see where the search landed and how well "
            "it fit. Returns {dim, n_corpus, best_fit, best_point, trace:{...}}. Pass a `seed` "
            "for a byte-stable, reproducible result; left out, the walk is non-deterministic.",
            { Vec( "query", true, "the query vector" ),
              Int( "iterations", false, "SFS generations (1-10000; default 30)", 30 ),
              Int( "population_size", false, "particles per generation (2-100000; default 50)", 50 ),
              Int( "diffusion_factor", false, "diffusion factor (1-32; default 2)", 2 ),
              Int( "seed", false, "walk seed; pin it for a reproducible result (default 0 = the "
                                   "engine's own non-deterministic seed)", 0 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_search_debug(?, ?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "query" ), "query" ) ),
                      SqlValue( valueOr<int>( a, "iterations", 30 ) ),
                      SqlValue( valueOr<int>( a, "population_size", 50 ) ),
                      SqlValue( valueOr<int>( a, "diffusion_factor", 2 ) ),
                      SqlValue( valueOr<int>( a, "seed", 0 ) ) } );
            }, true ) );

        // fractal_search_explore: plain UDF.
        t.push_back( mkTool( "fractal_search_explore", "discovery", "pure", ToolClass::Cheap,
            "Scout-mode diverse population search (SFS + MMR re-ranking) over an inline corpus - "
            "the anti-mode-collapse primitive. Returns {population:[[...]]} with one point per "
            "particle (population_size entries), each of the corpus's dimensionality. Inline "
            "corpus only - for table-backed searches use fractal_search_telemetry or the agents.",
            { Vec( "query", true, "the query vector" ),
              Mat( "corpus", true, "inline corpus points" ),
              kSfsParams },
            [ &db ]( const Json& a, CallCtx& )
            {
                const Json empty = Json::object();
                const Json& params = a.contains( "params" ) && a.at( "params" ).is_object()
                                       ? a.at( "params" ) : empty;
                return db.callScalarBind( "SELECT fractal_search_explore(?, ?, ?)",
                    { SqlValue( packMatrix( a.at( "corpus" ), "corpus" ) ),
                      SqlValue( packVector( a.at( "query" ), "query" ) ),
                      SqlValue( dumpParamsNo( params, { "session_id" } ) ) } );
            }, true ) );

        // Table-backed searches: stored PROCEDUREs with one trailing OUT var.
        // ToolSpec holds std::string_view, so any description assembled from
        // runtime pieces must outlive buildAllTools -- block statics do.
        static const std::string kTelemetryDesc =
            std::string( "Ground-truth K-nearest real table rows to a query vector, by exact cosine "
              "distance. Returns [{doc_id, dist}] ascending - doc_id is " ) + telemDocId +
              "; the handle fractal_feedback_report wants. The table needs exactly one "
              "single-column PRIMARY KEY and a bare (non-schema-qualified) name; vector_col is a "
              "TEXT column holding a JSON-array-string vector, or a MariaDB 11.7+ native VECTOR(n) "
              "column (auto-detected). Errors SIGNAL a clean 45000 message naming the problem.";
        t.push_back( mkTool( "fractal_search_telemetry", "discovery", "stateful", ToolClass::Cheap,
            kTelemetryDesc.c_str(),
            { Str( "table_name", true, "target table, bare name" ),
              Str( "vector_col", true, "embedding column" ),
              Vec( "query", true, "the query vector" ),
              Int( "k", false, "neighbors to return", 5 ),
              RowLimit() },
            [ &db, &rowCfg, kOf ]( const Json& a, CallCtx& )
            {
                Json result = db.callProc( "fractal_search_telemetry",
                    { SqlValue( a.at( "table_name" ).get<std::string>() ),
                      SqlValue( a.at( "vector_col" ).get<std::string>() ),
                      SqlValue( packVector( a.at( "query" ), "query" ) ),
                      SqlValue( kOf( a, rowCfg ) ) },
                    { "result" }, MergeMode::Single );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        t.push_back( mkTool( "fractal_hybrid_clinical_search", "discovery", "stateful", ToolClass::Cheap,
            "Cohort-restricted sibling of fractal_search_telemetry: pass doc_ids (the "
            "primary-key values to restrict the scan to - built by the caller with ordinary SQL "
            "or a prior search's doc_ids) to rank only within that cohort. Same {doc_id, dist} "
            "shape. No dynamic filter string is ever accepted here.",
            { Str( "table_name", true, "target table, bare name" ),
              Str( "vector_col", true, "embedding column" ),
              Vec( "query", true, "the query vector" ),
              Vec( "doc_ids", true, "primary-key values to restrict the scan to" ),
              Int( "k", false, "neighbors to return", 5 ),
              RowLimit() },
            [ &db, &rowCfg, kOf ]( const Json& a, CallCtx& )
            {
                Json result = db.callProc( "fractal_hybrid_clinical_search",
                    { SqlValue( a.at( "table_name" ).get<std::string>() ),
                      SqlValue( a.at( "vector_col" ).get<std::string>() ),
                      SqlValue( packVector( a.at( "query" ), "query" ) ),
                      SqlValue( vectors::intArrayToJsonText( a.at( "doc_ids" ), "doc_ids" ) ),
                      SqlValue( kOf( a, rowCfg ) ) },
                    { "result" }, MergeMode::Single );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        t.push_back( mkTool( "fractal_search_trajectory", "discovery", "stateful", ToolClass::Cheap,
            "Drift-vector search: finds the K nearest rows to (current_vector - baseline_vector) "
            "- \"what changed\", not \"where am I\". doc_id here is a 0-indexed scan position "
            "within this call, NOT the row primary key (same split in every FractalSQL engine).",
            { Str( "table_name", true, "target table, bare name" ),
              Str( "vector_col", true, "embedding column" ),
              Vec( "baseline_vector", true, "the reference state" ),
              Vec( "current_vector", true, "the state to diff against the baseline" ),
              Int( "k", false, "neighbors to return", 5 ),
              RowLimit() },
            [ &db, &rowCfg, kOf ]( const Json& a, CallCtx& )
            {
                Json result = db.callProc( "fractal_search_trajectory",
                    { SqlValue( a.at( "table_name" ).get<std::string>() ),
                      SqlValue( a.at( "vector_col" ).get<std::string>() ),
                      SqlValue( packVector( a.at( "baseline_vector" ), "baseline_vector" ) ),
                      SqlValue( packVector( a.at( "current_vector" ), "current_vector" ) ),
                      SqlValue( kOf( a, rowCfg ) ) },
                    { "result" }, MergeMode::Single );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        t.push_back( mkTool( "fractal_cross_modal_search", "discovery", "stateful", ToolClass::Cheap,
            "Weighted concatenation of two modality vectors (e.g. morphology + clinical) into a "
            "single combined vector (alpha-weighted: alpha_weight to the first vector, "
            "1-alpha_weight to the second) before the search. Same {doc_id, dist} result shape, "
            "0-indexed doc_id like trajectory. Dimension compatibility is the caller's ETL "
            "concern - only the usual dimension-match check applies at the engine.",
            { Str( "table_name", true, "target table, bare name" ),
              Str( "vector_col", true, "embedding column" ),
              Vec( "morphology_vector", true, "first modality vector" ),
              Vec( "clinical_vector", true, "second modality vector" ),
              Num( "alpha_weight", true, "weight of morphology_vector; 1-alpha goes to clinical_vector" ),
              Int( "k", false, "neighbors to return", 5 ),
              RowLimit() },
            [ &db, &rowCfg, kOf ]( const Json& a, CallCtx& )
            {
                const double alpha = a.at( "alpha_weight" ).get<double>();
                if( alpha < 0.0 || alpha > 1.0 )
                    throw ToolError( ErrorClass::Schema, "alpha_weight must be in [0,1]" );
                Json result = db.callProc( "fractal_cross_modal_search",
                    { SqlValue( a.at( "table_name" ).get<std::string>() ),
                      SqlValue( a.at( "vector_col" ).get<std::string>() ),
                      SqlValue( packVector( a.at( "morphology_vector" ), "morphology_vector" ) ),
                      SqlValue( packVector( a.at( "clinical_vector" ), "clinical_vector" ) ),
                      SqlValue( alpha ),
                      SqlValue( kOf( a, rowCfg ) ) },
                    { "result" }, MergeMode::Single );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        // Session-scoped UDFs (session id supplied by the adapter, never the schema).
        t.push_back( mkTool( "fractal_diversify_enable", "discovery", "stateful", ToolClass::Cheap,
            "Turns on the stateful Diversify/Repulsion layer for THIS session/connection "
            "(off by default everywhere). Session-scoped state is keyed to this server's "
            "own connection - on the stdio transport that is your client's process; on "
            "the shared HTTP transport each MCP session gets its own connection, so one "
            "client's Diversify setting cannot contaminate another's search.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                Json rc = db.callScalarBind( "SELECT fractal_diversify_enable(?)",
                                              { SqlValue( sessionId( db ) ) } );
                return Json{ { "enabled", true }, { "rc", rc } };
            } ) );

        t.push_back( mkTool( "fractal_diversify_disable", "discovery", "stateful", ToolClass::Cheap,
            "Turns the session's Diversify/Repulsion layer back off (idempotent).",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                Json rc = db.callScalarBind( "SELECT fractal_diversify_disable(?)",
                                              { SqlValue( sessionId( db ) ) } );
                return Json{ { "enabled", false }, { "rc", rc } };
            } ) );

        t.push_back( mkTool( "fractal_diversify_set_params", "discovery", "stateful", ToolClass::Cheap,
            "Tunes this session's Diversify knobs: window_n (default 5, max 32), "
            "stall_threshold (0.15), repulsion_sigma (dimension-derived), "
            "repulsion_weight, max_shadows_considered (64), tail_buffer_cap "
            "(256, max 1024). Pass only the keys you want to change.",
            // No published defaults: the core owns these values, and an
            // omitted key keeps the session's current value.
            { Int( "window_n", false, "" ), Num( "stall_threshold", false, "" ),
              Num( "repulsion_sigma", false, "" ), Num( "repulsion_weight", false, "" ),
              Int( "max_shadows_considered", false, "" ),
              Int( "tail_buffer_cap", false, "" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                if( a.contains( "window_n" ) && !a.at( "window_n" ).is_null() )
                {
                    const int wn = a.at( "window_n" ).get<int>();
                    if( wn < 1 || wn > 32 )
                        throw ToolError( ErrorClass::Schema, "window_n must be in [1,32]" );
                }
                if( a.contains( "tail_buffer_cap" ) && !a.at( "tail_buffer_cap" ).is_null() )
                {
                    const int tc = a.at( "tail_buffer_cap" ).get<int>();
                    if( tc > 1024 )
                        throw ToolError( ErrorClass::Schema, "tail_buffer_cap must be <= 1024" );
                }
                Json rc = db.callScalarBind( "SELECT fractal_diversify_set_params(?, ?)",
                    { SqlValue( sessionId( db ) ), SqlValue( adap::packParams( a ) ) } );
                return Json{ { "rc", rc }, { "params", a } };
            } ) );

        t.push_back( mkTool( "fractal_detect_collapse", "discovery", "pure", ToolClass::Cheap,
            "Current diversity quotient (D_q) for this session. Returns null when "
            "Diversify is off, or when no Diversify-aware search has happened on this "
            "session yet - not an error.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                Json v = db.callScalarBind( "SELECT fractal_detect_collapse(?)",
                                             { SqlValue( sessionId( db ) ) } );
                // Fold NaN to null (JSON has no NaN; the engine can emit one for a
                // degenerate diversity window).
                Json dq = nullptr;
                if( v.is_number() )
                {
                    const double d = v.get<double>();
                    dq = std::isnan( d ) ? Json( nullptr ) : Json( d );
                }
                else if( v.is_object() && v.contains( "value" ) && v.at( "value" ).is_string() )
                {
                    const std::string s = v.at( "value" ).get<std::string>();
                    char* end = nullptr;
                    const double d = std::strtod( s.c_str(), &end );
                    dq = ( end && *end == '\0' && !std::isnan( d ) ) ? Json( d ) : Json( nullptr );
                }
                else if( v.is_object() && v.contains( "value" ) ) dq = v.at( "value" );
                else if( !v.is_null() && !v.is_object() ) dq = v;
                return Json{ { "dq", dq },
                    { "note", dq.is_null() ? "null: Diversify is disabled for this session, or a Diversify-aware "
                                            "search has not run on it yet" : "" } };
            }, true ) );

        t.push_back( mkTool( "fractal_explain_result", "discovery", "pure", ToolClass::Cheap,
            "{dq, diversify_enabled, overhead_p99_us} - the session-level Diversify "
            "diagnostics JSON.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_explain_result(?)",
                                           { SqlValue( sessionId( db ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_feedback_report", "discovery", "stateful", ToolClass::Cheap,
            "Reports dwell/positive/negative engagement on a prior result by its "
            "result_handle (the doc_id/row-index a report-enabled search returned), "
            "feeding the same session's shadow store, which later Diversify-aware "
            "searches on this connection repel from.",
            { Int( "result_handle", true, "the doc_id/handle of the prior result" ),
              StrEnum( "kind", true, "'dwell', 'positive' or 'negative' (case-insensitive)" ),
              Int( "dwell_ms", false, "required for kind=dwell; 0 (bare report) for positive/negative" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                std::string lower = a.at( "kind" ).get<std::string>();
                for( char& c : lower ) c = static_cast<char>( std::tolower( static_cast<unsigned char>( c ) ) );
                if( lower != "dwell" && lower != "positive" && lower != "negative" )
                    throw ToolError( ErrorClass::Schema, "kind is 'dwell', 'positive' or 'negative'" );
                std::int64_t dwell = 0;
                if( a.contains( "dwell_ms" ) && !a.at( "dwell_ms" ).is_null() )
                    dwell = a.at( "dwell_ms" ).get<std::int64_t>();
                if( lower == "dwell" && dwell <= 0 )
                    throw ToolError( ErrorClass::Schema, "dwell_ms is required (>=1) for kind=dwell" );
                Json rc = db.callScalarBind( "SELECT fractal_feedback_report(?, ?, ?, ?)",
                    { SqlValue( sessionId( db ) ),
                      SqlValue( a.at( "result_handle" ).get<std::int64_t>() ),
                      SqlValue( lower ), SqlValue( dwell ) } );
                return Json{ { "rc", rc } };
            } ) );

        t.push_back( mkTool( "fractal_isolate_background", "discovery", "stateful", ToolClass::Cheap,
            "Convenience wrapper: reports 'negative' with no dwell time on the given "
            "result_handle - \"push this result into the background/shadow set for me\".",
            { Int( "result_handle", true, "the doc_id/handle of the prior result" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                Json rc = db.callScalarBind( "SELECT fractal_isolate_background(?, ?)",
                    { SqlValue( sessionId( db ) ),
                      SqlValue( a.at( "result_handle" ).get<std::int64_t>() ) } );
                return Json{ { "rc", rc } };
            } ) );

        t.push_back( mkTool( "fractal_session_close", "discovery", "stateful", ToolClass::Cheap,
            "Explicit early cleanup of THIS connection's session-scoped ctx (Diversify "
            "state, shadow store, registry entry). MariaDB gives UDFs no on-disconnect "
            "hook, and MariaDB can reuse CONNECTION_ID() values over the server's "
            "lifetime under churn - call this at the end of a logical session rather "
            "than relying on the idle-TTL sweep.",
            {},
            [ &db ]( const Json&, CallCtx& )
            {
                const std::int64_t sid = sessionId( db );
                Json rc = db.callScalarBind( "SELECT fractal_session_close(?)", { SqlValue( sid ) } );
                return Json{ { "rc", rc }, { "session_id", sid } };
            } ) );

        return t;
    }
}