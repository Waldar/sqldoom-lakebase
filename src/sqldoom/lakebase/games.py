"""One Lakebase branch per game.

Every game runs on its own branch of the project, made from `game-template`
(copy-on-write: ~3 s), with its own endpoint and its own referee in this app.
The `production` branch keeps the lobby: lobby.games, one row per game.

  template   game-template (no expiry): the schema, data and the game's SQL
             (sql/, installed by sqldoom.db). At app start it is refreshed
             when sql/ changed (pending migrations, then the code reinstalled,
             then every map reset and the tables compacted); games wait for it.
  create     branch g-<id> from the template (TTL as a safety net), size its
             endpoint (solo 16 CU = the project default, multi 32 CU: a resize
             restarts the compute, so it happens before anything else), load
             the cache with pg_prewarm over 16 connections (a cold compute
             took 27 s for its first frame, 2-3 s once warmed), then start
             the game's referee, which finds every frame view on the branch
             (it installs nothing). Measured
             2026-11-05: ~12 s from create to the referee ticking at 35 Hz.
  play       the relay routes /pg?game=<id> to the game's endpoint
             (endpoint_for: a solo game only lets its owner in; a multi game
              anyone while it has a free seat, up to MAX_PLAYERS).
  multi      opens with the multiplayer rules from its first tic
              (DOOM_START_MODE=deathmatch) and goes on with one player left
              (DOOM_KEEP_MODE=1: no final score). Player 1 is the player seated
              longest (rules.py), so when the host leaves the next one takes
              over. Its seats are polled every few seconds for the menu's list
              of open games (open_games). Quitting a multi game only leaves
              it; it ends when nobody has had it open for DOOM_GAME_IDLE_S.
  end        no player for DOOM_GAME_IDLE_S (the page touches the game while
             it is open), or the owner quits: referee stopped, branch deleted.
  restart    an app restart resumes every live game (the state is in its
             branch): its referee starts again on the map the game was on
             (the level itself restarts: the game loop opens a fresh match);
             games still being created are failed and their branch deleted. g-* branches without a live
             lobby row are deleted.

Env: LAKEBASE_PROJECT (projects/sqldoom), DOOM_TEMPLATE_BRANCH (game-template),
DOOM_SOLO_CU (16), DOOM_MULTI_CU (32), DOOM_MAX_GAMES (6), DOOM_GAME_TTL_S
(21600), DOOM_GAME_IDLE_S (180), DOOM_PREWARM_CONNS (16), DOOM_DB_ROLE.
"""
import os
import re
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg2

from sqldoom import db
from sqldoom.game.referee import Referee
from sqldoom.server.metrics import Metrics

PROJECT = os.getenv("LAKEBASE_PROJECT", "projects/sqldoom")
TEMPLATE = os.getenv("DOOM_TEMPLATE_BRANCH", "game-template")
LOBBY_ENDPOINT = os.getenv("LAKEBASE_ENDPOINT", f"{PROJECT}/branches/production/endpoints/primary")
CU = {"solo": float(os.getenv("DOOM_SOLO_CU", "16")), "multi": float(os.getenv("DOOM_MULTI_CU", "32"))}
MAX_GAMES = int(os.getenv("DOOM_MAX_GAMES", "6"))
GAME_TTL_S = int(os.getenv("DOOM_GAME_TTL_S", str(6 * 3600)))
IDLE_END_S = int(os.getenv("DOOM_GAME_IDLE_S", "180"))
PREWARM_CONNS = int(os.getenv("DOOM_PREWARM_CONNS", "16"))
BRANCH_PREFIX = "g-"
# Quick save / quick load (2026-11-20), single player, one save per player:
# a save is a child branch s-<id> of the game's branch (Lakebase copy on
# write, there in ~1 s), its compute disabled (storage only); a load is a new
# game branch made from it, the game loop going on from the saved tic
# (DOOM_CONTINUE). Lakebase rules (tested 2026-11-20): a branch with an
# expiry cannot have children (a game's branch loses its 6 h expiry at its
# first save), a branch with children cannot be deleted and a read-write
# compute cannot be deleted (such a branch is kept in lobby.retired with its
# compute disabled, and deleted once its children are gone).
SAVE_PREFIX = "s-"
# A spare single-player branch, made and warmed ahead (2026-11-20): on
# Postgres 19 a new branch's compute takes 15-24 s to start (Postgres 17:
# 2.6-2.8 s), most of a game's 21-27 s to ready. A solo game takes the spare
# and only starts its referee; the next one is made in the background. Only
# a spare made from the current template code is used; one older than
# SPARE_MAX_AGE_S is replaced (a game keeps most of GAME_TTL_S); none is kept
# once no game was asked for in SPARE_KEEP_S (no idle compute overnight: the
# next game is made the slow way and brings the spare back).
SPARE = os.getenv("DOOM_SPARE", "1") != "0"
SPARE_MAX_AGE_S = int(os.getenv("DOOM_SPARE_MAX_AGE_S", "3600"))
SPARE_KEEP_S = int(os.getenv("DOOM_SPARE_KEEP_S", "3600"))
GAME_ENV = {}                                # the game referee's own env
# IDLE_SECONDS (sqldoom.game.server): a seat whose page is silent that long is freed
# and its player killed (5 s by default). A background tab's timers slow down
# (Chrome: to once a minute after 5 min), so 5 s lost the player's place on
# a tab switch. A solo game keeps the seat past its own idle end (the game is
# gone by then) and pauses while the tab is hidden (DOOM_PAUSE, away());
# a multi game keeps an absent player's seat 90 s, the world going on.
MODE_ENV = {"solo": {"IDLE_SECONDS": str(IDLE_END_S + 60), "DOOM_PAUSE": "1"},
            "multi": {"DOOM_START_MODE": "deathmatch", "DOOM_KEEP_MODE": "1", "IDLE_SECONDS": "90"}}
