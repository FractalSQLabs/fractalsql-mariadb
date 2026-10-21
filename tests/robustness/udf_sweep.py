#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
"""Generates SQL that stresses every FractalSQL UDF with malformed or extreme input.

usage: udf_sweep.py MODE [--install sql/install_udf.sql] [--seed tests/robustness/seed_calls.sql]
                    [--only REGEX] [--stride N]

--only keeps just the functions whose name matches REGEX; --stride N keeps every Nth
generated statement (the sweeps are large; a stride trades depth for run time).

The output is plain SQL on stdout, meant to be piped into a `mariadb --force` client.
Nothing here asserts on a result: the caller checks that the daemon is still up and
still answers afterwards. Modes:

  arity     every UDF called with 0..8 arguments of several types (and NULL)
  mutate    each seed call with one argument at a time replaced by edge values
  shapes    numeric-list arguments replaced by series of many lengths and shapes
  params    JSON parameter objects in many spellings (numbers, whitespace, nesting)
  config    the session configuration functions across every key and edge value
  oversize  inputs just past the documented size limits
"""
import math
import random
import re
import sys


def read_names(install_sql):
    return re.findall(r"CREATE FUNCTION\s+(\w+)\s+RETURNS", open(install_sql, encoding="utf-8").read())


def split_args(s):
    """Splits a SQL argument list at top-level commas (quotes and brackets respected)."""
    args, depth, cur, quote, i = [], 0, "", None, 0
    while i < len(s):
        c = s[i]
        if quote:
            cur += c
            if c == "\\" and i + 1 < len(s):
                cur += s[i + 1]
                i += 1
            elif c == quote:
                if i + 1 < len(s) and s[i + 1] == quote:
                    cur += s[i + 1]
                    i += 1
                else:
                    quote = None
        elif c in "'\"":
            quote = c
            cur += c
        elif c in "([":
            depth += 1
            cur += c
        elif c in ")]":
            depth -= 1
            cur += c
        elif c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip() or args:
        args.append(cur.strip())
    return args


def read_seeds(path, names):
    seeds = []
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        m = re.match(r"SELECT\s+(fractal_\w+)\((.*)\);?$", line, re.S)
        if not m or m.group(1) not in names:
            continue
        seeds.append((m.group(1), split_args(m.group(2))))
    return seeds


def q(s):
    """A SQL string literal for an arbitrary Python string."""
    return "'" + s.replace("\\", "\\\\").replace("'", "''").replace("\n", "\\n").replace("\t", "\\t") + "'"


def is_num(a):
    if a.startswith("CONNECTION_ID"):
        return True
    try:
        float(a)
        return True
    except ValueError:
        return False


NUM_EDGES = ["0", "-1", "1", "2", "3", "5", "8", "9", "16", "31", "64", "100", "1000", "100000", "2147483647",
             "2147483648", "-2147483649", "4294967296", "1e308", "-1e308", "1e-300", "NULL", "''", "'x'",
             "'1e400'", "'nan'", "'inf'", "'-5'", "'0x10'"]
STR_EDGES = ["''", "' '", "'x'", "'[]'", "'[1]'", "'[1,2'", "'1,2,3'", "'1;2'", "'[[1,2],[3,4]]'", "'{}'",
             "'{\"a\":1}'", "'1,,2'", "','", "'1,2,'", "'nan'", "'inf,1'", "'1e999'", "'-0'",
             "'[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]'", "NULL", "0", "1", "'\\\\'", "'\"'",
             "'{\"iterations\":0}'", "'{\"iterations\":99999}'", "'{\"population_size\":1}'",
             "'{\"population_size\":99999}'", "'{\"seed\":-1}'", "'{\"seed\":1}'", "'{\"walk\":-1}'",
             "'{\"walk\":2}'", "'{\"session_id\":0}'", "'{\"session_id\":7}'", "'{\"debug\":true}'",
             "'{\"diffusion_factor\":0}'", "'{\"a\":{\"iterations\":3}}'", "'{\"iterations\":\"3\"}'",
             "'{\"iterations\":3.5}'", "'{\"iterations\":1e2}'", "'{\"iterations\":-}'", "'{\"iterations\":3x}'",
             "REPEAT('1,',3000)", "REPEAT('9',400)"]


def mode_arity(names):
    for n in names:
        yield f"SELECT {n}();"
        for k in range(1, 9):
            for v in ("NULL", "1", "''", "'x'", "'[1,2,3]'", "1.5"):
                yield f"SELECT {n}({','.join([v] * k)});"


