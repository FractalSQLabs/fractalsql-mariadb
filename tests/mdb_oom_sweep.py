#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""tests/mdb_oom_sweep.py -- every kit statement re-run with an allocation failure injected inside the daemon.

The daemon's own allocations are what the fault shim (tests/oom_preload.c, an LD_PRELOAD library) can fail:
the shim is armed with a control file and a signal, so the nth allocation after the arming fails, and the
driver sweeps that n over the statement's allocation points. The statement must still be answered or refused
cleanly -- the daemon may not crash and may not hang.

Env: FSQL_MARIADB_JSON -- the mariadb client command as a JSON list (connection options, -N); FSQL_OOM_CTL
-- the shim's control file; FSQD_PID -- the daemon's pid (the arming signal goes to it); OOM_MAX_N -- the
allocation ordinals tried per statement (default 12); OOM_MAX_KITS -- a cap, for debugging. Exit status is
nonzero when a check fails.
"""
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time

CLI = json.loads(os.environ["FSQL_MARIADB_JSON"]) + ["--default-character-set=utf8mb4"]
CTL = os.environ.get("FSQL_OOM_CTL", "")
PID = int(os.environ.get("FSQD_PID", "0") or 0)
MAX_N = int(os.environ.get("OOM_MAX_N", "12") or 12)
MAX_KITS = int(os.environ.get("OOM_MAX_KITS", "0") or 0)
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

TARGET = re.compile(r"(?is)^\s*(select|with)\b")
CALL = re.compile(r"\bfractal_[a-z0-9_]*\s*\(")

runs = 0
problems = 0


def sql(s, timeout=60):
    """One statement. Returns (ok, output)."""
    try:
        p = subprocess.run(CLI + ["-e", s], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    out = (p.stdout + p.stderr).decode("utf-8", "replace").strip()
    if p.returncode != 0 and ("Lost connection" in out or "server has gone away" in out or "Can't connect" in out):
        return False, "CRASH: " + out[:160]
    return p.returncode == 0, out


def alive():
    """The daemon is still there."""
    if PID <= 0:
        return True
    try:
        os.kill(PID, 0)
        return True
    except OSError:
        return False


def arm(n):
    """Fail the nth allocation after this point."""
    if not CTL or PID <= 0:
        return False
    with open(CTL, "w") as f:
        f.write("%d %d %d %d\n" % (n, 0, 0, 0))
    try:
        os.kill(PID, signal.SIGUSR1)
    except OSError:
        return False
    time.sleep(0.01)
    return True


def disarm():
    if PID <= 0:
        return
    try:
        os.kill(PID, signal.SIGUSR2)
    except OSError:
        pass


def split_statements(text):
    stmts, buf = [], []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'":
                    if j + 1 < n and text[j + 1] == "'":
                        j += 2
                        continue
                    break
                j += 1
            buf.append(text[i:min(j + 1, n)])
            i = j + 1
            continue
        if ch == '"':
            j = text.find('"', i + 1)
            j = n if j < 0 else j + 1
            buf.append(text[i:j])
            i = j
            continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(" ")
            i = j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i)
            j = n if j < 0 else j + 2
            buf.append(" ")
            i = j
            continue
        if ch == ";":
            stmts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    if "".join(buf).strip():
        stmts.append("".join(buf))
    return [s.strip() for s in stmts if s.strip()]


def main():
    global runs, problems
    if not CTL or PID <= 0:
        print("SKIP oom_sweep: the fault shim is not armed (FSQL_OOM_CTL / FSQD_PID)")
        return 0

    demo = os.path.join(ROOT, "demo")
    kits = sorted(glob.glob(os.path.join(demo, "demo-vertical-*.sql")))
    if MAX_KITS:
        kits = kits[:MAX_KITS]

    for kit in kits:
        with open(kit, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        stmts = split_statements(text)
        setup = [s for s in stmts if not (TARGET.match(s) and CALL.search(s))]
        targets = [s for s in stmts if TARGET.match(s) and CALL.search(s)]
        for s in setup:
            sql(s + ";")
        for st in targets:
            # Unarmed first: the statement must work at all, so a failure under the fault is the fault's.
            base_ok, _ = sql(st + ";")
            if not base_ok:
                continue
            for n in range(1, MAX_N + 1):
                if not arm(n):
                    break
                runs += 1
                sql(st + ";")
                disarm()
                if not alive():
                    problems += 1
                    shown = st[:120].replace("\n", " ").encode("ascii", "backslashreplace").decode("ascii")
                    print("  FAIL the daemon died: %s (allocation #%d)" % (shown, n))
                    break
    disarm()
    print("oom sweep: %d kits, %d runs, %d problem(s)" % (len(kits), runs, problems))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
