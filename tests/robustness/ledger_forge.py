#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Builds ledger files by hand, valid and deliberately corrupted, for integrity tests.

usage: ledger_forge.py OUT SCENARIO [KEY]      (SCENARIO 'list' prints the names)

KEY is the ledger HMAC key the records are authenticated with (omit it for an
unkeyed chain). File layout, little endian: the 8 bytes "FSQLLDGR", a version byte
(1), then records. A record is a fixed header

    kind u32 | blob_len u32 | has_mac u8 | sealed u8 | reserved[2] |
    mac[32] | prev_hash[32] | entry_hash[32] | updated i64

followed by the blob. entry_hash = SHA-256(prev_hash || blob [|| mac]) and
mac = HMAC-SHA256(key, blob). The first record of a kind chains from 32 zero bytes.
"""
import hashlib
import hmac
import struct
import sys

ZERO = b"\0" * 32
MAGIC = b"FSQLLDGR" + bytes([1])


def record(kind, blob, prev=ZERO, key=None, has_mac=None, bad_hash=False, bad_mac=False,
           sealed=0, blob_len=None, updated=1700000000):
    use_key = key if has_mac is None else (key if has_mac else None)
    mac = hmac.new(use_key, blob, hashlib.sha256).digest() if use_key else ZERO
    if bad_mac and use_key:
        mac = bytes([mac[0] ^ 1]) + mac[1:]
    digest = hashlib.sha256(prev + blob + (mac if use_key else b"")).digest()
    if bad_hash:
        digest = bytes([digest[0] ^ 1]) + digest[1:]
    header = struct.pack("<IIBB2s", kind, len(blob) if blob_len is None else blob_len,
                         1 if use_key else 0, sealed, b"\0\0") + mac + prev + digest + struct.pack("<q", updated)
    return header + blob, digest


def chain(kind, blobs, key, **kw):
    data, prev = b"", ZERO
    for blob in blobs:
        rec, prev = record(kind, blob, prev, key, **kw)
        data += rec
    return data


def blob(n):
    return b'{"type":"t","entry":{"n":%d}}' % n


def build(scenario, key):
    magic = MAGIC
    if scenario == "k1_ok":
        return magic, chain(1, [blob(1)], key)
    if scenario == "k1_two":
        return magic, chain(1, [blob(1), blob(2)], key)
    if scenario == "k1_three":
        return magic, chain(1, [blob(1), blob(2), blob(3)], key)
    if scenario == "k2_two":
        return magic, chain(2, [blob(1), blob(2)], key)
    if scenario == "mixed":
        r1, h1 = record(1, blob(1), ZERO, key)
        r2, _ = record(2, blob(2), ZERO, key)
        r3, _ = record(1, blob(3), h1, key)
        return magic, r1 + r2 + r3
    if scenario == "bad_hash":
        return magic, record(1, blob(1), ZERO, key, bad_hash=True)[0]
    if scenario == "bad_mac":
        return magic, record(1, blob(1), ZERO, key, bad_mac=True)[0]
    if scenario == "nomac":
        return magic, record(1, blob(1), ZERO, key, has_mac=False)[0]
    if scenario == "genesis_nonzero_prev":
        return magic, record(1, blob(1), b"\x01" * 32, key)[0]
    if scenario == "bad_link":
        r1, _ = record(1, blob(1), ZERO, key)
        r2, _ = record(1, blob(2), b"\x02" * 32, key)
        return magic, r1 + r2
    if scenario == "bad_link_prior":
        r1, h1 = record(1, blob(1), ZERO, key)
        r2, _ = record(1, blob(2), h1, key)
        r3, _ = record(1, blob(3), h1, key)
        return magic, r1 + r2 + r3
    if scenario == "kind0":
        return magic, record(0, blob(1), ZERO, key)[0]
    if scenario == "kind17":
        return magic, record(17, blob(1), ZERO, key)[0]
    if scenario == "kind_huge":
        return magic, record(99999, blob(1), ZERO, key)[0]
    if scenario == "blen_big":
        return magic, record(1, blob(1), ZERO, key, blob_len=0xFFFFFFF0)[0]
    if scenario == "blen_over":
        return magic, record(1, blob(1), ZERO, key, blob_len=70 * 1024 * 1024)[0]
    if scenario == "blen_short":
        return magic, record(1, blob(1), ZERO, key, blob_len=len(blob(1)) + 50)[0]
    if scenario == "blen_zero":
        return magic, record(1, b"", ZERO, key)[0]
    if scenario == "torn_hdr":
        rec = record(1, blob(1), ZERO, key)[0]
        return magic, rec + rec[:20]
    if scenario == "torn_blob":
        r1 = record(1, blob(1), ZERO, key)[0]
        r2 = record(1, blob(2), ZERO, key)[0]
        return magic, r1 + r2[:-5]
    if scenario == "sealed":
        return magic, record(1, blob(1), ZERO, key, sealed=1)[0]
    if scenario == "big_blob":
        return magic, record(1, b'{"x":"' + b"a" * 200000 + b'"}', ZERO, key)[0]
    if scenario == "many":
        return magic, chain(2, [blob(i) for i in range(60)], key)
    if scenario == "empty":
        return b"", b""
    if scenario == "magic_only":
        return magic, b""
    if scenario == "bad_version":
        return b"FSQLLDGR" + bytes([9]), record(1, blob(1), ZERO, key)[0]
    if scenario == "bad_magic":
        return b"XSQLLDGR" + bytes([1]), record(1, blob(1), ZERO, key)[0]
    if scenario == "short_magic":
        return b"FSQL", b""
    raise SystemExit("unknown scenario " + scenario)


SCENARIOS = ("k1_ok k1_two k1_three k2_two mixed bad_hash bad_mac nomac genesis_nonzero_prev bad_link "
             "bad_link_prior kind0 kind17 kind_huge blen_big blen_over blen_short blen_zero torn_hdr "
             "torn_blob sealed big_blob many empty magic_only bad_version bad_magic short_magic").split()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out, scenario = sys.argv[1], sys.argv[2]
    key = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] else None
    if scenario == "list":
        print(" ".join(SCENARIOS))
        return
    head, body = build(scenario, key)
    with open(out, "wb") as f:
        f.write(head + body)


if __name__ == "__main__":
    main()
