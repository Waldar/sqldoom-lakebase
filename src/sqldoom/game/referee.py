"""The match referee: the game loop (sqldoom.game.server), supervised, in its own process.

The referee is the only writer of the game world: it runs doom_run_mp_tic at
35 Hz on the game's branch. It runs server.main in a child process, so the
relay's Python work cannot steal the GIL from the tic clock, and SIGTERM
reaches the loop's own handler (graceful referee release). The game's SQL is
on the branch already (installed from sql/ by sqldoom.db): the referee
installs nothing, it only opens the match.

Every statements.mp_tic call is timed in the child and sent to the parent's
Metrics over a queue. If the child dies (a dropped connection, another referee
holding the heartbeat) it is started again with a fresh token after a backoff.
The parent resolves the DSN (host + OAuth token) and hands it to the child,
so the child needs no Databricks credentials of its own.

Between tics, the referee vacuums the tables the game writes to. Autovacuum
reclaims dead rows but never shrinks the heap file. At 35 tics/s the hot
tables grow to hundreds of pages; each tic reads them many times (~6 ms/tic
extra) and frames got ~35% slower. Each VACUUM invalidates cached plans that
read the table (the frame query re-plans once, ~87 ms, per render connection).

Env defaults for the app (overridable): MAP_ID=1 SKILL=2 ROTATION=E1M1..E1M9
TIMER_TICS=0 (no level timer) HOLD_MINUTES=0 (no seat limit).
DOOM_DB_ROLE: role the referee session runs as (SET ROLE), e.g. doom_owner,
the shared owner of the doom schema; empty = the login identity itself.
DOOM_VACUUM_INTERVAL: tics between referee-driven VACUUMs (default 1050,
~30 s at 35 Hz). Set 0 to disable.

Which tables: every doom table the game updates or deletes from (found from
pg_stat_user_tables, not a fixed list: about 40 tables -- player_state,
monster_ai, monster_steps, sound_events, world_effects, sectors, mp_* ...),
skipping big asset tables (>= 2000 pages) that only the WAD loader writes.

One table per tic: the referee works through a queue, one VACUUM between two
tics, so a pass over ~40 tables takes ~1 s and no tic waits for more than one
table. Each VACUUM runs with lock_timeout 30 ms. A VACUUM FULL that finds the
table busy (frame queries hold it) is retried ~1 s later, up to
DOOM_VACUUM_FULL_TRIES (8) times, then replaced by a plain VACUUM.

VACUUM FULL (compacts the file; a plain VACUUM cannot hand most of the space
back, so the heap creeps up over hours) is queued when the referee starts,
when someone joins an empty match (connected players 0 -> 1+), and when the
match changes map. Once a second the referee reads the player count and the
map. DOOM_VACUUM_FULL_ON_JOIN=0 turns VACUUM FULL off.
Plain VACUUM is queued every DOOM_VACUUM_INTERVAL tics for the tables that
have dead rows.

Map change from the page (Referee.request_map, POST /api/match/map): the
parent puts the request on a command queue; the child picks it up after a
tic, writes the map into mp_map_request (unless it is "next") and reports
that tic as the end of the level. The game loop then runs its own rotation:
the intermission (frag table, INTERMISSION_SECONDS) and doom_mp_rotate, whose
doom_mp_next_map returns the requested map (sql/functions/multiplayer).
Seats carry over as on any map change.
"""
import multiprocessing
import os
import queue
import sys
import threading
import time

# ROTATION: all of episode 1 (doom1.wad). Maps that are not loaded yet are
# skipped by the game loop ("rotation: E1Mx is not loaded, skipped").
# Game modes (see _mode_step): the match starts solo -- monsters, nothing
# respawns -- so ALTDEATH and RESPAWN_MONSTERS are off; deathmatch turns item
# respawn on and the monsters off when it starts.
REFEREE_ENV = {"MAP_ID": "1", "SKILL": "2",
               "ROTATION": "E1M1,E1M2,E1M3,E1M4,E1M5,E1M6,E1M7,E1M8,E1M9",
               "TIMER_TICS": "0", "HOLD_MINUTES": "0",
               "ALTDEATH": "0", "MONSTERS": "1", "RESPAWN_MONSTERS": "0"}
# Upper bound on one intermission in server.rotate() (it gives up after
# INTERMISSION_SECONDS + 20): the end of a deathmatch waits up to 30 s for
# the choice, plus a 10 s countdown when someone joins meanwhile.
_INTERMISSION_GUARD_S = 60


