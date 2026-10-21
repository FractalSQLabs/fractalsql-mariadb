// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Vectorizer tier tools. There is NO background embedding worker in
// this engine by design: triggers enqueue, callers drive the queue on their
// own schedule with fractal_vectorizer_process_queue.

#include "vectorizer.h"
#include "helpers.h"
#include "../db.h"
#include "../tool_param_helpers.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildVectorizerTools( Db& db )
    {
        using namespace adap;
        std::vector<ToolSpec> t;

        auto optInt = []( const Json& a, const char* key ) -> SqlValue
        {
            if( a.contains( key ) && !a.at( key ).is_null() && a.at( key ).is_number_integer() )
                return SqlValue( static_cast<std::int64_t>( a.at( key ).get<int>() ) );
            return SqlValue( nullptr );
        };

        t.push_back( mkTool( "fractal_vectorizer_create", "vectorizer", "stateful", ToolClass::Cheap,
            "Installs the AFTER INSERT/UPDATE sync trigger(s) for an existing table/text-col/"
            "embedding-col triple (unique per triple) and backfills the embedding queue. The "
            "source table needs exactly one single-column PRIMARY KEY; a native VECTOR(n) "
            "embedding column is auto-detected on MariaDB 11.7+. max_embeds_per_window / "
            "rate_window_secs (default 3600) rate-limit the trigger side. Returns the id all "
            "other vectorizer tools take.",
            { Str( "source_table", true, "source table, bare name" ),
              Str( "text_col", true, "TEXT column to embed" ),
              Str( "embedding_col", true, "embedding column (TEXT or native VECTOR(n))" ),
              Obj( "options", false, "{\"max_embeds_per_window\":n, \"rate_window_secs\":n (default 3600)}" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                Json res = db.callProc( "fractal_vectorizer_create",
                    { SqlValue( a.at( "source_table" ).get<std::string>() ),
                      SqlValue( a.at( "text_col" ).get<std::string>() ),
                      SqlValue( a.at( "embedding_col" ).get<std::string>() ),
                      ( a.contains( "options" ) && !a.at( "options" ).is_null() && a.at( "options" ).is_object() )
                        ? SqlValue( a.at( "options" ).dump() ) : SqlValue( nullptr ) },
                    { "vectorizer_id" }, MergeMode::Fields );
                return Json{ { "vectorizer_id", res.value( "vectorizer_id", Json( nullptr ) ) } };
            } ) );

        t.push_back( mkTool( "fractal_vectorizer_pause", "vectorizer", "stateful", ToolClass::Cheap,
            "Disables a vectorizer (idempotent). Clean engine error on an unknown id.",
            { Int( "id", true, "vectorizer id" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                db.callProc( "fractal_vectorizer_pause",
                    { SqlValue( a.at( "id" ).get<std::int64_t>() ) }, {}, MergeMode::None );
                return Json{ { "id", a.at( "id" ) }, { "paused", true } };
            } ) );

        t.push_back( mkTool( "fractal_vectorizer_resume", "vectorizer", "stateful", ToolClass::Cheap,
            "Re-enables a paused vectorizer (idempotent). Clean engine error on an unknown id.",
            { Int( "id", true, "vectorizer id" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                db.callProc( "fractal_vectorizer_resume",
                    { SqlValue( a.at( "id" ).get<std::int64_t>() ) }, {}, MergeMode::None );
                return Json{ { "id", a.at( "id" ) }, { "resumed", true } };
            } ) );

        t.push_back( mkTool( "fractal_vectorizer_drop", "vectorizer", "stateful", ToolClass::Cheap,
            "Permanently deregisters a vectorizer: drops its _fsql_vec_<id>_ins / _upd triggers "
            "and its queue history. IRREVERSIBLE - a client UI honoring the destructiveHint "
            "annotation will ask a human before calling this.",
            { Int( "id", true, "vectorizer id" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                db.callProc( "fractal_vectorizer_drop",
                    { SqlValue( a.at( "id" ).get<std::int64_t>() ) }, {}, MergeMode::None );
                return Json{ { "id", a.at( "id" ) }, { "dropped", true } };
            }, false, true ) );

        t.push_back( mkTool( "fractal_vectorizer_enqueue", "vectorizer", "stateful", ToolClass::Cheap,
            "Manually queue one source row by primary key, for rows the triggers couldn't see "
            "(bulk load with triggers off, a restored row, ...). Clean engine error for an "
            "unknown or paused vectorizer.",
            { Int( "id", true, "vectorizer id" ),
              Int( "pk_value", true, "the source row's primary-key value" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                db.callProc( "fractal_vectorizer_enqueue",
                    { SqlValue( a.at( "id" ).get<std::int64_t>() ),
                      SqlValue( a.at( "pk_value" ).get<std::int64_t>() ) }, {}, MergeMode::None );
                return Json{ { "id", a.at( "id" ) }, { "pk_value", a.at( "pk_value" ) }, { "enqueued", true } };
            } ) );

        t.push_back( mkTool( "fractal_vectorizer_process_queue", "vectorizer", "stateful", ToolClass::Cheap,
            "Drives the actual embedding sync (batch_size defaults 100 if omitted; "
            "stale_after_secs defaults 600) and returns {n_processed}. Call it on YOUR schedule "
            "- there is no background worker in this engine by design; nothing embeds until "
            "this is called.",
            { Int( "batch_size", false, "", 100 ),
              Int( "stale_after_secs", false, "", 600 ) },
            [ &db, optInt ]( const Json& a, CallCtx& )
            {
                // The one procedure with NO OUT var: an ordinary SELECT result set
                // arrives instead, captured before the drain (db.cpp).
                return db.callProcResultSet( "fractal_vectorizer_process_queue",
                    { optInt( a, "batch_size" ), optInt( a, "stale_after_secs" ) } );
            } ) );

        return t;
    }
}