#!/usr/bin/env python3
"""tests/test_index.py -- the native IVF index and the indexed
fractal_search (gate 81).

Covers: the build (every vector_format), the "index actually used" check
(the rows the index scanned are far below the table's row count), the
recall against the exact scan, the verified (exact) distances, the
fallback to an exact scan when there is no index, the rows added after
the build (the delta), a deleted row, the staleness report, the rebuild
(generation 2), the candidates for Scout, the drop, and the retired
fractal_search(vector, query) call.

THE CORE MUST CARRY THE IVF INDEX: the vendored core archive in
include/<platform>/ may predate the IVF maths, and then every index
operation reports "this build of fractalsql-core does not carry the IVF
index (rebuild the core and refresh include/<platform>)". That is the
documented behaviour, and this driver reports it as a SKIP (not a
failure) so a host with an older core says so plainly.

Skip-safe: exits 0 with SKIP if the mariadb connector is missing or no DB
is reachable.

Usage:
    python3 tests/test_index.py
"""
import json
import math
import random
import struct
import sys

from _t2s_common import connect_or_skip, to_str

fails = 0
DIM = 16
N = 1200
CLUSTERS = 12


def check(ok, name, detail=""):
    global fails
    print(("  [PASS] " if ok else "  [FAIL] ") + name + ("" if ok or not detail else ": " + str(detail)[:300]))
    if not ok:
        fails += 1


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def vtxt(v):
    return "[" + ",".join(repr(f32(t)) for t in v) + "]"


def as_bool(v):
    """MariaDB's JSON_OBJECT renders a boolean as the string 'true'/'false' on
    10.6 and as a JSON value from 11.0 on, so a flag is read the same way on
    every line."""
    if isinstance(v, bool):
        return v
    if isinstance(v, str):
        return v.strip().lower() in ("true", "1")
    return bool(v)


def as_int(v, dflt=0):
    """The same for a number: '1200' on 10.6, 1200 from 11.0 on."""
    if v is None or v == "":
        return dflt
    try:
        return int(v)
    except (TypeError, ValueError):
        return dflt


def call(cur, sql, params=()):
    cur.execute(sql, params)
    try:
        cur.fetchall()
    except Exception:
        pass


def out(cur, var):
    cur.execute("SELECT @" + var)
    row = cur.fetchone()
    return to_str(row[0]) if row else None


def jout(cur, var):
    raw = out(cur, var)
    try:
        return json.loads(raw or "null")
    except Exception:
        return raw


def corpus(rng):
    centers = [[rng.gauss(0, 1) for _ in range(DIM)] for _ in range(CLUSTERS)]
    rows = []
    for _ in range(N):
        c = rng.choice(centers)
        rows.append([f32(x + 0.25 * rng.gauss(0, 1)) for x in c])
    return rows


