"""SQLDoom on Lakebase -- the Databricks App.

  /             the page (web/; DOOM_WEB_ROOT overrides)
  /game/        the game itself (web/game/), in an iframe of the page
  /config.json  render target and frame cap for the game page
  /pg           WebSocket: the game page's Postgres connection (sqldoom.server.relay)
  /api/metrics  tic cost and frame cost (sqldoom.server.metrics)
  /api/health   liveness
  /api/maps     maps the page may switch to; POST /api/match/map?name=E1M5|next
  POST /api/match/mode?choice=stay|solo   end of a deathmatch: play on or go solo
  GET  /api/match/rules?tab=...           both modes' rules, the mode, who is Player 1
  POST /api/match/rules?tab=...&mode=...  Player 1 changes a mode's rules (JSON body)
  POST /api/match/rules/use?tab=...&mode=solo|deathmatch   Player 1 alone picks the rule set

One Lakebase branch per game (sqldoom.lakebase.games):
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
  and then act on that game's branch.

Each game's referee (sqldoom.game.referee) runs it at 35 Hz on its branch.
Env: see sqldoom/lakebase/connection.py, sqldoom/lakebase/games.py and
sqldoom/game/referee.py; DOOM_MAX_FPS caps the page's frame requests (35).

    PYTHONPATH=src python -m sqldoom.server.app   # uvicorn on $DATABRICKS_APP_PORT (default 8000)
"""
import asyncio
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Body, FastAPI, HTTPException, Request, WebSocket
from fastapi.staticfiles import StaticFiles

from sqldoom.game.referee import REFEREE_ENV
from sqldoom.lakebase.connection import CREDS, endpoints
from sqldoom.lakebase.games import GameError, GameManager
from sqldoom.server import relay, rules
from sqldoom.server.metrics import METRICS

REPO = Path(__file__).resolve().parents[3]
WEB_ROOT = Path(os.getenv("DOOM_WEB_ROOT", REPO / "web"))
MAX_FPS = int(os.getenv("DOOM_MAX_FPS", "35"))
# Render connections per player at page load (1 to 6); the page changes it live.
RENDER_POOL_SIZES = (1, 2, 3, 4, 5, 6)
RENDER_CONNS = int(os.getenv("DOOM_RENDER_CONNS", "4"))
ENDPOINTS = endpoints()
MAPS = [m.strip() for m in os.getenv("ROTATION", REFEREE_ENV["ROTATION"]).split(",") if m.strip()]
GAMES = GameManager(CREDS)


def _game(game, request, tab):
    """The game a request names, checked against the caller; None when it names none."""
    if not game:
        return None
    try:
        GAMES.touch(game, relay.identity_from(request.headers, tab))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))
    return GAMES.game(game)


def _referee(game, request, tab):
    g = _game(game, request, tab)
    if g is None:
        raise HTTPException(400, "which game? (?game=<id>)")
    return g.referee


@asynccontextmanager
async def lifespan(_app):
    try:
        await asyncio.to_thread(GAMES.start)
    except Exception as exc:              # the page still loads and says why
        print(f"[app] WARNING: games not available: {exc}", flush=True)
    try:
        yield
    finally:
        await asyncio.to_thread(GAMES.stop)


app = FastAPI(title="SQLDoom on Lakebase", lifespan=lifespan)


@app.get("/config.json")
def config():
    # guests=1: the page offers "play" without an account form; the relay
    # logs in with OAuth and tells the page which role it plays as.
    return {"targets": list(ENDPOINTS), "parallel": None, "max_fps": MAX_FPS,
            "guests": 1, "guests_free": 1,
            "render_conns": RENDER_CONNS if RENDER_CONNS in RENDER_POOL_SIZES else 4}


@app.get("/api/metrics")
def metrics(request: Request, window: float = 10.0, game: str = "", tab: str = ""):
    g = _game(game, request, tab)
    return (g.metrics if g else METRICS).snapshot(max(1.0, min(window, 300.0)))


@app.get("/api/health")
def health():
    return {"ok": True, "games": GAMES.snapshot()}


# ------------------------------------------------------------ games
@app.post("/api/games")
def new_game(request: Request, mode: str = "solo", tab: str = "", name: str = ""):
    try:
        return GAMES.create(mode, relay.identity_from(request.headers, tab), title=name.strip()[:12])
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.get("/api/games/mine")
def my_game(request: Request, tab: str = ""):
    me = relay.identity_from(request.headers, tab)
    return {"game": GAMES.mine(me), "multi": GAMES.mine(me, "multi"), "enabled": True,
            "template": GAMES.template_state}


@app.get("/api/games/open")
def open_games(request: Request, tab: str = ""):
    return {"games": GAMES.open_games(relay.identity_from(request.headers, tab))}


@app.post("/api/games/{game_id}/join")
def join_game(request: Request, game_id: str, tab: str = ""):
    try:
        return GAMES.join(game_id, relay.identity_from(request.headers, tab))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.get("/api/games/{game_id}")
def game_state(request: Request, game_id: str, tab: str = ""):
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
    try:
        return GAMES.away(game_id, relay.identity_from(request.headers, tab), bool(on))
    except GameError as exc:
        raise HTTPException(exc.status, str(exc))


@app.post("/api/games/{game_id}/quit")
def quit_game(request: Request, game_id: str, tab: str = ""):
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
    referee = _referee(game, request, tab)
    if referee is None or not referee.request_map(name):
        raise HTTPException(409, "the referee is not running")
    return {"ok": True, "map": name}


@app.post("/api/match/mode")
def choose_mode(request: Request, choice: str, game: str = "", tab: str = ""):
    """The final score of a deathmatch: "stay" starts it again on the same
    map, "solo" goes back to single player (also what happens after 30 s)."""
    if choice not in ("stay", "solo"):
        raise HTTPException(400, f"unknown choice {choice!r}")
    referee = _referee(game, request, tab)
    if referee is None or not referee.request_mode(choice):
        raise HTTPException(409, "the referee is not running")
    return {"ok": True, "choice": choice}


def _rules_endpoint(game, request, tab):
    """The game's branch; without a game, production (the menu's default rules)."""
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


# The game page runs in an iframe at /game/?embed=1. Its config.json fetch is
# relative, so /game/config.json must work too.
@app.get("/game/config.json")
def game_config():
    return config()


app.mount("/", StaticFiles(directory=str(WEB_ROOT), html=True), name="web")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("DATABRICKS_APP_PORT", "8000")),
                ws="websockets", ws_per_message_deflate=True, log_level="info")
