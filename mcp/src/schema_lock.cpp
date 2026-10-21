// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#include <stdexcept>
#include "schema_lock.h"
#include <openssl/evp.h>
#include <fstream>
#include <algorithm>

namespace fsqlmcp
{
    static OrderedJson sortKeysRecursive( const Json& v )
    {
        if( v.is_object() )
        {
            std::vector<std::string> keys;
            for( auto it = v.begin(); it != v.end(); ++it ) keys.push_back( it.key() );
            std::sort( keys.begin(), keys.end() );
            OrderedJson out = OrderedJson::object();
            for( const std::string& k : keys )
                out[ k ] = sortKeysRecursive( v.at( k ) );
            return out;
        }
        if( v.is_array() )
        {
            OrderedJson out = OrderedJson::array();
            for( const Json& e : v ) out.push_back( sortKeysRecursive( e ) );
            return out;
        }
        return v;
    }

    std::string computeSchemaHash( const std::vector<ToolSpec>& tools )
    {
        Json projection = Json::object();
        for( const ToolSpec& t : tools )
        {
            const Json annotations = buildAnnotations( t );

            projection[ std::string( t.name ) ] = Json{
                { "category", std::string( t.category ) },
                { "toolClass", t.toolClass == ToolClass::Cheap ? "cheap" : "expensive" },
                { "description", std::string( t.description ) },
                { "annotations", annotations },
                { "inputSchema", buildInputSchema( t ) }
            };
        }
        const std::string canonical = sortKeysRecursive( projection ).dump( -1 );

        unsigned char digest[ EVP_MAX_MD_SIZE ]; unsigned int len = 0;
        EVP_MD_CTX* ctx = EVP_MD_CTX_new();
        // Every step can fail (allocation failure inside OpenSSL); an unchecked failure is a null dereference.
        if( !ctx || EVP_DigestInit_ex( ctx, EVP_sha256(), nullptr ) != 1
            || EVP_DigestUpdate( ctx, canonical.data(), canonical.size() ) != 1
            || EVP_DigestFinal_ex( ctx, digest, &len ) != 1 )
        {
            if( ctx ) EVP_MD_CTX_free( ctx );
            throw std::runtime_error( "sha256 is unavailable (allocation failure inside OpenSSL)" );
        }
        EVP_MD_CTX_free( ctx );

        static const char* const kHex = "0123456789abcdef";
        std::string hex;
        for( unsigned int i = 0; i < len; ++i )
        {
            hex.push_back( kHex[ digest[ i ] >> 4 ] );
            hex.push_back( kHex[ digest[ i ] & 0xF ] );
        }
        return hex;
    }

    LockCheckResult checkSchemaLock( const std::string& lockFilePath, const std::string& computedHash,
                                       std::string* expectedOut )
    {
        std::ifstream in( lockFilePath );
        if( !in )
            return LockCheckResult::Absent;    // dev-mode friendly, not a failure
        std::string expected;
        std::getline( in, expected );
        /* The lock file holds one hex digest on one line. A file
         * committed with CRLF line endings (Windows; git's default for
         * text files) leaves the CR in the string getline() returns, and
         * the comparison against the computed hash then never matches: a
         * spurious "schema drift" warning on every machine that reads
         * the file as-is, and -- with FSQL_MCP_STRICT_SCHEMA_HASH=true
         * -- a server that refuses to start. Trailing whitespace of any
         * kind is not part of the digest. */
        while( !expected.empty() &&
               ( expected.back() == '\r' || expected.back() == '\n'
                 || expected.back() == ' '  || expected.back() == '\t' ) )
            expected.pop_back();
        if( expectedOut ) *expectedOut = expected;
        return ( expected == computedHash ) ? LockCheckResult::Ok : LockCheckResult::Warn;
    }

    void writeSchemaLock( const std::string& lockFilePath, const std::string& computedHash )
    {
        std::ofstream out( lockFilePath, std::ios::trunc );
        out << computedHash << '\n';
    }
}