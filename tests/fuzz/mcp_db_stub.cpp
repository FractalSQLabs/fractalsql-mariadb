// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
//
// Stand-in for mcp/src/db.cpp in the JSON-RPC fuzz target. The harness never
// binds a database, so these are never reached; they exist so the target
// links without Connector/C. Only the header is compiled against.
#include "db.h"

namespace fsqlmcp
{
    static Json none() { return Json( nullptr ); }

    Json Db::callProc( const std::string&, const std::vector<SqlValue>&,
                       const std::vector<std::string>&, MergeMode ) { return none(); }
    Json Db::callScalarBind( const std::string&, const std::vector<SqlValue>& ) { return none(); }
    Json Db::selectRowsRaw( const std::string& ) { return none(); }
    Json Db::selectScalarJson( const std::string& ) { return none(); }
    void Db::close() {}
}

extern "C" unsigned long mysql_thread_id( MYSQL* ) { return 0; }