def _child(samples, dsn, commands=None, env=None):
    """Child process body: timing and vacuum hooks, then server.main().
    env: settings for this referee only (a game branch's, see sqldoom/lakebase/games.py)."""
    os.environ.update(env or {})
    for k, v in REFEREE_ENV.items():
        os.environ.setdefault(k, v)
    os.environ["DB_DSN"] = dsn          # server.main() connects with it
    # The branch holds the game's SQL (sqldoom.db, installed on game-template
    # at its refresh). The referee installs nothing; it only opens the match
    # (mode, rules, world flags).
    # A referee start opens a solo match: its first map uses the solo rules
    # (mp_rules, set from the page by Player 1). server reads these at import.
    # DOOM_START_MODE=deathmatch (a multiplayer game's branch, sqldoom/lakebase/games.py)
    # opens it with the multiplayer rules instead: no monsters spawned, items
    # respawn, keys for all, from the first tic, without the countdown.
    start_mode = os.environ.get("DOOM_START_MODE", "")
    try:
        import psycopg2 as _pg
        _c = _pg.connect(dsn)
        with _c.cursor() as _k:
            _k.execute("SELECT monsters, skill, item_respawn, monster_respawn FROM mp_rules WHERE mode = %s",
                       (start_mode or "solo",))
            _r = _k.fetchone()
        _c.close()
        if _r:
            os.environ.update(MONSTERS="1" if _r[0] else "0", SKILL=str(int(_r[1])),
                              ALTDEATH="1" if _r[2] else "0", RESPAWN_MONSTERS="1" if _r[3] else "0")
    except Exception as exc:
        print(f"[referee] solo rules not read, using the defaults: {exc}", flush=True)
    from sqldoom.game import statements as stmts
    real_tic = stmts.mp_tic

    # --- referee-driven VACUUM (see the module docstring) -------------------
    _VACUUM_INTERVAL = int(os.environ.get("DOOM_VACUUM_INTERVAL", "1050"))  # ~30 s
    _FULL_ON_EVENTS = os.environ.get("DOOM_VACUUM_FULL_ON_JOIN", "1") != "0"
    _STATE_CHECK = 35                    # tics between player-count / map reads (~1 s)
    _MAX_PAGES = 2000                    # bigger tables are WAD assets, not tic state
    # Tables the game writes to: updated or deleted from since the stats began.
    # dead_only: plain VACUUM only where there is something to reclaim.
    _TABLES_SQL = ("SELECT relname, pg_relation_size(relid) / 8192 FROM pg_stat_user_tables "
                   "WHERE schemaname = 'doom' AND n_tup_upd + n_tup_del > 0 "
                   "AND pg_relation_size(relid) < %s * 8192 {extra} "
                   "ORDER BY n_tup_upd + n_tup_del DESC")
    _counter = 0
    _players = None                      # None = not read yet (referee start)
    _map = None
    # [table, full, tries, not_before_tic]; one entry is tried per tic
    _queue = []
    # VACUUM FULL needs an ACCESS EXCLUSIVE lock, which waits for every running
    # frame query that reads the table (render_segs, things, sectors, ...). With
    # frames rendering on the primary there is rarely a gap, so a FULL that times
    # out goes back in the queue and is tried again _RETRY_GAP tics later, up to
    # _FULL_TRIES times; then the table gets a plain VACUUM (no exclusive lock:
    # it frees space inside pages for reuse and truncates empty tail pages when
    # it can). Each failed try costs the referee lock_timeout, so retries are
    # spaced out instead of hammering one table every tic.
    _FULL_TRIES = int(os.environ.get("DOOM_VACUUM_FULL_TRIES", "8"))
    _RETRY_GAP = 35                      # ~1 s between tries of one table
    _LOCK_TIMEOUT = "30ms"
    _pass = None                         # current VACUUM FULL pass, for its log line
    # Regrowth: plain VACUUM cannot shrink a file, and with nobody joining or
    # changing map no FULL pass runs, so player_state went 7 -> 100 pages and
    # monster_ai 12 -> 30 in 8 h (tic +5 ms). Every _REGROW_CHECK tics, tables
    # that are at least twice their size right after their last VACUUM FULL
    # (and >= 8 pages) get a VACUUM FULL of their own.
    _REGROW_CHECK = int(os.environ.get("DOOM_VACUUM_REGROW_CHECK", "3500"))   # ~100 s
    _compact = {}                        # table -> pages after its last VACUUM FULL
    # Re-plan after a map change. Postgres decides once per statement whether
    # to use one generic plan (after 5 custom plans) and never revisits that,
    # even after ANALYZE. A referee that started on E1M1/E1M2 kept their plan
    # shapes on E1M6: 74 ms/tic against 51-56 ms on a fresh connection (lab,
    # E1M6 awake); live it was ~80 ms. On each map change, and again ~60 s
    # later (monsters awake by then): ANALYZE the game tables (~140 ms), then
    # DISCARD PLANS (prepared statements stay, they re-plan on next use).
    _REPLAN_AGAIN = 2100                 # tics after the map change (~60 s)
    _replan = []                         # tic numbers at which to re-plan

    def _maint(wall0, label):
        """A maintenance statement run during play (start, end, what), for the
        app's slow-frame lines (sqldoom.server.frames), 2026-11-19."""
        try:
            samples.put_nowait(("maint", wall0, time.time(), label))
        except Exception:
            pass

    def _replan_now(cur):
        raw = getattr(cur, "_cur", cur)
        t0 = time.perf_counter()
        w0 = time.time()
        raw.execute(_TABLES_SQL.format(extra=""), (_MAX_PAGES,))
        names = [t for t, _ in raw.fetchall()]
        if names:
            raw.execute("ANALYZE " + ", ".join(f'doom."{t}"' for t in names))
        raw.execute("DISCARD PLANS")
        _maint(w0, f"ANALYZE {len(names)} tables")
        print(f"[referee] re-plan for map {_map}: ANALYZE {len(names)} tables + DISCARD PLANS "
              f"in {(time.perf_counter() - t0) * 1000:.0f} ms", flush=True)

    def _regrown(cur):
        if not _compact:
            return []
        cur.execute("SELECT relname, pg_relation_size(relid) / 8192 FROM pg_stat_user_tables "
                    "WHERE schemaname = 'doom' AND relname = ANY(%s)", (list(_compact),))
        return [(t, p) for t, p in cur.fetchall() if p >= max(8, 2 * _compact[t])]

    def _enqueue(cur, full, why, rows=None):
        nonlocal _queue, _pass
        # plain passes skip tables with a handful of dead rows: every VACUUM
        # costs each render connection one frame re-plan, not worth it for 5 rows
        if rows is None:
            cur.execute(_TABLES_SQL.format(extra="" if full else "AND n_dead_tup >= 100"), (_MAX_PAGES,))
            rows = cur.fetchall()
        names = [t for t, _ in rows]
        if full:    # a FULL pass replaces any entry still queued for a table
            drop = set(names)
            _queue = [e for e in _queue if e[0] not in drop] + [[t, True, 0, 0] for t in names]
        else:
            queued = {e[0] for e in _queue}
            _queue += [[t, False, 0, 0] for t in names if t not in queued]
        if full and not rows:
            # nothing to do: say so now. (Kept open, the pass was only closed
            # by the next queued table, and logged "0 tables ... in 3.1 s":
            # the time until the player joined. A new game branch starts with
            # empty statistics, so the referee-start pass finds no table; the
            # template is compacted instead, sqldoom/lakebase/games.py _reset_template.)
            print(f"[referee] VACUUM FULL ({why}): no table written since the statistics began", flush=True)
            return
        if full:
            _pass = {"why": why, "t0": time.perf_counter(), "tables": len(rows),
                     "before": sum(int(p) for _, p in rows), "names": set(names), "retried": set(),
                     "fallback": [], "failed": []}

    def _vacuum_one(cur):
        nonlocal _pass
        ready = next((i for i, e in enumerate(_queue) if e[3] <= _counter), None)
        if ready is None:
            return                       # only retries waiting for their slot
        entry = _queue.pop(ready)
        tbl, full, tries, _ = entry
        w0 = time.time()
        try:
            cur.execute(f"SET lock_timeout = '{_LOCK_TIMEOUT}'")
            # Plain VACUUM: TRUNCATE false. Its truncate step waits for an
            # exclusive lock in a retry loop that ignores lock_timeout and
            # gives up only after 5 s (VacuumTruncate), and the game stood
            # still that long whenever frame queries held the table. FULL
            # hands the space back instead.
            cur.execute(f'VACUUM FULL doom."{tbl}"' if full else f'VACUUM (TRUNCATE false) doom."{tbl}"')
            if full:
                cur.execute("SELECT pg_relation_size(%s::regclass) / 8192", (f'doom."{tbl}"',))
                _compact[tbl] = int(cur.fetchone()[0])
        except Exception as exc:
            busy = "lock timeout" in str(exc)
            if full and busy and tries + 1 < _FULL_TRIES:
                _queue.append([tbl, True, tries + 1, _counter + _RETRY_GAP])
                if _pass is not None:
                    _pass["retried"].add(tbl)
            elif full and busy:
                _queue.append([tbl, False, 0, 0])     # give up on FULL: plain VACUUM
                if _pass is not None:
                    _pass["fallback"].append(tbl)
            elif _pass is not None:
                _pass["failed"].append(f"{tbl} ({str(exc).splitlines()[0][:40]})")
        finally:
            try:
                cur.execute("RESET lock_timeout")
            except Exception:
                pass
            _maint(w0, f"{'VACUUM FULL' if full else 'VACUUM'} {tbl}")
        if _pass is not None and not _queue:
            cur.execute(_TABLES_SQL.format(extra=""), (_MAX_PAGES,))
            after = sum(int(p) for t, p in cur.fetchall() if t in _pass["names"])
            got = len(_pass["retried"]) - len(_pass["fallback"])
            print(f"[referee] VACUUM FULL ({_pass['why']}): {_pass['tables']} tables, "
                  f"{_pass['before']} -> {after} pages in "
                  f"{time.perf_counter() - _pass['t0']:.1f} s"
                  + (f"; {got} compacted after retries" if _pass["retried"] else "")
                  + (f"; busy after {_FULL_TRIES} tries, plain VACUUM instead: "
                     f"{', '.join(_pass['fallback'])}" if _pass["fallback"] else "")
                  + (f"; failed: {', '.join(_pass['failed'])}" if _pass["failed"] else ""),
                  flush=True)
            _pass = None

    # Between maps: the map-change VACUUM FULL used to run once the new map
    # was playing, one table per tic with a 30 ms lock timeout, and frame
    # queries kept the tables busy: 11-13 s of retries (and slow tics) after
    # every map change live, 8-12 tables left uncompacted. It is now a plain
    # VACUUM (owner's call, 2026-11-12): no exclusive lock, so it never waits
    # for the frame queries nor blocks them, and the tables are small (~700
    # pages in all). TRUNCATE false: the truncate step waits for an exclusive
    # lock and ignores lock_timeout (see _vacuum_one). A file that keeps
    # growing is still compacted by the regrowth check (VACUUM FULL, queue).
    # Two passes, both with the world standing still:
    #   intermission  the tables the level wrote, as the intermission starts
    #                 (bounded so the intermission does not run long);
    #   rotation      right after doom_mp_rotate, before the new map's first
    #                 tic: the tables the rotation rewrote (old map's rows out,
    #                 the new map's in).
    # A table left over (budget, error) goes to the usual queue (plain VACUUM).
    # The rotation pass holds the new map back, so the intermission is cut by
    # as long as the last one took: the player waits no longer than before.
    # DOOM_VACUUM_BETWEEN_MAPS=0: the old way (VACUUM FULL after the change).
    #
    # Loading screen instead of the intermission (owner's call, 2026-11-13):
    # a map change asked from the page, or the end of a level in single
    # player, skips the 10 s frag table. The level's pass runs right after its
    # last tic, the intermission is opened with 0 s (mp_match.intermission_tics
    # = 0 for that one rotation), the rotation pass runs, and the new map
    # starts as soon as both are done. Every step goes to the parent
    # (Metrics.between) and the page shows it as a log over the game.
    # Restarts, mode switches and the end of a multiplayer level keep their
    # timed intermission (the passes then run inside it, as described above).
    _BETWEEN = os.environ.get("DOOM_VACUUM_BETWEEN_MAPS", "1") != "0" and _FULL_ON_EVENTS
    _BETWEEN_LOCK = os.environ.get("DOOM_VACUUM_BETWEEN_LOCK", "1s")
    _LOADING_MIN_S = float(os.environ.get("DOOM_LOADING_MIN_S", "3"))   # loading screen at least that long
    _LOADING_FULL = os.environ.get("DOOM_LOADING_VACUUM_FULL", "1") != "0"  # 0: plain VACUUM there too
    # While a map is playing (frames rendering), every pass is a plain VACUUM
    # (owner's call, 2026-11-13): a VACUUM FULL there fought the frames for
    # its locks (live: 7 s of retries, 8-12 tables left busy, slow tics) and
    # the files are compacted at every map change anyway (loading screen).
    # The referee-start pass stays FULL (no player yet). 1: the old way.
    _FULL_IN_GAME = os.environ.get("DOOM_VACUUM_FULL_IN_GAME", "0") == "1"
    _between = {"in_intermission": False, "rotated": False, "skip_change": False, "rotation_s": 1.5,
                "page_change": None, "loading": False, "saved_tics": None, "t0": 0.0}

    def _say(kind, text=""):
        """A line for the page's loading screen (sqldoom.server.metrics.Metrics.between)."""
        try:
            samples.put_nowait(("between", time.time(), kind, text))
        except Exception:
            pass

    def _vacuum_now(cur, why, tables, budget_s, log=False, full=False):
        """Plain VACUUM (TRUNCATE false) of tables now, within budget_s.
        Returns the tables not done. log: one line per table to the page.
        full: VACUUM FULL instead (the loading screen's passes, owner's call
        2026-11-13: they fit in its 3 s, 0.2 s each without frames and
        1.2-1.4 s each with frames rendering), waiting up to _BETWEEN_LOCK for
        each table's lock; frames queue behind it, nobody sees them."""
        raw = getattr(cur, "_cur", cur)
        t0 = time.perf_counter()
        dead = 0
        done, left = 0, []
        pages_before = [0, 0]            # VACUUM FULL: pages before, after
        try:
            raw.execute(f"SET lock_timeout = '{_BETWEEN_LOCK}'")
            names = [t for t, _ in tables]
            per = {}
            if names:
                raw.execute("SELECT relname, n_dead_tup FROM pg_stat_user_tables "
                            "WHERE schemaname = 'doom' AND relname = ANY(%s)", (names,))
                per = {t: int(n) for t, n in raw.fetchall()}
                dead = sum(per.values())
            for tbl, pages in tables:
                if time.perf_counter() - t0 > budget_s:
                    left.append((tbl, pages))
                    continue
                t1 = time.perf_counter()
                verb = "VACUUM FULL" if full else "VACUUM"
                try:
                    if full:
                        raw.execute(f'VACUUM FULL doom."{tbl}"')
                        raw.execute("SELECT pg_relation_size(%s::regclass) / 8192", (f'doom."{tbl}"',))
                        _compact[tbl] = int(raw.fetchone()[0])
                        pages_txt = f"{int(pages):>4} -> {_compact[tbl]:>4} pages"
                        pages_before[0] += int(pages)
                        pages_before[1] += _compact[tbl]
                    else:
                        raw.execute(f'VACUUM (TRUNCATE false) doom."{tbl}"')
                        pages_txt = ""
                    done += 1
                    if log:
                        _say("line", f"{verb} {tbl:<24} {per.get(tbl, 0):>6} dead rows  {pages_txt}  "
                                     f"{(time.perf_counter() - t1) * 1000:5.0f} ms")
                except Exception as exc:
                    left.append((tbl, pages))
                    if log:
                        _say("line", f"{verb} {tbl:<24} skipped ({str(exc).splitlines()[0][:40]})")
        finally:
            try:
                raw.execute("RESET lock_timeout")
            except Exception:
                pass
        took = time.perf_counter() - t0
        verb = "VACUUM FULL" if full else "VACUUM"
        pages_txt = f", {pages_before[0]} -> {pages_before[1]} pages" if full else ""
        print(f"[referee] {verb} ({why}, no tic running): {done} tables, ~{dead} dead rows{pages_txt} "
              f"in {took:.1f} s"
              + (f"; {len(left)} left for the queue: {', '.join(t for t, _ in left)}" if left else ""),
              flush=True)
        if log:
            _say("line", f"-- {why}: {done} tables, {dead} dead rows{pages_txt} in {took:.2f} s"
                         + (f", {len(left)} left for later" if left else ""))
        return left

    def _wait_frames_stopped(raw, limit_s=1.5):
        """The page stops asking for frames behind the loading screen (it shows
        it on the click, or within a second of the referee's 'begin'); wait
        for the frames still running, so VACUUM FULL does not queue behind
        them table after table (1.6 s per pass with frames running)."""
        t0 = time.perf_counter()
        n = None
        while time.perf_counter() - t0 < limit_s:
            # pg_locks, not pg_stat_activity: as doom_owner the referee does not
            # see other sessions' queries; a running frame holds AccessShare
            # locks on doom tables, an idle connection holds none
            raw.execute("SELECT count(DISTINCT l.pid) FROM pg_locks l JOIN pg_class c ON c.oid = l.relation "
                        "WHERE c.relnamespace = 'doom'::regnamespace AND l.pid <> pg_backend_pid() "
                        "AND l.mode = 'AccessShareLock' AND l.granted")
            n = int(raw.fetchone()[0])
            if n == 0:
                break
            time.sleep(0.05)
        _say("line", f"frames stopped after {time.perf_counter() - t0:.2f} s" if n == 0
             else f"{n} session(s) still reading after {limit_s:.1f} s, going on")

    def _loading_begin(cur, target):
        """Right after the last tic of a level that ends without a frag table:
        the level's pass, then a 0 s intermission for this one rotation."""
        raw = getattr(cur, "_cur", cur)
        _between.update(loading=True, in_intermission=True, rotated=True, t0=time.perf_counter())
        _say("begin", f"LOADING {target}")
        _say("line", f"level over, the world stops; next: {target}")
        if _LOADING_FULL:
            _wait_frames_stopped(raw)
        raw.execute(_TABLES_SQL.format(extra=""), (_MAX_PAGES,))
        left = _vacuum_now(cur, "end of level", raw.fetchall(), 6.0, log=True, full=_LOADING_FULL)
        if left:
            _enqueue(cur, _LOADING_FULL, "end of level leftovers", rows=left)
        raw.execute("SELECT intermission_tics FROM mp_match LIMIT 1")
        row = raw.fetchone()
        _between["saved_tics"] = int(row[0]) if row and row[0] is not None else None
        raw.execute("UPDATE mp_match SET intermission_tics = 0")
        _say("line", f"loading {target}")

    def _between_maps_intermission(cur):
        """From the game loop's housekeeping (mp_reap), about once a second, also
        during intermissions."""
        raw = getattr(cur, "_cur", cur)
        raw.execute("SELECT state::text, EXTRACT(EPOCH FROM (intermission_until - now())) FROM mp_match LIMIT 1")
        row = raw.fetchone()
        if row is None:
            return
        state, remaining = row
        if state != "intermission":
            _between["in_intermission"] = False
            return
        if _between["in_intermission"]:
            return                       # once per intermission
        _between["in_intermission"] = True
        _between["rotated"] = True       # mp_players after doom_mp_rotate runs the second pass
        budget = min(6.0, (float(remaining) if remaining is not None else 10.0) - 1.5)
        if budget < 0.5:
            return
        raw.execute(_TABLES_SQL.format(extra=""), (_MAX_PAGES,))
        left = _vacuum_now(cur, "intermission", raw.fetchall(), budget)
        if left:
            _enqueue(cur, False, "intermission leftovers", rows=left)
        # make room for the rotation pass: the new map starts on time
        raw.execute("UPDATE mp_match SET intermission_until = GREATEST(now() + interval '1 second', "
                    "intermission_until - make_interval(secs => %s)) WHERE state = 'intermission'",
                    (round(_between["rotation_s"], 1),))

    def _maybe_loading(cur):
        """A page map change, or a single-player level end: no frag table."""
        page, _between["page_change"] = _between["page_change"], None
        raw = getattr(cur, "_cur", cur)
        raw.execute("SELECT mode, pending FROM mp_match LIMIT 1")
        row = raw.fetchone()
        if row is None:
            return
        mode, pending = row
        if pending is not None or not (page or mode == "solo"):
            return                       # restart, mode switch, multiplayer level end: timed intermission
        if page is None:
            # the map doom_mp_rotate goes to: the one asked for, single player's
            # next after its intermission (Doom's order), or the rotation's
            raw.execute("SELECT COALESCE((SELECT ma.name FROM maps ma WHERE ma.map_id = doom_mp_next_map()), "
                        "'the next map')")
            page = raw.fetchone()[0]
        _loading_begin(cur, page)

    def _between_maps_rotation(cur):
        if not _between["rotated"]:
            return
        _between["rotated"] = False
        raw = getattr(cur, "_cur", cur)
        loading = _between["loading"]
        if loading and _between["saved_tics"] is not None:
            raw.execute("UPDATE mp_match SET intermission_tics = %s", (_between["saved_tics"],))
            _between["saved_tics"] = None
        if loading:
            raw.execute("SELECT ma.name FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id LIMIT 1")
            row = raw.fetchone()
            _say("line", f"{row[0] if row else 'the new map'} loaded")
        # loading screen: VACUUM FULL of every table the game writes (the dead
        # row counts lag behind the load, so they cannot pick the tables)
        raw.execute(_TABLES_SQL.format(extra="" if loading else "AND n_dead_tup > 0"), (_MAX_PAGES,))
        t0 = time.perf_counter()
        left = _vacuum_now(cur, "new map" if loading else "rotation", raw.fetchall(), 3.0,
                           log=loading, full=loading and _LOADING_FULL)
        _between["rotation_s"] = min(3.0, time.perf_counter() - t0)
        if left:
            _enqueue(cur, loading and _LOADING_FULL, "rotation leftovers", rows=left)
        _between["skip_change"] = True   # the map change below needs no pass of its own
        if loading:
            # The screen stays up at least _LOADING_MIN_S (owner, 2026-11-13: the
            # passes take ~0.1 s, too short to read). the game loop restarts its
            # tic clock after the rotation, so waiting here drops no tic; the
            # referee heartbeat keeps beating (claims expire after 3 s).
            done_s = time.perf_counter() - _between["t0"]
            if done_s < _LOADING_MIN_S:
                _say("line", f"ready in {done_s:.2f} s; starting at {_LOADING_MIN_S:.0f} s")
                while True:
                    left_s = _LOADING_MIN_S - (time.perf_counter() - _between["t0"])
                    if left_s <= 0:
                        break
                    try:
                        raw.execute("SELECT doom_mp_referee_beat(0)")
                    except Exception:
                        pass
                    time.sleep(min(0.5, left_s))
            _between["loading"] = False
            _say("end", f"go: {time.perf_counter() - _between['t0']:.1f} s since the end of the level")

    def _maybe_vacuum(cur):
        nonlocal _counter, _players, _map
        _counter += 1
        if _FULL_ON_EVENTS and (_players is None or _counter % _STATE_CHECK == 0):
            try:
                # maps_played counts level restarts too: a restart (death,
                # rules) gets the same VACUUM FULL as a map change
                cur.execute("SELECT (SELECT count(*) FROM api_scoreboard WHERE connected), "
                            "(SELECT map_id::text || ':' || maps_played::text FROM mp_match LIMIT 1)")
                players, map_id = cur.fetchone()
                players = int(players)
            except Exception:
                players, map_id = _players or 0, _map
            if _players is None:
                _enqueue(cur, True, "referee start")
            elif _players == 0 and players > 0:
                _enqueue(cur, _FULL_IN_GAME, f"game starts, {players} player{'s' if players != 1 else ''}")
            elif map_id is not None and _map is not None and map_id != _map:
                if _between["skip_change"]:
                    _between["skip_change"] = False      # done between the maps
                else:
                    _enqueue(cur, _FULL_IN_GAME, f"map change {_map} -> {map_id}")
                _replan[:] = [_counter + 1, _counter + _REPLAN_AGAIN]
            _players, _map = players, map_id
        if _replan and _counter >= _replan[0]:
            _replan.pop(0)
            try:
                _replan_now(cur)
            except Exception as exc:
                print(f"[referee] re-plan failed: {exc}", flush=True)
            return                       # one maintenance step per tic
        if _FULL_ON_EVENTS and _REGROW_CHECK > 0 and _counter % _REGROW_CHECK == 0 and not _queue:
            grown = _regrown(cur)
            if grown:
                why = "regrowth: " + ", ".join(f"{t} {_compact[t]}->{p}" for t, p in grown)
                if not _FULL_IN_GAME:
                    # plain VACUUM does not shrink the file: from this size on,
                    # so the same growth is not reported again every check
                    for t, p in grown:
                        _compact[t] = int(p)
                _enqueue(cur, _FULL_IN_GAME, why,
                         rows=grown)
        if _VACUUM_INTERVAL > 0 and _counter % _VACUUM_INTERVAL == 0 and not _queue:
            _enqueue(cur, False, "interval")
        if _queue:
            _vacuum_one(cur)

    # --- commands from the page: map change, end-of-deathmatch choice -------
    _inbox = {"map": None, "mode": None, "pause": None}  # several clicks: the last one wins
    # Pause (DOOM_PAUSE=1, a single-player game's branch): while the player's
    # tab is in the background (POST /api/games/{id}/away) the world stops:
    # no tic runs, so monsters, projectiles and the level clock wait too.
    _pausable = os.environ.get("DOOM_PAUSE") == "1"
    _pause = {"on": False, "since": 0.0}

    def _drain():
        if commands is None:
            return
        try:
            while True:
                kind, value = commands.get_nowait()
                if kind in _inbox:
                    _inbox[kind] = value
        except queue.Empty:
            pass

    # --- game modes -----------------------------------------------------------
    # solo while one player is seated; a second player starts a deathmatch on
    # the same map after a 10 s countdown (the intermission, overlay
    # "DEATHMATCH STARTS IN n"); when the deathmatch is down to one player
    # (or none), the final frag table stays up for 30 s with the choice "stay
    # in deathmatch" / "single player" (POST /api/match/mode); no choice means
    # single player, a new player joining means deathmatch again. The switch
    # itself is SQL: mp_match.pending, then doom_mp_rotate -> doom_mp_apply_mode
    # (sql/functions/multiplayer). Checked once a second, from the game loop's
    # housekeeping (statements.mp_reap), which also runs during intermissions.
    # skill: the match's difficulty (mp_match.skill, from the rules); every
    # tic gets it instead of the game loop's SKILL, re-read after each rotation.
    _keep_mode = os.environ.get("DOOM_KEEP_MODE") == "1"
    _mode = {"end_level": False, "last_seated": 0, "guard": False,
             "skill": int(os.environ.get("SKILL", "2"))}

    def _mode_step(cur):
        raw = getattr(cur, "_cur", cur)
        if not _mode["guard"]:
            # after doom_mp_configure has used the real value for intermission_tics
            from sqldoom.game import server as _ds
            _ds.INTERMISSION_SECONDS = max(_ds.INTERMISSION_SECONDS, _INTERMISSION_GUARD_S)
            _mode["guard"] = True
        _drain()
        raw.execute("SELECT m.state::text, m.mode, m.pending, ma.name, "
                    "(SELECT count(*) FROM mp_players mp WHERE mp.map_id = m.map_id AND mp.role_name IS NOT NULL), "
                    # between maps nobody can take a seat: a newcomer waits in the lobby
                    "(SELECT count(*) FROM mp_waiting w WHERE EXTRACT(EPOCH FROM (now() - w.last_seen)) <= 5) "
                    "FROM mp_match m JOIN maps ma ON ma.map_id = m.map_id LIMIT 1")
        row = raw.fetchone()
        if row is None:
            return
        state, mode, pending, map_name, seated, waiting = row
        seated, waiting = int(seated), int(waiting)
        last, _mode["last_seated"] = _mode["last_seated"], seated
        choice, _inbox["mode"] = _inbox["mode"], None

        def end_level(target):
            raw.execute("UPDATE mp_match SET pending = %s", (target,))
            raw.execute("INSERT INTO mp_map_request (map_name) VALUES (%s) ON CONFLICT (id) DO UPDATE "
                        "SET map_name = EXCLUDED.map_name, requested_at = now()", (map_name,))
            _mode["end_level"] = True
            why = {"deathmatch": "deathmatch starts after the countdown",
                   "final": "deathmatch over, final score and the choice",
                   "restart": "death in single player, the level restarts",
                   "rules": "rules changed by Player 1, the level restarts",
                   "stay": "Player 1 switched to the multiplayer rules",
                   "solo": "Player 1 switched back to the single player rules"}[target]
            print(f"[referee] {seated} player{'s' if seated != 1 else ''} on {map_name}: {why}", flush=True)

        def decide(target, seconds, why):
            raw.execute("UPDATE mp_match SET pending = %s, "
                        "intermission_until = now() + %s * interval '1 second' WHERE state = 'intermission'",
                        (target, seconds))
            print(f"[referee] {why}: {'deathmatch' if target == 'stay' else 'single player'} "
                  f"on {map_name} in {seconds} s", flush=True)

        if state == "playing" and pending in ("restart", "rules", "stay", "solo") and not _mode["end_level"]:
            # set by the tic (death) or the page (rules; Player 1 alone picking
            # the other mode: 'stay' = multiplayer rules, 'solo'): reopen this map.
            # A deathmatch with one player then lasts: it only ends when the
            # count drops from two or more to one.
            end_level(pending)
        elif state == "playing" and pending is None and not _mode["end_level"]:
            if mode == "solo" and seated >= 2:
                end_level("deathmatch")
            # a deathmatch someone chose to stay in alone waits for opponents;
            # it ends when the count drops to one or none
            # (DOOM_KEEP_MODE=1, a multiplayer game's branch: the game goes on
            # with one player, no final score)
            elif mode == "deathmatch" and seated <= 1 and last >= 2 and not _keep_mode:
                end_level("final")
        elif state == "intermission":
            if pending == "final":
                if seated + waiting >= 2:
                    decide("stay", 10, "a player joined during the final score")
                elif choice in ("stay", "solo"):
                    decide(choice, 10 if choice == "stay" else 3, "choice from the page")
            elif pending == "deathmatch" and seated < 2:
                decide("solo", 3, "the second player left during the countdown")

    real_reap = stmts.mp_reap

    def mp_reap(cur, *a, **k):
        freed = real_reap(cur, *a, **k)
        if _BETWEEN:
            try:
                _between_maps_intermission(cur)
            except Exception as exc:
                print(f"[referee] intermission VACUUM skipped: {str(exc).splitlines()[0][:160]}", flush=True)
        try:
            _mode_step(cur)
        except Exception as exc:
            try:
                getattr(cur, "_cur", cur).connection.rollback()
            except Exception:
                pass
            print(f"[referee] mode check skipped: {str(exc).splitlines()[0][:160]}", flush=True)
        return freed

    stmts.mp_reap = mp_reap

    # The game loop reads the slots right after doom_mp_rotate: the moment the
    # new level's difficulty is known.
    real_players = stmts.mp_players

    def mp_players(cur, *a, **k):
        out = real_players(cur, *a, **k)
        if _screen["on"]:
            _screen_say(None)            # the next map is in: its own view again
        if _BETWEEN:
            try:
                _between_maps_rotation(cur)
            except Exception as exc:
                print(f"[referee] rotation VACUUM skipped: {str(exc).splitlines()[0][:160]}", flush=True)
        try:
            raw = getattr(cur, "_cur", cur)
            raw.execute("SELECT skill FROM mp_match LIMIT 1")
            row = raw.fetchone()
            if row and int(row[0]) != _mode["skill"]:
                print(f"[referee] difficulty {_mode['skill']} -> {int(row[0])}", flush=True)
                _mode["skill"] = int(row[0])
        except Exception:
            pass
        return out

    stmts.mp_players = mp_players

    # --- map change requested from the page (see the module docstring) -----
    def _take_map_request(cur):
        """True when a request was taken: this tic ends the level."""
        _drain()
        name, _inbox["map"] = _inbox["map"], None
        if name is None:
            return False
        cur = getattr(cur, "_cur", cur)      # plain Postgres SQL: skip the shim
        try:
            if name == "next":
                cur.execute("DELETE FROM mp_map_request")
            else:
                cur.execute("INSERT INTO mp_map_request (map_name) SELECT name FROM maps WHERE name = %s "
                            "ON CONFLICT (id) DO UPDATE SET map_name = EXCLUDED.map_name, requested_at = now()",
                            (name,))
                if cur.rowcount == 0:
                    print(f"[referee] map change to {name} ignored: map not loaded", flush=True)
                    return False
            print(f"[referee] map change requested from the page: {name}", flush=True)
            _between["page_change"] = "the next map" if name == "next" else name
            return True
        except Exception as exc:
            print(f"[referee] map change to {name} failed: {exc}", flush=True)
            return False

    # --- single player's screens between levels (2026-11-21) ----------------
    # A single-player level that ends by its exit (not a map asked for from
    # the page, a death restart, a rules change or a mode switch): Doom's
    # intermission (the stats counting up, then the episode map) or, after
    # E?M8, the end of the episode (the text, then the picture), at 35 Hz with
    # the world standing still, then the loading screen and the next map
    # (sql/functions/game/doom_solo_level_end.sql, doom_solo_screen_tic.sql,
    # sql/views/api_screen_frame.sql). The app's frame threads draw the screen
    # meanwhile (Metrics.screen); a new press of fire or use moves it on, as
    # Doom's WI_checkForAccelerate. After the episode's picture the game goes
    # back to its first map and the page to the lobby.
    # DOOM_SOLO_SCREENS=0: straight to the loading screen, as before.
    _SCREENS = os.environ.get("DOOM_SOLO_SCREENS", "1") != "0"
    _SCREEN_ALONE_S = 30.0               # nobody seated that long: go on without them
    _screen = {"on": False}

    def _screen_say(kind):
        _screen["on"] = kind is not None
        try:
            samples.put_nowait(("screen", time.time(), kind))
        except Exception:
            pass

    def _solo_screens(cur, map_id):
        raw = getattr(cur, "_cur", cur)
        raw.execute("SELECT m.mode, m.pending, EXISTS (SELECT 1 FROM mp_map_request) FROM mp_match m LIMIT 1")
        row = raw.fetchone()
        if row is None or row[0] != "solo" or row[1] is not None or row[2]:
            return
        raw.execute("SELECT doom_solo_level_end(%s)", (map_id,))
        kind = raw.fetchone()[0]
        raw.execute("SELECT ma.name, (SELECT n.name FROM maps n WHERE n.map_id = s.next_map_id), s.secret_exit "
                    "FROM maps ma CROSS JOIN screen_state s WHERE ma.map_id = %s AND s.id = 0", (map_id,))
        names = raw.fetchone() or (map_id, None, False)
        print(f"[referee] single player: {names[0]} done" + (" by its secret exit" if names[2] else "")
              + (f", next {names[1]}: intermission" if kind == "stats" else ": the end of the episode"), flush=True)
        # the buttons as the last tic had them: a press is a change from up to down
        raw.execute("SELECT bool_or(attack_held), bool_or(use_requested) FROM game_tic_commands WHERE map_id = %s",
                    (map_id,))
        held = raw.fetchone() or (False, False)
        attack_down, use_down = bool(held[0]), bool(held[1])
        _screen_say(kind)
        t0 = next_t = last_beat = time.perf_counter()
        alone_since = None
        steps = 0
        while True:
            raw.execute("DELETE FROM mp_inputs WHERE map_id = %s RETURNING seq, attack_held, use_requested", (map_id,))
            accel = False
            for _, attack, use in sorted(raw.fetchall()):
                if (attack and not attack_down) or (use and not use_down):
                    accel = True
                attack_down, use_down = bool(attack), bool(use)
            now = time.perf_counter()
            if now - last_beat >= 1.0:
                last_beat = now
                raw.execute("SELECT doom_mp_referee_beat(0)")
                raw.execute("SELECT count(*) FROM mp_players WHERE map_id = %s AND role_name IS NOT NULL", (map_id,))
                if int(raw.fetchone()[0]) > 0:
                    alone_since = None
                elif alone_since is None:
                    alone_since = now
                elif now - alone_since > _SCREEN_ALONE_S:
                    print("[referee] single player: nobody seated, the screens end", flush=True)
                    accel = True         # as a press, every tic, until they are over
            raw.execute("SELECT doom_solo_screen_tic(%s)", (accel,))
            step = raw.fetchone()[0]
            steps += 1
            try:
                samples.put_nowait(("screen_tic",))
            except Exception:
                pass
            if step != kind:
                kind = step
                print(f"[referee] single player: {kind} after {time.perf_counter() - t0:.1f} s", flush=True)
                if kind not in ("done", "over"):
                    _screen_say(kind)
            if kind == "done":
                break
            if kind == "over":
                # the end of the episode: the game starts again from its first map
                # (fresh, no inventory carried), the page goes back to the lobby
                raw.execute("INSERT INTO mp_map_request (map_name) SELECT r.map_name FROM mp_rotation r "
                            "ORDER BY r.position LIMIT 1 ON CONFLICT (id) DO UPDATE "
                            "SET map_name = EXCLUDED.map_name, requested_at = now()")
                _screen_say("over")
                break
            next_t += 1.0 / 35.0
            delay = next_t - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            elif delay < -0.5:
                next_t = time.perf_counter()
        print(f"[referee] single player: screens over after {time.perf_counter() - t0:.1f} s, {steps} steps",
              flush=True)

    def mp_tic(*a, **k):
        if _pausable:
            _drain()
            want, _inbox["pause"] = _inbox["pause"], None
            if want is not None and bool(want) != _pause["on"]:
                _pause["on"] = bool(want)
                if want:
                    _pause["since"] = time.time()
                    print("[referee] paused: the player's tab is in the background", flush=True)
                else:
                    print(f"[referee] resumed after {time.time() - _pause['since']:.0f} s", flush=True)
            if _pause["on"]:
                return False             # no tic: the world waits (the game loop keeps its 35 Hz pace)
        t0, ok, ended = time.perf_counter(), False, False
        if len(a) >= 3:                  # (cur, map_id, skill, players): the rules' difficulty
            a = (a[0], a[1], _mode["skill"]) + tuple(a[3:])
        real_end = False
        try:
            result = real_tic(*a, **k)
            ok = True
            real_end = bool(result)      # the level's own end (its exit), not the page's or a mode's
            if not result and a and _take_map_request(a[0]):
                result = True            # the game loop: level done -> rotate()
            if _mode["end_level"]:       # mode switch: the intermission, then the same map
                _mode["end_level"] = False
                result = True
            ended = bool(result)
            return result
        finally:
            try:
                samples.put_nowait((time.time(), (time.perf_counter() - t0) * 1000.0, ok))
            except Exception:
                pass
            # A single-player level done by its exit: Doom's screens first.
            if ok and ended and real_end and _SCREENS and len(a) >= 2:
                try:
                    _solo_screens(a[0], a[1])
                except Exception as exc:
                    try:
                        getattr(a[0], "_cur", a[0]).connection.rollback()
                    except Exception:
                        pass
                    print(f"[referee] single player screens skipped: {str(exc).splitlines()[0][:160]}", flush=True)
            # The level is over (the game loop rotates next): loading screen
            # instead of the intermission, outside the tic's timing.
            if ok and ended and a and _BETWEEN:
                try:
                    _maybe_loading(a[0])
                except Exception as exc:
                    print(f"[referee] loading screen skipped: {str(exc).splitlines()[0][:160]}", flush=True)
            # Vacuum between tics, outside the timing window. The cursor is
            # the first positional arg (statements.mp_tic(cur, ...)); the
            # connection has autocommit=True so VACUUM runs immediately.
            if ok and a:
                try:
                    _maybe_vacuum(a[0])
                except Exception:
                    pass

    stmts.mp_tic = mp_tic               # server calls it as sql.mp_tic

    # --- opening the match -------------------------------------------------------
    # Right before the game loop checks the frame views (server.check_frame_views):
    # the game's mode and rules from the first tic.
    from sqldoom.game import server
    real_check_views = server.check_frame_views

    def check_frame_views(cur, map_ids):
        t0 = time.perf_counter()
        try:
            if start_mode in ("solo", "deathmatch"):
                # the game's mode from its first tic (doom_mp_apply_mode's update, no level end)
                raw0 = getattr(cur, "_cur", cur)
                raw0.execute("UPDATE mp_match m SET mode = r.mode, pending = NULL, monsters = r.monsters, "
                             "skill = r.skill FROM mp_rules r WHERE r.mode = %s", (start_mode,))
                raw0.execute("SELECT doom_mp_world_flags(%s)", (start_mode == "deathmatch",))
                print(f"[referee] match opens with the {start_mode} rules", flush=True)
            else:
                cur.execute("SELECT doom_mp_world_flags(false)")
            cur.execute("SELECT doom_mp_rules_live()")     # the mode's rules: respawns, weapons, death
            print(f"[referee] match opened in {(time.perf_counter() - t0) * 1000:.0f} ms", flush=True)
        except Exception as exc:
            print(f"[referee] opening the match failed: {exc}", flush=True)
            raise
        return real_check_views(cur, map_ids)

    server.check_frame_views = check_frame_views
    _start_hud_worker(dsn)
    sys.exit(server.main())


