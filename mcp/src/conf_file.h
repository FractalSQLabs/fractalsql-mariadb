// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <map>
#include <mutex>

namespace fsqlmcp::conffile
{
    // fractalsqld.conf: the daemon is the config's authoritative home, never
    // the MariaDB connection, never SET GLOBAL. Keys live-reloadable for the
    // provider/text-to-sql tiers take effect on the tier's NEXT call; a reload
    // never performs a plugin/library load itself; socket_path/hmac_key_file
    // are refused at reload (startup-only).
    bool isSecretKey( const std::string& key );        // reasoning_token, enterprise_ledger_key
    bool isOperatorOnlyKey( const std::string& key );  // enterprise_* keys: operator territory
    bool isEditableKey( const std::string& key );      // the 14 live-reloadable provider/t2s keys

    // Path keys (reasoning_plugin, enterprise_lib, enterprise_ledger_path)
    // carry a FILE PATH, and a path has rules the daemon also enforces:
    // it must be absolute, and it must contain no ".." traversal segment.
    //
    // Why the MCP enforces them too, at write time rather than leaving it
    // to the daemon: the daemon's refusal at reload leaves the conf file
    // ALREADY written with the bad value. The tool's contract is that a
    // refused change leaves the live config unchanged in behavior, so the
    // shape check happens BEFORE the file is written -- the daemon's
    // all-or-nothing reload validation remains the backstop, not the
    // first line of defence.
    //
    // The rules (Windows: drive-letter, UNC or rooted; POSIX: rooted;
    // no ".." anywhere) are the same ones the daemon's config loader
    // applies, so a value this accepts is a value the daemon accepts.
    bool isPathKey( const std::string& key );

    // The reason `value` is not an acceptable path for `key`, or an
    // empty string when it is acceptable. A non-path key is always
    // acceptable (it has no path shape to get wrong).
    std::string pathProblem( const std::string& key, const std::string& value );

    // key=value parse (comments/blank lines skipped).
    std::map<std::string, std::string> readConf( const std::string& path );

    // The lock every config change takes.
    //
    // A change is a read, a merge and a write: two changes running at the
    // same time would each read the file before the other wrote it, and
    // the second write would drop the first one's change. The lock is
    // held for the whole read-merge-write-reload sequence, so a reload
    // always sees the file the change that asked for it wrote.
    std::mutex& confLock();

    // Atomic swap: temp file -> (POSIX: original's mode bits) -> rename over.
    // Never leaves a half-applied state behind.
    std::string writeConf( const std::string& path, const std::map<std::string, std::string>& conf );
}