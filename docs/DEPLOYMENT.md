# Deploying SQLDoom on Lakebase in another workspace

From an empty Databricks workspace to a playable app. Names used below (change them to yours): Lakebase project `sqldoom`, branches `production` and `game-template`, database `databricks_postgres`, schema `doom`, app `sqldoom-ltap`.

**What you end up with.** A Databricks App that serves the game page and runs one game per Lakebase branch. Each new game is a copy-on-write branch of `game-template` (about 3 s), with its own endpoint (16 CU for single player, 32 CU for multiplayer) and its own game loop in the app; quitting or leaving the game idle deletes the branch. The `production` branch only holds the lobby (one row per game), so its endpoint can stay small. The game's tables and SQL are plain Postgres files in `sql/`: the setup installs them, and the app installs a new version on `game-template` whenever they change.

## Quick path: the setup notebook

1. Clone your copy of the repository as a Git folder in the workspace.
2. Upload `DOOM1.WAD` to a Unity Catalog volume.
3. Open [`setup/setup_notebook.ipynb`](../setup/setup_notebook.ipynb), attach serverless compute, set the widgets (`project`, `app`, `wad`) and run all cells.
4. Give players **Can use** on the app.

The notebook runs `setup/setup_workspace.py`, which does steps 2 to 8 below and, optionally, the deployment of step 9. Every step checks what is already there, so a failed run can be started again.

**Tested 2026-11-18** (the database steps, on a scratch branch with an empty schema `doom`): 28 s, the 9 maps 0.3 to 0.6 s each; a second run changed nothing. Compared with the live `game-template`:
* Catalog: identical on all 1,723 objects (functions, views, the 180 frame views, materialized views, indexes, tables, columns, constraints, enums, casts, operator).
* Data: 99 of the 116 tables byte for byte identical. The other 17 differ in data, not in the install: the match tables are empty until a referee opens a match, the live solo rules were changed from the page (and two respawn delays follow them), and the live WAD was loaded 6 times (`wads`, `maps.wad_id`).
* Play: the referee opened a match on the freshly built world and ran 35 tics/s (tic p50 7 ms).

**Not tested in this layout:** steps 2 and 8 (a new Lakebase project, creating the app and its grants).

The numbered steps below are what the notebook does, for reference or to run by hand.


## 1. Prerequisites

