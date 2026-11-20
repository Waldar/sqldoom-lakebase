"""Frames rendered next to the database and pushed to the page (/frames).

Until 2026-11-19 the browser asked for every frame across the internet
(camera + frame on its own connections, through the relay): each request
waited a browser <-> app round trip before the database could start it. As
in LBDoom's webapp/engine.py, the app now renders: per player tab, render
threads with their own connections to the game's endpoint (about 1 ms
away), logged in as that player (doom.player, as the relay's sessions), take
slots from one 35 Hz clock in turn, run the player's camera and frame view,
and one sender per tab pushes the newest frame on one WebSocket. The network
then only delays the picture; it no longer limits the frame rate.

Protocol, on /frames?game=<id>&tab=<tab>:
  page -> app, text JSON, any subset:  {"view": "api_frame_idx_slot1_m1",
      "conns": 2, "pause": false, "stamp": true}; view must match the relay's
      frame views (relay.ALLOWED_RE), conns 1..6 render threads, pause stops
      the clock (loading screen, automap), stamp asks for the input stamp.
  app -> page, binary: 9-byte header (seq u32, database ms x 100 u32,
      flags u8: 1 = XOR against the previous frame of the same length,
      2 = no frame, the view returned NULL: the seat is gone or the map
      changed, 4 = an input stamp u64 follows the header), then the frame's
      bytes. The stamp (2026-11-20, as LBDoom's ?lag=1): the newest input
      (api_input's number) the game had taken when the frame was read, in
      the frame's own statement, so its snapshot (migration 0005); only for
      a page that asked, so a page from before keeps its 9-byte header.
  app -> page, text JSON once a second: {"stats": {"fps", "pool_full",
      "db_ms", "conns"}}.
Compression is the WebSocket's permessage-deflate; the XOR makes an
unchanged part of the picture zeros, which it squeezes to almost nothing.
"""
import asyncio
import json
import os
import queue
import struct
import threading
import time

import psycopg2

from sqldoom.lakebase.connection import CREDS, SESSION_OPTIONS
from sqldoom.server.relay import ALLOWED_RE, log, player_identity

MAX_FPS = 35.0
MAX_CONNS = 6
# A frame starts the moment a tic commits (LBDoom's _claim_tic): it draws
# that tic, an input shows in the first frame after the tic that took it.
# No tic for IDLE_S (paused, loading, intermission): IDLE_HZ slots, so the
# picture still follows. DOOM_FRAMES_ON_TIC=0: the plain 35 Hz clock.
ON_TIC = os.getenv("DOOM_FRAMES_ON_TIC", "1") != "0"
IDLE_S, IDLE_HZ = 0.2, 5.0
# Slow frames (2026-11-19, the owner's 8-12 ms spikes): once a second, frames
# over SLOW_X x this stream's median get one log line, with what ran next to
# them (tic ms overlapping, the referee's VACUUM / ANALYZE) against the same
# for normal frames. DOOM_FRAMES_SLOW_LOG=0 turns it off.
SLOW_LOG = os.getenv("DOOM_FRAMES_SLOW_LOG", "1") != "0"
SLOW_X = float(os.getenv("DOOM_FRAMES_SLOW_X", "1.2"))
HEADER = struct.Struct(">IIB")
HEADER_STAMPED = struct.Struct(">IIBQ")
F_DELTA, F_NULL, F_STAMP = 1, 2, 4
# The newest input of this player the game has taken (migration 0005): what
# the last tic took, or just below the oldest of the player's inputs still
# waiting if that is lower (one committed while that tic ran).
STAMP_SQL = ("(SELECT LEAST(g.inputs_upto, COALESCE((SELECT MIN(i.seq) - 1 FROM mp_inputs i"
             " WHERE i.map_id = g.map_id AND i.player_thing_id = g.player_thing_id), g.inputs_upto))"
             " FROM game_tic_commands g JOIN mp_players mp"
             " ON mp.map_id = g.map_id AND mp.player_thing_id = g.player_thing_id"
             " WHERE mp.role_name = doom_caller())")
# A frame's session, as LBDoom's render threads (engine.py SESSION_SETTINGS):
# no JIT (planning a frame with it cost more than the frame), one generic plan.
SESSION_SQL = ("SET jit = off", "SET plan_cache_mode = force_generic_plan", "SET work_mem = '8MB'")


