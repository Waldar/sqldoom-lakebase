"""SQLDoom on Lakebase: game-tic and frame latency, the way the app runs them.

    PYTHONPATH=src python tools/bench.py --endpoint projects/<p>/branches/<scratch>/endpoints/primary
        [--map E1M1] [--tics 300] [--frames 30] [--skill 2]

On a scratch branch (a copy of game-template): the bench opens a match, takes
seat 1 as the player "bench" and plays. Tics are the referee's statement
(sqldoom.game.statements.mp_tic, autocommit: every tic a committed
transaction), idle and with input (run, turn, fire through api_input). Frames
are what the page reads: api_camera, then api_frame_idx_slot1_m<map>. Reports
wall time seen by this client and the server's own time (EXPLAIN ANALYZE), to
separate the network from the database.
"""
import argparse
import json
import statistics
import time

import psycopg2

from sqldoom.game import statements as sql
from sqldoom.lakebase.connection import CREDS

PLAYER = "bench"
PROTECTED = ("/branches/production/", "/branches/game-template/")


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def line(name, xs):
    print(f"{name:40s} n={len(xs):4d}  p50={pct(xs, 50):8.2f}  p95={pct(xs, 95):8.2f}  "
          f"max={max(xs):8.2f}  mean={statistics.mean(xs):8.2f} ms")


def server_ms(cur, statement, params=()):
    cur.execute(f"EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON, FORMAT JSON) {statement}", params)
    plan = cur.fetchone()[0]
    plan = plan[0] if isinstance(plan, list) else json.loads(plan)[0]
    return plan["Execution Time"] + plan.get("Planning Time", 0.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--endpoint", required=True, help="a scratch branch's endpoint (the bench plays on it)")
    ap.add_argument("--role", default="doom_owner")
    ap.add_argument("--tics", type=int, default=300)
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    a = ap.parse_args()
    if any(p in a.endpoint for p in PROTECTED):
        raise SystemExit(f"{a.endpoint}: the bench plays on the branch; use a scratch copy, not production or game-template")

    conn = psycopg2.connect(CREDS.dsn(a.endpoint, application_name="sqldoom-bench", role=a.role))
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET doom.player = %s", (PLAYER,))     # doom_caller(): this session plays as PLAYER

    rtt = []                                            # network baseline
    for _ in range(50):
        t0 = time.perf_counter(); cur.execute("SELECT 1"); cur.fetchone()
        rtt.append((time.perf_counter() - t0) * 1e3)

    cur.execute("SELECT map_id FROM maps WHERE name = %s", (a.map,))
    map_id = cur.fetchone()[0]
    sql.load_constants(cur)
    sql.prepare(cur)
    # the match row, as the game loop opens it for a solo game: no timer, no
    # item respawn, monsters, no monster respawn, 10 s intermission
    cur.execute("SELECT doom_mp_configure(%s, %s, 0, false, true, false, 350)", (map_id, a.skill))
    players = sql.mp_start(cur, map_id, a.skill)
    cur.execute("UPDATE mp_match SET map_id = %s, state = 'playing', intermission_until = NULL", (map_id,))
    cur.execute("UPDATE mp_players SET role_name = NULL WHERE role_name = %s", (PLAYER,))
    cur.execute("DELETE FROM mp_waiting")
    cur.execute("SELECT api_join()")                    # the seat, as the page's join does
    if cur.fetchone()[0] < 0:
        raise SystemExit("could not take a seat (api_join)")
    cur.execute("SELECT slot FROM mp_players WHERE role_name = %s", (PLAYER,))
    slot = cur.fetchone()[0]
    frame_sql = f"SELECT frame_rgb FROM api_frame_idx_slot{slot}_m{map_id}"

    def tic(move):
        if move:
            cur.execute("SELECT api_input(1.0, 0.0, true, 3.0, true, 0, false)")   # run + turn + fire
        t0 = time.perf_counter()
        if sql.mp_tic(cur, map_id, a.skill, players):
            raise SystemExit("the level ended during the bench (an exit line?): run it again")
        return (time.perf_counter() - t0) * 1e3

    for _ in range(10):                                 # warm up plans, spawn
        tic(False)
    tics = {"idle": [tic(False) for _ in range(a.tics)], "action": [tic(True) for _ in range(a.tics)]}
    tic_server = [server_ms(cur, "SELECT doom_run_mp_tic(%s,%s,%s,%s,%s,%s)",
                            (map_id, a.skill, players[1], players.get(2), players.get(3), players.get(4)))
                  for _ in range(20)]

    for _ in range(3):                                  # warm up the frame view's plan
        cur.execute("SELECT api_camera(1.0)"); cur.execute(frame_sql); cur.fetchone()
    frames, sizes = [], set()
    for _ in range(a.frames):
        tic(True)                                       # a new pose for every frame
        t0 = time.perf_counter()
        cur.execute("SELECT api_camera(1.0)")
        cur.execute(frame_sql)
        raw = cur.fetchone()[0]
        frames.append((time.perf_counter() - t0) * 1e3)
        sizes.add(len(raw) if raw is not None else 0)
    frame_server = [server_ms(cur, frame_sql) for _ in range(10)]
    camera_server = [server_ms(cur, "SELECT api_camera(1.0)") for _ in range(20)]
    cur.execute("UPDATE mp_players SET role_name = NULL WHERE role_name = %s", (PLAYER,))
    cur.execute("DELETE FROM mp_waiting WHERE role_name = %s", (PLAYER,))

    cur.execute("SHOW server_version"); ver = cur.fetchone()[0]
    print(f"server {ver}; map {a.map} (seat {slot}); skill {a.skill}")
    line("network RTT (SELECT 1)", rtt)
    line("tic idle      client", tics["idle"])
    line("tic action    client", tics["action"])
    line("tic action    server execution", tic_server)
    line("frame         client (camera + frame)", frames)
    line("frame         server execution", frame_server)
    line("camera        server execution", camera_server)
    print(f"tic budget 28.6 ms: action tics within budget {sum(t <= 28.6 for t in tics['action'])}/{len(tics['action'])}")
    print(f"frame sizes: {sorted(sizes)} bytes (palette byte + 320x200 palette indices); "
          f"frames per second on one connection (client p50) = {1000 / pct(frames, 50):.1f}")


if __name__ == "__main__":
    main()
