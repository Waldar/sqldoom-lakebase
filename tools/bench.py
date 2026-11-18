#!/usr/bin/env python3
"""SQLDoom on Lakebase: game-tic and renderer latency.

    python3 run_on_lakebase.py <repo> /abs/path/bench.py [--tics 300] [--frames 30] [--map E1M1]

Uses the repo's own prepared statements (doom_sql) exactly like doom_client.py
(autocommit, so every tic is a committed transaction). Reports client-observed
wall time and server-side execution time (EXPLAIN ANALYZE) to separate network
from compute.
"""
import argparse
import json
import os
import statistics
import sys
import time

import psycopg2

sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
import doom_sql as sql  # noqa: E402
import prepared_pipeline_smoke as smoke  # noqa: E402


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


def line(name, xs):
    print(f"{name:40s} n={len(xs):4d}  p50={pct(xs, 50):8.2f}  p95={pct(xs, 95):8.2f}  "
          f"max={max(xs):8.2f}  mean={statistics.mean(xs):8.2f} ms")


def server_ms(cur, name, params):
    args = f"({','.join(['%s'] * len(params))})" if params else ""
    cur.execute(f"EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON, FORMAT JSON) EXECUTE {name}{args}", params)
    plan = cur.fetchone()[0]
    plan = plan[0] if isinstance(plan, list) else json.loads(plan)[0]
    return plan["Execution Time"] + plan.get("Planning Time", 0.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tics", type=int, default=300)
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--map", default="E1M1")
    ap.add_argument("--skill", type=int, default=2)
    a = ap.parse_args()

    conn = psycopg2.connect(os.environ["DB_DSN"])
    conn.autocommit = True
    cur = conn.cursor()

    # Network baseline
    rtt = []
    for _ in range(50):
        t0 = time.perf_counter(); cur.execute("SELECT 1"); cur.fetchone()
        rtt.append((time.perf_counter() - t0) * 1e3)

    stage = smoke.select_stage(cur, a.map)
    map_id, player = stage["map_id"], stage["player_thing_id"]
    sql.prepare_client(cur)
    sql.reset_stage(cur, map_id, a.skill)
    sql.spawn_stage(cur, stage)
    sql.record_level_secret(cur, map_id, player)

    idle = (a.skill, 0.0, 0.0, False, 0.0, False, 0, False)
    action = (a.skill, 1.0, 0.0, True, 3.0, True, 0, False)   # run + turn + fire
    for _ in range(10):                                         # warm up plans
        sql.execute_game_tic(cur, map_id, player, idle)
        sql.finish_game_tic(cur, map_id, player)

    tic, fin, poses = {"idle": [], "action": []}, {"idle": [], "action": []}, []
    for label, cmd in (("idle", idle), ("action", action)):
        for _ in range(a.tics):
            t0 = time.perf_counter()
            sql.execute_game_tic(cur, map_id, player, cmd)
            t1 = time.perf_counter()
            snap = sql.finish_game_tic(cur, map_id, player)
            t2 = time.perf_counter()
            tic[label].append((t1 - t0) * 1e3)
            fin[label].append((t2 - t1) * 1e3)
            if label == "action":
                poses.append((snap["x"], snap["y"], snap["z"], snap["angle"]))

    tic_server = [server_ms(cur, sql.GAME_TIC_STATEMENT, (map_id, player, *action)) for _ in range(20)]

    # Renderer: folded form, exactly what the client uses after a level load
    sql.prepare_renderer(cur, map_id, player, a.skill)
    step = max(1, len(poses) // max(1, a.frames))
    frame_poses = [p for p in poses[::step]][:a.frames] or poses[-1:]
    for p in frame_poses[:6]:                                   # warm up / generic plan
        sql.render_frame(cur, map_id, player, a.skill, p)
    frames, sizes = [], set()
    for p in frame_poses:
        t0 = time.perf_counter()
        raw = sql.render_frame(cur, map_id, player, a.skill, p)
        frames.append((time.perf_counter() - t0) * 1e3)
        sizes.add(len(raw))
    render_server = [server_ms(cur, sql.RENDER_FOLDED_STATEMENT, tuple(p)) for p in frame_poses[:10]]

    cur.execute("SHOW server_version"); ver = cur.fetchone()[0]
    print(f"server {ver}; map {a.map}; skill {a.skill}")
    line("network RTT (SELECT 1)", rtt)
    line("tic idle      client (game_tic)", tic["idle"])
    line("tic idle      client (finish/snapshot)", fin["idle"])
    line("tic action    client (game_tic)", tic["action"])
    line("tic action    client (finish/snapshot)", fin["action"])
    line("tic action    server execution", tic_server)
    line("render frame  client", frames)
    line("render frame  server execution", render_server)
    both = [x + y for x, y in zip(tic["action"], fin["action"])]
    print(f"tic budget 28.6 ms: action tics within budget {sum(b <= 28.6 for b in both)}/{len(both)}")
    print(f"frame sizes: {sorted(sizes)} (expected {320 * 200 * 3}); "
          f"render fps (client p50) = {1000 / pct(frames, 50):.1f}")


if __name__ == "__main__":
    main()
