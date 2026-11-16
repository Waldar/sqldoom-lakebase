"""Tic replay harness for scratch Lakebase branches (monster-stage work, 2026-10-28).

replay(): fixed per-tic inputs, doom_run_mp_tic in ONE transaction that is
always rolled back, so every variant starts from the same game state. The game
tables are hashed every `hash_every` tics (timestamps, intervals and serial
columns left out); hashing is outside the timed window.
"""
import math
import os
import statistics
import time

import psycopg2
from databricks.sdk import WorkspaceClient

_w = None


def ws():
    global _w
    if _w is None:
        _w = WorkspaceClient()
    return _w


def connect(endpoint, host, options="-c search_path=doom -c synchronous_commit=off"):
    w = ws()
    c = psycopg2.connect(host=host, dbname="databricks_postgres", user=w.current_user.me().user_name,
                         password=w.postgres.generate_database_credential(endpoint=endpoint).token,
                         sslmode="require", options=options, connect_timeout=30)
    c.autocommit = True
    return c


# Bookkeeping that is not game state (or differs run to run by design).
EXCLUDED_TABLES = {"tic_trace", "api_tic_stats", "mp_referee", "mp_waiting", "mp_join_requests",
                   "hud_cache", "mp_holders", "mp_inputs"}


def table_hash_sql(cur):
    """{table: SELECT returning one md5} for every doom table, volatile columns removed."""
    cur.execute("""
        SELECT c.relname,
               array_agg(a.attname::text) FILTER (
                 WHERE format_type(a.atttypid, NULL) IN ('timestamp with time zone', 'timestamp without time zone', 'interval')
                    OR pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%%')
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE c.relnamespace = 'doom'::regnamespace AND c.relkind = 'r' AND c.relname NOT LIKE 'bench%%'
        GROUP BY c.relname""")
    out = {}
    for rel, drop in cur.fetchall():
        if rel in EXCLUDED_TABLES:
            continue
        minus = " - ARRAY[" + ",".join("'" + x + "'" for x in drop) + "]::text[]" if drop else ""
        out[rel] = (f"SELECT md5(COALESCE(string_agg(r, '|' ORDER BY r), '')) FROM "
                    f"(SELECT (to_jsonb(x){minus})::text AS r FROM {rel} x) s")
    return out


def hash_tables(cur, sqls):
    res = {}
    for t, q in sqls.items():
        cur.execute(q)
        res[t] = cur.fetchone()[0]
    return res


