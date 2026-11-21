"""Two versions of the indexed frame view, frame by frame: identical bytes? how fast?

    PYTHONPATH=src python tools/frame_compare.py --endpoint projects/<p>/branches/<scratch>/endpoints/primary
        [--template sql/frame_views/api_frame_idx_slotS_mM.sql] [--maps E1M1 E1M6 E1M9]
        [--positions 8] [--repeat 3] [--seed 1]

On a scratch branch (a copy of game-template): "base" is the frame view
installed there (api_frame_idx_slot1_m<map>), "candidate" the same view made
from a template file, usually the working copy being changed
(api_frame_idx_slot1_m<map>_cand, created by this tool). For each map the
tool opens a match, seats the player "bench" in slot 1 and puts its camera at
fixed poses: the slot's start, then things of the map picked by a seeded
random, each at two angles, at eye height over the floor there. Both views
render every pose from the same game state (no tic runs meanwhile), through
prepared statements as the page uses them, interleaved; the time is the
median of `repeat` renders as this client sees it (a few ms of network
included, the same for both).
"""
import argparse
import hashlib
import random
import statistics
import time
from pathlib import Path

import psycopg2

from sqldoom.game import statements as sql
from sqldoom.lakebase.connection import CREDS

PLAYER = "bench"
PROTECTED = ("/branches/production/", "/branches/game-template/")
EYE = 41.0
TEMPLATE_FN = "doom.frame_view_template_api_frame_idx()"


def make_candidate(cur, template_sql, map_id, slot):
    """Create the candidate view from a template file's text."""
    if template_sql.count(TEMPLATE_FN) != 1:
        raise SystemExit(f"the template does not define {TEMPLATE_FN} once")
    cur.execute(template_sql.replace(TEMPLATE_FN, "doom.frame_view_template_candidate()"))
    cur.execute("SELECT id FROM things WHERE map_id = %s AND type = %s", (map_id, slot))
    thing_id = cur.fetchone()[0]
    name = f"api_frame_idx_slot{slot}_m{map_id}_cand"
    cur.execute(f"DROP VIEW IF EXISTS doom.{name}")
    cur.execute("SELECT doom.frame_view_template_candidate()")
    view = cur.fetchone()[0]
    for k, v in (("{name}", name), ("{map_id}", str(map_id)), ("{slot}", str(slot)), ("{thing_id}", str(thing_id))):
        view = view.replace(k, v)
    cur.execute(view)
    cur.execute("DROP FUNCTION doom.frame_view_template_candidate()")
    return name


def seat(cur, map_id, skill):
    cur.execute("SELECT doom_mp_configure(%s, %s, 0, false, true, false, 350)", (map_id, skill))
    players = sql.mp_start(cur, map_id, skill)
    cur.execute("UPDATE mp_match SET map_id = %s, state = 'playing', intermission_until = NULL", (map_id,))
    cur.execute("UPDATE mp_players SET role_name = NULL WHERE role_name = %s", (PLAYER,))
    cur.execute("DELETE FROM mp_waiting")
    cur.execute("SELECT api_join()")
    if cur.fetchone()[0] < 0:
        raise SystemExit("could not take a seat (api_join)")
    sql.mp_tic(cur, map_id, skill, players)          # spawn
    cur.execute("SELECT slot FROM mp_players WHERE role_name = %s", (PLAYER,))
    return cur.fetchone()[0]


def poses(cur, map_id, slot, positions, seed):
    """The slot's start, then seeded things of the map; two angles each."""
    cur.execute("SELECT x, y, angle FROM things WHERE map_id = %s AND type = %s", (map_id, slot))
    start = cur.fetchone()
    cur.execute("SELECT x, y, angle FROM things WHERE map_id = %s AND type > 4 ORDER BY id", (map_id,))
    things = cur.fetchall()
    picked = [start] + random.Random(seed * 1000 + map_id).sample(things, min(positions - 1, len(things)))
    out = []
    for x, y, angle in picked:
        cur.execute("SELECT s.floor_height FROM sectors s WHERE s.map_id = %s AND s.id = doom_sector_at(%s, %s, %s)",
                    (map_id, map_id, float(x), float(y)))
        row = cur.fetchone()
        z = (row[0] if row else 0) + EYE
        for a in (float(angle), (float(angle) + 135.0) % 360.0):
            out.append((float(x), float(y), float(z), a))
    return out


