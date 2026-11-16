#!/usr/bin/env python3
"""SQLDoom on Lakebase -- Databricks App entry point.

  /             the page (upstream web/ for now; DOOM_WEB_ROOT overrides)
  /config.json  render targets (panes) and frame cap, in upstream doom_web.py's shape
  /pg           WebSocket: the page's Postgres connection to a pane (doomapp.relay)
  /api/metrics  tic cost, per-pane frame cost and lag (doomapp.metrics)
  /api/health   liveness
  /api/maps     maps the page may switch to; POST /api/match/map?name=E1M5|next
  POST /api/match/mode?choice=stay|solo   end of a deathmatch: play on or go solo
  GET  /api/match/rules?tab=...           both modes' rules, the mode, who is Player 1
  POST /api/match/rules?tab=...&mode=...  Player 1 changes a mode's rules (JSON body)
  POST /api/match/rules/use?tab=...&mode=solo|deathmatch   Player 1 alone picks the rule set

One Lakebase branch per game (doomapp/games.py, DOOM_GAMES=1, the default):
  POST /api/games?mode=solo|multi&tab=...&name=...   start a game (or get back this
                                        tab's live game of that mode); name = the host's
  GET  /api/games/mine?tab=...          this tab's live solo game, if any (menu: Resume)
  GET  /api/games/open?tab=...          multiplayer games with a free seat (menu: Join)
  POST /api/games/{id}/join?tab=...     check a seat is free in a multiplayer game
  GET  /api/games/{id}?tab=...          state and loading step; also keeps the game alive
  POST /api/games/{id}/away?on=1|0&tab=...   tab hidden / back: a solo game pauses
  POST /api/games/{id}/quit?tab=...     solo: end the game (referee stopped, branch deleted);
                                        multi: leave it, it goes on for the others
  /pg?game=<id>, /api/metrics, /api/match/* and the rules routes take ?game=<id>
  and then act on that game's branch instead of the shared match.

The referee (doomapp.referee) runs the game at 35 Hz on the primary for as
long as the app runs. Env: see doomapp/lakebase.py and doomapp/referee.py;
DOOM_REFEREE=0 serves the page without running the game, DOOM_MAX_FPS caps
the page's frame requests (default 35).

    python app.py            # uvicorn on $DATABRICKS_APP_PORT (default 8000)
"""
import asyncio
import os
import sys
from contextlib import asynccontextmanager
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from fastapi import Body, FastAPI, HTTPException, Request, WebSocket  # noqa: E402
from fastapi.responses import Response  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402

from doomapp import appjs_patch, relay, rules  # noqa: E402
from doomapp.lakebase import CREDS, endpoints  # noqa: E402
from doomapp.metrics import METRICS, poll_lag  # noqa: E402
from doomapp.referee import REFEREE_ENV, Referee  # noqa: E402
from doomapp.games import GameError, GameManager  # noqa: E402

WEB_ROOT = Path(os.getenv("DOOM_WEB_ROOT", HERE / "web"))
UPSTREAM_WEB = HERE / "sqldoom" / "web"
MAX_FPS = int(os.getenv("DOOM_MAX_FPS", "35"))
# Initial render pool size (1, 2, 4 or 6; default 4); the page's selector changes it live.
RENDER_CONNS = int(os.getenv("DOOM_RENDER_CONNS", "4"))
RUN_REFEREE = os.getenv("DOOM_REFEREE", "1") == "1"
ENDPOINTS = endpoints()
MAPS = [m.strip() for m in os.getenv("ROTATION", REFEREE_ENV["ROTATION"]).split(",") if m.strip()]
REFEREE = {"r": None}
GAMES = GameManager(CREDS) if os.getenv("DOOM_GAMES", "1") == "1" else None


def _game(game, request, tab):
    """The game a request names, checked against the caller; None = the shared match."""
    if not game:
        return None
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    try:
        GAMES.touch(game, relay.identity_from(request.headers, tab))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))
    return GAMES.game(game)


