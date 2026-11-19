"""Browser <-> Lakebase relay: the game page's Postgres connection.

The game page (web/game/app.js + web/game/pgwire.js) speaks the Postgres
protocol over a WebSocket at /pg?game=<id>. The relay tunnels it to the
game's Lakebase endpoint:

  * Login is done here, with OAuth. The relay opens TLS to the Lakebase
    endpoint and logs in as the app's identity with a fresh OAuth token. The
    browser's own startup message is swallowed and answered with
    AuthenticationOk plus the real session's ParameterStatus / BackendKeyData /
    ReadyForQuery. The browser never sees a password or token. With ?guest=1
    the page is first told the role it plays as.
  * Statement allowlist. Every browser session runs as the app identity, which
    has more than the api_* grants a player needs. So only the SQL
    text web/game/app.js uses may be parsed or run (Query / Parse messages; Bind and
    Execute only reach statements that passed Parse). Anything else ends the
    tunnel with an ErrorResponse.
  * Frame timing. The relay times each request from the browser's Sync (or
    Query) to the server's ReadyForQuery, and records the time when the answer
    carried a frame. This is the frame's cost as seen next to the database,
    without the browser's network leg.

Compression is the WebSocket server's permessage-deflate (uvicorn +
websockets). With the "pg-delta" subprotocol, frames are delta-coded
(DeltaCoder below; pgwire.js decodes them).
"""
import asyncio
import json
import re
import struct
import time
from collections import deque

from sqldoom.lakebase.connection import AUTH_OK, CREDS, error_response, open_session

DELTA_MIN = 32768   # a binary column at least this long is a frame worth delta-coding


class DeltaCoder:
    """XOR large DataRow columns against the previous one of the same length.
    Both ends see the same ordered stream, so "previous" means the same thing
    on both sides; the first frame of each size goes through unchanged."""

    def __init__(self):
        self.buf = bytearray()
        self.prev = {}
        self.frames = 0

    def feed(self, chunk):
        self.buf.extend(chunk)
        out = bytearray()
        while len(self.buf) >= 5:
            length = int.from_bytes(self.buf[1:5], "big")
            if len(self.buf) < 1 + length:
                break
            msg = bytes(self.buf[:1 + length])
            del self.buf[:1 + length]
            out.extend(self._code(msg) if msg[0] == 0x44 else msg)   # 'D'
        return bytes(out)

    def _code(self, msg):
        ncols = int.from_bytes(msg[5:7], "big")
        if ncols != 1:
            return msg
        clen = int.from_bytes(msg[7:11], "big", signed=True)
        if clen < DELTA_MIN or 11 + clen != len(msg):
            return msg
        cell = msg[11:]
        prev = self.prev.get(clen)
        self.prev[clen] = cell
        self.frames += 1
        if prev is None:
            return msg
        coded = (int.from_bytes(cell, "big") ^ int.from_bytes(prev, "big")).to_bytes(clen, "big")
        return msg[:11] + coded


def log(message):
    print(f"[relay {time.strftime('%H:%M:%S')}] {message}", flush=True)