class FrameStream:
    """One tab's frames: a clock thread, render threads, and the sender
    (an asyncio task on the app's loop)."""

    def __init__(self, loop, endpoint, player, metrics):
        self.loop, self.endpoint, self.player, self.metrics = loop, endpoint, player, metrics
        self.view = None
        self.paused = False
        self.stamp = False            # the page asked for input stamps
        self.target = 2
        self.stop = threading.Event()
        self.slots = queue.Queue()
        self.lock = threading.Lock()
        self.idle = 0                 # render threads waiting for a slot
        self.owed = 0                 # slots kept for the next thread free (at most 2)
        self.seq = 0
        self.workers = []             # [thread, retire Event]
        self.out = asyncio.Queue()
        self.stat = {"slots": 0, "full": 0, "frames": 0, "db": 0.0, "on_tic": 0}
        self.errors = 0
        self.on_tic = ON_TIC and hasattr(metrics, "wait_tic")
        self.busy = 0                 # render threads inside a frame now
        self.done = []                # (wall0, wall1, ms, busy at start) for the slow-frame lines
        self.recent_ms = []           # the last 300 frame times, for the median
        self.sent_bytes = 0           # frame bytes handed to the socket (before its deflate)

    # ------------------------------------------------------------- control
    def configure(self, msg):
        if "view" in msg:
            v = str(msg["view"])
            if ALLOWED_RE.fullmatch(f"SELECT frame_rgb FROM {v}"):
                self.view = v
        if "pause" in msg:
            self.paused = bool(msg["pause"])
        if "stamp" in msg:
            self.stamp = bool(msg["stamp"])
        if "conns" in msg:
            try:
                self.resize(int(msg["conns"]))
            except (TypeError, ValueError):
                pass

    def resize(self, n):
        n = max(1, min(MAX_CONNS, n))
        with self.lock:
            self.target = n
            live = [w for w in self.workers if not w[1].is_set() and w[0].is_alive()]
            for w in live[n:]:
                w[1].set()
            for _ in range(n - len(live[:n])):
                retire = threading.Event()
                t = threading.Thread(target=self._render, args=(retire,), daemon=True, name="frames-render")
                self.workers.append([t, retire])
                t.start()
            self.workers = [w for w in self.workers if w[0].is_alive() or not w[1].is_set()]

    def live_conns(self):
        with self.lock:
            return sum(1 for t, r in self.workers if t.is_alive() and not r.is_set())

    def start(self):
        threading.Thread(target=self._clock, daemon=True, name="frames-clock").start()
        self.resize(self.target)

    def close(self):
        self.stop.set()
        with self.lock:
            for w in self.workers:
                w[1].set()

    # ---------------------------------------------------------------- clock
    def _clock(self):
        """One slot per committed tic (or every 1/35 s without ON_TIC) to
        whichever render thread is free; a slot no thread can take is owed (at
        most 2) to the next free one, past that it counts as pool full (the
        page's auto setting reads it). Several tics since the last slot: one
        slot, the frame draws the newest."""
        interval = 1.0 / MAX_FPS
        at = time.perf_counter()
        seen = self.metrics.tic_count if self.on_tic else 0
        last_tic_at = time.perf_counter()
        while not self.stop.is_set():
            on_tic = False
            if self.on_tic:
                now = time.perf_counter()
                idle = now - last_tic_at > IDLE_S
                count = self.metrics.wait_tic(seen, (1.0 / IDLE_HZ) if idle else IDLE_S)
                if count > seen:
                    seen, last_tic_at, on_tic = count, time.perf_counter(), True
                elif not (time.perf_counter() - last_tic_at > IDLE_S):
                    continue
            else:
                at = max(at + interval, time.perf_counter() - interval)
                delay = at - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
            if self.paused or self.view is None:
                continue
            with self.lock:
                self.stat["slots"] += 1
                self.stat["on_tic"] += on_tic
                if self.idle > 0:
                    self.idle -= 1
                    self.slots.put(1)
                elif self.owed < 2:
                    self.owed += 1
                else:
                    self.stat["full"] += 1

    def _claim(self, retire):
        with self.lock:
            if self.owed > 0:
                self.owed -= 1
                return True
            self.idle += 1
        while not (self.stop.is_set() or retire.is_set()):
            try:
                self.slots.get(timeout=0.25)
                return True
            except queue.Empty:
                continue
        with self.lock:
            self.idle = max(0, self.idle - 1)
        return False

    # ------------------------------------------------------------- render
    def _connect(self):
        options = SESSION_OPTIONS + (f" -c doom.player={self.player}" if self.player else "")
        conn = psycopg2.connect(CREDS.dsn(self.endpoint, application_name="doom-frames"), options=options)
        conn.autocommit = True
        cur = conn.cursor()
        for s in SESSION_SQL:
            cur.execute(s)
        cur.execute("PREPARE frames_cam AS SELECT api_camera(1.0)")
        return conn, cur

    def _render(self, retire):
        # The frame views read the camera from player_state (the newest tic),
        # so no api_camera write per frame; it still runs about once a second
        # (per thread), for the seat's last_seen, which the seat reaper reads.
        # A game created before that keeps its views, which read mp_players'
        # pose: for those, api_camera before every frame as before.
        conn = cur = None
        prepared = {}
        reads_state = {}
        cam_at = 0.0
        while not (self.stop.is_set() or retire.is_set()):
            try:
                if conn is None:
                    conn, cur = self._connect()
                    prepared = {}
                if not self._claim(retire):
                    break
                view, stamped = self.view, self.stamp
                if view is None:
                    continue
                with self.lock:
                    self.seq += 1
                    seq = self.seq
                name = prepared.get((view, stamped))
                if name is None:
                    name = f"frames_{len(prepared)}"
                    if stamped:
                        cur.execute(f"PREPARE {name} AS SELECT f.frame_rgb, {STAMP_SQL} FROM {view} f")
                    else:
                        cur.execute(f"PREPARE {name} AS SELECT frame_rgb FROM {view}")
                    prepared[(view, stamped)] = name
                if view not in reads_state:
                    # the old views read mp_players.pose_x (pg_get_viewdef
                    # reformats a view's text, so look for the column)
                    cur.execute("SELECT pg_get_viewdef(%s::regclass) !~ 'pose_x'", (f"doom.{view}",))
                    reads_state[view] = bool(cur.fetchone()[0])
                t0 = time.perf_counter()
                if not reads_state.get(view) or t0 - cam_at >= 1.0:
                    cur.execute("EXECUTE frames_cam")
                    cam_at = t0
                    t0 = time.perf_counter()
                with self.lock:
                    others = self.busy
                    self.busy += 1
                w0 = time.time()
                try:
                    cur.execute(f"EXECUTE {name}")
                    row = cur.fetchone()
                finally:
                    with self.lock:
                        self.busy -= 1
                ms = (time.perf_counter() - t0) * 1000
                if SLOW_LOG:
                    with self.lock:
                        self.done.append((w0, time.time(), ms, others))
                        if len(self.done) > 2000:
                            del self.done[:1000]
                frame = bytes(row[0]) if row and row[0] is not None else None
                stamp = int(row[1]) if stamped and row and len(row) > 1 and row[1] is not None else None
                if frame is not None:
                    self.metrics.frame("primary", ms)
                self.loop.call_soon_threadsafe(self.out.put_nowait, (seq, ms, frame, stamp))
            except Exception as exc:  # noqa: BLE001 - a render thread must not die on one frame
                self.errors += 1
                if self.errors <= 5 or self.errors % 100 == 0:
                    log(f"frames {self.player}: {str(exc).splitlines()[0][:160]}")
                try:
                    conn and conn.close()
                except Exception:
                    pass
                conn = cur = None
                time.sleep(0.5)
        try:
            conn and conn.close()
        except Exception:
            pass

    # ------------------------------------------------------------- sender
    async def send(self, ws):
        """Newest frame first: one that finished after a newer one is dropped.
        XOR against the previous frame sent of the same length."""
        last_seq, prev, mark = 0, {}, time.perf_counter()
        sent = 0
        while True:
            try:
                seq, ms, frame, stamp = await asyncio.wait_for(self.out.get(), timeout=1.0)
            except asyncio.TimeoutError:
                seq = None
            if seq is not None and seq > last_seq:
                last_seq = seq
                if frame is None:
                    await ws.send_bytes(HEADER.pack(seq, int(ms * 100), F_NULL))
                else:
                    p = prev.get(len(frame))
                    prev[len(frame)] = frame
                    if p is None:
                        payload, flags = frame, 0
                    else:
                        payload = (int.from_bytes(frame, "big") ^ int.from_bytes(p, "big")).to_bytes(len(frame), "big")
                        flags = F_DELTA
                    if stamp is None:
                        msg = HEADER.pack(seq, int(ms * 100), flags) + payload
                    else:
                        msg = HEADER_STAMPED.pack(seq, int(ms * 100), flags | F_STAMP, max(0, stamp)) + payload
                    await ws.send_bytes(msg)
                    self.sent_bytes += len(msg)
                    sent += 1
                    self.stat["frames"] += 1
                    self.stat["db"] += ms
            now = time.perf_counter()
            if now - mark >= 1.0:
                if SLOW_LOG:
                    self._slow_line()
                with self.lock:
                    st = dict(self.stat)
                    self.stat = {"slots": 0, "full": 0, "frames": 0, "db": 0.0, "on_tic": 0}
                await ws.send_text(json.dumps({"stats": {
                    "fps": round(st["frames"] / (now - mark), 1),
                    "pool_full": round(st["full"] / st["slots"], 3) if st["slots"] else None,
                    "db_ms": round(st["db"] / st["frames"], 1) if st["frames"] else None,
                    "on_tic": round(st["on_tic"] / st["slots"], 3) if st["slots"] else None,
                    "bytes": self.sent_bytes,
                    "conns": self.live_conns()}}))
                mark = now


    def _slow_line(self):
        """Frames done at least 0.3 s ago (their tics have reported by then):
        one line if any was over SLOW_X x the median of the last 300."""
        cutoff = time.time() - 0.3
        with self.lock:
            ready = [d for d in self.done if d[1] <= cutoff]
            self.done = [d for d in self.done if d[1] > cutoff]
        if not ready:
            return
        self.recent_ms = (self.recent_ms + [d[2] for d in ready])[-300:]
        if len(self.recent_ms) < 30 or not hasattr(self.metrics, "alongside"):
            return
        med = sorted(self.recent_ms)[len(self.recent_ms) // 2]
        slow = [d for d in ready if d[2] > SLOW_X * med]
        if not slow:
            return
        normal = [d for d in ready if d[2] <= SLOW_X * med]

        def side(group):
            tic, maint = 0.0, {}
            for w0, w1, _, _ in group:
                t, m = self.metrics.alongside(w0, w1)
                tic += t
                for label in m:
                    maint[label] = maint.get(label, 0) + 1
            return tic / len(group), maint
        s_tic, s_maint = side(slow)
        n_tic, n_maint = side(normal) if normal else (None, {})
        worst = max(slow, key=lambda d: d[2])
        log(f"frames slow {self.player}: {len(slow)}/{len(ready)} over {SLOW_X:g}x median {med:.0f} ms, "
            f"worst {worst[2]:.0f} ms at {time.strftime('%H:%M:%S', time.gmtime(worst[0]))}.{int(worst[0] % 1 * 1000):03d}; "
            f"tic overlap {s_tic:.0f} ms (normal frames {'-' if n_tic is None else f'{n_tic:.0f}'} ms); "
            f"other frames at start {sum(d[3] for d in slow) / len(slow):.1f} "
            f"(normal {'-' if not normal else f'{sum(d[3] for d in normal) / len(normal):.1f}'}); "
            f"maintenance alongside: {', '.join(f'{k} x{v}' for k, v in s_maint.items()) or 'none'}"
            + (f" (normal frames: {', '.join(f'{k} x{v}' for k, v in n_maint.items())})" if n_maint else ""))


async def serve(ws, games, game_id):
    """One tab's frame socket, for a player the game lets in (as the relay)."""
    if not game_id or games is None:
        await ws.close(code=1008, reason="which game? (/frames?game=<id>)")
        return
    player = player_identity(ws)
    try:
        endpoint = games.endpoint_for(game_id, player)
        metrics = games.game(game_id).metrics
    except Exception as exc:
        await ws.close(code=1008, reason=str(exc)[:120])
        return
    await ws.accept()
    stream = FrameStream(asyncio.get_running_loop(), endpoint, player, metrics)
    stream.start()
    started = time.perf_counter()
    log(f"{getattr(ws.client, 'host', '?')} frames open for {player or 'app identity'}")

    async def control():
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return
            if msg.get("text"):
                try:
                    stream.configure(json.loads(msg["text"]))
                except (ValueError, TypeError):
                    pass

    tasks = [asyncio.create_task(control()), asyncio.create_task(stream.send(ws))]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        stream.close()
        try:
            await ws.close(code=1000)
        except Exception:
            pass
        log(f"frames for {player or 'app identity'} closed after {time.perf_counter() - started:.0f} s, "
            f"{stream.errors} errors")
