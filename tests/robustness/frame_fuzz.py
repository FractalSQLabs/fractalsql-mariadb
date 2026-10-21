#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Frame-level abuse of a running fractalsqld.

usage: frame_fuzz.py SOCKET_PATH HMAC_KEY_HEX

Sends correctly authenticated frames (the HMAC is valid, so the daemon parses
them) whose payloads are malformed or hostile, for every opcode: truncated and
over-long INIT/CALL/DEINIT/CANCEL bodies, argument counts and lengths that
disagree with the payload, wrong argument types, unknown functions, handles
that belong to another connection, replayed idempotency tokens, large cached
replies, and random byte-level mutations of valid frames. It also sends frames
with bad tags, versions, flags and lengths. Nothing is asserted on the replies;
the caller checks that the daemon is still alive and still answers a ping.
Exits 0 after printing "frame_fuzz: done" when the final ping is answered.
"""
import hashlib
import hmac
import random
import socket
import struct
import sys

SOCK, KEY = sys.argv[1], bytes.fromhex(sys.argv[2])

PING, VERSION, INIT, CALL, DEINIT, CANCEL, RELOAD = 1, 2, 0x10, 0x11, 0x12, 0x13, 0x14
T_NULL, T_STRING, T_INT, T_REAL = 0, 1, 2, 3


def frame(op, payload=b"", ver=2, flags=0, rid=7, ctx=0, auth_len=32, declared=None, bad_tag=False):
    """One request frame: 32-byte header, 32-byte HMAC tag, payload."""
    header = b"FSQ1" + struct.pack("<HHIIQII", ver, op, flags, rid, ctx, auth_len,
                                   len(payload) if declared is None else declared)
    tag = hmac.new(KEY, header + payload, hashlib.sha256).digest()
    if bad_tag:
        tag = bytes([tag[0] ^ 0xFF]) + tag[1:]
    return header + tag + payload


def connect():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
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


def read_reply(s):
    """The reply payload, or None when the daemon closed the connection."""
    try:
        header = read_exact(s, 32)
        if header is None or header[:4] != b"FSQ1":
            return None
        length = struct.unpack("<I", header[28:32])[0]
        if read_exact(s, 32) is None:
            return None
        return read_exact(s, length) if length else b""
    except OSError:
        return None


def arg(kind, data=b"", is_null=0):
    return bytes([kind, is_null]) + struct.pack("<I", len(data)) + data


def init_payload(name, args):
    n = name.encode()
    return bytes([len(n)]) + n + struct.pack("<I", len(args)) + b"".join(args)


def call_payload(name, handle, args):
    n = name.encode()
    return bytes([len(n)]) + n + struct.pack("<Q", handle) + struct.pack("<I", len(args)) + b"".join(args)


def send(data, read=True, half=False):
    """Opens a fresh connection, writes `data` (or half of it) and reads one reply."""
    s = connect()
    reply = None
    try:
        s.sendall(data[:len(data) // 2] if half else data)
        if read and not half:
            reply = read_reply(s)
    except OSError:
        pass
    s.close()
    return reply


def handle_of(reply):
    return struct.unpack("<Q", reply[8:16])[0] if reply and len(reply) >= 16 else 0


def lifecycle(name, init_args, call_args=None):
    """INIT, three CALLs (one repeated under a token), CANCEL, CALL, DEINIT twice, CALL on a dead handle."""
    call_args = init_args if call_args is None else call_args
    s = connect()
    s.sendall(frame(INIT, init_payload(name, init_args)))
    handle = handle_of(read_reply(s))
    body = call_payload(name, handle, call_args)
    for ctx in (0, 0xABC, 0xABC):
        s.sendall(frame(CALL, body, ctx=ctx))
        read_reply(s)
    s.sendall(frame(CANCEL, struct.pack("<Q", handle)))
    read_reply(s)
    s.sendall(frame(CALL, body))
    read_reply(s)
    for _ in range(2):
        s.sendall(frame(DEINIT, struct.pack("<Q", handle)))
        read_reply(s)
    s.sendall(frame(CALL, body))
    read_reply(s)
    s.close()


def main():
    random.seed(20261028)
    s_arg = lambda text: arg(T_STRING, text)
    i_arg = lambda v: arg(T_INT, struct.pack("<q", v))

    # Framing: bad versions, flags, tags and lengths, truncated headers, garbage.
    for fr in (frame(PING), frame(VERSION), frame(PING, ver=1), frame(PING, ver=3), frame(PING, auth_len=16),
               frame(PING, bad_tag=True), frame(PING, flags=1), frame(PING, flags=2), frame(0x7777), frame(0),
               frame(0xFFFF), frame(PING, declared=81 * 1024 * 1024), frame(PING, declared=5),
               b"XXXX" + b"\0" * 60, b"FSQ1", b"", b"\xff" * 200, frame(PING, b"x" * 100), frame(VERSION, b"x" * 10)):
        send(fr)
    send(frame(PING, b"abc", declared=100), read=False)
    send(frame(PING), half=True)
    send(frame(INIT, init_payload("fractal_version", [])), half=True)
    send(frame(RELOAD))
    send(frame(RELOAD, b"x"))

    # Well-formed lifecycles that misuse the handle afterwards.
    lifecycle("fractal_vector_dims", [s_arg(b"[1,2,3]")])
    lifecycle("fractal_version", [])
    lifecycle("fractal_vector_scale", [s_arg(b"[1,2,3]"), arg(T_REAL, struct.pack("<d", 2.0))])
    lifecycle("fractal_vector_scale", [s_arg(b"[1,2,3]"), i_arg(2)])
    lifecycle("fractal_vector_scale", [s_arg(b"[1,2,3]"), arg(T_NULL, b"", 1)])
    lifecycle("fractal_vector_scale", [s_arg(b"[1,2,3]"), arg(T_INT, b"12")])
    lifecycle("fractal_vector_scale", [s_arg(b"[1,2,3]"), arg(T_REAL, b"1234567")])
    lifecycle("fractal_vector_dims", [s_arg(b"[1,2,3]")], [s_arg(b"[1,2,3]"), s_arg(b"x")])
    lifecycle("fractal_vector_dims", [s_arg(b"[1,2,3]")], [])
    lifecycle("fractal_vector_dims", [s_arg(b"[1,2,3]")], [s_arg(b"x" * 100000)])
    lifecycle("fractal_vector_dims", [s_arg(b"x" * 100000)], [s_arg(b"[1]")])
    search = [s_arg(b"0,0;1,1"), s_arg(b"0,0"), i_arg(1), s_arg(b'{"iterations":3}')]
    lifecycle("fractal_search", search)
    lifecycle("fractal_search", search, [s_arg(b"0,0;1,1"), s_arg(b"0,0"), i_arg(99), s_arg(b"{}")])
    lifecycle("fractal_reason", [s_arg(b"q"), s_arg(b"ctx")])
    lifecycle("fractal_audit_log", [s_arg(b"t"), s_arg(b"{}")])
    lifecycle("fractal_ledger_verify", [i_arg(1)])

    # INIT with unknown or malformed function names and argument blocks.
    for name in ("", "x", "fractal_nope", "fractal_" + "a" * 200, "FRACTAL_VERSION", "fractal_version\0"):
        send(frame(INIT, init_payload(name, [])))
    name15 = bytes([15]) + b"fractal_version"
    for payload in (b"", bytes([5]), bytes([200]) + b"abc", bytes([3]) + b"abc",
                    name15 + struct.pack("<I", 65), name15 + struct.pack("<I", 2),
                    name15 + struct.pack("<I", 1) + bytes([1, 0]),
                    name15 + struct.pack("<I", 1) + bytes([1, 0]) + struct.pack("<I", 999) + b"ab",
                    name15 + struct.pack("<I", 0) + b"trailing",
                    init_payload("fractal_version", [bytes([9, 0]) + struct.pack("<I", 0)]),
                    init_payload("fractal_search", [s_arg(b"x")] * 4),
                    init_payload("fractal_vector_dims", [s_arg(b"x")] * 5)):
        send(frame(INIT, payload))

    # CALL / DEINIT / CANCEL with bad handles and bodies.
    for payload in (b"", bytes([3]), bytes([3]) + b"abc" + b"\0" * 5,
                    bytes([3]) + b"abc" + struct.pack("<QI", 1, 0),
                    call_payload("fractal_version", 12345, []), call_payload("fractal_version", 0, []),
                    call_payload("", 1, []), call_payload("fractal_version", 1, [s_arg(b"x")] * 65),
                    name15 + struct.pack("<QI", 1, 1) + bytes([1])):
        send(frame(CALL, payload))
        send(frame(CALL, payload, ctx=77))
    for payload in (b"", b"x" * 7, b"x" * 8, b"x" * 9, struct.pack("<Q", 0), struct.pack("<Q", 2 ** 64 - 1),
                    struct.pack("<Q", 12345)):
        send(frame(DEINIT, payload))
        send(frame(CANCEL, payload))

    # A handle used from a different connection than the one that created it.
    owner = connect()
    owner.sendall(frame(INIT, init_payload("fractal_vector_dims", [s_arg(b"[1]")])))
    handle = handle_of(read_reply(owner))
    send(frame(CALL, call_payload("fractal_vector_dims", handle, [s_arg(b"[1]")])))
    send(frame(DEINIT, struct.pack("<Q", handle)))
    send(frame(CANCEL, struct.pack("<Q", handle)))
    owner.close()

    # Idempotency cache: many tokens (eviction), then replays, then large cached bodies.
    s = connect()
    s.sendall(frame(INIT, init_payload("fractal_state_fingerprint", [s_arg(b"[1,2,3]"), i_arg(128), i_arg(1)])))
    handle = handle_of(read_reply(s))
    for token in list(range(1, 700)) + [1, 2, 300, 699, 700]:
        s.sendall(frame(CALL, call_payload("fractal_state_fingerprint", handle,
                                           [s_arg(b"[1,2,3]"), i_arg(128), i_arg(token)]), ctx=token))
        read_reply(s)
    s.close()
    s = connect()
    s.sendall(frame(INIT, init_payload("fractal_vector_normalize", [s_arg(b"[1]")])))
    handle = handle_of(read_reply(s))
    big = b"[" + b",".join([b"1.5"] * 600000) + b"]"       # about 2.4 MB, so the reply is cached too
    for token in range(1, 40):
        s.sendall(frame(CALL, call_payload("fractal_vector_normalize", handle, [s_arg(big)]), ctx=1000 + token))
        read_reply(s)
    s.close()

    # Random byte-level mutations of valid frames.
    bases = [(INIT, init_payload("fractal_search", search)),
             (INIT, init_payload("fractal_vector_scale", [s_arg(b"[1,2,3]"), arg(T_REAL, struct.pack("<d", 2.0))])),
             (CALL, call_payload("fractal_vector_dims", 1, [s_arg(b"[1,2,3]")])),
             (DEINIT, struct.pack("<Q", 1)), (CANCEL, struct.pack("<Q", 1))]
    for _ in range(1500):
        op, payload = random.choice(bases)
        payload = bytearray(payload)
        choice = random.random()
        if choice < 0.4 and payload:
            payload[random.randrange(len(payload))] = random.randrange(256)
        elif choice < 0.6 and payload:
            payload = payload[:random.randrange(len(payload))]
        elif choice < 0.8:
            payload += bytes(random.randrange(256) for _ in range(random.randrange(1, 40)))
        elif payload:
            i = random.randrange(len(payload))
            word = struct.pack("<I", random.choice([0, 1, 2 ** 31, 2 ** 32 - 1, 65, 64]))
            payload[i:i + random.randrange(1, 5)] = word[:random.randrange(1, 5)]
        send(frame(op, bytes(payload), ctx=random.choice([0, 0, 5, 2 ** 64 - 1])))

    alive = send(frame(PING)) is not None
    print("frame_fuzz: done" if alive else "frame_fuzz: the daemon stopped answering")
    sys.exit(0 if alive else 1)


if __name__ == "__main__":
    main()