# ------------------------------------------------------------- allowlist
# The statements web/app.js prepares or runs, verbatim.
ALLOWED_SQL = frozenset({
    "SELECT pal, idx, r, g, b FROM api_palettes",
    "SELECT name, wav_data FROM sound_assets",
    "SELECT api_join()",
    "SELECT api_slot()",
    "SELECT api_set_name($1)",
    "SELECT slot, role_name, connected, frags, health, alive, login FROM api_scoreboard",
    "SELECT state, map_name, level_tics, timer_tics, intermission_seconds, next_map, map_id, "
    "waiting, ahead_of_me, hold_seconds FROM api_match",
    "SELECT alive, health, frags, position_x, position_y FROM api_player_state",
    "SELECT api_automap()",
    "SELECT api_automap_pan($1,$2)",
    "SELECT api_automap_zoom($1)",
    "SELECT api_automap_toggle($1)",
    "SELECT api_automap_fit()",
    "SELECT api_input($1,$2,$3,$4,$5,$6,$7)",
    "SELECT api_camera($1)",
    "SELECT 1",                     # render connection ping (frame time breakdown)
    "SELECT event_id, sound_name, volume, pan FROM api_sound_events WHERE event_id > $1 ORDER BY event_id",
    "SELECT COALESCE(MAX(event_id), 0) FROM api_sound_events",
    "SELECT loop_key, sound_name, volume, pan FROM api_sound_loops",
    "SELECT name, audio_data, audio_format FROM api_stage_music",
    "SELECT api_weapon_slot($1)",
    "SELECT api_weapon_cycle($1)",
    "SELECT api_cheat_key($1)",       # single player only (the function checks)
    "SELECT name, audio_data, audio_format FROM api_music_track($1)",   # idmus
    "SELECT x1, y1, x2, y2, solid FROM api_map_geometry",
    "SELECT kind, name, x, y, angle, alive FROM api_things_live WHERE map_id = $1",
})
ALLOWED_RE = re.compile(r"SELECT frame_rgb FROM api_frame_idx_slot[1-4]_m\d{1,3}(_low)?")
# Frontend messages a page may send: Query, Parse, Bind, Execute, Describe,
# Close, Sync, Flush, Terminate. No COPY, no FunctionCall.
ALLOWED_KINDS = frozenset(b"QPBEDCSHX")


class Refused(Exception):
    pass


def _message(kind, body):
    return kind + struct.pack("!i", len(body) + 4) + body


def _cstring(msg, off):
    end = msg.index(0, off)
    return msg[off:end].decode("utf-8", "replace"), end + 1


def check_statement(sql):
    if sql in ALLOWED_SQL or ALLOWED_RE.fullmatch(sql):
        return sql
    raise Refused(f"statement not allowed through the app relay: {sql[:120]!r}")


def check_message(msg):
    """One whole frontend message -> the message to forward (maybe rewritten)."""
    kind = msg[0]
    if kind not in ALLOWED_KINDS:
        raise Refused(f"protocol message {chr(kind)!r} not allowed through the app relay")
    if kind == ord("Q"):
        sql, _ = _cstring(msg, 5)
        new = check_statement(sql)
        return msg if new == sql else _message(b"Q", new.encode() + b"\0")
    if kind == ord("P"):
        name, off = _cstring(msg, 5)
        sql, rest = _cstring(msg, off)
        new = check_statement(sql)
        return msg if new == sql else _message(b"P", name.encode() + b"\0" + new.encode() + b"\0" + msg[rest:])
    return msg


# ---------------------------------------------------------- frame timing
class FrameWatch(DeltaCoder):
    """DeltaCoder that also times requests. Each Sync or Query the
    browser sends starts a clock; the ReadyForQuery that answers it stops it,
    and the time counts as a frame if the answer carried a frame-sized column."""

    def __init__(self, delta, on_frame):
        super().__init__()
        self.delta = delta
        self.on_frame = on_frame
        self.sent = deque()
        self.big = False
        # Each frame's relay-side time, sent back to the browser as a text
        # frame {"frame_ms": ...} after the frame's bytes, so the page can
        # split its own frame time into database and network parts. Clients
        # that don't know the message ignore it (pgwire.js drops unknown text
        # frames after login).
        self.timings = deque()
        # Relay idle: from the moment the last answer was forwarded (nothing
        # outstanding) to the next request's first Sync. Minus the browser's
        # own wait over the same span, that is this connection's round trip.
        self.idle_since = None
        self.last_idle = None
        # Requests are pipelined (render_pool.js: camera + frame, and two
        # frames per connection): one that waited behind the previous answer
        # is timed from that answer's ReadyForQuery, not from its own Sync.
        self.last_ready = 0.0

    def feed(self, chunk):
        self.buf.extend(chunk)
        out = bytearray()
        while len(self.buf) >= 5:
            length = int.from_bytes(self.buf[1:5], "big")
            if len(self.buf) < 1 + length:
                break
            msg = bytes(self.buf[:1 + length])
            del self.buf[:1 + length]
            if msg[0] == 0x44:                                   # DataRow
                if (int.from_bytes(msg[5:7], "big") == 1
                        and int.from_bytes(msg[7:11], "big", signed=True) >= DELTA_MIN):
                    self.big = True
                if self.delta:
                    msg = self._code(msg)
            elif msg[0] == 0x5A and self.sent:                   # ReadyForQuery
                now = time.perf_counter()
                ms = (now - max(self.sent.popleft(), self.last_ready)) * 1000
                self.last_ready = now
                if self.big:
                    self.on_frame(ms)
                    self.timings.append(ms)
                self.big = False
                if not self.sent:
                    self.idle_since = time.perf_counter()
            out.extend(msg)
        return bytes(out)