def set_pose(cur, x, y, z, angle):
    """The camera, where the frame views read it: the player's state (since
    2026-11-19, frames rendered in the app), now and one tic ago the same so
    no interpolation moves it. (Until 2026-11-20 this tool set
    mp_players.pose_*, which the views no longer read: every pose rendered
    the player's start.)"""
    cur.execute("UPDATE player_state ps SET position_x = %s, previous_x = %s, position_y = %s, previous_y = %s, "
                "view_z = %s, previous_view_z = %s, view_angle = %s, previous_view_angle = %s "
                "FROM mp_players mp WHERE mp.role_name = %s AND ps.map_id = mp.map_id "
                "AND ps.player_thing_id = mp.player_thing_id", (x, x, y, y, z, z, angle, angle, PLAYER))
    cur.execute("UPDATE mp_players SET pose_x = %s, pose_y = %s, pose_z = %s, pose_angle = %s WHERE role_name = %s",
                (x, y, z, angle, PLAYER))


def render(cur, stmt):
    t0 = time.perf_counter()
    cur.execute(f"EXECUTE {stmt}")
    raw = cur.fetchone()[0]
    return (time.perf_counter() - t0) * 1e3, bytes(raw) if raw is not None else b""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--endpoint", required=True, help="a scratch branch's endpoint")
    ap.add_argument("--role", default="doom_owner")
    ap.add_argument("--template", default=str(Path(__file__).resolve().parent.parent
                                              / "sql/frame_views/api_frame_idx_slotS_mM.sql"))
    ap.add_argument("--maps", nargs="+", default=["E1M1", "E1M6", "E1M9"])
    ap.add_argument("--positions", type=int, default=8)
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--skill", type=int, default=2)
    a = ap.parse_args()
    if any(p in a.endpoint for p in PROTECTED):
        raise SystemExit(f"{a.endpoint}: use a scratch copy, not production or game-template")
    template_sql = Path(a.template).read_text(encoding="utf-8")

    conn = psycopg2.connect(CREDS.dsn(a.endpoint, application_name="sqldoom-frame-compare", role=a.role))
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET doom.player = %s", (PLAYER,))
    sql.load_constants(cur)
    sql.prepare(cur)
    total, same_total, results = 0, 0, []
    for name in a.maps:
        cur.execute("SELECT map_id FROM maps WHERE name = %s", (name,))
        map_id = cur.fetchone()[0]
        slot = seat(cur, map_id, a.skill)
        cand = make_candidate(cur, template_sql, map_id, slot)
        base = f"api_frame_idx_slot{slot}_m{map_id}"
        cur.execute("DEALLOCATE ALL")                 # last map's frame statements
        cur.execute(f"PREPARE f_base AS SELECT frame_rgb FROM {base}")
        cur.execute(f"PREPARE f_cand AS SELECT frame_rgb FROM {cand}")
        sql.prepare(cur)
        ps = poses(cur, map_id, slot, a.positions, a.seed)
        tb, tc, same, diffs, seen = [], [], 0, [], set()
        for i, (x, y, z, ang) in enumerate(ps):
            set_pose(cur, x, y, z, ang)
            if i == 0:
                for _ in range(6):                    # warm up both plans (generic after 5)
                    render(cur, "f_base"); render(cur, "f_cand")
            b_ms, c_ms = [], []
            for _ in range(a.repeat):
                t, fb = render(cur, "f_base"); b_ms.append(t)
                t, fc = render(cur, "f_cand"); c_ms.append(t)
            tb.append(statistics.median(b_ms)); tc.append(statistics.median(c_ms))
            seen.add(hashlib.md5(fb).digest())
            if fb == fc:
                same += 1
            else:
                n = sum(1 for p, q in zip(fb, fc) if p != q) + abs(len(fb) - len(fc))
                diffs.append((i, (round(x), round(y), round(ang)), n, hashlib.md5(fb).hexdigest()[:8], hashlib.md5(fc).hexdigest()[:8]))
        total += len(ps); same_total += same
        mb, mc = statistics.mean(tb), statistics.mean(tc)
        results.append((name, len(ps), same, statistics.median(tb), statistics.median(tc), mb, mc))
        print(f"{name}: {same}/{len(ps)} frames identical ({len(seen)} distinct); base median {statistics.median(tb):.1f} ms mean {mb:.1f}, "
              f"candidate median {statistics.median(tc):.1f} ms mean {mc:.1f} ({(mc - mb) / mb * 100:+.1f}% mean)", flush=True)
        for d in diffs:
            print(f"  pose {d[0]} at {d[1]}: {d[2]} bytes differ (base {d[3]}, candidate {d[4]})")
        cur.execute(f"DROP VIEW IF EXISTS doom.{cand}")
        cur.execute("UPDATE mp_players SET role_name = NULL WHERE role_name = %s", (PLAYER,))
        cur.execute("DELETE FROM mp_waiting WHERE role_name = %s", (PLAYER,))
    print(f"all: {same_total}/{total} frames identical; mean of map means: base "
          f"{statistics.mean(r[5] for r in results):.1f} ms, candidate {statistics.mean(r[6] for r in results):.1f} ms")
    conn.close()
    return results


if __name__ == "__main__":
    main()
