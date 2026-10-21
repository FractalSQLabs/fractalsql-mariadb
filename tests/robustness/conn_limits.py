#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Connection limits of a running fractalsqld.

usage: conn_limits.py SOCKET_PATH HMAC_KEY_HEX MAX_CONNECTIONS IDLE_SECONDS

The daemon under test must have been started with max_connections =
MAX_CONNECTIONS and idle_timeout_secs = IDLE_SECONDS. Checks, each printed as
"ok NAME" or "FAIL NAME: reason":

  limit      with MAX_CONNECTIONS connections held open, further connections
             are closed without being served
  release    closing a held connection frees its slot for a new one
  idle       a connection that sends nothing is closed after the idle timeout
  recover    after the idle connections are gone, the daemon serves again

The exit status is 0 when every check passed.
"""
import hashlib
import hmac
import socket
import struct
import sys
import time

SOCK, KEY = sys.argv[1], bytes.fromhex(sys.argv[2])
MAXC, IDLE = int(sys.argv[3]), int(sys.argv[4])
failed = False


def ping_frame():
    header = b"FSQ1" + struct.pack("<HHIIQII", 2, 1, 0, 7, 0, 32, 0)
    return header + hmac.new(KEY, header, hashlib.sha256).digest()


def connect():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(3)
    s.connect(SOCK)
    return s


def read_exact(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def served(s):
    """True when the daemon answers a PING on this connection (the whole reply is read)."""
    try:
        s.sendall(ping_frame())
        header = read_exact(s, 32)
        if header is None:
            return False
        length = struct.unpack("<I", header[28:32])[0]
        return read_exact(s, 32 + length) is not None
    except OSError:
        return False


def check(name, ok, why=""):
    global failed
    if ok:
        print("ok " + name)
    else:
        failed = True
        print("FAIL %s: %s" % (name, why))


held = []
for _ in range(MAXC):
    s = connect()
    if not served(s):
        check("limit", False, "a connection within the limit was not served")
    held.append(s)
extra = connect()
check("limit", not served(extra), "a connection past max_connections was served")
extra.close()

def serve_soon(timeout=3.0):
    """A new connection that gets served within `timeout` seconds, or None.
    The daemon frees a closed connection's slot from its own thread, so the
    slot can take a moment to come back on a loaded machine."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        c = connect()
        if served(c):
            return c
        c.close()
        time.sleep(0.1)
    return None


held.pop().close()
fresh = serve_soon()
check("release", fresh is not None, "a slot freed by a closed connection was not reusable")
if fresh is not None:
    held.append(fresh)

time.sleep(IDLE + 1.5)
closed = 0
for s in held:
    s.settimeout(1)
    try:
        if s.recv(1) == b"":
            closed += 1
    except OSError:
        closed += 1
check("idle", closed == len(held), "%d of %d idle connections were still open after the timeout" % (len(held) - closed, len(held)))
for s in held:
    s.close()
last = serve_soon()
check("recover", last is not None, "the daemon did not serve once the idle connections had gone")
if last is not None:
    last.close()
sys.exit(1 if failed else 0)