* A Databricks workspace with **Lakebase Postgres (projects and branches)** and **Databricks Apps** enabled.
* Somewhere to run Python 3.10+ that can reach Lakebase: a serverless notebook or the web terminal in the workspace, or a laptop with the Databricks CLI signed in (`databricks auth login`). The scripts get a fresh OAuth token through `databricks-sdk`.
* `pip install -r requirements.txt` (at least `databricks-sdk>=0.70` and `psycopg2-binary`). In a notebook, run the commands below in the notebook's own Python, not with `python -m` in a subprocess: a subprocess cannot use the notebook's sign-in.
* The shareware `DOOM1.WAD` (not included).
* The public [Waldar/sqldoom-lakebase](https://github.com/Waldar/sqldoom-lakebase) repository, or your own fork. The app lives at the repository root; no access to the original private monorepo is needed.

## 2. Lakebase project

1. Create a Lakebase project with **Postgres 19** (`Setup(pg_version=19)`, the default in `setup/setup_workspace.py`). Against Postgres 17 on 24 CU, frames are about 7.5% faster and a tic with monsters fighting about 20% faster, with identical pictures and game state (`docs/PERFORMANCE.md`). Postgres 17 works too. Lakebase has no in-place upgrade: moving means a new project (`docs/PERFORMANCE.md`, "Postgres 19"). Its default branch is `production`.
2. Set the project's **default endpoint size to 16 CU** (min = max), the single-player size. New game branches get the default size at birth; a multiplayer game temporarily raises the default to 32 CU while its branch is created (`DOOM_SOLO_CU`, `DOOM_MULTI_CU`).
3. Size the `production` primary for the map load: 8 CU or more. Once the app runs, 1 CU is enough (it only serves the lobby).
4. In the Lakebase SQL editor (database `databricks_postgres`, on `production`):

```sql
CREATE SCHEMA IF NOT EXISTS doom;
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA doom;   -- the (map_id, box) GiST index on linedef_geom
CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA doom;   -- the app loads a new game's cache with it
ALTER DATABASE databricks_postgres SET work_mem = '64MB';
```

## 3. Get the code into the workspace

Clone `https://github.com/Waldar/sqldoom-lakebase.git` (or your fork) as a Git folder, for example `/Workspace/Users/<you>/sqldoom-lakebase`. The app deploys from the repository root (`app.yaml` runs the package in `src/`); the setup is in `setup/`.

## 4. Shared owner role and lobby schema

In the Lakebase SQL editor, on `production`, run `setup/doom_owner.sql`:

* **Part 1** creates the `doom_owner` role (NOLOGIN), hands it the `doom` schema (and anything already in it), and keeps you a member. The final `SELECT` must show `0 | 0 | 0 | doom_owner`; otherwise run `ROLLBACK`.
* **Part 3** creates the `lobby` schema, owned by `doom_owner` (the app creates its tables).
* Part 2 comes after the app exists (step 8).

Everything the next step creates is then owned by `doom_owner`, which the app runs as.

## 5. Tables, the game's SQL and the maps

Upload `DOOM1.WAD` to a Unity Catalog volume, for example `/Volumes/<catalog>/<schema>/wad/DOOM1.WAD`. Then, in a notebook's own Python (a subprocess cannot use the notebook's sign-in), as yourself running as `doom_owner`:

```python
import sys
ROOT = "/Workspace/Users/<you>/sqldoom-lakebase"
sys.path[:0] = [ROOT + "/src"]
import psycopg2
from sqldoom import db, wad
from sqldoom.lakebase.connection import CREDS
conn = psycopg2.connect(CREDS.dsn("projects/sqldoom/branches/production/endpoints/primary",
                                  application_name="sqldoom-setup", role="doom_owner"))
db.install(conn)                                    # tables (sql/migrations), then the game's SQL
wad.load(conn, "/Volumes/<catalog>/<schema>/wad/DOOM1.WAD")   # definitions, WAD assets, 9 maps, frame views
conn.close()
```

`db.install` runs the migrations (`0001_baseline.sql`: 24 types, 116 tables, then `0002` to `0011`) and creates the game's functions, views and materialized views (139 and 30 at the 2026-11-23 install) and the indexes, in one transaction. `wad.load` then loads the game's definitions (`sql/seed/`), the WAD's palettes, textures, sprites, sounds, music and maps, the derived data, and creates the 180 per-map, per-seat frame views. About 30 s; the loader fills an empty schema only. From a terminal: `PYTHONPATH=src python -m sqldoom.wad <DOOM1.WAD> --endpoint <endpoint>` does both.

## 7. The template branch (after the app: do step 8 first)

> Create `game-template` only once the app exists (step 8, at least items 1-3). Lakebase roles are per branch and a new branch copies its parent's roles when it is created: a template made before the app has no database login for the app, and every game then fails with `template not available: ... password authentication failed for user '<app id>'` (found 2026-11-16 on the first deployment in another workspace). `setup_workspace.py` runs the steps in that order, and its template step adds the missing login to a template made too early (`Setup(...).run(steps=["template"])`).

Create `game-template` from `production`, **with no expiry**, in a notebook:

```python
from databricks.sdk import WorkspaceClient
from databricks.sdk.service import postgres as P
w = WorkspaceClient()
w.postgres.create_branch(parent="projects/sqldoom", branch_id="game-template",
    branch=P.Branch(spec=P.BranchSpec(source_branch="projects/sqldoom/branches/production"))).wait()
print(list(w.postgres.list_endpoints(parent="projects/sqldoom/branches/game-template")))
```

