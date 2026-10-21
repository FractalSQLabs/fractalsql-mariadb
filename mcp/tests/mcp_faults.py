#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs

"""Fails one allocation, file call or socket call at a time inside the MCP server.

The server runs under tests/oom_preload.c, armed through a control file, with
the main thread (the request reader) spared: only the worker thread that
handles a request has a failed call to recover from. For each
call from mcp_fixtures.py the driver first counts nothing: it simply arms the
Nth allocation (then the Mth file call and the Kth socket call) for a spread of
N, M and K, sends the call, and disarms. Whatever the server answers is fine
(an internal-error response is the right answer to a failed allocation); what
must hold is that the server is still running afterwards and that its next
request is answered. A server that dies is restarted and counted.

  usage: mcp_faults.py            (environment as for mcp_smoke_client.py, plus
                                   MCP_OOM_PRELOAD=<oom_preload.so>)
  MCP_FAULT_POINTS=N   allocation points tried per call (default 40)
  MCP_FAULT_SYS=N      socket-call numbers tried per errno (default 20)
  MCP_FAULT_PHASES=a,f,s   which of the allocation, file and socket phases to run
  MCP_FAULT_BUDGET_S=N  wall-clock cap per phase in seconds (default 60); a phase that hits it stops and says so
  MCP_FAULT_VERBOSE=1  print every call that got no answer (the first three are always printed)
  MCP_FAULT_TOOLS=a,b      only the tools whose name contains one of these

POSIX only (LD_PRELOAD and signals). Zero dependencies beyond the stdlib."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcp_fixtures  # noqa: E402
import mcp_robustness as rb  # noqa: E402

_FAILURES = 0
_BUDGET = float(os.environ.get("MCP_FAULT_BUDGET_S", "60"))   # wall clock for each phase


def _over(start):
    return time.monotonic() - start > _BUDGET


def _check(label, cond):
    global _FAILURES
    print(("PASS " if cond else "FAIL ") + label, flush=True)
    if not cond:
        _FAILURES += 1
    return bool(cond)


def _mariadb(sql):
    exe = os.environ["MCP_MARIADB_BIN"]
    r = subprocess.run(
        [exe, "--host=" + os.environ["MARIADB_HOST"], "--port=" + os.environ["MARIADB_PORT"], "-uroot",
         "-D", os.environ["MARIADB_DATABASE"], "-e", sql],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("fixture SQL failed: " + r.stderr[:300])


def _fixtures():
    _mariadb("""
    DROP TABLE IF EXISTS mcp_sm_docs;
    CREATE TABLE mcp_sm_docs (id BIGINT PRIMARY KEY AUTO_INCREMENT, title VARCHAR(64), emb TEXT);
    INSERT INTO mcp_sm_docs (title, emb) VALUES ('alpha','[1.0,0.0,0.0]'),('beta','[0.0,1.0,0.0]'),
      ('gamma','[0.9,0.1,0.0]'),('delta','[0.15,0.15,0.12]');
    DROP TABLE IF EXISTS mcp_sm_logs;
    CREATE TABLE mcp_sm_logs (ts BIGINT, host VARCHAR(64), metric DOUBLE);
    INSERT INTO mcp_sm_logs (ts, host, metric)
      SELECT seq*2, 'host-1', 50.0 + (seq % 8) * 1.3 FROM seq_1_to_96;
    """)


def _thread_states(pid):
    """State and kernel wait point of each thread of a server that is alive but not
    answering (Linux)."""
    out = []
    try:
        for tid in sorted(os.listdir("/proc/%d/task" % pid), key=int):
            base = "/proc/%d/task/%s/" % (pid, tid)
            st = open(base + "stat").read().split(")")[-1].split()[0]
            try:
                wc = open(base + "wchan").read().strip() or "-"
            except OSError:
                wc = "?"
            out.append("%s:%s:%s" % (tid, st, wc))
    except OSError:
        pass
    return " ".join(out)[:300]


class _Faulty:
    """A server session under the fault shim, restarted when it dies."""

    def __init__(self, exe, cwd, so, ctl):
        self.exe, self.cwd, self.so, self.ctl = exe, cwd, so, ctl
        self.deaths = 0
        self.unanswered = 0
        self.first_death = ""
        self.causes = {}
        self.alloc_aborts = 0
        self.other_deaths = 0
        self.s = None
        self.start()

    def start(self):
        if self.s is not None:
            self.s.close()
        self.errpath = self.ctl + ".err"
        self.errf = open(self.errpath, "w")
        self.s = rb._Session(self.exe, self.cwd, {"LD_PRELOAD": self.so, "FSQL_OOM_CTL": self.ctl,
                                                  "FSQL_OOM_WORKERS_ONLY": "1"}, stderr=self.errf)
        rb._init(self.s)

    def arm(self, n, m, k, e=0):
        with open(self.ctl, "w") as f:
            f.write("%d %d %d %d\n" % (n, m, k, e))
        os.kill(self.s.p.pid, signal.SIGUSR1)

    def disarm(self):
        if self.s.alive():
            os.kill(self.s.p.pid, signal.SIGUSR2)

    def _call_any(self, name, args, timeout=8):
        """Sends one call and returns the first response that answers it: its own,
        or the id-less error a request gets when it cannot even be parsed (a failed
        allocation while reading the line)."""
        rid = self.s.send("tools/call", {"name": name, "arguments": args})
        deadline = time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("no answer")
            line = self.s.q.get(timeout=left)
            if line is None:
                self.s.q.put(None)
                raise RuntimeError("server closed stdout")
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and obj.get("id") in (rid, None):
                return obj

    def trial(self, label, name, args, arm):
        """One call with one fault armed. Returns after the server is known to be
        answering again (restarting it if it died)."""
        arm()
        t_call = time.monotonic()
        try:
            self._call_any(name, args)
        except Exception:  # noqa: BLE001
            self.unanswered += 1
            if os.environ.get("MCP_FAULT_VERBOSE") or self.unanswered <= 3:
                print("      note: no answer within %.0fs to %s (%s)" % (time.monotonic() - t_call, name, label), flush=True)
        self.disarm()
        ok = False
        if self.s.alive():
            try:
                ok = "result" in self.s.call("ping", {}, timeout=8)
            except Exception:  # noqa: BLE001
                ok = False
        if not ok:
            self.deaths += 1
            if not self.first_death:
                self.first_death = "%s: %s" % (label, name)
            # A server that has just hit std::terminate stays alive while the system
            # writes its core dump; let it finish going down before judging it, or its
            # last message is not yet in the log and it looks like a hang.
            end = time.monotonic() + 3
            while self.s.p.poll() is None and time.monotonic() < end:
                time.sleep(0.2)
            try:
                text = open(self.errpath, errors="replace").read()
            except OSError:
                text = ""
            rc = self.s.p.poll()
            if rc is None:
                text += " [threads: %s]" % _thread_states(self.s.p.pid)
            if "bad_alloc" in text:
                # The standard library's own report that an allocation failed and nothing
                # caught it: the process ends, as an unhandled C++ exception does.
                self.alloc_aborts += 1
            else:
                self.other_deaths += 1
                lines = text.strip().splitlines()[-1:]
                note = "rc=%s %s" % (rc, lines[0][-320:] if lines else "no message")
                if note not in self.causes:
                    self.causes[note] = "%s: %s" % (label, name)
            try:
                self.start()
            except Exception as e:  # noqa: BLE001
                raise SystemExit("cannot restart the server: %r" % (e,))
        return ok


def run():
    exe = os.environ["MCP_SERVER_EXE"]
    cwd = os.environ.get("MCP_SERVER_CWD") or os.path.dirname(os.path.abspath(exe)) or "."
    so = os.environ["MCP_OOM_PRELOAD"]
    points = int(os.environ.get("MCP_FAULT_POINTS", "10"))
    sys_n = int(os.environ.get("MCP_FAULT_SYS", "4"))
    phases = os.environ.get("MCP_FAULT_PHASES", "a,f,s").split(",")
    _fixtures()
    ctl = os.path.join(tempfile.mkdtemp(prefix="fsqlmcp_fault_"), "ctl")
    open(ctl, "w").write("0 0 0 0\n")
    f = _Faulty(exe, cwd, so, ctl)
    # Calls that change nothing the later calls need, and that never rewrite the
    # daemon's configuration or the ledger.
    only = [t for t in os.environ.get("MCP_FAULT_TOOLS", "").split(",") if t]
    calls = [(n, a) for n, a in mcp_fixtures.FIXTURE_CALLS
             if not only or any(t in n for t in only)]
    calls = [(n, a) for n, a in calls
             if n not in rb._CONFIG_WRITERS and not n.startswith("fractal_ledger_")
             and n not in ("fractal_vectorizer_drop", "fractal_session_close")]
    # Allocation failures: a spread of points, dense at the start of a call.
    trials = 0
    t_ph = time.monotonic()
    capped = False
    for name, args in (calls if "a" in phases else []):
        if _over(t_ph):
            capped = True
            break
        for i in range(points):
            n = max(1, int(1.2 ** i))
            f.trial("allocation %d" % n, name, args, lambda n=n: f.arm(n, 0, 0))
            trials += 1
    _check("faults: %d injected allocation failures over %d tool calls%s: %d ended the server with an uncaught "
           "std::bad_alloc, %d other server deaths%s"
           % (trials, len(calls), " (time budget reached)" if capped else "", f.alloc_aborts, f.other_deaths,
              (" (first: " + f.first_death + ")") if f.other_deaths and f.first_death else ""),
           f.other_deaths == 0)
    for note, where in list(f.causes.items())[:6]:
        print("      cause: %s  [%s]" % (note, where), flush=True)
    allocation_deaths = f.deaths
    # File-system failures (the server reads its config and lock files per call).
    trials = 0
    f.deaths = 0
    f.first_death = ""
    t_ph = time.monotonic()
    for name, args in (calls[:25] if "f" in phases else []):
        if _over(t_ph):
            break
        for m in range(1, 7):
            f.trial("file call %d" % m, name, args, lambda m=m: f.arm(0, m, 0))
            trials += 1
    _check("faults: %d injected file-call failures, %d server deaths%s"
           % (trials, f.deaths, (" (first: " + f.first_death + ")") if f.first_death else ""), f.deaths == 0)
    # Socket and thread failures: the connection to the engine and to the daemon.
    trials = 0
    f.deaths = 0
    f.first_death = ""
    t_ph = time.monotonic()
    for name, args in (calls[::4] if "s" in phases else []):
        if _over(t_ph):
            break
        for e in (5, 104, 111):
            for k in range(1, sys_n + 1):
                f.trial("socket call %d errno %d" % (k, e), name, args, lambda k=k, e=e: f.arm(0, 0, k, e))
                trials += 1
    _check("faults: %d injected socket and thread failures, %d server deaths%s"
           % (trials, f.deaths, (" (first: " + f.first_death + ")") if f.first_death else ""), f.deaths == 0)
    rc = f.s.close()
    _check("faults: the server exits cleanly after the sweep", rc == 0)
    return allocation_deaths


if __name__ == "__main__":
    run()
    print("mcp-faults: %s; %d failure(s)" % ("ALL GREEN" if not _FAILURES else "FAILED", _FAILURES))
    sys.exit(1 if _FAILURES else 0)
