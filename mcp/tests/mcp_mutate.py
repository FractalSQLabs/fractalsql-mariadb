#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Replays the smoke client's own tool calls with one argument at a time changed,
and sweeps the resource and prompt methods.

mcp_robustness.py mutates every tool from placeholder values taken from the tool
schemas ("smoke", 3, [0.1, 0.2, 0.3]); most handlers refuse those before they
reach the engine. The calls the smoke client makes are valid for the fixtures it
builds, so a mutation of one of them reaches the handler's own validation and
the engine. mcp_smoke_client.py records each tools/call it sends and passes the
list to run().

A mutation must always come back as a well-formed response, never kill or wedge
the server, and never be reported as the adapter-layer "server" error class.
Tools that are destructive, or that rewrite the daemon's configuration, are not
replayed with a changed argument.

  MCP_MUTATE_STRIDE=N       keep every Nth mutation (default 1)
  MCP_TEST_DAEMON_EXE=PATH  the daemon binary. When set, a throwaway daemon with
                            its own socket, key and conf file is started and the
                            server under test is pointed at it, so the tools that
                            rewrite the daemon's configuration can be replayed
                            without touching the daemon the gate itself uses

Zero dependencies beyond the stdlib."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcp_robustness as rb  # noqa: E402

_BIG_STR = "x" * 70000
_DEEP = {}
_cur = _DEEP
for _i in range(70):
    _cur["k"] = {}
    _cur = _cur["k"]

_EDGES = {
    "string": [None, "", " ", "x", "a" * 300, _BIG_STR, "é☃\U0001f600", "'; DROP TABLE t; --",
               "../../etc/passwd", "-1", "0", "1e999", "NaN", "[1,2", "{\"a\":", "\\", "%s%n", 12345, True,
               [], {}, ["a"]],
    "integer": [None, -1, 0, 1, 2, 255, 65536, 2 ** 31, 2 ** 31 - 1, -2 ** 31, 2 ** 63 - 1, -2 ** 63, 2 ** 64,
                1.5, "3", "", True, [], {}],
    "number": [None, -1, 0, 1, 0.0, -0.0, 1e308, -1e308, 1e-308, 5e-324, 2 ** 63, "nan", "inf", "", True, [], {}],
    "boolean": [None, 0, 1, "true", "false", "maybe", "", [], {}],
    "array": [None, [], [None], [[]], [[1, 2], [3]], ["a", "b"], [1e308, -1e308, 0], [0.1] * 5000,
              [0.1] * 70, [True], "not-an-array", {}, 7],
    "object": [None, {}, {"a": 1}, {"k": {"k": {"k": 1}}}, _DEEP, [], [1, 2], "str", 5,
               {"iterations": -1}, {"iterations": 10 ** 12}, {"population_size": 0}],
}


def _edges_for(value):
    if isinstance(value, bool):
        return _EDGES["boolean"]
    if isinstance(value, int):
        return _EDGES["integer"]
    if isinstance(value, float):
        return _EDGES["number"]
    if isinstance(value, str):
        return _EDGES["string"]
    if isinstance(value, list):
        return _EDGES["array"]
    if isinstance(value, dict):
        return _EDGES["object"]
    return _EDGES["string"]


_ALLOW_RISKY = False   # set by run(): a throwaway daemon is in use and the edition is Community


def _skip_tool(tool):
    ann = tool.get("annotations") or {}
    if _ALLOW_RISKY:
        return False
    return bool(ann.get("destructiveHint")) or tool["name"] in rb._CONFIG_WRITERS


def _start_daemon():
    """Starts a throwaway daemon; returns its settings, or None."""
    exe = os.environ.get("MCP_TEST_DAEMON_EXE")
    if not exe or not os.path.isfile(exe):
        return None
    td = tempfile.mkdtemp(prefix="fsqlmcp_mut_")
    key, conf, log = (os.path.join(td, n) for n in ("k", "d.conf", "d.log"))
    with open(key, "w") as f:
        f.write(os.urandom(32).hex() + "\n")
    sock = r"\\.\pipe\fsqlmcp_mut_%d" % os.getpid() if os.name == "nt" else os.path.join(td, "s")
    lines = ["socket_path = " + sock, "hmac_key_file = " + key]
    if os.name != "nt":
        lines.append("allowed_uids = %d" % os.getuid())
    with open(conf, "w") as f:
        f.write("\n".join(lines) + "\n")
    if os.name != "nt":
        os.chmod(key, 0o600)
        os.chmod(conf, 0o600)
    logf = open(log, "w")
    p = subprocess.Popen([exe, "-c", conf], stdout=logf, stderr=logf, stdin=subprocess.DEVNULL,
                         env={k: v for k, v in os.environ.items() if k != "LD_PRELOAD"})
    for _ in range(100):
        if p.poll() is not None:
            break
        try:
            if "listening on" in open(log, errors="replace").read():
                return {"proc": p, "dir": td, "sock": sock, "key": key, "conf": conf, "log": logf}
        except OSError:
            pass
        time.sleep(0.1)
    p.kill()
    logf.close()
    shutil.rmtree(td, ignore_errors=True)
    return None