(or in the Lakebase UI: New branch from `production`, no expiration). Every game branch is a copy of it. On its first start the app checks its SQL version (installing the current one if it differs), resets every map to its WAD start and compacts its tables.

You can now size the `production` primary down to 1 CU.

## 8. Create the app

1. Create a Databricks App (Compute: **Medium**), for example `sqldoom-ltap`.
2. Add a **Lakebase database** resource: branch `production`, database `databricks_postgres`, permission **Can connect and create**. This creates the Postgres role of the app's service principal, named after its client (application) id.
3. Run **part 2** of `setup/doom_owner.sql`, with that client id (app page, Authorization tab):

```sql
GRANT doom_owner TO "<app-sp-client-id>" WITH INHERIT TRUE, SET TRUE;
```

4. Give the app's service principal **Can manage** on the Lakebase project (project page, Permissions): it creates and deletes the game branches and sets the project's default endpoint size.
5. Edit `app.yaml` for your names: `LAKEBASE_ENDPOINT` (the `production` primary), `LAKEBASE_DB`, `LAKEBASE_SCHEMA`, and add `LAKEBASE_PROJECT` (default `projects/sqldoom`) and `DOOM_TEMPLATE_BRANCH` (default `game-template`) if yours differ. Commit and push.
6. Give players **Can use** on the app (app page, Permissions).

## 9. Deploy and check

### Deploy from Git

1. On the app page, Edit, Configure Git: repository `https://github.com/Waldar/sqldoom-lakebase.git` (or your fork), provider GitHub.
2. Use your own Git credential if your workspace requires one, or if you deploy from a private fork. No access to `Waldar/databricks` is needed.
3. Deploy, **From Git**: reference `main`, type branch, source code path empty (the repository root). CLI:

```sh
databricks apps get sqldoom-ltap --output JSON          # RUNNING, no pending_deployment
databricks apps start sqldoom-ltap --timeout 20m        # only if it is STOPPED
databricks apps deploy sqldoom-ltap --git-branch main
```

The deployment takes the whole repository: `app.yaml` runs `python -m sqldoom.server.app` with `PYTHONPATH=src`, and the app reads `sql/` and `web/`. A deployment restarts the app; live games are picked up again after it (their level restarts).

### Check

In the app logs, within a minute of the first start:

* `[games] running the games (instance ...)`
* `[games] template game-template: installing code db-...`, then `[db] code ...: 134 functions, ...`, `[games] template compacted: ... tables`, `[games] template reset: 9 maps ...`, `[games] template game-template refreshed in ... s`. Later starts say `up to date`.

Open the app URL, type a name, choose **Single player**. The loading screen shows the steps (branch, cache, game); expect about 5-15 s. Then in the logs:

* `[games] <id>: ready in ... s`
* `[referee] match opened in ... ms` and `[server] ready in ... s; players join from the browser`
* `[server] E1M1 playing ... | tic ... ms ..., 175 tics, 0 dropped` every 5 s
* No traceback, and no `frame views missing on this branch` (that one means the maps were not loaded with the frame views, step 5).

Change the map from the page once: a loading screen with the VACUUM log shows for about 3 s, then the new map. **Quit game** deletes the game's branch.

## The game's SQL (`sql/`) and how it is installed

Everything the game runs in Postgres is a plain file under `sql/`, installed by `src/sqldoom/db/install.py`:

* **Tables and types** (`sql/migrations/`): `0001_baseline.sql`, then one numbered file per later change (`0002_...sql`), each applied once and recorded in `doom.schema_migrations`. A database made before migrations existed (the tables already there) records the baseline as applied without running it.
* **Code** (`sql/functions/`, `sql/views/`, `sql/matviews/`, `sql/frame_views/`, `sql/indexes.sql`): one object per file, applied in passes so no file lists an order (an object that needs one not created yet waits for the next pass). When the files change (their hash, `doom.schema_version`), the installer recreates every function and view, then the frame views (`doom.create_frame_views()`) and the indexes, in one transaction.
* **Seed data** (`sql/seed/`): the game's definitions and the default rules, loaded once with the maps by `sqldoom.wad`.

