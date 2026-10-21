#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# tests/ledger_chain_tool.py
#
# Build and tamper a FractalSQL ledger chain, for the harness's
# full-chain verification gate (build_test.sh's gate 47 /
# build_test.ps1's Gate-47-LedgerChain).
#
# WHY A HARNESS-SIDE BUILDER:
#
#   The gate needs a chain with MORE THAN ONE record, because the whole
#   point of the assertion is what happens when a record that is NOT the
#   tip is tampered with. The only SQL-reachable writer for the kind=2
#   decision-audit chain is fractal_audit_log, and that UDF is gated
#   behind the licensed enterprise library -- which this public repo
#   does not ship, so a gate that used it would SKIP everywhere. The
#   kind=1 (QTL Truth/Shadow) chain is written by the enterprise
#   library too.
#
#   The on-disk format is fully documented in
#   src/fractalsql_enterprise.c (ledger_write_entry /
#   ledger_read_record_header) and mirrored in
#   service/tests/ledger_concurrency_runner.c, so the fixture can be
#   built here without the product. The WRITE side is already covered
#   by gate 26 (flush -> fractal_ledger_verify round trip, against the
#   product's own writer); what this fixture exercises is the VERIFIER's
#   chain walk, which is the part the plan's ledger slice is about.
#
# THE FORMAT (little-endian, as the product writes it):
#
#   file header : "FSQLLDGR" (8 bytes) + version byte (1 byte)
#   record      : kind u32 | blen u32 | has_mac u8 | sealed u8
#                 | reserved[2] | mac[32] | prev_hash[32]
#                 | entry_hash[32] | updated i64 | payload[blen]
#
#   entry_hash = SHA256(prev_hash || payload)          (unkeyed chain)
#              = SHA256(prev_hash || payload || mac)    (keyed chain)
#
# USAGE:
#
#   ledger_chain_tool.py build  <path> <count>
#       Writes <count> chained kind=2 records to <path> and prints one
#       "payload_offset <index> <byte_offset>" line per record (the
#       offset of that record's payload inside the file).
#
#   ledger_chain_tool.py tamper <path> <index>
#       Flips one byte inside record <index>'s payload (in place) and
#       prints the byte offset it flipped.
#
# EXIT CODES: 0 = success, 1 = error.
#
import hashlib
import struct
import sys
import time

LEDGER_MAGIC = b"FSQLLDGR"
LEDGER_VERSION = 1
LEDGER_KIND = 2          # the decision-audit chain
HASH_LEN = 32
REC_FIXED = 116          # 4+4+1+1+2+32+32+32+8
HDR_LEN = len(LEDGER_MAGIC) + 1


def _payload(index):
    """A distinct, well-formed JSON payload per record. The shape
    matters to the product's other audit UDFs (fractal_audit_unpack
    expects {"type":..., "entry":...}), so it is built to match."""
    return ('{"type":"gate47-canary","entry":{"index":%d}}' % index).encode("utf-8")


def build(path, count):
    prev = b"\0" * HASH_LEN
    out = bytearray(LEDGER_MAGIC + bytes([LEDGER_VERSION]))
    offsets = []
    now = int(time.time())
    for i in range(count):
        payload = _payload(i)
        entry = hashlib.sha256(prev + payload).digest()
        out += struct.pack("<II", LEDGER_KIND, len(payload))
        out += bytes([0, 0])          # has_mac = 0, sealed = 0
        out += b"\0\0"                # reserved[2]
        out += b"\0" * HASH_LEN       # mac[32] (absent)
        out += prev                   # prev_hash[32]
        out += entry                  # entry_hash[32]
        out += struct.pack("<q", now) # updated i64
        offsets.append(len(out))
        out += payload
        prev = entry
    with open(path, "wb") as f:
        f.write(out)
    for i, off in enumerate(offsets):
        print("payload_offset %d %d" % (i, off))
    return 0


def _record_offsets(path):
    """(kind, payload_offset, payload_len) for every record in the file."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < HDR_LEN or data[:len(LEDGER_MAGIC)] != LEDGER_MAGIC:
        raise ValueError("not a ledger file: %s" % path)
    off = HDR_LEN
    out = []
    while off + REC_FIXED <= len(data):
        kind, blen = struct.unpack_from("<II", data, off)
        payload_off = off + REC_FIXED
        if payload_off + blen > len(data):
            break
        out.append((kind, payload_off, blen))
        off = payload_off + blen
    return out


def tamper(path, index):
    recs = _record_offsets(path)
    matching = [r for r in recs if r[0] == LEDGER_KIND]
    if index < 0 or index >= len(matching):
        raise ValueError("no kind=%d record #%d in %s" % (LEDGER_KIND, index, path))
    _, payload_off, blen = matching[index]
    if blen <= 0:
        raise ValueError("record #%d has an empty payload" % index)
    with open(path, "r+b") as f:
        f.seek(payload_off)
        b = f.read(1)
        f.seek(payload_off)
        f.write(bytes([b[0] ^ 0xFF]))
    print("tampered %d" % payload_off)
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: %s build <path> <count> | tamper <path> <index>\n" % argv[0])
        return 1
    try:
        if argv[1] == "build":
            if len(argv) != 4:
                sys.stderr.write("usage: %s build <path> <count>\n" % argv[0])
                return 1
            return build(argv[2], int(argv[3]))
        if argv[1] == "tamper":
            if len(argv) != 4:
                sys.stderr.write("usage: %s tamper <path> <index>\n" % argv[0])
                return 1
            return tamper(argv[2], int(argv[3]))
    except Exception as exc:                       # noqa: BLE001 - report and fail
        sys.stderr.write("ledger_chain_tool: %s\n" % exc)
        return 1
    sys.stderr.write("usage: %s build <path> <count> | tamper <path> <index>\n" % argv[0])
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
