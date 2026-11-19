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
      "conns": 2, "pause": false}; view must match the relay's frame views
      (relay.ALLOWED_RE), conns 1..6 render threads, pause stops the clock
      (loading screen, automap).
  app -> page, binary: 9-byte header (seq u32, database ms x 100 u32,
      flags u8: 1 = XOR against the previous frame of the same length,
      2 = no frame, the view returned NULL: the seat is gone or the map
      changed), then the frame's bytes.
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
HEADER = struct.Struct(">IIB")
F_DELTA, F_NULL = 1, 2
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
        self.sent_bytes = 0           # frame bytes handed to the socket (before its deflate)

    # ------------------------------------------------------------- control
    def configure(self, msg):
        if "view" in msg:
            v = str(msg["view"])
            if ALLOWED_RE.fullmatch(f"SELECT frame_rgb FROM {v}"):
                self.view = v
        if "pause" in msg:
            self.paused = bool(msg["pause"])
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
                view = self.view
                if view is None:
                    continue
                with self.lock:
                    self.seq += 1
                    seq = self.seq
                name = prepared.get(view)
                if name is None:
                    name = f"frames_{len(prepared)}"
                    cur.execute(f"PREPARE {name} AS SELECT frame_rgb FROM {view}")
                    prepared[view] = name
                    # the old views read mp_players.pose_x (pg_get_viewdef
                    # reformats a view's text, so look for the column)
                    cur.execute("SELECT pg_get_viewdef(%s::regclass) !~ 'pose_x'", (f"doom.{view}",))
                    reads_state[view] = bool(cur.fetchone()[0])
                t0 = time.perf_counter()
                if not reads_state.get(view) or t0 - cam_at >= 1.0:
                    cur.execute("EXECUTE frames_cam")
                    cam_at = t0
                    t0 = time.perf_counter()
                cur.execute(f"EXECUTE {name}")
                row = cur.fetchone()
                ms = (time.perf_counter() - t0) * 1000
                frame = bytes(row[0]) if row and row[0] is not None else None
                if frame is not None:
                    self.metrics.frame("primary", ms)
                self.loop.call_soon_threadsafe(self.out.put_nowait, (seq, ms, frame))
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
                seq, ms, frame = await asyncio.wait_for(self.out.get(), timeout=1.0)
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
                    msg = HEADER.pack(seq, int(ms * 100), flags) + payload
                    await ws.send_bytes(msg)
                    self.sent_bytes += len(msg)
                    sent += 1
                    self.stat["frames"] += 1
                    self.stat["db"] += ms
            now = time.perf_counter()
            if now - mark >= 1.0:
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