**At the app's start** the template refresh compares `game-template`'s version (in `lobby.template`) with the files', and when they differ installs them on the template (about 25 s), then resets the maps. Python changes do not refresh the template. **The referee installs nothing**: it checks that the branch has every frame view, opens the match with the mode's rules, then runs the game at 35 tics/s and vacuums between tics (VACUUM FULL only behind the loading screen between two maps).

**To change the SQL:** edit the file and deploy (new games get it; running games keep theirs). A change to a table is a new migration, never an edit of an applied one. To try a change first: create a branch from `game-template`, run `sqldoom.db.install` on it (from a notebook, as in step 5), play or bench it there (`tools/bench.py`), delete the branch.

**Data the installer does not add.** Some changes need WAD content or rendered audio on a database loaded before them. Run these on `game-template` (new games copy it), on the first spare made after a template refresh, and on `production` (a future template is made from it); both can run again:

* `tools/backfill_texture_masks.py`: the see-through textures' masks and the `STFKILL` faces (migration `0007`), and `HELP2`, the picture after Episode 1's end text (2026-11-21).
* `tools/render_music.py`: every track without audio, including `D_INTER` and `D_VICTOR`, the music of single player's screens between levels (2026-11-21).

## Single player's screens between levels

A single-player level that ends by its exit runs Doom's screens before the loading screen (`sqldoom/game/referee.py` `_solo_screens`): `doom_solo_level_end` works out the exit (secret or not), the next map in Doom's order and the figures; `doom_solo_screen_tic` steps the intermission (or, after E1M8, the episode's end) at 35 Hz with the world standing still; the app's frame threads draw `api_screen_frame` meanwhile, and the page plays `D_INTER` / `D_VICTOR` (`api_stage_music`). Fire or use moves the screens on. After the episode's picture the game goes back to its first map and the page to the lobby. `DOOM_SOLO_SCREENS=0` (app env) skips them: straight to the loading screen and the rotation's next map, as before.

## Quick save and quick load (branches)

Single player, one save per player (`lobby.saves`; `sqldoom/lakebase/games.py`). A save is a child branch `s-<id>` of the game's branch, made with no expiry; its compute is disabled at once, so a save costs storage only. A load is a new game branch `g-<id>` made from the save; the game loop starts with `DOOM_CONTINUE=1` and goes on from the saved tic (no fresh level), and the seat is handed to the loading tab. A save made before a deploy that changed the game's SQL is brought up to date on load (`sqldoom.db.install`).

Lakebase's rules shape the rest: a branch with an expiry cannot have children, so a game's branch loses its 6 h expiry at its first save; a branch with children cannot be deleted, and a read-write compute cannot be deleted. So when a game ends, or a save is replaced, a branch that still has children is kept in `lobby.retired` with its compute disabled; the reaper deletes it once its children are gone, leaves first (every 10 min, with the orphan sweep).

## Configuration (`app.yaml`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `LAKEBASE_ENDPOINT` | `projects/sqldoom/branches/production/endpoints/primary` | The `production` primary (lobby) |
| `LAKEBASE_PROJECT` | `projects/sqldoom` | Project the game branches are created in |
| `DOOM_TEMPLATE_BRANCH` | `game-template` | Branch every game is copied from |
| `LAKEBASE_DB`, `LAKEBASE_SCHEMA` | `databricks_postgres`, `doom` | Database and schema |
| `DOOM_DB_ROLE` | `doom_owner` | Role the referee and the template refresh run as |
| `DOOM_SOLO_CU`, `DOOM_MULTI_CU` | `16`, `32` | Endpoint size of a single-player and a multiplayer game branch (16 CU ran as fast as 24 next to 3 render threads, 2026-11-20) |
| `DOOM_MAX_GAMES` | `6` | Games at once |
| `DOOM_SPARE` | `1` | A spare single-player branch, made and warmed ahead, so a new game skips the branch's compute start (15-24 s on Postgres 19); `0` turns it off |
| `DOOM_SPARE_MAX_AGE_S`, `DOOM_SPARE_KEEP_S` | `3600`, `3600` | A spare older than that is replaced; with no new game for that long, none is kept (no idle compute) |
| `DOOM_GAME_IDLE_S` | `180` | A game nobody has open for that long ends (its branch is deleted) |
| `DOOM_GAME_TTL_S` | `21600` | Expiry set on each game branch, as a safety net |
| `DOOM_RENDER_CONNS` | `4` | Render threads per player at page load (1 to 4; the page's auto mode adjusts it) |
| `DOOM_MAX_FPS` | `35` | Frame request cap |
| `DOOM_HUD_INTERVAL_MS` | `0` | Status-bar cache writer's check interval, 0 = off. Off since 2026-11-24: no frame view reads `hud_cache`, the frames draw the status bar themselves (taking it from the cache measured 0.5 ms of a 55 ms frame) |
| `DOOM_VACUUM_INTERVAL` | `1050` | Plain VACUUM of the game tables every n tics (~30 s), 0 = off |
| `DOOM_LOADING_MIN_S` | `3` | Loading screen between two maps lasts at least this long |
| `DOOM_LOADING_VACUUM_FULL` | `1` | VACUUM FULL behind the loading screen (0: plain VACUUM) |
| `ROTATION` | `E1M1,...,E1M9` | Map rotation |
| `LAKEBASE_TOKEN_REFRESH_S` | `2400` | Reuse an OAuth token for this long (tokens last 1 h) |

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Deploy fails with "not in RUNNING state" | Run `apps get`. `STOPPED`: `apps start`, then deploy. `STARTING`/`STOPPING`: wait and check again |
| Page loads, no game, `permission denied` in the logs | The service principal is not a member of `doom_owner` (step 8.3) or the database resource is missing |
| A new game fails with `template not available: ... password authentication failed for user '<app id>'` | `game-template` was made before the app (step 7 before step 8): `Setup(...).run(steps=["template"])` adds the app's login there; then redeploy or restart the app if it was deployed before 2026-11-16 |
| A new game fails at "creating your world" | The service principal lacks Can manage on the Lakebase project (step 8.4), or `game-template` does not exist (step 7) |
| `template refresh failed` in the logs | The SQL from `sql/` could not be installed on `game-template`: the lines after it name the file and the Postgres error |
| `frame views missing on this branch` | The maps were loaded without the frame views (step 5): `SELECT doom.create_frame_views()` on `game-template` as `doom_owner` |
| `No module named sqldoom` at the app's start | The Git source code path is not the repository root, or `app.yaml` lost its `PYTHONPATH=src` |
| All browsers share one player | The relay sets `doom.player` per tab; check that the page is served by this app |
| Tic over budget on big maps | Can happen in the heaviest fights on E1M6/E1M9 (120-180 monsters), where three frames and the tic share the 16 CU branch (a live heavy E1M9 scene: tic p50 25.3, p99 34.5 ms); see `docs/PERFORMANCE.md`. Auto frames in flight then gives frames back |
| A solo game starts on another skill or with respawns | The default rules of a new game come from `doom.mp_rules` on `game-template`, which the template refresh copies from `production`: single player Hurt me plenty, no monster or item respawn since 2026-11-25 (the same as `sql/seed/rules.sql`) |
| Monsters respawn although respawn is off | On Nightmare, Doom always respawns monsters (12 s or more after death, at random); with the rule on, they come back exactly the set time after death, as items |