def inputs(tic, slot, combat):
    """Deterministic input for one player on one tic."""
    if not combat:
        return (0.0, 0.0, False, 0.0, False, None, False)
    phase = (tic // 35 + slot) % 4
    fwd = (25.0, 50.0, -25.0, 0.0)[phase]
    strafe = (0.0, 0.0, 0.0, 24.0)[phase] * (1 if slot % 2 else -1)
    turn = round(4.0 * math.sin((tic + 7 * slot) / 9.0), 3)
    return (fwd, strafe, phase == 1, turn, (tic + slot) % 6 < 3, None, (tic + slot) % 50 == 0)


def replay(cur, map_id, skill, players, tics, combat, sqls=None, hash_every=10, prelude=(), on_end=None):
    """players: {slot: player_thing_id}. prelude: SQL run first in the same
    transaction (e.g. doom_mp_respawn). Returns (list of hash dicts, tic ms list)."""
    hashes, times = [], []
    p = [players.get(s) for s in (1, 2, 3, 4)]
    cur.execute("BEGIN")
    try:
        for q in prelude:
            cur.execute(q)
        for t in range(tics):
            for slot, th in players.items():
                f, s, run, turn, att, wpn, use = inputs(t, slot, combat)
                cur.execute("INSERT INTO mp_inputs (map_id, player_thing_id, move_fwd, move_strafe, running, turn_degrees, "
                            "attack_held, weapon_switch_to, use_requested) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                            (map_id, th, f, s, run, turn, att, wpn, use))
            t0 = time.perf_counter()
            cur.execute("SELECT doom_run_mp_tic(%s,%s,%s,%s,%s,%s)", (map_id, skill, *p))
            cur.fetchone()
            times.append((time.perf_counter() - t0) * 1000.0)
            if sqls and (t + 1) % hash_every == 0:
                hashes.append(hash_tables(cur, sqls))
        if on_end:
            on_end(cur)
    finally:
        cur.execute("ROLLBACK")
    return hashes, times


def diff(h1, h2):
    """Tables that differ at any checkpoint: {table: first checkpoint index}."""
    out = {}
    for i, (a, b) in enumerate(zip(h1, h2)):
        for t in a:
            if a[t] != b.get(t) and t not in out:
                out[t] = i
    if len(h1) != len(h2):
        out["<checkpoints>"] = (len(h1), len(h2))
    return out


def stats(ts):
    s = sorted(ts)
    return {"p50": round(statistics.median(s), 1), "p90": round(s[int(0.9 * (len(s) - 1))], 1),
            "mean": round(statistics.mean(s), 1), "over": sum(x > 28.6 for x in s), "n": len(s)}


def function_defs(cur, names):
    """{regprocedure text: CREATE OR REPLACE text} for functions named in `names`."""
    cur.execute("SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid) FROM pg_proc p "
                "WHERE p.pronamespace = 'doom'::regnamespace AND p.proname = ANY(%s)", (list(names),))
    return dict(cur.fetchall())


def apply(cur, defs):
    for d in defs.values():
        cur.execute(d)


# --- bench branch (E1M9, skill 4, a copy of production) -------------------------
# MB_ENDPOINT / MB_HOST: the bench branch's endpoint resource name and host.
MB_ENDPOINT = os.environ.get("MB_ENDPOINT", "projects/sqldoom/branches/monster-bench/endpoints/primary")
MB_HOST = os.environ.get("MB_HOST", "")
MB_PRE = ("SELECT doom_mp_respawn(9, 0)",)       # the copied player was dead
# Tables the tic changed in 60 combat tics on E1M9 (discovered by hashing all).
MB_DYN = ["game_tic_commands", "line_special_events", "monster_ai", "monster_attack_damage",
          "monster_projectiles", "monster_steps", "player_state", "player_weapons", "render_segs",
          "render_things", "sector_movers", "sectors", "sound_events", "thing_health", "things",
          "world_effects"]


def mb_setup():
    """(admin cursor, tic cursor, {table: hash sql}) on the monster-bench branch."""
    ka = connect(MB_ENDPOINT, MB_HOST).cursor()
    kt = connect(MB_ENDPOINT, MB_HOST).cursor()
    sqls = table_hash_sql(ka)
    return ka, kt, {t: sqls[t] for t in MB_DYN}


def vacuum(cur, tables):
    """Rolled-back replays leave dead rows (autovacuum is off on per-tic tables)."""
    for t in list(tables) + ["mp_inputs"]:
        cur.execute(f"VACUUM {t}")


def nestloop_off(defs):
    out = {}
    for s, d in defs.items():
        assert d.count(" LANGUAGE plpgsql\n") == 1, s
        out[s] = d.replace(" LANGUAGE plpgsql\n", " LANGUAGE plpgsql\n SET enable_nestloop TO 'off'\n", 1)
    return out


def ab(ka, kt, dyn, variants, rounds=2, tics=240, combat=True, map_id=9, skill=4, players=None, prelude=MB_PRE):
    """variants: {label: defs or None}; each run from a vacuumed state, original
    functions restored after. Returns {label: [(hashes, times), ...]}."""
    players = players or {1: 0}
    res = {}
    for r in range(rounds):
        for label, defs in variants.items():
            vacuum(ka, dyn)
            orig = function_defs(ka, [s.split("(")[0] for s in defs]) if defs else None
            if defs:
                apply(ka, defs)
            try:
                replay(kt, map_id, skill, players, 5, combat, prelude=prelude)
                h, ts = replay(kt, map_id, skill, players, tics, combat, dyn, prelude=prelude)
            finally:
                if orig:
                    apply(ka, orig)
            res.setdefault(label, []).append((h, ts))
            print(r, label, stats(ts), flush=True)
    return res


# --- committed runs on fresh branches -------------------------------------------
# A rolled-back replay keeps every row version of the transaction, so scans of
# monster_ai / things slow down tic after tic (E1M9: 30 -> 62 ms over 240
# tics). Timing therefore uses committed tics like the referee (one VACUUM per
# tic between tics, outside the timed window), each variant on its own branch
# made from the same production LSN, so every run starts from the same state.
MB_SOURCE_LSN = "2A/B1385628"          # monster-bench's start (E1M9, 117 alive)


def fresh_branch(branch_id, cu=8.0, lsn=MB_SOURCE_LSN, source="production"):
    from databricks.sdk.service import postgres as P
    from databricks.sdk.service.postgres import Duration, FieldMask
    w = ws()
    w.postgres.create_branch(parent="projects/sqldoom", branch_id=branch_id, branch=P.Branch(spec=P.BranchSpec(
        source_branch=f"projects/sqldoom/branches/{source}", source_branch_lsn=lsn,
        ttl=Duration(seconds=86400)))).wait()
    parent = f"projects/sqldoom/branches/{branch_id}"
    eps = list(w.postgres.list_endpoints(parent=parent))
    if eps:
        ep = eps[0]
    else:
        ep = w.postgres.create_endpoint(parent=parent, endpoint_id="primary", endpoint=P.Endpoint(spec=P.EndpointSpec(
            endpoint_type=P.EndpointType.ENDPOINT_TYPE_READ_WRITE))).wait()
    ep = w.postgres.update_endpoint(name=ep.name, endpoint=P.Endpoint(name=ep.name, spec=P.EndpointSpec(
        endpoint_type=P.EndpointType.ENDPOINT_TYPE_READ_WRITE, autoscaling_limit_min_cu=cu, autoscaling_limit_max_cu=cu)),
        update_mask=FieldMask(field_mask=["spec.autoscaling_limit_min_cu", "spec.autoscaling_limit_max_cu"])).wait()
    return ep.name, ep.status.hosts.host


def drop_branch(branch_id):
    ws().postgres.delete_branch(name=f"projects/sqldoom/branches/{branch_id}")


def committed_run(endpoint, host, defs, tics, combat, map_id=9, skill=4, players=None, prelude=MB_PRE,
                  hash_every=20, warm=5, warm_rollback=40, profile_names=None, profile_statements_of=None,
                  vacuum_tables=MB_DYN, tic_players=None):
    """Install `defs` (if any), warm the fresh endpoint's cache with a rolled-back
    replay (then VACUUM), then run committed tics. Returns (hashes, times, profile)
    where profile is {callee or 'fn#stmt': ms per tic} when profile_names /
    profile_statements_of are given (instrumented copies, timing includes the
    instrumentation)."""
    players = players or {1: 0}
    ka = connect(endpoint, host).cursor()
    kt = connect(endpoint, host).cursor()
    if defs:
        apply(ka, defs)
    if profile_names:
        apply(ka, {s: instrument(d) for s, d in function_defs(ka, profile_names).items()})
    if profile_statements_of:
        apply(ka, {s: instrument_statements(d, s.split("(")[0])
                   for s, d in function_defs(ka, profile_statements_of).items()})
    kt.execute("CREATE TEMP TABLE IF NOT EXISTS bench_prof (name text, ms float8)")
    sqls = {t: q for t, q in table_hash_sql(ka).items() if t in MB_DYN}
    if warm_rollback:
        replay(kt, map_id, skill, players, warm_rollback, combat, prelude=prelude)
        vacuum(ka, MB_DYN)
    for q in prelude:
        kt.execute(q)
    # doom_server passes every slot (seated or not) to the tic: tic_players.
    p = [(tic_players or players).get(s) for s in (1, 2, 3, 4)]
    hashes, times = [], []
    for t in range(tics):
        for slot, th in players.items():
            f, s, run, turn, att, wpn, use = inputs(t, slot, combat)
            kt.execute("INSERT INTO mp_inputs (map_id, player_thing_id, move_fwd, move_strafe, running, turn_degrees, "
                       "attack_held, weapon_switch_to, use_requested) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                       (map_id, th, f, s, run, turn, att, wpn, use))
        t0 = time.perf_counter()
        kt.execute("SELECT doom_run_mp_tic(%s,%s,%s,%s,%s,%s)", (map_id, skill, *p))
        kt.fetchone()
        if t >= warm:
            times.append((time.perf_counter() - t0) * 1000.0)
        if t + 1 == warm:
            kt.execute("DELETE FROM pg_temp.bench_prof")
        if vacuum_tables:
            ka.execute(f"VACUUM {vacuum_tables[t % len(vacuum_tables)]}")
        if (t + 1) % hash_every == 0:
            hashes.append(hash_tables(ka, sqls))
    prof = {}
    if profile_names or profile_statements_of:
        kt.execute("SELECT name, sum(ms), count(*) FROM pg_temp.bench_prof GROUP BY 1 ORDER BY 2 DESC")
        n = max(1, tics - warm)
        prof = {nm: (round(ms / n, 2), round(cnt / n, 2)) for nm, ms, cnt in kt.fetchall()}
    ka.connection.close()
    kt.connection.close()
    return hashes, times, prof


# --- stage profile ------------------------------------------------------------
# track_functions cannot be set on Lakebase, so callers are instrumented: each
# `PERFORM doom_x(...);` / `v := doom_x(...);` statement is timed into
# pg_temp.bench_prof (inner calls are included in their caller's time).
import re as _re

_CALL_RE = _re.compile(r"(PERFORM (doom_\w+)\([^;]*\);|\w+ := (doom_\w+)\([^;]*\);)")


def instrument(ddl):
    def wrap(m):
        name = m.group(2) or m.group(3)
        return (f"_pt := clock_timestamp(); {m.group(1)} INSERT INTO pg_temp.bench_prof VALUES "
                f"('{name}', extract(epoch FROM clock_timestamp() - _pt) * 1000);")
    head, sep, body = ddl.partition("AS $function$")
    body = _CALL_RE.sub(wrap, body)
    if "DECLARE" in body.split("BEGIN", 1)[0]:
        body = body.replace("DECLARE", "DECLARE\n_pt timestamptz;", 1)
    else:
        body = body.replace("BEGIN", "DECLARE _pt timestamptz;\nBEGIN", 1)
    return head + sep + body


def _split_statements(body):
    """Top-level statements of a plpgsql body (depth 0, outside quotes/comments)."""
    out, cur, depth, i, n = [], [], 0, 0, len(body)
    while i < n:
        ch = body[i]
        if body.startswith("--", i):
            j = body.find("\n", i)
            j = n if j < 0 else j
            cur.append(body[i:j]); i = j
            continue
        if ch == "'":
            j = i + 1
            while j < n:
                if body[j] == "'" and body[j + 1:j + 2] == "'":
                    j += 2
                    continue
                if body[j] == "'":
                    break
                j += 1
            cur.append(body[i:j + 1]); i = j + 1
            continue
        depth += (ch == "(") - (ch == ")")
        cur.append(ch)
        if ch == ";" and depth == 0:
            out.append("".join(cur)); cur = []
        i += 1
    out.append("".join(cur))
    return out


_SQL_START = _re.compile(r"^\s*(?:--[^\n]*\n\s*)*(WITH|SELECT|UPDATE|INSERT|DELETE)\b", _re.I)


def instrument_statements(ddl, label):
    """Time every top-level SQL statement (WITH/SELECT/UPDATE/INSERT/DELETE) of
    one plpgsql function into pg_temp.bench_prof as '<label>#<n>'."""
    head, sep, rest = ddl.partition("AS $function$")
    body, sep2, tail = rest.rpartition("$function$")
    pre, b, main = body.partition("\nBEGIN\n")
    parts, n = [], 0
    for st in _split_statements(main):
        if _SQL_START.match(st) and st.rstrip().endswith(";"):
            n += 1
            parts.append(f"\n_pt := clock_timestamp();{st} INSERT INTO pg_temp.bench_prof VALUES "
                         f"('{label}#{n}', extract(epoch FROM clock_timestamp() - _pt) * 1000);")
        else:
            parts.append(st)
    if "DECLARE" in pre:
        pre = pre.replace("DECLARE", "DECLARE\n_pt timestamptz;", 1)
    else:
        pre = pre + "\nDECLARE _pt timestamptz;"
    return head + sep + pre + b + "".join(parts) + sep2 + tail


def profile_statements(cur, admin, names, map_id, skill, players, tics, combat, prelude=()):
    """Per-statement ms per tic for the functions in `names`."""
    orig = function_defs(admin, names)
    cur.execute("CREATE TEMP TABLE IF NOT EXISTS bench_prof (name text, ms float8)")
    out = {}

    def grab(c):
        c.execute("SELECT name, sum(ms), count(*) FROM pg_temp.bench_prof GROUP BY 1 ORDER BY 2 DESC")
        for nm, ms, cnt in c.fetchall():
            out[nm] = (round(ms / tics, 2), round(cnt / tics, 2))
    try:
        apply(admin, {s: instrument_statements(d, s.split("(")[0]) for s, d in orig.items()})
        _, ts = replay(cur, map_id, skill, players, tics, combat, prelude=prelude, on_end=grab)
    finally:
        apply(admin, orig)
    return out, stats(ts)


def profile(cur, admin, names, map_id, skill, players, tics, combat, prelude=()):
    """Per-callee ms per tic (mean over `tics`), for the callers in `names`."""
    orig = function_defs(admin, names)
    cur.execute("CREATE TEMP TABLE IF NOT EXISTS bench_prof (name text, ms float8)")
    out = {}

    def grab(c):
        c.execute("SELECT name, sum(ms), count(*) FROM pg_temp.bench_prof GROUP BY 1 ORDER BY 2 DESC")
        for n, ms, cnt in c.fetchall():
            out[n] = (round(ms / tics, 2), round(cnt / tics, 2))
    try:
        apply(admin, {s: instrument(d) for s, d in orig.items()})
        _, ts = replay(cur, map_id, skill, players, tics, combat, prelude=prelude, on_end=grab)
    finally:
        apply(admin, orig)
    return out, stats(ts)