MAX_PLAYERS = 4                              # the game loop's 4 seats
SEATS_POLL_S = 3.0
LIVE = ("creating", "warming", "starting", "ready")
# The lobby schema itself is created once by the database owner, owned by
# doom_owner (setup/doom_owner.sql): doom_owner has no CREATE on the database.
LOBBY_DDL = """
CREATE TABLE IF NOT EXISTS lobby.games (
    game_id    text PRIMARY KEY,
    mode       text NOT NULL CHECK (mode IN ('solo', 'multi')),
    owner      text NOT NULL,
    branch     text NOT NULL,
    endpoint   text,
    cu         real NOT NULL,
    state      text NOT NULL,
    step       text,
    error      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    ready_at   timestamptz,
    last_seen  timestamptz NOT NULL DEFAULT now(),
    ended_at   timestamptz);
CREATE INDEX IF NOT EXISTS games_live ON lobby.games (owner) WHERE ended_at IS NULL;
CREATE TABLE IF NOT EXISTS lobby.manager (
    id         boolean PRIMARY KEY DEFAULT true CHECK (id),
    instance   text NOT NULL,
    beat       timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS lobby.template (
    id           boolean PRIMARY KEY DEFAULT true CHECK (id),
    version      text NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS lobby.saves (
    owner      text PRIMARY KEY,      -- the player (user, without the tab): one quick save each
    branch     text NOT NULL,         -- s-<id>, a child of the game's branch
    game_id    text NOT NULL,
    identity   text NOT NULL,         -- the seat's holder in the save (user#tab)
    map_name   text,
    skill      integer,
    code       text NOT NULL,         -- code_version() of the game's SQL at the save
    created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS lobby.retired (
    branch     text PRIMARY KEY,      -- deleted once it has no children (a save, a loaded game)
    why        text,
    since      timestamptz NOT NULL DEFAULT now());
"""


def user_of(identity):
    """The player without the tab: a quick save is the player's, any tab."""
    return (identity or "").split("#", 1)[0]


class GameError(Exception):
    def __init__(self, status, text):
        super().__init__(text)
        self.status = status


def code_version():
    """What the template holds: the SQL under sql/ alone (its code and its
    last migration), so Python changes do not refresh it."""
    migrations = sorted((db.SQL_ROOT / "migrations").glob("*.sql"))
    return f"db-{db.code_version()}-{migrations[-1].stem if migrations else 'none'}"


class Game:
    def __init__(self, game_id, mode, owner, branch, cu, state="creating", endpoint=None, title=""):
        self.game_id, self.mode, self.owner, self.branch, self.cu = game_id, mode, owner, branch, cu
        self.title = title or (owner or "").split("@")[0]   # the host's name in the menu
        self.seats = []                      # [(identity, name)], Player 1 first (multi games)
        self.paused = False                  # solo: the tab is in the background
        self.connected_at = 0.0              # last game connection from a page
        self.endpoint_cu = None              # [min, max] CU of the game's endpoint, from the Lakebase API
        self.region = None                   # from the endpoint's host name (Lakebase API)
        self.pg_version = None               # the project's Postgres version (Lakebase API)
        self.map_name = None
        self.state, self.step, self.error, self.endpoint = state, None, None, endpoint
        self.created = time.time()
        self.ready_at = None
        self.last_seen = time.time()
        self.seen_saved = 0.0
        self.metrics = Metrics()
        self.referee = None
        self.load = None                     # quick load: the lobby.saves row it starts from
        self.no_expiry = False               # the branch lost its expiry (a first quick save)

    def public(self):
        return {"game_id": self.game_id, "mode": self.mode, "state": self.state, "step": self.step,
                "error": self.error, "cu": self.cu, "age_s": round(time.time() - self.created, 1),
                "ready_in_s": round(self.ready_at - self.created, 1) if self.ready_at else None,
                "referee": self.metrics.referee["state"], "title": self.title, "map": self.map_name,
                "players": [n for _, n in self.seats], "paused": self.paused,
                "branch": self.branch, "endpoint_cu": self.endpoint_cu,
                "region": self.region, "pg_version": self.pg_version, "max_players": MAX_PLAYERS if self.mode == "multi" else 1}


