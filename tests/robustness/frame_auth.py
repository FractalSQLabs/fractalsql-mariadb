#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Frame authentication of fractalsqld.

usage: frame_auth.py SOCKET KEYFILE DAEMON_PID PAYLOAD_LEN
The daemon runs with fail_size_preload.so and FSQL_FAIL_SIZE = 32 + PAYLOAD_LEN (the size of the buffer it once allocated to
authenticate a PAYLOAD_LEN-byte request):
  - a forged frame (all-zero tag) is refused, and a genuine one answered: authenticating allocates nothing, so there is no
    allocation failure to fail open on (the daemon used to zero the expected tag, making an all-zero tag valid);
  - 16 connections each declaring a 64 MiB payload and sending 100 bytes do not make the daemon hold what was only declared.
"""
import hashlib
import hmac
import socket
import struct
import sys
import time

sock, keyfile, pid, plen = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
key = bytes.fromhex("".join(open(keyfile).read().split()))
failures = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else "  " + str(detail)))
    if not cond:
        failures.append(name)


def recv(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def ping(size, forged):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sock)
    payload = b"x" * size
    hdr = b"FSQ1" + struct.pack("<HHIIQII", 2, 1, 0, 1, 0, 32, len(payload))
    tag = bytes(32) if forged else hmac.new(key, hdr + payload, hashlib.sha256).digest()
    try:
        s.sendall(hdr + tag + payload)
        recv(s, 32)
        return True
    except (ConnectionError, OSError):
        return False
    finally:
        s.close()


check("a forged (all-zero tag) frame is refused with the old tag buffer size failing", not ping(plen, True))
check("a genuine frame of that size is answered (authentication allocates nothing)", ping(plen, False))
check("a forged frame of another size is refused", not ping(plen + 1, True))
check("a genuine frame of another size is answered", ping(plen + 1, False))


def rss_mib():
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) // 1024


before = rss_mib()
conns = []
for _ in range(16):
    c = socket.socket(socket.AF_UNIX)
    c.connect(sock)
    c.sendall(b"FSQ1" + struct.pack("<HHIIQII", 2, 1, 0, 1, 0, 32, 64 * 1024 * 1024) + bytes(32) + b"x" * 100)
    conns.append(c)
time.sleep(1.5)
after = rss_mib()
for c in conns:
    c.close()
check(f"16 half-sent 64 MiB frames do not grow the daemon (resident {before} -> {after} MiB)", after - before < 32)
sys.exit(1 if failures else 0)