# --- status-bar cache writer (off by default) ----------------------------------
# Writes hud_cache: every DOOM_HUD_INTERVAL_MS (0 = off, the default since
# 2026-11-24) it checks each seated slot of the current map (the
# doom_hudkey_slot<S>_m<M> key, ~1.5 ms) and redraws the cached bar (~20 ms)
# when the key changed, on its own connection. No frame view reads hud_cache
# any more: the frames draw the status bar themselves, and taking it from the
# cache measured ~0.5 ms of a 55 ms frame (E1M9, 2026-11-24).
def _start_hud_worker(dsn):
    interval = int(os.environ.get("DOOM_HUD_INTERVAL_MS", "0")) / 1000.0
    if interval <= 0:
        return

    def run():
        import psycopg2
        conn = None
        prepared = set()
        written, last_log = 0, time.time()
        while True:
            try:
                if conn is None or conn.closed:
                    conn = psycopg2.connect(dsn)
                    conn.autocommit = True
                    prepared.clear()
                cur = conn.cursor()
                cur.execute("SELECT mp.map_id, mp.slot FROM mp_players mp JOIN mp_match m ON m.map_id = mp.map_id "
                            "AND m.state = 'playing' WHERE mp.role_name IS NOT NULL ORDER BY mp.slot")
                for map_id, slot in cur.fetchall():
                    name = f"slot{int(slot)}_m{int(map_id)}"
                    if name not in prepared:
                        cur.execute("SELECT to_regclass(%s) IS NOT NULL", (f"doom_hud_{name}",))
                        if not cur.fetchone()[0]:
                            continue
                        cur.execute(f"PREPARE hudkey_{name} AS SELECT key FROM doom_hudkey_{name}")
                        cur.execute(f"PREPARE hudfill_{name} AS INSERT INTO hud_cache (map_id, slot, key, bar) "
                                    f"SELECT {int(map_id)}, {int(slot)}, h.key, h.bar FROM doom_hud_{name} h "
                                    "ON CONFLICT (map_id, slot) DO UPDATE SET key = EXCLUDED.key, "
                                    "bar = EXCLUDED.bar, updated_at = now()")
                        prepared.add(name)
                    cur.execute(f"EXECUTE hudkey_{name}")
                    row = cur.fetchone()
                    cur.execute("SELECT key FROM hud_cache WHERE map_id = %s AND slot = %s", (map_id, slot))
                    cached = cur.fetchone()
                    if row and (cached is None or cached[0] != row[0]):
                        cur.execute(f"EXECUTE hudfill_{name}")
                        written += 1
                cur.close()
            except Exception as exc:
                print(f"[referee] hud worker: {exc}", flush=True)
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
                time.sleep(5.0)
            if time.time() - last_log > 300 and written:
                print(f"[referee] hud worker: {written} status bars cached in the last 5 min", flush=True)
                written, last_log = 0, time.time()
            time.sleep(interval)

    threading.Thread(target=run, name="hud-cache", daemon=True).start()


