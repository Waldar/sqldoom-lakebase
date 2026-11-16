"""What the demo shows next to each render pane: the cost of a game tic, the
cost of a frame, and how far behind the primary each pane's endpoint is.

  tic   -- measured in the referee process around every doom_sql.mp_tic call
           (the whole tic transaction, client side), sent here over a queue
  frame -- measured in the relay: from the browser's Sync to the server's
           ReadyForQuery, for requests whose answer carried a frame
  lag   -- polled: the newest level tic each endpoint can see, minus the
           primary's (0 on the primary itself; replication lag on a replica)
"""
import asyncio
import threading
import time
from collections import deque

import psycopg2

TIC_HZ = 35
BUDGET_MS = 1000.0 / TIC_HZ           # 28.6 ms: a tic must fit in its slot
LAG_POLL_S = 0.25
_LAG_SQL = ("SELECT COALESCE(max(ps.level_tics), -1), pg_is_in_recovery() "
            "FROM player_state ps JOIN mp_match m ON m.map_id = ps.map_id")


def _stats(samples, now, window_s):
    """p50/p99/max over the samples (t, ms) of the last window_s seconds."""
    ms = sorted(v for t, v in samples if t >= now - window_s)
    if not ms:
        return {"n": 0, "per_s": 0.0, "p50_ms": None, "p75_ms": None, "p90_ms": None, "p99_ms": None, "max_ms": None}
    return {"n": len(ms), "per_s": round(len(ms) / window_s, 2),
            "p50_ms": round(ms[len(ms) // 2], 2),
            "p75_ms": round(ms[min(len(ms) - 1, int(len(ms) * 0.75))], 2),   # the page's frame pacing
            "p90_ms": round(ms[min(len(ms) - 1, int(len(ms) * 0.9))], 2),
            "p99_ms": round(ms[min(len(ms) - 1, int(len(ms) * 0.99))], 2),
            "max_ms": round(ms[-1], 2)}


class Metrics:
    def __init__(self):
        self._lock = threading.Lock()
        self.tics = deque(maxlen=TIC_HZ * 300)     # (wall time, ms)
        self.tic_failures = deque(maxlen=1000)     # wall times of failed tics
        self.frames = {}                           # pane -> deque((wall time, ms))
        self.connections = {}                      # pane -> open browser tunnels
        self.lag = {}                              # pane -> latest poll result
        self.referee = {"state": "off", "restarts": 0, "last_exit": None, "since": None}
        # The loading screen between two maps (doomapp/referee.py _say): the
        # referee's steps and VACUUM lines, shown by the page over the game.
        self._between = {"active": False, "title": "", "lines": [], "since": None, "ended": None}

    # ----------------------------------------------------------- writers
    def tic(self, wall, ms, ok):
        with self._lock:
            if ok:
                self.tics.append((wall, ms))
            else:
                self.tic_failures.append(wall)

    def frame(self, pane, ms):
        with self._lock:
            self.frames.setdefault(pane, deque(maxlen=5000)).append((time.time(), ms))

    def tunnel(self, pane, delta):
        with self._lock:
            self.connections[pane] = self.connections.get(pane, 0) + delta

    def between(self, wall, kind, text):
        with self._lock:
            b = self._between
            if kind == "begin":
                b.update(active=True, title=text, lines=[], since=wall, ended=None)
            elif kind == "end":
                b["lines"].append(text)
                b.update(active=False, ended=wall)
            else:
                b["lines"] = (b["lines"] + [text])[-60:]

    def referee_state(self, state, exitcode=None):
        with self._lock:
            r = self.referee
            if state == "starting" and r["state"] == "exited":
                r["restarts"] += 1
            if exitcode is not None:
                r["last_exit"] = exitcode
            r["state"], r["since"] = state, time.time()

    # ----------------------------------------------------------- reader
    def snapshot(self, window_s=10.0):
        now = time.time()
        with self._lock:
            tics = list(self.tics)
            failed = sum(1 for t in self.tic_failures if t >= now - window_s)
            frames = {p: list(d) for p, d in self.frames.items()}
            panes = set(frames) | set(self.connections) | set(self.lag)
            out = {"at": now, "window_s": window_s, "budget_ms": round(BUDGET_MS, 2),
                   "referee": dict(self.referee),
                   "between": dict(self._between, lines=list(self._between["lines"]))}
            tic = _stats(tics, now, window_s)
            tic["over_budget"] = sum(1 for t, v in tics if t >= now - window_s and v > BUDGET_MS)
            tic["failed"] = failed
            out["tic"] = tic
            out["panes"] = {}
            for p in sorted(panes):
                f = _stats(frames.get(p, ()), now, window_s)
                f["fps"] = f.pop("per_s")
                out["panes"][p] = {"connections": self.connections.get(p, 0), "frame": f,
                                   **self.lag.get(p, {})}
        return out


METRICS = Metrics()


async def poll_lag(endpoint_map, creds, metrics=METRICS):
    """Every LAG_POLL_S: the newest level tic on every endpoint, queried at
    the same moment; lag = primary's minus the endpoint's."""
    conns = {}

    def probe(pane, endpoint):
        conn = conns.get(pane)
        try:
            if conn is None or conn.closed:
                conn = conns[pane] = psycopg2.connect(creds.dsn(endpoint, f"sqldoom-lag-{pane}"))
                conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(_LAG_SQL)
                tic, standby = cur.fetchone()
            return {"level_tic": tic, "standby": standby, "error": None}
        except Exception as exc:          # psycopg2 errors, and token/SDK errors on reconnect
            conns.pop(pane, None)
            try:
                if conn is not None:
                    conn.close()
            except psycopg2.Error:
                pass
            return {"level_tic": None, "error": str(exc).splitlines()[0][:200]}

    try:
        while True:
            panes = list(endpoint_map.items())
            results = await asyncio.gather(*(asyncio.to_thread(probe, p, ep) for p, ep in panes))
            seen = dict(zip((p for p, _ in panes), results))
            head = seen.get("primary", {}).get("level_tic")
            with metrics._lock:
                for pane, r in seen.items():
                    lag = (head - r["level_tic"]) if head is not None and r["level_tic"] is not None else None
                    metrics.lag[pane] = {"level_tic": r["level_tic"], "standby": r.get("standby"),
                                         "lag_tics": lag,
                                         "lag_ms": None if lag is None else round(lag * BUDGET_MS, 1),
                                         "lag_error": r["error"]}
            await asyncio.sleep(LAG_POLL_S)
    finally:
        for conn in conns.values():
            try:
                conn.close()
            except psycopg2.Error:
                pass
