#!/usr/bin/env python3
"""tests/unicode_matrix.py -- text in and out of the extension keeps its characters.

Accented Latin, CJK, right-to-left text, emoji (skin tone, flag, joined sequences), combining marks and JSON-special characters go
through fractal_chunk_text and a table round trip. Checks: one chunk holds the whole text unchanged, chunk offsets are character
offsets, chunks joined back give the text, the output is strict UTF-8 JSON, stored text comes back byte for byte, and bytes that are not
UTF-8 give an error or valid output (never invalid JSON).
Env: FSQL_MARIADB_JSON -- the mariadb client command as a JSON list (connection options, -N). Exit status is nonzero when a check fails."""
import json, os, subprocess, sys
CLI = json.loads(os.environ["FSQL_MARIADB_JSON"]) + ["--default-character-set=utf8mb4"]
CASES = {
    "latin": "Crème brûlée à la façon de São Paulo, naïve café, Ångström, straße",
    "cjk": "日本語のテキストと中文汉字、한국어 문장입니다",
    "rtl": "مرحبا بالعالم שלום עולם",
    "emoji": "😀👍🏽🇯🇵 👨‍👩‍👧‍👦 ok 🧪",
    "combining": "é ñ ạ̈ end",
    "specials": "quote \" backslash \\ tab\t newline\n ctrl \x01\x1f slash / <tag> &amp;    ",
}
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def sql(s):
    p = subprocess.run(CLI + ["-e", s], capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace")
def lit(t): return "CONVERT(UNHEX('%s') USING utf8mb4)" % t.encode("utf-8").hex()
def chunks(t, size, ov, mode="fixed"):
    rc, out, err = sql("SELECT HEX(CONVERT(fractal_chunk_text(%s,%d,%d,'%s') USING utf8mb4))" % (lit(t), size, ov, mode))
    if rc or not out: raise RuntimeError(err[:200] or "no output")
    return json.loads(bytes.fromhex(out).decode("utf-8"))
# A table made without a CHARACTER SET takes the database default; it holds every character only when that default is utf8mb4.
DEFAULT_OK = sql("SELECT @@character_set_database")[1].strip().startswith("utf8mb4")
if not DEFAULT_OK: print("  note: the database default character set is not utf8mb4, so the default-charset table is not checked")
TABLES = ("utf8mb4", "default") if DEFAULT_OK else ("utf8mb4",)
for cs in TABLES:
    sql("DROP TABLE IF EXISTS fsql_uni_%s; CREATE TABLE fsql_uni_%s(id INT, body TEXT)%s" % (cs, cs, " CHARACTER SET utf8mb4" if cs == "utf8mb4" else ""))
for i, (name, text) in enumerate(CASES.items()):
    n = len(text)
    try:
        one = chunks(text, 100000, 0)
        check(len(one) == 1 and one[0]["text"] == text and one[0]["start"] == 0 and one[0]["end"] == n, name + ": one chunk holds the whole text", one)
        for size, ov in ((5, 0), (7, 3), (1, 0)):
            ch = chunks(text, size, ov)
            check(all(x["text"] == text[x["start"]:x["end"]] for x in ch), "%s: size %d overlap %d offsets are character offsets" % (name, size, ov))
            check(all(len(x["text"]) <= size for x in ch), "%s: size %d chunks are at most %d characters" % (name, size, size))
            if ov == 0: check("".join(x["text"] for x in ch) == text, "%s: size %d chunks join back to the text" % (name, size))
        for mode in ("paragraph", "sentence"):
            check(len(chunks(text, 100000, 0, mode)) >= 1, name + ": " + mode + " mode answers")
    except Exception as e:
        check(False, name + ": chunk_text output is strict UTF-8 JSON", e)
    for cs in TABLES:
        sql("INSERT INTO fsql_uni_%s VALUES (%d, %s)" % (cs, i, lit(text)))
        rc, out, err = sql("SELECT HEX(CONVERT(body USING utf8mb4)), CHAR_LENGTH(body) FROM fsql_uni_%s WHERE id=%d" % (cs, i))
        parts = out.split()
        check(rc == 0 and len(parts) == 2 and bytes.fromhex(parts[0]) == text.encode("utf-8") and int(parts[1]) == n,
              "%s: a %s table round trip returns the same characters" % (name, cs), out[:120] + err[:120])
# bytes that are not UTF-8: the output must be valid UTF-8 JSON or an error, never invalid JSON
for label, raw in (("lone continuation", b"a\x80b"), ("0xff", b"a\xffb"), ("truncated sequence", b"ab\xe2\x82")):
    rc, out, err = sql("SELECT HEX(fractal_chunk_text(CONVERT(UNHEX('%s') USING binary),10,0))" % raw.hex())
    ok = rc != 0 or not out or out == "NULL"
    if not ok:
        try: json.loads(bytes.fromhex(out).decode("utf-8")); ok = True
        except Exception as e: err = str(e)
    check(ok, "invalid bytes (%s): valid UTF-8 JSON or a refusal" % label, err)
for cs in ("utf8mb4", "default"): sql("DROP TABLE IF EXISTS fsql_uni_" + cs)
print("unicode_matrix: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