@asynccontextmanager
async def lifespan(_app):
    referee = Referee(ENDPOINTS["primary"], METRICS, CREDS) if RUN_REFEREE else None
    REFEREE["r"] = referee
    if referee:
        referee.start()
    if GAMES:
        try:
            await asyncio.to_thread(GAMES.start)
        except Exception as exc:          # the shared match still works without games
            print(f"[app] WARNING: games not available: {exc}", flush=True)
    poller = asyncio.create_task(poll_lag(ENDPOINTS, CREDS))
    try:
        yield
    finally:
        poller.cancel()
        if GAMES:
            await asyncio.to_thread(GAMES.stop)
        if referee:
            await asyncio.to_thread(referee.stop)


app = FastAPI(title="SQLDoom on Lakebase", lifespan=lifespan)


@app.get("/config.json")
def config():
    # guests=1: the page offers "play" without an account form; the relay
    # logs in with OAuth and tells the page which role it plays as.
    return {"targets": list(ENDPOINTS), "parallel": None, "max_fps": MAX_FPS,
            "guests": 1, "guests_free": 1,
            "render_conns": RENDER_CONNS if RENDER_CONNS in appjs_patch.POOL_SIZES else 4}


@app.get("/api/metrics")
def metrics(request: Request, window: float = 10.0, game: str = "", tab: str = ""):
    g = _game(game, request, tab)
    return (g.metrics if g else METRICS).snapshot(max(1.0, min(window, 300.0)))


@app.get("/api/health")
def health():
    return {"ok": True, "referee": METRICS.referee["state"], "panes": list(ENDPOINTS),
            "games": GAMES.snapshot() if GAMES else None}


# ------------------------------------------------------------ games
@app.post("/api/games")
def new_game(request: Request, mode: str = "solo", tab: str = "", name: str = ""):
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    try:
        return GAMES.create(mode, relay.identity_from(request.headers, tab), title=name.strip()[:12])
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.get("/api/games/mine")
def my_game(request: Request, tab: str = ""):
    if GAMES is None:
        return {"game": None, "enabled": False}
    me = relay.identity_from(request.headers, tab)
    return {"game": GAMES.mine(me), "multi": GAMES.mine(me, "multi"), "enabled": True,
            "template": GAMES.template_state}


@app.get("/api/games/open")
def open_games(request: Request, tab: str = ""):
    if GAMES is None:
        return {"games": []}
    return {"games": GAMES.open_games(relay.identity_from(request.headers, tab))}


@app.post("/api/games/{game_id}/join")
def join_game(request: Request, game_id: str, tab: str = ""):
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    try:
        return GAMES.join(game_id, relay.identity_from(request.headers, tab))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.get("/api/games/{game_id}")
def game_state(request: Request, game_id: str, tab: str = ""):
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    g = GAMES.game(game_id)
    try:
        if g is not None and g.state == "ready":
            return GAMES.touch(game_id, relay.identity_from(request.headers, tab))
        if g is not None and g.mode == "solo" and g.owner != relay.identity_from(request.headers, tab):
            raise GameError(403, "not your game")
        return GAMES.get(game_id)
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.post("/api/games/{game_id}/away")
def game_away(request: Request, game_id: str, on: int = 1, tab: str = ""):
    """The page's tab went to the background (on=1) or came back (on=0):
    a single-player game pauses meanwhile; a multiplayer game goes on."""
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    try:
        return GAMES.away(game_id, relay.identity_from(request.headers, tab), bool(on))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.post("/api/games/{game_id}/quit")
def quit_game(request: Request, game_id: str, tab: str = ""):
    if GAMES is None:
        raise HTTPException(404, "games are off (DOOM_GAMES=0)")
    try:
        return GAMES.end(game_id, relay.identity_from(request.headers, tab))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.get("/api/maps")
def maps():
    return {"maps": MAPS}


@app.post("/api/match/map")
def change_map(request: Request, name: str, game: str = "", tab: str = ""):
    """End the level now; after the intermission the match goes to `name`
    ("next" = the rotation's next map). Seats carry over."""
    if name != "next" and name not in MAPS:
        raise HTTPException(400, f"unknown map {name!r}")
    g = _game(game, request, tab)
    referee = g.referee if g else REFEREE["r"]
    if referee is None or not referee.request_map(name):
        raise HTTPException(409, "the referee is not running")
    return {"ok": True, "map": name}


