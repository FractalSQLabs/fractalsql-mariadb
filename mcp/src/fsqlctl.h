// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#pragma once
#include <string>
#include <cstdint>
#include "mcp_json.h"

namespace fsqlmcp
{
    // Minimal FSQ-protocol client (fractalsqld's own wire protocol, v2) for the
    // admin tier. This is the ONLY path in the whole plugin that talks to a
    // process OTHER than the MariaDB connection, tool descriptions say so
    // explicitly, since it's the one place an operator could be confused
    // about which credential governs which half of the config.
    //
    // Frame layout per docs/fractalsql-daemon.md (all little-endian):
    //   magic 'FSQ1'(4B) | version=2(u16) | opcode(u16) | flags(u32) | request_id(u32)
    //   | context=0(u64) | auth_len=32(u32) | payload_len(u32)
    //   | tag = HMAC-SHA256(header[0:32] || payload, key)  (32B, via OpenSSL)
    //   | payload
    // A reply payload = status:u32 | core_rc:i32 | body (fsqlctl's roundtrip
    // decoder). A refusal reply carries flags & 0x2 and the daemon's own reason
    // in its body, surfaced unmodified.
    class FsqlCtl
    {
    public:
        // Expects FSQLCTL_SOCKET + FSQLCTL_KEY; throws Connectivity on either
        // missing, on an unreadable/non-hex key file, or (per call) when the
        // daemon cannot be reached, immediate clean error, never a hang.
        FsqlCtl( const std::string& socketPath, const std::string& keyPath );

        std::uint16_t ping();        // OP_PING   -> daemon protocol version
        std::string   version();     // OP_VERSION
        std::string   reload();      // OP_RELOAD -> "reloaded: configuration swapped in"

    private:
        struct Reply { std::uint16_t opcode; std::uint32_t flags; std::uint32_t status; std::int32_t coreRc; std::string body; };
        Reply rawRoundtrip( std::uint16_t opcode, const std::string& payload );
        void raiseRefusal( const Reply& r, const char* what );

        std::string socketPath_;
        std::string keyPath_;
        std::string hmacKey_;    // raw bytes, decoded once from the hex file, cached
    };
}