def _stop_daemon(d):
    if not d:
        return
    try:
        d["proc"].terminate()
        d["proc"].wait(timeout=10)
    except Exception:  # noqa: BLE001
        d["proc"].kill()
    d["log"].close()
    shutil.rmtree(d["dir"], ignore_errors=True)


def _variants(args):
    """Yields (label, arguments) for one recorded call."""
    yield "as recorded", args
    yield "no arguments", {}
    yield "unknown property", {**args, "zz_unknown": 1}
    for k, v in args.items():
        yield "drop %s" % k, {a: b for a, b in args.items() if a != k}
        for i, e in enumerate(_edges_for(v)):
            yield "%s edge %d" % (k, i), {**args, k: e}


def _call(s, bad, name, label, args, must_be_well_formed=True):
    try:
        resp = s.call("tools/call", {"name": name, "arguments": args}, timeout=120)
    except Exception as e:  # noqa: BLE001
        bad.append("%s [%s]: %r" % (name, label, e))
        return False
    if rb._is_server_error(resp):
        bad.append("%s [%s]: %s" % (name, label, json.dumps(resp)[:200]))
    return True


def _tool_replay(s, tools, calls, check):
    by_name = {t["name"]: t for t in tools}
    stride = max(1, int(os.environ.get("MCP_MUTATE_STRIDE", "1")))
    seen, uniq = set(), []
    for name, args in calls:
        key = name + json.dumps(args, sort_keys=True, default=str)
        if key in seen or name not in by_name or _skip_tool(by_name[name]):
            continue
        seen.add(key)
        uniq.append((name, args))
    bad, n, k = [], 0, 0
    for name, args in uniq:
        for label, v in _variants(args):
            k += 1
            if stride > 1 and k % stride != 0 and label != "as recorded":
                continue
            n += 1
            if not _call(s, bad, name, label, v):
                if not s.alive():
                    bad.append("SERVER DIED during " + name)
                    check("mutate: replayed %d mutated calls (%d recorded) and the server died" % (n, len(uniq)), False)
                    for b in bad[:8]:
                        print("      offender: " + b)
                    return
    check("mutate: %d mutations of %d recorded tool calls all answered, none a server error" % (n, len(uniq)), not bad)
    for b in bad[:8]:
        print("      offender: " + b)


# ---- resources, prompts and protocol methods ----------------------------------

_URIS = ["fractalsql://schema", "fractalsql://config", "fractalsql://vectorizer/status", "fractalsql://agents",
         "fractalsql://ledger/1", "fractalsql://ledger/2", "fractalsql://ledger/3", "fractalsql://ledger/",
         "fractalsql://ledger/abc", "fractalsql://ledger/1/extra", "fractalsql://ledger/-1",
         "fractalsql://ledger/99999999999999999999", "fractalsql://unknown", "fractalsql://", "fractalsql:",
         "http://example.invalid/", "file:///etc/passwd", "", " ", "x" * 5000, "fractalsql://schema?x=1",
         "fractalsql://schema/", "FRACTALSQL://SCHEMA"]