@app.post("/api/match/mode")
def choose_mode(request: Request, choice: str, game: str = "", tab: str = ""):
    """The final score of a deathmatch: "stay" starts it again on the same
    map, "solo" goes back to single player (also what happens after 30 s)."""
    if choice not in ("stay", "solo"):
        raise HTTPException(400, f"unknown choice {choice!r}")
    g = _game(game, request, tab)
    referee = g.referee if g else REFEREE["r"]
    if referee is None or not referee.request_mode(choice):
        raise HTTPException(409, "the referee is not running")
    return {"ok": True, "choice": choice}


def _rules_endpoint(game, request, tab):
    g = _game(game, request, tab)
    return g.endpoint if g else ENDPOINTS["primary"]


@app.get("/api/match/rules")
def get_rules(request: Request, tab: str = "", game: str = ""):
    ep = _rules_endpoint(game, request, tab)
    try:
        return rules.get_rules(CREDS, ep, relay.identity_from(request.headers, tab))
    except Exception as exc:
        raise HTTPException(503, f"rules not readable: {exc}")


@app.post("/api/match/rules")
def save_rules(request: Request, mode: str, tab: str = "", game: str = "", values: dict = Body(...)):
    ep = _rules_endpoint(game, request, tab)
    try:
        return rules.save_rules(CREDS, ep, relay.identity_from(request.headers, tab), mode, values)
    except rules.RulesError as exc:
        raise HTTPException(exc.status, str(exc))
    except (TypeError, ValueError) as exc:
        raise HTTPException(400, str(exc))


@app.post("/api/match/rules/use")
def use_rules(request: Request, mode: str, tab: str = "", game: str = ""):
    ep = _rules_endpoint(game, request, tab)
    try:
        return rules.switch_mode(CREDS, ep, relay.identity_from(request.headers, tab), mode)
    except rules.RulesError as exc:
        raise HTTPException(exc.status, str(exc))


@app.websocket("/pg")
async def pg(ws: WebSocket):
    q = ws.query_params
    await relay.serve(ws, q.get("target", "primary"), q.get("guest") == "1", ENDPOINTS, METRICS,
                      games=GAMES, game_id=q.get("game", ""))


# The upstream page runs in an iframe at /upstream/?embed=1 (the main game pane).
# Its config.json fetch is relative, so /upstream/config.json must work too.
@app.get("/upstream/config.json")
def upstream_config():
    return config()

# --------------- patched app.js served at /upstream/app.js -----------------
# The upstream page loads app.js from its own directory; this route serves a
# patched copy (doomapp/appjs_patch.py + doomapp/render_pool.js): input on
# one connection, frames from a pool of 1/2/4/8 render connections the host
# page can resize live. Patched once at import; the Git folder is not touched.
_PATCHED_APP_JS: str | None = None
try:
    _PATCHED_APP_JS = appjs_patch.patch((UPSTREAM_WEB / "app.js").read_text())
    print(f"[app] patched app.js: {len(_PATCHED_APP_JS)} bytes, render pool sizes {appjs_patch.POOL_SIZES}", flush=True)
except Exception as exc:
    print(f"[app] WARNING: could not patch app.js, serving upstream unpatched: {exc}", flush=True)

@app.get("/upstream/app.js")
def upstream_appjs():
    if _PATCHED_APP_JS:
        return Response(content=_PATCHED_APP_JS, media_type="application/javascript")
    # Fallback: serve unpatched
    return Response(content=(UPSTREAM_WEB / "app.js").read_text(), media_type="application/javascript")

app.mount("/upstream", StaticFiles(directory=str(UPSTREAM_WEB), html=True), name="upstream")
app.mount("/", StaticFiles(directory=str(WEB_ROOT), html=True), name="web")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("DATABRICKS_APP_PORT", "8000")),
                ws="websockets", ws_per_message_deflate=True, log_level="info")