# ---------------------------------------------------------------- tunnel
class _Closed(Exception):
    pass


class Tunnel:
    def __init__(self, ws, pane, reader, writer, watch):
        self.ws, self.pane = ws, pane
        self.reader, self.writer = reader, writer
        self.watch = watch
        self.inbound = bytearray()
        self.raw_out = self.raw_in = 0

    async def _recv(self):
        msg = await self.ws.receive()
        if msg["type"] == "websocket.disconnect":
            raise _Closed()
        return msg.get("bytes") or b""          # text frames from the page carry nothing for us

    async def startup(self, tail):
        """Swallow the browser's StartupMessage; answer with our login's outcome."""
        while True:
            while len(self.inbound) < 8:
                self.inbound.extend(await self._recv())
            n = int.from_bytes(self.inbound[:4], "big")
            while len(self.inbound) < n:
                self.inbound.extend(await self._recv())
            code = int.from_bytes(self.inbound[4:8], "big")
            del self.inbound[:n]
            if code == 80877103:                 # SSLRequest: no TLS on this leg (the app's HTTPS is)
                await self.ws.send_bytes(b"N")
                continue
            if code >> 16 != 3:
                raise Refused(f"unsupported startup code {code}")
            await self.ws.send_bytes(AUTH_OK + tail)
            return

    async def ws_to_db(self):
        while True:
            self.inbound.extend(await self._recv())
            out = bytearray()
            while len(self.inbound) >= 5:
                length = int.from_bytes(self.inbound[1:5], "big")
                if len(self.inbound) < 1 + length:
                    break
                msg = bytes(self.inbound[:1 + length])
                del self.inbound[:1 + length]
                msg = check_message(msg)
                if msg[0] in (0x53, 0x51):       # Sync, Query: a ReadyForQuery will answer
                    now = time.perf_counter()
                    w = self.watch
                    if not w.sent and w.idle_since is not None:
                        w.last_idle = (now - w.idle_since) * 1000
                        w.idle_since = None
                    w.sent.append(now)
                out.extend(msg)
                if msg[0] == 0x58:               # Terminate
                    self.writer.write(bytes(out))
                    await self.writer.drain()
                    return
            if out:
                self.raw_in += len(out)
                self.writer.write(bytes(out))
                await self.writer.drain()

    async def db_to_ws(self):
        while True:
            chunk = await self.reader.read(65536)
            if not chunk:
                return
            out = self.watch.feed(chunk)
            if out:
                self.raw_out += len(out)
                await self.ws.send_bytes(out)
            while self.watch.timings:
                await self.ws.send_text(json.dumps({"frame_ms": round(self.watch.timings.popleft(), 2),
                                                    "idle_ms": None if self.watch.last_idle is None
                                                    else round(self.watch.last_idle, 2)}))


# ------------------------------------------------------------- identity
_ID_UNSAFE = re.compile(r"[^A-Za-z0-9@._+-]")
_TAB_RE = re.compile(r"[a-z0-9]{1,12}")


