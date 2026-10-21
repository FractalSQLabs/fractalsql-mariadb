// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// buildAllTools: the full catalog assembly.
// The concatenation order is stable and matches the documented tier
// ordering, so the schema hash is reproducible.

#include "db.h"
#include "config.h"
#include "adapters/discovery.h"
#include "adapters/cognition.h"
#include "adapters/agency.h"
#include "adapters/analytics.h"
#include "adapters/enterprise.h"
#include "adapters/vectorizer.h"
#include "adapters/admin.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAllTools( Db& db, const EngineConfig& ecfg, const RowLimitConfig& rowCfg )
    {
        std::vector<ToolSpec> out;
        std::vector<ToolSpec> part = buildDiscoveryTools( db, rowCfg );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildCognitionTools( db );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildAgencyTools( db, rowCfg );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildAnalyticsTools( db, rowCfg );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildEnterpriseTools( db );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildVectorizerTools( db );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        part = buildAdminTools( db, ecfg );
        out.insert( out.end(), make_move_iterator( part.begin() ), make_move_iterator( part.end() ) );
        classifyStateMutatingTools( out );
        // The context-scoped tools take an optional context_id: the modern
        // protocol era has no protocol session, so the handle that names the
        // engine state is passed explicitly. It is added here, in one place,
        // so the schema, the manifest and the locks all describe the same
        // argument.
        for( ToolSpec& t : out )
            if( isContextScopedTool( t.name ) )
                t.params.push_back( contextIdParam() );
        return out;
    }
}