class GameManager:
    def __init__(self, creds):
        self.creds = creds
        self._lock = threading.Lock()
        self._games = {}                     # game_id -> Game (live ones)
        self._template_ready = threading.Event()
        self._template_retry = threading.Lock()
        self.template_state = "unknown"
        self._stop = threading.Event()
        self._threads = []
        self._pg_version = None              # projects/sqldoom's, read once
        self.instance = f"{os.getenv('DATABRICKS_APP_NAME', 'local')}-{os.getpid()}-{uuid.uuid4().hex[:6]}"
        self.leader = False
        self._spare = None                   # {"branch", "endpoint", "version", "made"}, ready to take
        self._spare_lock = threading.Lock()
        self._spare_idle = threading.Event()  # set while no spare is being made
        self._spare_idle.set()
        self._keep = set()                   # branches the orphan sweep leaves alone (a spare)
        self._save_lock = threading.Lock()   # one quick save or load at a time
        self._last_demand = time.time()      # the last game asked for (the app start counts)

    # ------------------------------------------------------------ plumbing
    def _w(self):
        return self.creds._client()

    def _lobby(self, sql, args=(), fetch=False):
        conn = psycopg2.connect(self.creds.dsn(LOBBY_ENDPOINT, application_name="sqldoom-lobby",
                                               role=os.getenv("DOOM_DB_ROLE") or None))
        try:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(sql, args)
                return cur.fetchall() if fetch else None
        finally:
            conn.close()

    def _branch_name(self, branch_id):
        return f"{PROJECT}/branches/{branch_id}"

    def _endpoint_of(self, branch_id):
        eps = list(self._w().postgres.list_endpoints(parent=self._branch_name(branch_id)))
        if not eps:
            raise RuntimeError(f"branch {branch_id} has no endpoint")
        return eps[0]

    def _save(self, g, stamp=(), **cols):
        """Set `cols` on the game and its lobby row; `stamp` columns get now()."""
        for k, v in cols.items():
            setattr(g, k, v)
        sets = [f"{k} = %s" for k in cols] + [f"{k} = now()" for k in stamp]
        try:
            self._lobby(f"UPDATE lobby.games SET {', '.join(sets)} WHERE game_id = %s", (*cols.values(), g.game_id))
        except Exception as exc:
            print(f"[games] {g.game_id}: lobby update failed: {exc}", flush=True)

    def _spawn(self, target, *args, name):
        t = threading.Thread(target=target, args=args, name=name, daemon=True)
        t.start()
        return t

    # ------------------------------------------------------------- startup
    def start(self):
        self._lobby(LOBBY_DDL)
        self._spawn(self._lead, name="games-lead")

    # One GameManager runs the games: the one holding lobby.manager (beat
    # every LEASE_BEAT_S). Another one (a second app instance, a notebook
    # test, a deploy overlapping the old process) waits as a standby: it
    # resumes, reaps or creates nothing. 2026-11-10: a test manager without
    # this resumed a player's live game and deleted its branch on exit.
    LEASE_S, LEASE_BEAT_S = 20, 5

    def _take_lease(self):
        rows = self._lobby(
            "INSERT INTO lobby.manager (instance) VALUES (%s) ON CONFLICT (id) DO UPDATE "
            "SET instance = EXCLUDED.instance, beat = now() "
            "WHERE lobby.manager.instance = EXCLUDED.instance "
            "OR lobby.manager.beat < now() - %s * interval '1 second' RETURNING instance",
            (self.instance, self.LEASE_S), fetch=True)
        return bool(rows)

    def _lead(self):
        waited = 0.0
        while not self._stop.is_set():
            try:
                if self._take_lease():
                    break
            except Exception as exc:
                print(f"[games] lease: {exc}", flush=True)
            if waited == 0.0:
                print("[games] standby: another app instance runs the games", flush=True)
            waited += self.LEASE_BEAT_S
            self._stop.wait(self.LEASE_BEAT_S)
        if self._stop.is_set():
            return
        print(f"[games] running the games (instance {self.instance}, waited {waited:.0f} s)", flush=True)
        self.leader = True
        self._resume()
        self._spawn(self._refresh_template, name="games-template")
        self._spawn(self._reaper, name="games-reaper")
        self._spawn(self._seats_poller, name="games-seats")
        if SPARE:
            self._spawn(self._spare_keeper, name="games-spare")
        while not self._stop.wait(self.LEASE_BEAT_S):
            try:
                if not self._take_lease():
                    print("[games] lease lost to another instance: standing down", flush=True)
                    self.leader = False
                    self._stand_down()
                    return
            except Exception as exc:
                print(f"[games] lease beat failed: {exc}", flush=True)

    def _stand_down(self):
        """Stop this instance's referees, keep every branch and lobby row."""
        with self._lock:
            games = list(self._games.values())
            self._games.clear()
        for g in games:
            if g.referee:
                g.referee.stop()

    def stop(self):
        """App shutdown: stop the referees, keep the branches (resumed at next start)."""
        self._stop.set()
        if self.leader:
            self._stand_down()
            try:
                self._lobby("UPDATE lobby.manager SET beat = 'epoch' WHERE instance = %s", (self.instance,))
            except Exception:
                pass
            self.leader = False

    def _resume(self):
        rows = self._lobby("SELECT game_id, mode, owner, branch, cu, state, endpoint FROM lobby.games "
                           "WHERE ended_at IS NULL", fetch=True)
        for game_id, mode, owner, branch, cu, state, endpoint in rows:
            g = Game(game_id, mode, owner, branch, cu, state, endpoint)
            try:
                self._w().postgres.get_branch(name=self._branch_name(branch))
                alive = True
            except Exception:
                alive = False
            if not alive or state != "ready" or not endpoint:
                self._save(g, state="failed", error="app restarted while the game was being created"
                           if alive else "branch gone", stamp=("ended_at",))
                if alive:
                    self._delete_branch(branch)
                continue
            with self._lock:
                self._games[game_id] = g
            self._save(g, state="starting", step="resuming after an app restart")
            self._spawn(self._resume_game, g, name=f"game-{game_id}")
            print(f"[games] {game_id}: resumed ({mode}, {owner})", flush=True)

    # ------------------------------------------------------------ template
    def _refresh_template(self):
        version = code_version()
        try:
            rows = self._lobby("SELECT version FROM lobby.template", fetch=True)
            ep = self._endpoint_of(TEMPLATE)
            if rows and rows[0][0] == version:
                self.template_state = "ready"
                self._template_ready.set()
                print(f"[games] template {TEMPLATE} up to date ({version})", flush=True)
                return
            self.template_state = "refreshing"
            print(f"[games] template {TEMPLATE}: installing code {version}", flush=True)
            t0 = time.time()
            # pending migrations, then the code (sqldoom.db), in one transaction
            conn = psycopg2.connect(self.creds.dsn(ep.name, application_name="sqldoom-template",
                                                   role=os.getenv("DOOM_DB_ROLE") or None))
            try:
                db.install(conn)
            finally:
                conn.close()
            self._reset_template(ep.name)
            self._lobby("INSERT INTO lobby.template (version) VALUES (%s) ON CONFLICT (id) DO UPDATE "
                        "SET version = EXCLUDED.version, refreshed_at = now()", (version,))
            self.template_state = "ready"
            self._template_ready.set()
            print(f"[games] template {TEMPLATE} refreshed in {time.time() - t0:.0f} s", flush=True)
        except Exception as exc:
            self.template_state = f"failed: {exc}"
            print(f"[games] template refresh failed: {exc}", flush=True)

    def _reset_template(self, endpoint):
        """Every map back to its WAD start, no seat, no queue. The template is a
        copy of production, so it held that world's play (2026-11-05: dead
        monsters on 4 maps, taken items on 5, a stale seat holder). Only the
        map a referee opens is reset (doom_reset_stage via doom_mp_start), so
        without this a game's later maps started as production left them."""
        t0 = time.time()
        conn = psycopg2.connect(self.creds.dsn(endpoint, application_name="sqldoom-template",
                                               role=os.getenv("DOOM_DB_ROLE") or None))
        try:
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute("SET search_path = doom")
                cur.execute("SELECT skill FROM mp_rules WHERE mode = 'solo'")
                row = cur.fetchone()
                skill = int(row[0]) if row else 3
                cur.execute("SELECT map_id FROM maps ORDER BY map_id")
                maps = [r[0] for r in cur.fetchall()]
                for map_id in maps:
                    cur.execute("SELECT doom_reset_stage(%s, %s)", (map_id, skill))
                cur.execute("UPDATE mp_players SET role_name = NULL, last_seen = NULL, display_name = NULL "
                            "WHERE role_name IS NOT NULL")
                for table in ("mp_holders", "mp_waiting", "mp_join_requests", "mp_inputs",
                              "mp_map_request", "hud_cache"):
                    cur.execute("SELECT to_regclass(%s) IS NOT NULL", (table,))
                    if cur.fetchone()[0]:
                        cur.execute(f"DELETE FROM {table}")
                # Compact every small table (the game's state, not the WAD
                # assets): the reset deletes and re-inserts, and the template
                # carried old bloat (2026-11-13: render_segs 354 -> 224 pages,
                # monster_ai 230 -> 114). A game branch is born from it with
                # empty statistics, so its referee cannot tell which tables
                # need it; here nothing runs, no frames, ~1.3 s.
                cur.execute("SELECT c.relname, pg_relation_size(c.oid) / 8192 FROM pg_class c "
                            "WHERE c.relnamespace = 'doom'::regnamespace AND c.relkind = 'r' "
                            "AND pg_relation_size(c.oid) < 2000 * 8192")
                small = cur.fetchall()
                t1 = time.time()
                for name, _ in small:
                    cur.execute(f'VACUUM FULL doom."{name}"')
                cur.execute("SELECT sum(pg_relation_size(c.oid)) / 8192 FROM pg_class c "
                            "WHERE c.relnamespace = 'doom'::regnamespace AND c.relkind = 'r' AND c.relname = ANY(%s)",
                            ([n for n, _ in small],))
                print(f"[games] template compacted: {len(small)} tables, {sum(int(p) for _, p in small)} -> "
                      f"{int(cur.fetchone()[0] or 0)} pages in {time.time() - t1:.1f} s", flush=True)
                cur.execute("ANALYZE")
                cur.execute("SELECT (SELECT count(*) FROM monster_deaths), (SELECT count(*) FROM picked_up_items), "
                            "(SELECT count(*) FROM thing_health WHERE NOT alive), (SELECT count(*) FROM mp_holders)")
                left = cur.fetchone()
        finally:
            conn.close()
        if any(left):
            raise RuntimeError(f"template reset left deaths/items/dead/holders {left}")
        print(f"[games] template reset: {len(maps)} maps at skill {skill} in {time.time() - t0:.1f} s", flush=True)

    # --------------------------------------------------------------- games
    def create(self, mode, owner, title=""):
        if mode not in CU:
            raise GameError(400, f"unknown mode {mode!r}")
        if not owner:
            raise GameError(401, "no player identity")
        if not self.leader:
            raise GameError(503, "the game service is starting, try again in a few seconds")
        with self._lock:
            for g in self._games.values():
                if g.mode == mode and g.owner == owner and g.state in LIVE:
                    return g.public()              # one game per player and mode: back to it
            if sum(g.state in LIVE for g in self._games.values()) >= MAX_GAMES:
                raise GameError(429, f"{MAX_GAMES} games are running, try again later")
            game_id = uuid.uuid4().hex[:8]
            g = Game(game_id, mode, owner, f"{BRANCH_PREFIX}{game_id}", CU[mode], title=(title or "")[:12])
            self._games[game_id] = g
            self._last_demand = time.time()
        self._lobby("INSERT INTO lobby.games (game_id, mode, owner, branch, cu, state) VALUES (%s, %s, %s, %s, %s, %s)",
                    (g.game_id, mode, owner, g.branch, g.cu, g.state))
        self._spawn(self._provision, g, name=f"game-{game_id}")
        return g.public()

    def _provision(self, g):
        from databricks.sdk.service import postgres as P
        from databricks.sdk.service.postgres import Duration, FieldMask
        try:
            if self.template_state.startswith("failed"):
                # Once more before giving up: a template fixed after the app
                # started (e.g. the app's login added to it) works without a
                # restart. One retry at a time.
                with self._template_retry:
                    if self.template_state.startswith("failed"):
                        self._save(g, step="updating the levels")
                        self._refresh_template()
            if not self._template_ready.is_set():
                self._save(g, step="updating the levels")
                while not self._template_ready.wait(2.0):
                    if self.template_state.startswith("failed") or self._stop.is_set():
                        raise RuntimeError(f"template not available: {self.template_state}")
            if g.load:
                self._provision_load(g, P, Duration, FieldMask)
                return
            spare = self._take_spare() if g.mode == "solo" else None
            if spare:
                # the lobby row names the spare's branch first, so the orphan
                # sweep sees it as this game's (it stays in _keep meanwhile)
                self._save(g, step="creating the world", branch=spare["branch"], endpoint=spare["endpoint"])
                print(f"[games] {g.game_id}: spare branch {spare['branch']} taken "
                      f"({time.time() - spare['made']:.0f} s old)", flush=True)
                self._save(g, state="warming", step="loading the level")
                self._read_cu(g)
                self._save(g, state="starting", step="starting the game")
                self._start_referee(g)
                return
            self._save(g, step="creating the world" + (f" ({g.cu:g} CU)" if g.mode == "multi" else ""))
            t0 = time.time()
            w = self._w()
            self._create_branch_sized(w, g, P, Duration, FieldMask)
            ep = self._sized_endpoint(w, g, P, FieldMask)
            self._save(g, state="warming", step="loading the level", endpoint=ep.name)
            self._read_cu(g)
            blocks = self._prewarm(ep.name)
            print(f"[games] {g.game_id}: branch + {blocks} blocks warm in {time.time() - t0:.1f} s", flush=True)
            self._save(g, state="starting", step="starting the game")
            self._start_referee(g)
        except Exception as exc:
            print(f"[games] {g.game_id}: creation failed: {exc}", flush=True)
            self._finish(g, "failed", str(exc)[:500])
        finally:
            self._keep.discard(g.branch)

    def _provision_load(self, g, P, Duration, FieldMask):
        """A quick load: the game's branch from the save's, the save's code
        brought up to date if it is older, the seat handed to the loading tab,
        then the game loop going on from the saved tic."""
        s = g.load
        self._save(g, step="loading your quick save")
        t0 = time.time()
        w = self._w()
        self._create_branch_sized(w, g, P, Duration, FieldMask, source=s["branch"])
        ep = self._sized_endpoint(w, g, P, FieldMask)
        self._save(g, state="warming", step="loading the level", endpoint=ep.name)
        self._read_cu(g)
        blocks = self._prewarm(ep.name)
        conn = psycopg2.connect(self.creds.dsn(ep.name, application_name="sqldoom-lobby",
                                               role=os.getenv("DOOM_DB_ROLE") or None))
        try:
            conn.autocommit = True
            if s["code"] != code_version():
                # saved before a deploy that changed the game's SQL: install it
                # (migrations then code, as on the template; the game state stays)
                self._save(g, step="updating the saved game's code")
                db.install(conn)
                print(f"[games] {g.game_id}: saved code {s['code']} brought to {code_version()}", flush=True)
            with conn.cursor() as cur:
                cur.execute("UPDATE doom.mp_players SET role_name = %s, last_seen = now() + interval '30 seconds' "
                            "WHERE role_name = %s", (g.owner, s["identity"]))
                cur.execute("DELETE FROM doom.mp_waiting")
                cur.execute("UPDATE doom.player_state ps SET message = 'GAME LOADED.', message_tics = 140 "
                            "FROM doom.mp_players mp WHERE mp.role_name = %s AND ps.map_id = mp.map_id "
                            "AND ps.player_thing_id = mp.player_thing_id", (g.owner,))
        finally:
            conn.close()
        print(f"[games] {g.game_id}: quick save {s['branch']} ({s['map_name']}) loaded, "
              f"branch + {blocks} blocks warm in {time.time() - t0:.1f} s", flush=True)
        self._save(g, state="starting", step="starting the game")
        self._start_referee(g, {"DOOM_CONTINUE": "1"})

    # ---------------------------------------------------------- quick save
    def quick_info(self, identity):
        """The player's quick save, for the page: map, skill, how old."""
        rows = self._lobby("SELECT map_name, skill, EXTRACT(EPOCH FROM now() - created_at)::float, branch "
                           "FROM lobby.saves WHERE owner = %s", (user_of(identity),), fetch=True)
        if not rows:
            return None
        m, sk, age, branch = rows[0]
        return {"map": m, "skill": sk, "age_s": round(age), "branch": branch}

    def quicksave(self, game_id, identity):
        """A snapshot branch of the game, now. Replaces the player's previous
        quick save. Single player, while playing and alive."""
        from databricks.sdk.service import postgres as P
        from databricks.sdk.service.postgres import FieldMask
        g = self.game(game_id)
        if g is None:
            raise GameError(404, "no such game")
        if g.mode != "solo" or g.owner != identity:
            raise GameError(403, "quick save is for your own single-player game")
        if g.state != "ready" or not g.endpoint:
            raise GameError(409, "the game is not running yet")
        if not self._save_lock.acquire(timeout=30):
            raise GameError(429, "a quick save or load is under way")
        try:
            t0 = time.time()
            conn = psycopg2.connect(self.creds.dsn(g.endpoint, application_name="sqldoom-lobby",
                                                   role=os.getenv("DOOM_DB_ROLE") or None))
            try:
                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("SELECT m.state::text, m.pending, ps.alive, ma.name, m.skill "
                                "FROM doom.mp_match m JOIN doom.maps ma ON ma.map_id = m.map_id "
                                "JOIN doom.mp_players mp ON mp.map_id = m.map_id AND mp.role_name = %s "
                                "JOIN doom.player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id",
                                (identity,))
                    row = cur.fetchone()
                    if row is None or row[0] != "playing" or row[1] is not None:
                        raise GameError(409, "not now: only while playing (not between levels)")
                    if not row[2]:
                        raise GameError(409, "not now: you are dead")
                    map_name, skill = row[3], int(row[4])
                    w = self._w()
                    if not g.no_expiry:
                        # a branch with an expiry cannot have children
                        name = self._branch_name(g.branch)
                        w.postgres.update_branch(name=name, branch=P.Branch(name=name, spec=P.BranchSpec(no_expiry=True)),
                                                 update_mask=FieldMask(field_mask=["spec.no_expiry"])).wait()
                        g.no_expiry = True
                    sid = f"{SAVE_PREFIX}{uuid.uuid4().hex[:8]}"
                    # the snapshot is taken now (the branch's LSN); its compute
                    # is not waited for: it is disabled below
                    w.postgres.create_branch(parent=PROJECT, branch_id=sid, branch=P.Branch(spec=P.BranchSpec(
                        source_branch=self._branch_name(g.branch), no_expiry=True)))
                    for _ in range(120):
                        try:
                            w.postgres.get_branch(name=self._branch_name(sid))
                            break
                        except Exception:
                            time.sleep(0.25)
                    else:
                        raise GameError(504, "the save branch did not appear")
                    took = time.time() - t0
                    cur.execute("UPDATE doom.player_state ps SET message = 'GAME SAVED.', message_tics = 140 "
                                "FROM doom.mp_players mp WHERE mp.role_name = %s AND ps.map_id = mp.map_id "
                                "AND ps.player_thing_id = mp.player_thing_id", (identity,))
            finally:
                conn.close()
            old = self._lobby("SELECT branch FROM lobby.saves WHERE owner = %s", (user_of(identity),), fetch=True)
            self._lobby("INSERT INTO lobby.saves (owner, branch, game_id, identity, map_name, skill, code) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (owner) DO UPDATE SET branch = EXCLUDED.branch, "
                        "game_id = EXCLUDED.game_id, identity = EXCLUDED.identity, map_name = EXCLUDED.map_name, "
                        "skill = EXCLUDED.skill, code = EXCLUDED.code, created_at = now()",
                        (user_of(identity), sid, g.game_id, identity, map_name, skill, code_version()))
            self._spawn(self._disable_compute, sid, name=f"save-{sid}")
            if old and old[0][0] != sid:
                self._spawn(self._delete_branch, old[0][0], name=f"unsave-{old[0][0]}")
            print(f"[games] {g.game_id}: quick save {sid} on {map_name} in {took:.1f} s", flush=True)
            return {"branch": sid, "map": map_name, "skill": skill, "took_s": round(took, 1)}
        finally:
            self._save_lock.release()

    def quickload(self, identity, title=""):
        """A new single-player game from the player's quick save; the tab's
        current single-player game ends."""
        if not identity:
            raise GameError(401, "no player identity")
        if not self.leader:
            raise GameError(503, "the game service is starting, try again in a few seconds")
        rows = self._lobby("SELECT branch, identity, map_name, skill, code FROM lobby.saves WHERE owner = %s",
                           (user_of(identity),), fetch=True)
        if not rows:
            raise GameError(404, "no quick save yet")
        save = dict(zip(("branch", "identity", "map_name", "skill", "code"), rows[0]))
        with self._lock:
            current = [g for g in self._games.values() if g.owner == identity and g.mode == "solo" and g.state in LIVE]
        for g in current:
            self._finish(g, "ended", "quick load")
        with self._lock:
            if sum(g.state in LIVE for g in self._games.values()) >= MAX_GAMES:
                raise GameError(429, f"{MAX_GAMES} games are running, try again later")
            game_id = uuid.uuid4().hex[:8]
            g = Game(game_id, "solo", identity, f"{BRANCH_PREFIX}{game_id}", CU["solo"], title=(title or "")[:12])
            g.load = save
            self._games[game_id] = g
        self._lobby("INSERT INTO lobby.games (game_id, mode, owner, branch, cu, state) VALUES (%s, %s, %s, %s, %s, %s)",
                    (g.game_id, "solo", identity, g.branch, g.cu, g.state))
        self._spawn(self._provision, g, name=f"game-{game_id}")
        return g.public()

    def _disable_compute(self, branch_id):
        """A save or a retired branch keeps its storage, not a running compute
        (a read-write compute cannot be deleted; disabled, it stops)."""
        from databricks.sdk.service import postgres as P
        from databricks.sdk.service.postgres import FieldMask
        try:
            w = self._w()
            for e in w.postgres.list_endpoints(parent=self._branch_name(branch_id)):
                if e.status and e.status.disabled:
                    continue
                w.postgres.update_endpoint(name=e.name, endpoint=P.Endpoint(name=e.name, spec=P.EndpointSpec(
                    endpoint_type=P.EndpointType.ENDPOINT_TYPE_READ_WRITE, disabled=True)),
                    update_mask=FieldMask(field_mask=["spec.disabled"])).wait()
        except Exception as exc:
            print(f"[games] branch {branch_id}: compute not disabled: {exc}", flush=True)

    def _sized_endpoint(self, w, g, P, FieldMask):
        """The branch's endpoint, resized to g.cu if it was born at another size."""
        ep = self._endpoint_of(g.branch)
        if (ep.status.autoscaling_limit_min_cu, ep.status.autoscaling_limit_max_cu) != (g.cu, g.cu):
            if g.game_id in self._games:
                self._save(g, step=f"sizing the compute ({g.cu:g} CU)")
            ep = w.postgres.update_endpoint(name=ep.name, endpoint=P.Endpoint(name=ep.name, spec=P.EndpointSpec(
                endpoint_type=P.EndpointType.ENDPOINT_TYPE_READ_WRITE,
                autoscaling_limit_min_cu=g.cu, autoscaling_limit_max_cu=g.cu)),
                update_mask=FieldMask(field_mask=["spec.autoscaling_limit_min_cu",
                                                  "spec.autoscaling_limit_max_cu"])).wait()
        return ep

    # --------------------------------------------------------------- spare
    def _take_spare(self):
        """The spare, if one fits: made from the current template code and not
        too old. One being made is waited for (it is nearer than a new one)."""
        if not SPARE:
            return None
        self._spare_idle.wait(40.0)
        with self._spare_lock:
            s = self._spare
            if s is None or s["version"] != code_version() or time.time() - s["made"] > SPARE_MAX_AGE_S:
                return None
            self._spare = None
        try:
            self._w().postgres.get_branch(name=self._branch_name(s["branch"]))
        except Exception as exc:
            print(f"[games] spare branch {s['branch']} gone ({exc}): a new branch instead", flush=True)
            self._keep.discard(s["branch"])
            return None
        return s

    def _make_spare(self):
        # first of all: a game asked for from now on waits for this spare
        # (_take_spare) instead of making a branch of its own
        self._spare_idle.clear()
        sid = uuid.uuid4().hex[:8]
        g = Game(sid, "solo", None, f"{BRANCH_PREFIX}{sid}", CU["solo"])
        self._keep.add(g.branch)
        t0 = time.time()
        try:
            from databricks.sdk.service import postgres as P
            from databricks.sdk.service.postgres import Duration, FieldMask
            version = code_version()
            w = self._w()
            self._create_branch_sized(w, g, P, Duration, FieldMask)
            ep = self._sized_endpoint(w, g, P, FieldMask)
            blocks = self._prewarm(ep.name)
            with self._spare_lock:
                self._spare = {"branch": g.branch, "endpoint": ep.name, "version": version, "made": time.time()}
            print(f"[games] spare branch {g.branch} ready in {time.time() - t0:.1f} s "
                  f"({g.cu:g} CU, {blocks} blocks warm)", flush=True)
            return True
        except Exception as exc:
            print(f"[games] spare branch {g.branch} failed: {exc}", flush=True)
            self._delete_branch(g.branch)
            self._keep.discard(g.branch)
            return False
        finally:
            self._spare_idle.set()

    def _drop_spare(self, why):
        with self._spare_lock:
            s, self._spare = self._spare, None
        if s:
            self._delete_branch(s["branch"])
            self._keep.discard(s["branch"])
            print(f"[games] spare branch {s['branch']} deleted ({why})", flush=True)

    def _spare_keeper(self):
        """Every 5 s: a spare while games are being asked for, a fresh one when
        it is too old or from older code, none after SPARE_KEEP_S without a
        new game."""
        backoff = 0.0
        while not self._stop.wait(5.0):
            if not self.leader or not self._template_ready.is_set() or time.time() < backoff:
                continue
            now = time.time()
            with self._spare_lock:
                s = self._spare
            if s:
                if now - self._last_demand > SPARE_KEEP_S:
                    self._drop_spare(f"no new game for {SPARE_KEEP_S} s")
                elif now - s["made"] > SPARE_MAX_AGE_S:
                    self._drop_spare(f"older than {SPARE_MAX_AGE_S} s")
                elif s["version"] != code_version():
                    self._drop_spare("made from older code")
                continue
            if now - self._last_demand > SPARE_KEEP_S:
                continue
            with self._lock:
                live = sum(g.state in LIVE for g in self._games.values())
            if live >= MAX_GAMES:
                continue                           # the computes go to games first
            if not self._make_spare():
                backoff = time.time() + 60.0

    _create_lock = threading.Lock()

    def _create_branch_sized(self, w, g, P, Duration, FieldMask, source=None):
        """Create the game's branch with its endpoint already at g.cu. A new
        branch's endpoint takes the project's default size; resizing it after
        restarts the compute (measured 2026-11-11: 17.8 s, 21.6 s to a warm
        32 CU branch). Setting the default to g.cu just for this creation (0.4 s
        each way) gave a warm 32 CU branch in 4.0 s. Branch creations are
        serialized so a solo game never lands in the 32 CU window."""
        def set_default(lo, hi, suspend):
            w.postgres.update_project(name=PROJECT, project=P.Project(name=PROJECT, spec=P.ProjectSpec(
                default_endpoint_settings=P.ProjectDefaultEndpointSettings(
                    autoscaling_limit_min_cu=lo, autoscaling_limit_max_cu=hi, suspend_timeout_duration=suspend))),
                update_mask=FieldMask(field_mask=["spec.default_endpoint_settings"])).wait()

        def create():
            w.postgres.create_branch(parent=PROJECT, branch_id=g.branch, branch=P.Branch(spec=P.BranchSpec(
                source_branch=self._branch_name(source or TEMPLATE), ttl=Duration(seconds=GAME_TTL_S)))).wait()

        with self._create_lock:
            d = w.postgres.get_project(name=PROJECT).status.default_endpoint_settings
            if (d.autoscaling_limit_min_cu, d.autoscaling_limit_max_cu) == (g.cu, g.cu):
                return create()
            suspend = d.suspend_timeout_duration or Duration(seconds=300)
            back = (d.autoscaling_limit_min_cu, d.autoscaling_limit_max_cu, suspend)
            set_default(g.cu, g.cu, suspend)
            try:
                create()
            finally:
                try:
                    set_default(*back)
                except Exception as exc:     # retried once: solo games would get g.cu
                    print(f"[games] project default not restored, retrying: {exc}", flush=True)
                    time.sleep(1.0)
                    set_default(*back)

    def _prewarm(self, endpoint):
        """Read the game's tables, indexes and the catalog into the new
        compute's cache, 16 connections in parallel (one at a time: 28 s)."""
        role = os.getenv("DOOM_DB_ROLE") or None
        dsn = self.creds.dsn(endpoint, application_name="sqldoom-prewarm", role=role)
        conn = psycopg2.connect(dsn)
        try:
            conn.autocommit = True
            with conn.cursor() as cur:
                # pg_prewarm needs SELECT on the relation: the doom tables and
                # indexes (doom_owner owns them) and the catalog tables, not the
                # catalog's indexes or toast (bootstrap superuser only).
                cur.execute("SELECT c.oid::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                            "WHERE n.nspname IN ('doom', 'pg_catalog') AND c.relkind IN ('r', 'i', 'm', 't') "
                            "AND c.relpersistence = 'p' AND has_table_privilege(c.oid, 'SELECT') "
                            "UNION ALL SELECT c.reltoastrelid::int FROM pg_class c JOIN pg_namespace n "
                            "ON n.oid = c.relnamespace WHERE n.nspname = 'doom' AND c.reltoastrelid <> 0 "
                            "AND has_table_privilege(c.reltoastrelid, 'SELECT')")
                rels = [r[0] for r in cur.fetchall()]
        finally:
            conn.close()

        def warm(oids):
            c = psycopg2.connect(dsn)
            try:
                c.autocommit = True
                with c.cursor() as k:
                    k.execute("SELECT coalesce(sum(pg_prewarm(o)), 0) FROM unnest(%s::oid[]) o", (oids,))
                    return int(k.fetchone()[0])
            finally:
                c.close()

        n = max(1, PREWARM_CONNS)
        with ThreadPoolExecutor(n) as ex:
            return sum(ex.map(warm, [rels[i::n] for i in range(n)]))

    def _read_cu(self, g):
        """The game endpoint's size as Lakebase reports it (the page shows it)."""
        try:
            w = self._w()
            s = w.postgres.get_endpoint(name=g.endpoint).status
            g.endpoint_cu = [s.autoscaling_limit_min_cu, s.autoscaling_limit_max_cu]
            m = re.search(r"\.database\.([a-z0-9-]+)\.cloud\.", (s.hosts.host if s.hosts else "") or "")
            g.region = m.group(1) if m else None
            if self._pg_version is None:
                self._pg_version = w.postgres.get_project(name=PROJECT).status.pg_version
            g.pg_version = self._pg_version
        except Exception as exc:
            print(f"[games] {g.game_id}: endpoint size not read: {str(exc)[:160]}", flush=True)

    def _resume_game(self, g):
        """After an app restart: the referee opens the match again (the game
        loop always starts a fresh level), on the map the game was on."""
        try:
            conn = psycopg2.connect(self.creds.dsn(g.endpoint, application_name="sqldoom-lobby",
                                                   role=os.getenv("DOOM_DB_ROLE") or None))
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT map_id FROM doom.mp_match LIMIT 1")
                    row = cur.fetchone()
            finally:
                conn.close()
            self._read_cu(g)
            self._start_referee(g, {"MAP_ID": str(int(row[0]))} if row else None)
        except Exception as exc:
            # Never delete a resumed game's branch here: the player's world is
            # in it, and the failure may be ours (shutting down, a referee
            # already on it). The game is dropped from memory; the lobby row
            # stays live, so the next instance tries again.
            print(f"[games] {g.game_id}: resume failed, branch kept: {exc}", flush=True)
            if g.referee:
                g.referee.stop()
            with self._lock:
                self._games.pop(g.game_id, None)

    def _start_referee(self, g, env=None):
        g.referee = Referee(g.endpoint, g.metrics, self.creds,
                            env={**GAME_ENV, **MODE_ENV.get(g.mode, {}), **(env or {})},
                            name=f"referee-{g.game_id}")
        g.referee.start()
        t0 = time.time()
        while g.metrics.referee["state"] != "running":
            if time.time() - t0 > 300 or self._stop.is_set():
                raise RuntimeError(f"referee not running after {time.time() - t0:.0f} s "
                                   f"(state {g.metrics.referee['state']})")
            time.sleep(0.25)
        g.last_seen = time.time()
        g.ready_at = time.time()
        self._save(g, state="ready", step=None, stamp=("ready_at",))
        print(f"[games] {g.game_id}: ready in {g.ready_at - g.created:.1f} s", flush=True)

    def get(self, game_id):
        with self._lock:
            g = self._games.get(game_id)
        if g is None:
            rows = self._lobby("SELECT state, error FROM lobby.games WHERE game_id = %s", (game_id,), fetch=True)
            if not rows:
                raise GameError(404, "no such game")
            return {"game_id": game_id, "state": rows[0][0], "error": rows[0][1]}
        return g.public()

    def mine(self, owner, mode="solo"):
        """The caller's live game of `mode`, if any (the menu offers to resume it)."""
        with self._lock:
            for g in self._games.values():
                if g.owner == owner and g.mode == mode and g.state in LIVE:
                    return g.public()
        return None

    def open_games(self, identity=None):
        """Multiplayer games for the menu: being created or ready, with a free
        seat (or the caller's seat), oldest first."""
        with self._lock:
            games = [g for g in self._games.values() if g.mode == "multi" and g.state in LIVE]
        out = []
        for g in sorted(games, key=lambda g: g.created):
            ids = [i for i, _ in g.seats]
            if len(ids) < MAX_PLAYERS or identity in ids:
                out.append({**g.public(), "yours": g.owner == identity, "seated": identity in ids})
        return out

    def join(self, game_id, identity):
        g = self.game(game_id)
        if g is None or g.state not in LIVE:
            raise GameError(404, "no such game")
        if g.mode != "multi":
            raise GameError(403, "a single-player game has no room for another player")
        self._check_seat(g, identity)
        g.last_seen = time.time()
        return g.public()

    def _check_seat(self, g, identity):
        ids = [i for i, _ in g.seats]
        if len(ids) >= MAX_PLAYERS and identity not in ids:
            raise GameError(409, f"the game is full ({MAX_PLAYERS} players)")

    def _seats_poller(self):
        """Seats and map of every ready multi game (Player 1 first), for the menu."""
        role = os.getenv("DOOM_DB_ROLE") or None
        conns = {}
        while not self._stop.wait(SEATS_POLL_S):
            with self._lock:
                games = [g for g in self._games.values() if g.mode == "multi" and g.state == "ready"]
            for gid in set(conns) - {g.game_id for g in games}:
                try:
                    conns.pop(gid).close()
                except Exception:
                    pass
            for g in games:
                try:
                    c = conns.get(g.game_id)
                    if c is None or c.closed:
                        c = conns[g.game_id] = psycopg2.connect(self.creds.dsn(
                            g.endpoint, application_name="sqldoom-lobby", role=role))
                        c.autocommit = True
                    with c.cursor() as k:
                        k.execute("SELECT mp.role_name, coalesce(nullif(mp.display_name, ''), split_part(mp.role_name, '@', 1)) "
                                  "FROM doom.mp_players mp JOIN doom.mp_match m ON m.map_id = mp.map_id "
                                  "WHERE mp.role_name IS NOT NULL ORDER BY mp.claimed_at NULLS LAST, mp.slot")
                        g.seats = [(r[0], r[1]) for r in k.fetchall()]
                        k.execute("SELECT ma.name FROM doom.mp_match m JOIN doom.maps ma ON ma.map_id = m.map_id LIMIT 1")
                        row = k.fetchone()
                        g.map_name = row[0] if row else None
                except Exception as exc:
                    conns.pop(g.game_id, None)
                    print(f"[games] {g.game_id}: seats not read: {str(exc).splitlines()[0][:120]}", flush=True)

    def game(self, game_id):
        with self._lock:
            return self._games.get(game_id)

    def touch(self, game_id, identity):
        g = self.game(game_id)
        if g is None or g.state not in LIVE:
            raise GameError(404, "no such game")
        if g.mode == "solo" and identity != g.owner:
            raise GameError(403, "not your game")
        g.last_seen = time.time()
        if g.last_seen - g.seen_saved > 30:
            g.seen_saved = g.last_seen
            self._save(g, stamp=("last_seen",))
        return g.public()

    def away(self, game_id, identity, on):
        """The solo player's tab went to the background (on) or came back:
        the world pauses, then goes on where it was."""
        g = self.game(game_id)
        if g is None or g.state != "ready":
            raise GameError(404, "no such game")
        if g.mode != "solo":
            return {"game_id": game_id, "paused": False}   # others keep playing
        if identity != g.owner:
            raise GameError(403, "not your game")
        g.last_seen = time.time()
        if on and g.last_seen - g.connected_at < 3.0:
            # the old page's "hidden" from its unload, after the new page connected
            return {"game_id": game_id, "paused": g.paused}
        g.paused = bool(on)
        if g.referee:
            g.referee.pause(on)
        return {"game_id": game_id, "paused": g.paused}

    def endpoint_for(self, game_id, identity):
        """The endpoint a player's connection to `game_id` goes to."""
        g = self.game(game_id)
        if g is None or g.state != "ready":
            raise GameError(409 if g else 404, "the game is not ready" if g else "no such game")
        if g.mode == "solo" and identity != g.owner:
            raise GameError(403, "this single-player game belongs to someone else")
        if g.mode == "multi":
            self._check_seat(g, identity)
        g.last_seen = g.connected_at = time.time()
        if g.paused and g.referee:
            # A page connecting is a player at the game: a reload or a new
            # tab sends no "back" (only the old page's "hidden" as it
            # unloaded), so the world would stay paused (2026-11-12).
            g.paused = False
            g.referee.pause(False)
        return g.endpoint

    def end(self, game_id, identity=None, why="quit"):
        g = self.game(game_id)
        if g is None:
            raise GameError(404, "no such game")
        if identity is not None and g.mode == "solo" and identity != g.owner:
            raise GameError(403, "not your game")
        if identity is not None and g.mode == "multi":
            # leaving: the seat frees up when the page's connections close; the
            # game goes on for the others (and ends once nobody has it open)
            return {"game_id": game_id, "state": "left"}
        self._spawn(self._finish, g, "ended", why, name=f"end-{game_id}")
        return {"game_id": game_id, "state": "ending"}

    def _finish(self, g, state, why):
        if g.referee:
            try:
                g.referee.stop()
            except Exception as exc:
                print(f"[games] {g.game_id}: referee stop: {exc}", flush=True)
        self._delete_branch(g.branch)
        self._save(g, state=state, error=why if state == "failed" else None, step=why,
                   stamp=("ended_at",))
        with self._lock:
            self._games.pop(g.game_id, None)
        print(f"[games] {g.game_id}: {state} ({why})", flush=True)

    def _delete_branch(self, branch_id):
        """Delete a game or save branch. One with children (a quick save, a
        game loaded from one) cannot be: it is kept in lobby.retired with its
        compute disabled, and the reaper deletes it once they are gone."""
        if not branch_id.startswith((BRANCH_PREFIX, SAVE_PREFIX)):
            return False                            # never anything but a game or save branch
        try:
            self._w().postgres.delete_branch(name=self._branch_name(branch_id))
        except Exception as exc:
            text = str(exc)
            if "children" in text:
                first = self._lobby("INSERT INTO lobby.retired (branch, why) VALUES (%s, %s) "
                                    "ON CONFLICT DO NOTHING RETURNING branch",
                                    (branch_id, "has child branches"), fetch=True)
                if first:
                    print(f"[games] branch {branch_id} kept until its child branches go (compute disabled)", flush=True)
                    # in the background: disabling waits for the compute (~18 s)
                    self._spawn(self._disable_compute, branch_id, name=f"retire-{branch_id}")
                return False
            if "not found" not in text.lower() and "NOT_FOUND" not in text:
                print(f"[games] branch {branch_id} not deleted: {exc}", flush=True)
                return False
        self._lobby("DELETE FROM lobby.retired WHERE branch = %s", (branch_id,))
        return True

    # -------------------------------------------------------------- reaper
    def _reaper(self):
        """Every 15 s: end idle games; every 10 min: delete orphan g-* branches."""
        last_orphans = last_cu = 0.0
        while not self._stop.wait(15.0):
            now = time.time()
            with self._lock:
                idle = [g for g in self._games.values() if g.state == "ready" and now - g.last_seen > IDLE_END_S]
            for g in idle:
                self._finish(g, "ended", f"no player for {IDLE_END_S} s")
            if now - last_cu > 300:            # a size changed by hand shows within 5 min
                last_cu = now
                with self._lock:
                    ready = [g for g in self._games.values() if g.state == "ready"]
                for g in ready:
                    self._read_cu(g)
            if now - last_orphans > 600:
                last_orphans = now
                try:
                    self._sweep_branches()
                except Exception as exc:
                    print(f"[games] orphan sweep failed: {exc}", flush=True)

    def _sweep_branches(self):
        """Orphan g-* and s-* branches (no live game, no quick save) deleted;
        the ones kept for their children (lobby.retired) deleted once those
        are gone, leaves first, so a chain goes in one pass."""
        live = {r[0] for r in self._lobby("SELECT branch FROM lobby.games WHERE ended_at IS NULL", fetch=True)}
        saves = {r[0] for r in self._lobby("SELECT branch FROM lobby.saves", fetch=True)}
        retired = {r[0] for r in self._lobby("SELECT branch FROM lobby.retired", fetch=True)}
        for b in self._w().postgres.list_branches(parent=PROJECT):
            bid = b.name.rsplit("/", 1)[-1]
            orphan = ((bid.startswith(BRANCH_PREFIX) and bid not in live)
                      or (bid.startswith(SAVE_PREFIX) and bid not in saves))
            if orphan and bid not in self._keep and bid not in retired:
                print(f"[games] orphan branch {bid}: deleting", flush=True)
                self._delete_branch(bid)
        for _ in range(len(retired) + 1):
            left = [r[0] for r in self._lobby("SELECT branch FROM lobby.retired ORDER BY since DESC", fetch=True)
                    if r[0] not in saves]
            if not left or not any([self._delete_branch(bid) for bid in left]):
                break

    def snapshot(self):
        with self._lock:
            return {"template": self.template_state, "games": [g.public() for g in self._games.values()]}