def mode_mutate(seeds):
    for n, a in seeds:
        yield f"SELECT {n}({','.join(a)});"
        yield f"SELECT {n}();"
        yield f"SELECT {n}({','.join(a + ['1'])});"
        yield f"SELECT {n}({','.join(a + ['NULL'] * 9)});"
        for i in range(len(a)):
            yield f"SELECT {n}({','.join(a[:i] + a[i + 1:])});"
            for v in (NUM_EDGES if is_num(a[i]) else STR_EDGES):
                if v != a[i]:
                    yield f"SELECT {n}({','.join(a[:i] + [v] + a[i + 1:])});"


def shapes(n, seed):
    r = random.Random(seed * 1000 + n)
    return {
        "ramp": [i for i in range(n)], "const": [3.0] * n, "alt": [(-1) ** i * 2.0 for i in range(n)],
        "sin": [round(math.sin(i / 3.0) * 5, 4) for i in range(n)],
        "rand": [round(r.uniform(-5, 5), 4) for i in range(n)],
        "spike": [0.0] * (n // 2) + [100.0] + [0.0] * (n - n // 2 - 1) if n else [],
        "neg": [-i - 1 for i in range(n)], "huge": [1e150 * (i + 1) for i in range(n)],
        "tiny": [1e-150 * (i + 1) for i in range(n)], "step": [0.0] * (n // 2) + [5.0] * (n - n // 2),
        "walk": [round(sum(r.uniform(-1, 1) for _ in range(i + 1)), 4) for i in range(n)],
    }


def fmt_series(vals, bracket):
    parts = []
    for v in vals:
        f = float(v)
        parts.append(str(int(f)) if f.is_integer() and abs(f) < 1e15 else repr(f))
    body = ",".join(parts)
    return "[" + body + "]" if bracket else body


def mode_shapes(seeds):
    lens = [0, 1, 2, 3, 4, 5, 7, 8, 9, 12, 16, 24, 33, 64, 65, 128, 257, 1000]
    junk = ["'x,1,2,3,4,5,6,7,8,9'", "'1,2,3,4,5,6,7,8,x'", "'1,2,3,4,5,6,7,8,'", "',1,2,3,4,5,6,7,8'",
            "'1,2,3,4,5,6,7,8;9'", "'[1,2,3,4,5,6,7,8'", "'1,2,3,4,5,6,7,8]'", "'[[1,2],[3,4]]'"]
    for n, a in seeds:
        for i, x in enumerate(a):
            m = re.fullmatch(r"'(\[?)(-?[\d.eE+-]+(?:[,;]-?[\d.eE+-]+)*)(\]?)'", x)
            if not m:
                continue
            bracket = bool(m.group(1))
            for length in lens:
                for name, vals in shapes(length, 7).items():
                    if length < 8 and name not in ("ramp", "const"):
                        continue
                    yield f"SELECT {n}({','.join(a[:i] + [q(fmt_series(vals, bracket))] + a[i + 1:])});"
            for j in junk:
                yield f"SELECT {n}({','.join(a[:i] + [j] + a[i + 1:])});"


PARAM_NUMBERS = ["3", "-3", "0", "3.0", "3.", ".5", "-.5", "1e1", "1E1", "1e+1", "1e-1", "1e", "1e+", "1.e2", "+3",
                 "--3", "3x", '"3"', '"x"', "true", "false", "null", "[3]", '{"a":3}', "99999999999",
                 "2147483647", "2147483648", "-2147483649", "1e999", "-1e999", "123456789012345678901234567890",
                 "0.0000001", " 3 ", "\n3\n", "\t3", "3 ", "3\n", "0x10", "NaN", "Infinity", '"" ', "3e2x", "1.2.3"]
INT_KEYS = ["iterations", "population_size", "diffusion_factor", "seed", "session_id", "window_n",
            "max_shadows_considered", "tail_buffer_cap"]
DOUBLE_KEYS = ["walk", "stall_threshold", "repulsion_sigma", "repulsion_weight", "diversity_weight",
               "turnover_penalty"]
PARAM_SHAPES = ['{}', '', '  ', '{"iterations"', '{"iterations":', '{"iterations" :3}', '{"iterations"\n:\t3}',
                '{"iterations":3', '{ "iterations" : 3 , "population_size" : 4 }',
                '{"a":{"iterations":9},"iterations":3}', '{"x":"\\"iterations\\":99","iterations":3}',
                '{"x":"a\\\\","iterations":3}', '{"iterations":3,"iterations":4}', '[{"iterations":3}]',
                '{"iterations":[1,2],"population_size":4}', '{"it\\u0065rations":3}', '{"iterations":3}garbage',
                'garbage{"iterations":3}', '{"iterations":3,"debug":true}', '{"debug":false}',
                '{"debug":"true"}', '{"debug":tru}', '{"debug":1}', '{"diffusion_mode":"levy"}',
                '{"diffusion_mode":"gaussian"}', '{"diffusion_mode":"x"}', '{"diffusion_mode":levy}',
                '{"diffusion_mode":"lev', '{"diffusion_mode":"' + "a" * 40 + '"}', '{"session_id":9,"iterations":2}',
                '{"session_id":9,"debug":true}', '{"session_id":0}', '{"session_id":-1}',
                '{"session_id":18446744073709551615}', '{"session_id":18446744073709551616}',
                '{"session_id":9.5}', '{"session_id":"9"}', '{"seed":0}', '{"seed":-5}',
                '{"seed":18446744073709551615}', '{"seed":1.5}',
                '{"walk":0.25,"iterations":4,"population_size":6,"diffusion_factor":3,"seed":11}',
                '{"iterations":10001}', '{"population_size":10001}', '{"population_size":1}',
                '{"diffusion_factor":33}']
CORPUS = "'0,0;1,1;2,2;3,3;4,4;5,5;6,6;7,7'"


def mode_params():
    for k in INT_KEYS + DOUBLE_KEYS:
        for v in PARAM_NUMBERS:
            p = '{"%s":%s}' % (k, v)
            yield f"SELECT fractal_search({CORPUS},'0,0',2,{q(p)});"
            yield f"SELECT fractal_search_explore({CORPUS},'0,0',{q(p)});"
            yield f"SELECT fractal_diversify_enable(CONNECTION_ID()),fractal_diversify_set_params(CONNECTION_ID(),{q(p)});"
    for p in PARAM_SHAPES:
        yield f"SELECT fractal_search({CORPUS},'0,0',2,{q(p)});"
        yield f"SELECT fractal_search_explore({CORPUS},'0,0',{q(p)});"
        yield f"SELECT fractal_diversify_set_params(CONNECTION_ID(),{q(p)});"
    for sid in ("9", "777", "0", "-1", "18446744073709551615"):
        yield (f"SELECT fractal_diversify_enable({sid});"
               f"SELECT fractal_search({CORPUS},'0,0',2,'{{\"session_id\":{sid},\"debug\":true}}');"
               f"SELECT fractal_search_explore({CORPUS},'0,0','{{\"session_id\":{sid}}}');"
               f"SELECT fractal_explain_result({sid});SELECT fractal_detect_collapse({sid});"
               f"SELECT fractal_isolate_background({sid});SELECT fractal_diversify_disable({sid});"
               f"SELECT fractal_session_close({sid});")
    for a in ("'0,0'", "'0,0',0", "'0,0',1", "'0,0',3,2", "'0,0',3,3,1", "'0,0',3,3,33", "'0,0',3,3,2,5",
              "'0,0',10001", "'0,0',3,10001", "'0,0',3,3,2,-1", "'0,0',NULL,NULL,NULL,NULL", "'0,0','x'",
              "'0,0',3.5", "'',3", "NULL", "'x'", "'0,0,0,0,0,0,0,0'"):
        yield f"SELECT fractal_search_debug({a});"


CONFIG_KEYS = ("reasoning_plugin reasoning_url reasoning_token reasoning_model reasoning_allow_plaintext embed_url "
               "embed_model think think_provider think_native_url think_num_ctx t2s_max_attempts "
               "t2s_allowed_statements t2s_use_review enterprise_lib enterprise_ledger_path enterprise_ledger_key "
               "enterprise_require_signature nonexistent_key").split()
CONFIG_VALUES = ["", "x", "0", "1", "-1", "5", "10", "11", "99999999999", "10000001", "abc", "true", "false", "on",
                 "off", "yes", "no", "TRUE", "1.5", " 5", "5 ", "/abs/path", "rel/path", "/a/../b", "a/./b",
                 "/a//b", "../x", "/", "C:\\x", "select", "select_insert_update", "SELECT", "delete", "a" * 8191,
                 "a" * 8192, "a" * 9000, "\u00e9", "line\nbreak", "tab\there", "'quote", '"dq', "'; DROP"]


def mode_config():
    sid = 1000
    for k in CONFIG_KEYS:
        sid += 1
        yield f"SELECT fractal_config_get({q(k)},{sid});"
        for v in CONFIG_VALUES:
            yield (f"SELECT fractal_config_set({q(k)},{q(v)},{sid}), fractal_config_get({q(k)},{sid}), "
                   f"fractal_config_list({sid});")
        yield (f"SELECT fractal_config_reset({sid}), fractal_config_list({sid}), "
               f"fractal_config_get({q(k)},{sid});")
    yield ("SELECT fractal_config_keys();SELECT fractal_config_list(999999);SELECT fractal_config_reset(999999);"
           "SELECT fractal_config_get('think',0);SELECT fractal_config_set('think','x',0);")
    yield ("SELECT fractal_config_set('think','x',NULL);SELECT fractal_config_set(NULL,'x',1);"
           "SELECT fractal_config_set('think',NULL,1);SELECT fractal_config_get(NULL,1);"
           "SELECT fractal_config_get('think',NULL);SELECT fractal_config_get('think',-1);"
           "SELECT fractal_config_set('think','x','a');SELECT fractal_config_set('think','x',1.5);"
           "SELECT fractal_config_set(1,2,3);SELECT fractal_config_get(1,2);SELECT fractal_config_list('a');"
           "SELECT fractal_config_list(NULL);SELECT fractal_config_reset(NULL);SELECT fractal_config_reset('x');"
           "SELECT fractal_config_set('think','x');SELECT fractal_config_get('think');SELECT fractal_config_list();"
           "SELECT fractal_config_reset();SELECT fractal_config_keys(1);SELECT fractal_config_list(1,2);")
    for i in range(1, 4400):          # more sessions than the registry holds: forces eviction
        yield f"SELECT fractal_config_set('think','v{i}',{50000 + i});"
    for i in range(1, 50):
        yield (f"SELECT fractal_config_get('think',{50000 + i}), fractal_config_list({50000 + i}), "
               f"fractal_config_reset({50000 + i});")


def mode_oversize():
    big = "CONCAT(REPEAT('1,',2300000),'1')"        # about 4.4 MiB, past the 4 MiB query limit
    calls = ["fractal_search(%s,%s,2,'{}')" % (CORPUS, big), "fractal_search(%s,'0,0',2,'{}')" % big,
             "fractal_search_explore(%s,%s,'{}')" % (CORPUS, big), "fractal_search_debug(%s)" % big,
             "fractal_dimension_dfa(%s)" % big, "fractal_dimension_boxcount(%s,2)" % big,
             "fractal_dimension_drift(%s,16)" % big, "fractal_periodogram(%s,3)" % big,
             "fractal_change_point_detect(%s,16)" % big, "fractal_spectrogram_entropy(%s)" % big,
             "fractal_vector_norm(%s)" % big, "fractal_vector_normalize(%s)" % big,
             "fractal_vector_dims(%s)" % big, "fractal_morphological_complexity(%s,2)" % big,
             "fractal_state_fingerprint(%s,128,1)" % big, "fractal_tda_persistence_diagram(%s,2,1)" % big,
             "fractal_cycle_detect(%s,3)" % big]
    one = ["fractal_vector_scale({v},2)", "fractal_vector_quantize_int8({v})", "fractal_vector_quantize_binary({v})",
           "fractal_vector_from_text({v})", "fractal_vector_to_json({v})", "fractal_vector_from_float8_array({v})",
           "fractal_vector_to_float8_array({v})"]
    two = ["fractal_vector_add", "fractal_vector_sub", "fractal_vector_l2_distance", "fractal_vector_l2_squared",
           "fractal_vector_cosine_distance", "fractal_vector_cosine_similarity",
           "fractal_vector_negative_inner_product", "fractal_vector_hamming_distance"]
    calls += [t.format(v=big) for t in one]
    for fn in two:
        calls.append(f"{fn}({big},'[1,2]')")
        calls.append(f"{fn}('[1,2]',{big})")
    calls += [f"fractal_vector_lp_distance({big},'[1,2]',2)", f"fractal_vector_lp_distance('[1,2]',{big},2)"]
    for c in calls:
        yield f"SELECT LENGTH({c});"


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    mode = args[0]
    opts = dict(zip(args[1::2], args[2::2]))
    install = opts.get("--install", "sql/install_udf.sql")
    seed = opts.get("--seed", "tests/robustness/seed_calls.sql")
    names = read_names(install)
    only = re.compile(opts["--only"]) if "--only" in opts else None
    stride = max(1, int(opts.get("--stride", "1")))
    if only:
        names = [n for n in names if only.search(n)]
    gens = {
        "arity": lambda: mode_arity(names),
        "mutate": lambda: mode_mutate(read_seeds(seed, names)),
        "shapes": lambda: mode_shapes(read_seeds(seed, names)),
        "params": mode_params,
        "config": mode_config,
        "oversize": mode_oversize,
    }
    if mode not in gens:
        sys.exit(f"unknown mode {mode!r}")
    out = sys.stdout
    for i, stmt in enumerate(gens[mode]()):
        if i % stride == 0:
            out.write(stmt + "\n")


if __name__ == "__main__":
    main()