def player_identity(ws):
    """The player a tunnel plays as: the signed-in user (Databricks Apps puts
    it in X-Forwarded-Email) plus the browser tab's token (?tab=, from the
    page's sessionStorage), so two tabs are two players. Every connection of
    one tab (control + render pool) carries the same
    token, so they all resolve to the same seat. A page can only pick the
    tab part: the user part comes from the proxy."""
    return identity_from(ws.headers, ws.query_params.get("tab", ""))


def identity_from(h, tab):
    """player_identity from request headers and a tab token (also used by
    the HTTP endpoints, e.g. the rules: same player, same string)."""
    user = (h.get("x-forwarded-email") or h.get("x-forwarded-preferred-username")
            or h.get("x-forwarded-user") or "")
    user = _ID_UNSAFE.sub("", user)[:96]
    if not user:
        return None                      # no proxy (local run): the session user plays
    tab = tab or ""
    return f"{user}#{tab}" if _TAB_RE.fullmatch(tab) else user


async def serve(ws, pane, guest, endpoint_map, metrics, games=None, game_id=""):
    """One browser WebSocket, bridged to one Lakebase session on the game's
    endpoint (one branch per game, sqldoom.lakebase.games), only for a player
    the game lets in (a solo game: its owner)."""
    if not game_id or games is None or pane != "primary":
        await ws.close(code=1008, reason="which game? (/pg?game=<id>)")
        return
    try:
        endpoint = games.endpoint_for(game_id, player_identity(ws))
        metrics = games.game(game_id).metrics
    except Exception as exc:
        log(f"{getattr(ws.client, 'host', '?')} game {game_id} refused: {exc}")
        await ws.close(code=1008, reason=str(exc)[:120])
        return
    delta = "pg-delta" in ws.scope.get("subprotocols", [])
    await ws.accept(subprotocol="pg-delta" if delta else None)
    peer = getattr(ws.client, "host", "?")
    try:
        player = player_identity(ws)
        reader, writer, tail = await open_session(endpoint, f"doom-web-{pane}", player=player)
    except Exception as exc:
        reason = f"cannot log in to Lakebase ({pane}): {exc}"
        log(f"{peer} {reason}")
        try:
            if guest:
                await ws.send_text(json.dumps({"error": reason}))
            else:
                await ws.send_bytes(error_response(reason))
            await ws.close(code=1011)
        except Exception:
            pass
        return
    tunnel = Tunnel(ws, pane, reader, writer, FrameWatch(delta, lambda ms: metrics.frame(pane, ms)))
    metrics.tunnel(pane, +1)
    started = time.perf_counter()
    why = "closed"
    tasks = []
    try:
        if guest:
            await ws.send_text(json.dumps({"user": player or CREDS.user(), "password": ""}))
        await tunnel.startup(tail)
        log(f"{peer} tunnel open -> {pane} as {player or 'app identity'} (delta frames {'on' if delta else 'off'})")
        tasks = [asyncio.create_task(tunnel.ws_to_db()), asyncio.create_task(tunnel.db_to_ws())]
        done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for t in done:
            if t.exception() is not None:
                raise t.exception()
    except Refused as exc:
        why = f"refused: {exc}"
        try:
            await ws.send_bytes(error_response(str(exc), code="42501", severity="ERROR"))
        except Exception:
            pass
    except (_Closed, ConnectionError, asyncio.IncompleteReadError):
        pass
    except Exception as exc:
        why = f"error: {exc!r}"
    finally:
        for t in tasks:
            t.cancel()
        writer.close()
        metrics.tunnel(pane, -1)
        try:
            await ws.close(code=1000)
        except Exception:
            pass
        log(f"{peer} tunnel {pane} {why} after {time.perf_counter() - started:.0f} s: "
            f"db->browser {tunnel.raw_out / 1e6:.1f} MB raw, {tunnel.watch.frames} frames delta-coded, "
            f"browser->db {tunnel.raw_in / 1e3:.0f} KB")