def main():
    conn = connect_or_skip()
    if conn is None:
        return 0
    cur = conn.cursor()
    rng = random.Random(11)
    rows = corpus(rng)

    cur.execute("DROP TABLE IF EXISTS _fi_t")
    cur.execute("CREATE TABLE _fi_t (id INT PRIMARY KEY, emb TEXT NOT NULL, label TEXT)")
    for i, r in enumerate(rows):
        cur.execute("INSERT INTO _fi_t VALUES (%s, %s, %s)", (i + 1, vtxt(r), "r%d" % i))

    q = rows[7]
    qt = vtxt(q)

    # --- the build --------------------------------------------------------
    call(cur, "CALL fractal_index_create('_fi_t', 'emb', %s, @r)",
         (json.dumps({"name": "ix1", "vector_format": "FP32"}),))
    created = jout(cur, "r")
    if isinstance(created, str) and "does not carry the IVF index" in created:
        print("SKIP: the vendored core does not carry the IVF index "
              "(rebuild the core and refresh include/<platform>) -- the index gate needs it")
        cur.execute("DROP TABLE IF EXISTS _fi_t")
        return 0
    check(isinstance(created, dict), "the build returns a JSON report", created)
    if not isinstance(created, dict):
        cur.execute("DROP TABLE IF EXISTS _fi_t")
        return 1
    # MariaDB's JSON_OBJECT renders a scalar as a STRING on 10.6 and as a
    # value from 11.0 on (the server's own JSON rendering changed), so the
    # report's numbers arrive as '1200' on one line and as 1200 on another.
    # Coerce them, the way this host's other drivers already do for the
    # telemetry rows (float(x["dist"])).
    check(as_int(created.get("rows")) == N and as_int(created.get("dim")) == DIM
          and as_int(created.get("generation")) == 1,
          "the build reports rows, dim and generation 1", created)
    check(as_int(created.get("nlist")) >= 1, "the build reports the cell count", created)

    # --- the indexed search ----------------------------------------------
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)",
         (qt, json.dumps({"index": "ix1"})))
    indexed = jout(cur, "r")
    stats = jout(cur, "s")
    check(isinstance(indexed, list) and len(indexed) == 10, "the indexed search returns k rows", indexed)
    check(isinstance(stats, dict) and as_bool(stats.get("used_index")) is True,
          "the search reports that the index was used", stats)

    # THE "INDEX ACTUALLY USED" CHECK: the rows the index scanned must be
    # far below the table's row count. A benchmark that silently ran flat
    # (a full scan behind the index's name) must fail here.
    scanned = as_int(stats.get("rows_scanned"))
    check(0 < scanned < N // 2,
          "the index actually used: it scanned %d rows of the table's %d" % (scanned, N), stats)
    check(as_int(stats.get("cells_probed")) >= 1, "the search probed at least one cell", stats)

    # --- the distances are EXACT (verified against the base table) --------
    exact = {}
    for i, r in enumerate(rows):
        cur.execute("SELECT fractal_vector_cosine_distance(%s, %s)", (vtxt(r), qt))
        exact[i + 1] = float(cur.fetchone()[0])
    bad = [(x["doc_id"], x["dist"]) for x in (indexed or [])
           if int(x["doc_id"]) not in exact
           or struct.pack("<d", float(x["dist"])) != struct.pack("<d", exact[int(x["doc_id"])])]
    check(not bad, "every indexed distance is EXACT (bit-identical to the exact scan)", bad[:3])
    order = [int(x["doc_id"]) for x in (indexed or [])]
    check(order == sorted(order, key=lambda i: (exact.get(i, 0.0), i)),
          "the indexed results are ordered by distance, ties on the row id", order)

    # --- every vector_format: build, recall at every cell, exact distances, really used ---
    # INT8 and INT4 keep a compressed code and re-check the shortlist against the table; FP16 and FP32 keep (almost) the whole vector.
    truth10 = [i for i in sorted(exact, key=lambda i: (exact[i], i))[:10]]
    for fmt, floor in (("INT8", 0.60), ("INT4", 0.50), ("FP16", 0.98), ("FP32", 0.99)):
        name = "fm_" + fmt
        call(cur, "CALL fractal_index_create('_fi_t', 'emb', %s, @r)", (json.dumps({"name": name, "vector_format": fmt, "nlist": 16}),))
        made = jout(cur, "r")
        check(isinstance(made, dict) and made.get("format") == fmt and as_int(made.get("rows")) == N,
              "%s: the index builds and reports its format and rows" % fmt, made)
        if not isinstance(made, dict):
            continue
        call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)", (qt, json.dumps({"index": name, "nprobe": 16})))
        got = jout(cur, "r") or []
        hit = len({int(x["doc_id"]) for x in got} & set(truth10)) / 10.0
        check(hit >= floor, "%s: recall@10 at every cell is at least %.2f (got %.2f)" % (fmt, floor, hit), got[:3])
        badd = [(x["doc_id"], x["dist"]) for x in got
                if struct.pack("<d", float(x["dist"])) != struct.pack("<d", exact[int(x["doc_id"])])]
        check(len(got) == 10 and not badd, "%s: every returned distance is the exact cosine (bit-identical)" % fmt, badd[:3])
        call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)", (qt, json.dumps({"index": name, "nprobe": 2})))
        st = jout(cur, "s")
        check(isinstance(st, dict) and as_bool(st.get("used_index")) is True and 0 < as_int(st.get("rows_scanned")) < N,
              "%s: a search at nprobe 2 goes through the index and scans fewer rows than the table" % fmt, st)
        call(cur, "CALL fractal_index_drop(%s, @r)", (name,))

    # --- the exact fallback ----------------------------------------------
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)",
         (qt, json.dumps({"use_index": False})))
    fallback = jout(cur, "r")
    fstats = jout(cur, "s")
    check(isinstance(fallback, list) and len(fallback) == 10, "the exact fallback returns k rows", fallback)
    check(isinstance(fstats, dict) and as_bool(fstats.get("used_index")) is False
          and as_int(fstats.get("rows_scanned")) == N,
          "the exact fallback scans every row and reports that it did", fstats)
    check([int(x["doc_id"]) for x in (fallback or [])] == order,
          "the exact fallback returns the same rows as the indexed search")

    # --- the delta, the delete, the staleness -----------------------------
    cur.execute("INSERT INTO _fi_t VALUES (%s, %s, %s)", (90001, vtxt(rows[3]), "new"))
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)",
         (vtxt(rows[3]), json.dumps({"index": "ix1"})))
    delta = jout(cur, "r")
    check(90001 in [int(x["doc_id"]) for x in (delta or [])],
          "a row added after the build is found (the delta is scanned exactly)", delta)

    cur.execute("DELETE FROM _fi_t WHERE id = 8")
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)",
         (qt, json.dumps({"index": "ix1"})))
    after = jout(cur, "r")
    check(8 not in [int(x["doc_id"]) for x in (after or [])],
          "a deleted row is dropped by the verification step", after)

    call(cur, "CALL fractal_index_info('ix1', @r)")
    info = jout(cur, "r")
    check(isinstance(info, dict) and as_bool(info.get("stale")) is True and as_bool(info.get("has_delta")) is True,
          "info reports stale and has_delta", info)
    check(isinstance(info, dict) and info.get("status") == "stale" and as_int(info.get("rows_added_since_build")) == 1
          and any("refresh" in a for a in info.get("advice", [])),
          "the status is stale with one row added and a refresh is advised",
          {k: info.get(k) for k in ("status", "rows_added_since_build", "advice")} if isinstance(info, dict) else info)
    call(cur, "CALL fractal_index_list(@r)")
    lst = jout(cur, "r")
    check(isinstance(lst, list) and len(lst) == 1 and lst[0].get("name") == "ix1" and lst[0].get("status") == "stale"
          and as_int(lst[0].get("rows")) == N and as_int(lst[0].get("rows_now")) == N,
          "the list shows the index with its status and row counts", lst)

    # --- IDS: the search restricted to a set of row ids --------------------
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 5, %s, @r, @s)",
         (qt, json.dumps({"ids": [8, 9, 10, 90001, 99999]})))
    sub = jout(cur, "r"); sst = jout(cur, "s")
    check(isinstance(sub, list) and {int(x["doc_id"]) for x in sub} <= {9, 10, 90001} and len(sub) == 3
          and as_bool(sst.get("used_index")) is False and as_int(sst.get("rows_scanned")) == 3,
          "a short ids set is an exact scan of just those rows (deleted and unknown ids are ignored)", (sub, sst))
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 5, %s, @r, @s)", (qt, json.dumps({"ids": []})))
    check(jout(cur, "r") == [], "an empty ids set returns no rows", jout(cur, "r"))
    try:
        call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 5, %s, @r, @s)", (qt, json.dumps({"ids": [1, "x"]})))
        check(False, "a malformed ids set is refused")
    except Exception as e:
        check("integers" in str(e), "a malformed ids set is refused", e)
    big = list(range(1, N + 1)) + list(range(100000, 104500))
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 5, %s, @r, @s)", (qt, json.dumps({"ids": big, "index": "ix1"})))
    lng = jout(cur, "r"); lst2 = jout(cur, "s")
    check(isinstance(lng, list) and len(lng) == 5 and as_bool(lst2.get("used_index")) is True,
          "a long ids set goes through the index and is filtered", (lng, lst2))

    # --- refresh folds the added row in without retraining ------------------
    call(cur, "CALL fractal_index_refresh('ix1', @r)")
    rf = jout(cur, "r")
    check(isinstance(rf, dict) and as_int(rf.get("added")) == 1 and as_int(rf.get("generation")) == 2 and as_bool(rf.get("refreshed")) is True,
          "the refresh adds the new row as generation 2", rf)
    call(cur, "CALL fractal_index_info('ix1', @r)")
    info = jout(cur, "r")
    check(isinstance(info, dict) and info.get("status") in ("ready", "stale") and as_bool(info.get("has_delta")) is False
          and as_int(info.get("rows_indexed")) == N + 1 and as_int(info.get("generation")) == 2,
          "after the refresh nothing is added since the build", info)
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 10, %s, @r, @s)",
         (vtxt(rows[3]), json.dumps({"index": "ix1", "nprobe": 1})))
    got = jout(cur, "r"); gst = jout(cur, "s")
    check(90001 in [int(x["doc_id"]) for x in got] and int(gst.get("rows_scanned", 0)) < N // 2,
          "the refreshed row is answered from its cell", (got, gst))
    call(cur, "CALL fractal_index_refresh('ix1', @r)")
    rf = jout(cur, "r")
    check(isinstance(rf, dict) and as_bool(rf.get("refreshed")) is False and as_int(rf.get("added")) == 0 and as_int(rf.get("generation")) == 2,
          "a second refresh has nothing to add", rf)

    # --- orphaned: the table is gone ----------------------------------------
    cur.execute("RENAME TABLE _fi_t TO _fi_t_gone")
    call(cur, "CALL fractal_index_info('ix1', @r)")
    info = jout(cur, "r")
    check(isinstance(info, dict) and info.get("status") == "orphaned", "an index whose table is gone is orphaned", info)
    cur.execute("RENAME TABLE _fi_t_gone TO _fi_t")

    call(cur, "CALL fractal_index_rebuild('ix1', @r)")
    rebuilt = jout(cur, "r")
    check(isinstance(rebuilt, dict) and as_int(rebuilt.get("generation")) == 3,
          "the rebuild produces generation 3", rebuilt)
    call(cur, "CALL fractal_index_info('ix1', @r)")
    info = jout(cur, "r")
    check(isinstance(info, dict) and as_bool(info.get("stale")) is False and info.get("status") == "ready",
          "after the rebuild nothing is stale and the status is ready", info)

    # --- the candidates for Scout -----------------------------------------
    call(cur, "CALL fractal_index_candidates('_fi_t', 'emb', %s, %s, @r)",
         (qt, json.dumps({"near": 2, "per_cell": 1})))
    ids = jout(cur, "r")
    check(isinstance(ids, list) and 0 < len(ids) <= N,
          "the candidates are a distinct subset of the rows", len(ids) if isinstance(ids, list) else ids)
    check(isinstance(ids, list) and len(set(ids)) == len(ids),
          "the candidates hold no duplicates")

    # --- agent_use_index: the nearest-row agents' search helper -----------
    def agent_hit(setting):
        if setting is not None:
            cur.execute("SELECT fractal_config_set('agent_use_index', %s, CONNECTION_ID())", (setting,))
            cur.fetchall()
        call(cur, "CALL _fractalsql_agent_search1('_fi_t', 'emb', %s, @h)", (qt,))
        cur.execute("SELECT @h, @_fractalsql_agent_search_path")
        h, path = cur.fetchone()
        hit = json.loads(to_str(h))[0]
        return int(hit["doc_id"]), float(hit["dist"]), path
    cur.execute("SELECT fractal_config_reset(CONNECTION_ID())")
    cur.fetchall()
    d_off, dist_off, path_off = agent_hit(None)
    check(path_off == "scan", "agent_use_index off (the default): the agents' search scans exactly", path_off)
    d_on, dist_on, path_on = agent_hit("on")
    check(path_on == "index", "agent_use_index on with an index: the agents' search goes through the index", path_on)
    check(d_on == d_off and abs(dist_on - dist_off) < 1e-9,
          "the index path returns the same nearest row and exact distance as the scan", (d_on, d_off, dist_on, dist_off))
    cur.execute("SELECT fractal_config_get('agent_use_index', CONNECTION_ID())")
    check(to_str(cur.fetchone()[0]) in ("on", "1", "true"), "the key reads back")
    cur.execute("SELECT fractal_config_reset(CONNECTION_ID())")
    cur.fetchall()
    d_back, _, path_back = agent_hit(None)
    check(path_back == "scan", "after the session reset the agents scan again", path_back)

    # --- the drop -----------------------------------------------------------
    call(cur, "CALL fractal_index_drop('ix1', @ok)")
    dropped = jout(cur, "ok")
    check(dropped == 1, "the drop returns 1", dropped)
    try:
        call(cur, "CALL fractal_index_info('ix1', @r)")
        cur.execute("SELECT @r")
        got = to_str(cur.fetchone()[0])
        check("no index" in (got or "").lower(), "info after the drop is refused", got)
    except Exception as e:
        check("no index" in str(e).lower(), "info after the drop is refused", e)
    call(cur, "CALL fractal_search('_fi_t', 'emb', %s, 5, %s, @r, @s)",
         (qt, json.dumps({})))
    fallback = jout(cur, "r")
    check(isinstance(fallback, list) and len(fallback) == 5,
          "after the drop the search falls back to the exact scan", fallback)

    _, _, path_noidx = agent_hit("on")
    check(path_noidx == "scan", "agent_use_index on with no index on the table still scans exactly", path_noidx)
    cur.execute("SELECT fractal_config_reset(CONNECTION_ID())")
    cur.fetchall()

    # --- the retired inline-corpus surface ----------------------------------
    try:
        cur.execute("SELECT fractal_search(%s, %s, 3, %s)", (vtxt(q), vtxt(rows[1]), "{}"))
        check(False, "the old fractal_search(vector, query, k, params) call is refused")
    except Exception as e:
        check("fractal_sfs_converge" in str(e),
              "the old fractal_search(vector, query, k, params) call is refused and names fractal_sfs_converge", e)

    cur.execute("DROP TABLE IF EXISTS _fi_t")
    print("test_index: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