class Referee:
    """Starts, watches and restarts the referee child; feeds tic samples to metrics."""

    def __init__(self, endpoint, metrics, creds, backoff_max_s=30.0, env=None, name="sqldoom-referee"):
        self.endpoint, self.metrics, self.creds = endpoint, metrics, creds
        self.backoff_max_s = backoff_max_s
        self.env = dict(env or {})          # child-only env (game branches)
        self.name = name
        self._ctx = multiprocessing.get_context("spawn")
        self._stop = threading.Event()
        self._proc = None
        self._thread = None
        self._commands = self._ctx.Queue(maxsize=100)    # parent -> child, survives restarts

    def pause(self, on):
        """Stop (on) or restart the world's tics (DOOM_PAUSE=1 referees only)."""
        return self._command("pause", bool(on))

    def request_map(self, name):
        """Ask the running referee to end the level and go to `name` (or "next")."""
        return self._command("map", name)

    def request_mode(self, choice):
        """End of a deathmatch: "stay" (deathmatch again) or "solo"."""
        return self._command("mode", choice)

    def _command(self, kind, value):
        if self._proc is None or not self._proc.is_alive():
            return False
        try:
            self._commands.put_nowait((kind, value))
            return True
        except queue.Full:
            return False

    def start(self):
        self._thread = threading.Thread(target=self._supervise, name=f"{self.name}-supervisor", daemon=True)
        self._thread.start()

    def _supervise(self):
        failures = 0
        while not self._stop.is_set():
            began = time.time()
            try:
                dsn = self.creds.dsn(self.endpoint, application_name="sqldoom-referee",
                                     role=os.getenv("DOOM_DB_ROLE") or None)
            except Exception as exc:
                print(f"[referee] cannot get Lakebase credentials: {exc}", flush=True)
                self.metrics.referee_state("exited", f"credentials: {str(exc)[:200]}")
                failures += 1
                self._stop.wait(min(self.backoff_max_s, 2.0 ** failures))
                continue
            samples = self._ctx.Queue(maxsize=10000)
            proc = self._ctx.Process(target=_child, args=(samples, dsn, self._commands, self.env),
                                     name=self.name, daemon=True)
            self.metrics.referee_state("starting")
            proc.start()
            self._proc = proc
            running = False
            while proc.is_alive() or not samples.empty():
                try:
                    item = samples.get(timeout=0.5)
                except queue.Empty:
                    continue
                if item and item[0] == "between":       # loading screen line (_say)
                    self.metrics.between(*item[1:])
                    continue
                if item and item[0] == "maint":         # a VACUUM / ANALYZE during play (_maint)
                    self.metrics.maintenance(*item[1:])
                    continue
                if item and item[0] == "screen_tic":    # a step of the screens between levels
                    self.metrics.screen_tic()
                    continue
                if item and item[0] == "screen":        # they start, change or end (_screen_say)
                    self.metrics.screen(*item[1:])
                    continue
                wall, ms, ok = item
                if not running:
                    running = True
                    self.metrics.referee_state("running")
                self.metrics.tic(wall, ms, ok)
            proc.join()
            self.metrics.screen(time.time(), None)    # a child gone mid-screen: back to the game's view
            self.metrics.referee_state("stopped" if self._stop.is_set() else "exited", proc.exitcode)
            print(f"[referee] child exited with {proc.exitcode} after {time.time() - began:.0f} s", flush=True)
            if self._stop.is_set():
                break
            # A referee that ran for a while gets restarted at once; one that
            # keeps failing at startup backs off.
            failures = 0 if time.time() - began > 60 else failures + 1
            self._stop.wait(min(self.backoff_max_s, 2.0 ** failures))

    def stop(self, timeout=10.0):
        """SIGTERM: the game loop finishes its tic and releases the referee claim."""
        self._stop.set()
        proc = self._proc
        if proc is not None and proc.is_alive():
            proc.terminate()
            proc.join(timeout)
            if proc.is_alive():
                proc.kill()
        if self._thread is not None:
            self._thread.join(timeout)