def _proto_sweep(s, check):
    bad = []

    def go(method, params=None, label=None):
        try:
            resp = s.call(method, params, timeout=60)
        except Exception as e:  # noqa: BLE001
            bad.append("%s %s: %r" % (method, label or "", e))
            return None
        if rb._is_server_error(resp):
            bad.append("%s %s: %s" % (method, label or "", json.dumps(resp)[:160]))
        elif isinstance(resp, dict) and "result" not in resp and "error" not in resp:
            bad.append("%s %s: neither result nor error" % (method, label or ""))
        return resp

    go("resources/list")
    go("resources/list", {})
    go("resources/templates/list")
    go("resources/templates/list", {"cursor": "x"})
    for u in _URIS:
        go("resources/read", {"uri": u}, u[:40])
    for p in (None, {}, {"uri": None}, {"uri": 5}, {"uri": []}, {"uri": {}}, {"uri": True}, {"nope": 1}, [], "x", 7):
        go("resources/read", p, repr(p)[:40])
    go("resources/subscribe", {"uri": "fractalsql://schema"})
    go("resources/unsubscribe", {"uri": "fractalsql://schema"})

    listed = go("prompts/list") or {}
    prompts = (listed.get("result") or {}).get("prompts") or []
    for pr in prompts:
        name = pr["name"]
        args = pr.get("arguments") or []
        full = {a["name"]: "value" for a in args}
        go("prompts/get", {"name": name, "arguments": full}, name + " full")
        go("prompts/get", {"name": name}, name + " no arguments")
        go("prompts/get", {"name": name, "arguments": {}}, name + " empty arguments")
        go("prompts/get", {"name": name, "arguments": {**full, "zz": "x"}}, name + " extra argument")
        go("prompts/get", {"name": name, "arguments": {a: "{" + a + "}" for a in full}}, name + " placeholder text")
        go("prompts/get", {"name": name, "arguments": {a: "x" * 20000 for a in full}}, name + " long values")
        go("prompts/get", {"name": name, "arguments": {a: "é☃" for a in full}}, name + " non-ASCII")
        for a in full:
            go("prompts/get", {"name": name, "arguments": {**full, a: 5}}, name + " numeric " + a)
            go("prompts/get", {"name": name, "arguments": {**full, a: None}}, name + " null " + a)
            go("prompts/get", {"name": name, "arguments": {k: v for k, v in full.items() if k != a}},
               name + " without " + a)
        go("prompts/get", {"name": name, "arguments": "not-an-object"}, name + " non-object arguments")
    for p in (None, {}, {"name": None}, {"name": 5}, {"name": "no-such-prompt"}, {"name": ""}, [], "x"):
        go("prompts/get", p, repr(p)[:40])

    for method, params in (
            ("no/such/method", {}), ("", {}), ("tools/call", None), ("tools/call", {}),
            ("tools/call", {"name": None}), ("tools/call", {"name": 5}), ("tools/call", {"name": "no_such_tool"}),
            ("tools/call", {"name": "fractalsql_get_version", "arguments": "x"}),
            ("tools/call", {"name": "fractalsql_get_version", "arguments": [1]}),
            ("tools/call", {"name": "fractalsql_get_version", "arguments": None}),
            ("tools/call", {"name": "x" * 5000, "arguments": {}}),
            ("tools/list", {"cursor": "abc"}), ("tools/list", {"cursor": 5}), ("tools/list", None),
            ("completion/complete", {}), ("logging/setLevel", {"level": "debug"}), ("logging/setLevel", {"level": 5}),
            ("logging/setLevel", {}), ("ping", None), ("ping", [1]), ("ping", "x"),
            ("initialize", None), ("initialize", {}), ("initialize", {"protocolVersion": None}),
            ("initialize", {"protocolVersion": "2024-11-05", "capabilities": {"roots": {}}}),
            ("initialize", {"protocolVersion": "2025-03-26", "clientInfo": {"name": 5}}),
            ("initialize", {"protocolVersion": "2025-06-18", "clientInfo": "x", "capabilities": []})):
        go(method, params, repr(params)[:40])

    # notifications get no response; send them and make sure the stream stays in sync
    for method, params in (("notifications/initialized", {}), ("notifications/cancelled", {"requestId": 99999}),
                           ("notifications/cancelled", {}), ("notifications/cancelled", {"requestId": "x"}),
                           ("notifications/cancelled", {"requestId": None}), ("$/cancelRequest", {"id": 1}),
                           ("$/cancel", {"id": 12345}), ("$/cancel", {}), ("$/cancel", {"id": None}),
                           ("notifications/progress", {}), ("notifications/roots/list_changed", {}),
                           ("notifications/no_such", {})):
        s.send(method, params, notify=True)
    go("ping", {}, "after notifications")
    check("mutate: resource, prompt and protocol requests were all answered, none a server error",
          not bad and s.alive())
    for b in bad[:8]:
        print("      offender: " + b)


def run(check, calls):
    """Entry point used by mcp_smoke_client.py. `calls` is the list of
    (tool name, arguments) the smoke client sent."""
    global _ALLOW_RISKY
    exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ.get("MCP_SERVER_CWD") or os.path.dirname(os.path.abspath(exe)) or "."
    daemon = _start_daemon()
    env_extra = {}
    if daemon:
        env_extra = {"FSQLCTL_SOCKET": daemon["sock"], "FSQLCTL_KEY": daemon["key"], "FSQLCTL_CONF": daemon["conf"]}
    s = rb._Session(exe, cwd, env_extra)
    try:
        rb._init(s)
        _proto_sweep(s, check)
        if daemon:
            # The destructive tools act on the engine's own daemon; only replay them
            # against a Community install, where they refuse.
            ver = json.dumps(s.call("tools/call", {"name": "fractalsql_get_version", "arguments": {}}, timeout=60))
            _ALLOW_RISKY = "nterprise" not in ver
        listed = s.call("tools/list", {})
        tools = (listed.get("result") or {}).get("tools") or []
        _tool_replay(s, tools, calls, check)
        check("mutate: the server is still answering after the replay",
              "result" in s.call("ping", {}, timeout=30) and s.alive())
    except Exception as e:  # noqa: BLE001
        check("mutate: the sweep raised %r" % (e,), False)
    finally:
        rc = s.close()
        _stop_daemon(daemon)
        _ALLOW_RISKY = False
    check("mutate: the server exits cleanly (rc 0) after the sweep", rc == 0)


if __name__ == "__main__":
    print("mcp_mutate.py is run from mcp_smoke_client.py, which supplies the recorded calls")
    sys.exit(2)
