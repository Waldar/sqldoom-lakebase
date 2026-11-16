# Deploying SQLDoom on Lakebase in another workspace

From an empty Databricks workspace to a playable app. Names used below (change them to yours): Lakebase project `sqldoom`, branches `production` and `game-template`, database `databricks_postgres`, schema `doom`, app `sqldoom-ltap`.

**What you end up with.** A Databricks App that serves the game page and runs one game per Lakebase branch. Each new game is a copy-on-write branch of `game-template` (about 3 s), with its own endpoint (24 CU for single player, 32 CU for multiplayer) and its own game loop in the app; quitting or leaving the game idle deletes the branch. The `production` branch only holds the lobby (one row per game), so its endpoint can stay small. The game's SQL (functions, views, frame views) is plain Postgres in `sql_frozen/`; the app applies it to `game-template` whenever it changes.

## Quick path: the setup notebook

1. Clone your copy of the repository as a Git folder in the workspace.
2. Upload `DOOM1.WAD` to a Unity Catalog volume.
3. Open [`setup_notebook.ipynb`](../setup_notebook.ipynb) at the repository root, attach serverless compute, set the widgets (`project`, `app`, `wad`) and run all cells.
4. Give players **Can use** on the app.

The notebook runs `setup_workspace.py`, which does steps 2 to 8 below and, optionally, the deployment of step 9. Every step checks what is already there, so a failed run can be started again.

**Tested 2026-11-13 on a new Lakebase project** in this workspace: steps 2 to 7 ran in 53 s (map load 17 s). A second run found everything in place and changed nothing (15 s). The result was compared with the live `game-template`:
* Catalog: its SQL matched `sql_frozen/` exactly; tables, columns, enums, indexes, constraints and table settings were identical.
* Data: 98 of the 100 tables that are not game state were byte for byte identical. The other two differ in data, not in the install: `maps.wad_id` (the WAD was loaded 6 times on the live project) and two respawn constants (the live solo rules were changed from the page).
* Play: the template reset worked. On a game branch of it, the referee started in 3 s and a player joined. Frames rendered at full detail (64,001 bytes) and low detail (37,121 bytes). A map change to E1M9 took 3.1 s, then 35 tics/s.

**Not tested:** creating the app (the app step was not run, to avoid a second app) and granting Can manage on the project from the script; `app.yaml` editing was tested on a copy.

The new-project test found and fixed five problems that a new workspace would have hit with the manual steps:
* `postgres_compat.sql` needs upstream's tables, while the translated runtime needs its `doom_caller()`. The fix: upstream schema, then compat, then the load, then compat again (for `colormap_idx_lvl`, which comes from the WAD data).
* One translator fix matched 3 times in a whole runtime file. It is skipped during the load, since `sql_frozen/` replaces those functions next.
* `setup_doom_owner.sql` tried to take over extension objects (`pg_prewarm`). Extension objects now keep their owner.
* `sql_frozen/` granted to `databricks_reader_16406`, a role numbered per project. Lakebase's numbered reader and writer roles are now left out.
* The tuned autovacuum and fillfactor settings of 20 tables were set by hand on the live project. They are now in `table_settings.sql`.

The numbered steps below are what the notebook does, for reference or to run by hand.


## 1. Prerequisites

* A Databricks workspace with **Lakebase Postgres (projects and branches)** and **Databricks Apps** enabled.
* Somewhere to run Python 3.10+ that can reach Lakebase: a serverless notebook or the web terminal in the workspace, or a laptop with the Databricks CLI signed in (`databricks auth login`). The scripts get a fresh OAuth token through `databricks-sdk`.
* `pip install -r requirements.txt` (at least `databricks-sdk>=0.70` and `psycopg2-binary`). In a notebook, run the commands below in the notebook's own Python, not with `python -m` in a subprocess: a subprocess cannot use the notebook's sign-in.
* The shareware `DOOM1.WAD` (not included).
* The public [Waldar/sqldoom-lakebase](https://github.com/Waldar/sqldoom-lakebase) repository, or your own fork. The app lives at the repository root; no access to the original private monorepo is needed.

## 2. Lakebase project

1. Create a Lakebase project with **Postgres 17** (Postgres 18 works but renders about 10% slower). Its default branch is `production`.
2. Set the project's **default endpoint size to 24 CU** (min = max). New game branches get the default size at birth; a multiplayer game temporarily raises the default to 32 CU while its branch is created (`DOOM_SOLO_CU`, `DOOM_MULTI_CU`).
3. Size the `production` primary for the map load: 8 CU or more. Once the app runs, 1 CU is enough (it only serves the lobby).
4. In the Lakebase SQL editor (database `databricks_postgres`, on `production`):

```sql
CREATE SCHEMA IF NOT EXISTS doom;
CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA doom;   -- the app loads a new game's cache with it
ALTER DATABASE databricks_postgres SET work_mem = '64MB';
```

(`btree_gist` is created by `postgres_compat.sql` in step 4.)

## 3. Get the code into the workspace

Clone `https://github.com/Waldar/sqldoom-lakebase.git` (or your fork) as a Git folder, for example `/Workspace/Users/<you>/sqldoom-lakebase`. The commands below run from the repository root, where `app.py`, `app.yaml` and `setup_notebook.ipynb` live.

Upstream SQLDoom is vendored in `sqldoom/` (GPL-2.0, its own `LICENSE`), at upstream commit `95753a20e403d0658e624f623f972eb1f708deed`, with password-free DSN examples in the loader's help and upstream README. The app imports it at runtime (the game loop and its client statements), so it has to be inside the deployed folder.

## 4. Load the maps (schema, data, upstream functions)

> On an empty schema, load the maps with the notebook (`Setup(...).run(steps=["maps"])`), not with the command below: the command applies `postgres_compat.sql` first, which fails on an empty schema, and a fresh load also needs the ordering and the lenient translator fixes described under *Quick path*. The command below is for reloading maps into an existing schema.

Upload `DOOM1.WAD` to a Unity Catalog volume, for example `/Volumes/<catalog>/<schema>/wad/DOOM1.WAD`, then:

```sh
export LAKEBASE_ENDPOINT=projects/sqldoom/branches/production/endpoints/primary
export LAKEBASE_DB=databricks_postgres LAKEBASE_SCHEMA=doom
python3 run_on_lakebase.py sqldoom wad_loader.py /Volumes/<catalog>/<schema>/wad/DOOM1.WAD \
  E1M1 E1M2 E1M3 E1M4 E1M5 E1M6 E1M7 E1M8 E1M9 --dsn {DSN}
```

`run_on_lakebase.py` replaces `{DSN}` with a DSN that has a fresh OAuth token, installs `postgres_compat.sql` (CedarDB built-ins missing in Postgres, rules and helper tables), and translates every `cedarscript` function to PL/pgSQL while the upstream loader installs the schema, the runtime and the maps. This creates every table, type and the WAD data; the functions it installs are replaced by the final ones in step 6.

Optional: `python3 run_on_lakebase.py sqldoom "$PWD/static_check.py"` plans every SQL statement inside the ported functions (expect 0 errors).

## 5. Shared owner role and lobby schema

In the Lakebase SQL editor, as the user who loaded the maps, run `setup_doom_owner.sql`:

* **Part 1** creates the `doom_owner` role (NOLOGIN), hands it the `doom` schema and everything in it, and keeps you a member. The final `SELECT` must show `0 | 0 | 0 | doom_owner`; otherwise run `ROLLBACK`.
* **Part 3** creates the `lobby` schema, owned by `doom_owner` (the app creates its tables).
* Part 2 comes after the app exists (step 8).

## 6. Apply the game's SQL (`sql_frozen/`)

Still on `production`, as yourself (a member of `doom_owner`):

```sh
python -m doomapp.frozen apply projects/sqldoom/branches/production/endpoints/primary
python -m doomapp.frozen check projects/sqldoom/branches/production/endpoints/primary   # expect "differs: nothing"
```

In a notebook, the same in-process:

```python
import os, sys
ROOT = "/Workspace/Users/<you>/sqldoom-lakebase"
os.chdir(ROOT); sys.path[:0] = [ROOT, ROOT + "/sqldoom"]
from doomapp import frozen
ep = "projects/sqldoom/branches/production/endpoints/primary"
frozen.main(["apply", ep]); frozen.main(["check", ep])
```

`apply` creates or replaces the 125 functions, 2 aggregates, 19 views, 7 materialized views, 15 indexes and the 180 per-map, per-player frame views, in one transaction (all or nothing). It runs as `doom_owner` (`DOOM_DB_ROLE`, default `doom_owner`). A second `check` right after should find nothing to change.

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

(or in the Lakebase UI: New branch from `production`, no expiration). Every game branch is a copy of it. On its first start the app applies `sql_frozen/` to it again (nothing to change), resets every map to its WAD start and compacts its tables.

You can now size the `production` primary down to 1 CU.

## 8. Create the app

1. Create a Databricks App (Compute: **Medium**), for example `sqldoom-ltap`.
2. Add a **Lakebase database** resource: branch `production`, database `databricks_postgres`, permission **Can connect and create**. This creates the Postgres role of the app's service principal, named after its client (application) id.
3. Run **part 2** of `setup_doom_owner.sql`, with that client id (app page, Authorization tab):

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
3. Deploy, **From Git**: reference `main`, type branch, source code path `.` (the repository root). CLI:

```sh
databricks apps get sqldoom-ltap --output JSON          # RUNNING, no pending_deployment
databricks apps start sqldoom-ltap --timeout 20m        # only if it is STOPPED
databricks apps deploy sqldoom-ltap --git-branch main --git-source-code-path .
```

The deployment includes the repository root, including `app.py`, `app.yaml`, `sql_frozen/` and the vendored `sqldoom/` runtime. Do not select a nested `sqldoom-lakebase/` path: that was the layout of the original monorepo. A deployment restarts the app; live games are picked up again after it (their level restarts).

### Check

In the app logs, within a minute of the first start:

* `[games] running the games (instance ...)`
* `[games] template game-template: installing code frozen-...`, then `[frozen] applied: nothing`, `[games] template compacted: ... tables`, `[games] template reset: 9 maps ...`, `[games] template game-template refreshed in ... s`. Later starts say `up to date`.

Open the app URL, type a name, choose **Single player**. The loading screen shows the steps (branch, cache, game); expect about 5-15 s. Then in the logs:

* `[games] <id>: ready in ... s`
* `[referee] SQL from sql_frozen/ (version ...): nothing installed at start` and `[referee] match opened in ... ms`
* `[server] E1M1 playing ... | tic ... ms ..., 175 tics, 0 dropped` every 5 s
* No traceback, and no `frame views missing on this branch` (that one means step 6 or 7 was skipped: apply `sql_frozen/` to `game-template`).

Change the map from the page once: a loading screen with the VACUUM log shows for about 3 s, then the new map. **Quit game** deletes the game's branch.

## Frozen SQL (`sql_frozen/`)

The game's Postgres code lives as plain files in `sql_frozen/` (`doomapp/frozen.py`): one file per function, view and materialized view, the 180 per-slot frame views as 5 templates (`{map_id}`, `{slot}`, `{thing_id}`), the indexes, and `manifest.json` (apply order, per-slot instances). Tables, types and their data are not in it; they come with the branch.

The app needs `sql_frozen/manifest.json` (since 2026-11-13 there is no other way to install the SQL):

* **Template refresh** applies the files to `game-template`, replacing only the objects whose text differs from the branch's catalog (one transaction, a few seconds), then resets the maps. No referee runs for it, and Python changes no longer rebuild the template: its version is the hash of `sql_frozen/`.
* **The referee installs nothing** at start: no `postgres_compat.sql`, no CedarScript translation, no rewrites, no frame view build. It only opens the match (mode, rules, world flags).

To change the SQL, edit the file and deploy. Postgres stores views in its own layout, so afterwards run `dump` once and commit the result. Commands, from `sqldoom-lakebase/` with Databricks credentials:

```
python -m doomapp.frozen dump  projects/sqldoom/branches/game-template/endpoints/primary   # branch -> files
python -m doomapp.frozen check projects/sqldoom/branches/game-template/endpoints/primary   # what differs
python -m doomapp.frozen apply projects/sqldoom/branches/game-template/endpoints/primary   # files -> branch
```

## What the referee does at each start

The referee (`doomapp/referee.py`) runs upstream `doom_server` through the `run_on_lakebase.py` shim (upstream's client statements in `doom_sql.py` are CedarDB SQL, translated when they are prepared). It installs nothing: it checks that the branch has every frame view, opens the match with the mode's rules, then runs the game at 35 tics/s and vacuums between tics (VACUUM FULL only behind the loading screen between two maps).

## Where the SQL comes from (regenerating from upstream)

`sql_frozen/` was produced from upstream's CedarScript with `cedar2plpgsql.py`, `postgres_compat.sql`, LBDoom's `lbdoom/renderer.sql` and earlier referee-side rewrites. It is now the authoritative, deployable Postgres SQL; the app does not regenerate it on startup. This standalone repository begins with a clean snapshot and does not include the original monorepo's historical rewrite pipeline. Do not regenerate `sql_frozen/` from the transpiler alone and assume equivalence. For an upstream update, use a scratch Lakebase branch, preserve the current SQL as a baseline, validate game state and frames, then `dump` the validated branch into `sql_frozen/`.

## Configuration (`app.yaml`)

| Variable | Default | Meaning |
| --- | --- | --- |
| `LAKEBASE_ENDPOINT` | `projects/sqldoom/branches/production/endpoints/primary` | The `production` primary (lobby) |
| `LAKEBASE_PROJECT` | `projects/sqldoom` | Project the game branches are created in |
| `DOOM_TEMPLATE_BRANCH` | `game-template` | Branch every game is copied from |
| `LAKEBASE_DB`, `LAKEBASE_SCHEMA` | `databricks_postgres`, `doom` | Database and schema |
| `DOOM_DB_ROLE` | `doom_owner` | Role the referee and the template refresh run as |
| `DOOM_SOLO_CU`, `DOOM_MULTI_CU` | `16`, `32` (`app.yaml`: 24) | Endpoint size of a single-player and a multiplayer game branch |
| `DOOM_MAX_GAMES` | `6` | Games at once |
| `DOOM_GAME_IDLE_S` | `180` | A game nobody has open for that long ends (its branch is deleted) |
| `DOOM_GAME_TTL_S` | `21600` | Expiry set on each game branch, as a safety net |
| `DOOM_REFEREE` | `0` in `app.yaml` | 1 also runs a shared match on `production` (the setup before branch per game) |
| `DOOM_RENDER_CONNS` | `4` | Frames in flight per player at page load (the page's auto mode adjusts it, 2-6) |
| `DOOM_MAX_FPS` | `35` | Frame request cap |
| `DOOM_HUD_INTERVAL_MS` | `100` | Status-bar cache check interval, 0 = off |
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
| `template refresh failed` in the logs | `sql_frozen/` could not be applied to `game-template`: run `python -m doomapp.frozen check <template endpoint>` to see what differs |
| `frame views missing on this branch` | The template never got `sql_frozen/` (step 6, or apply it to `game-template` directly) |
| `sql_frozen/manifest.json missing` | The Git source code path is not `.` (the repository root), or the files were not committed |
| All browsers share one player | The relay sets `doom.player` per tab; check that the page is served by this app and not by upstream `doom_web.py` |
| Tic over budget on big maps | Expected in big fights on E1M6/E1M9 (120-180 monsters); see `docs/PERFORMANCE.md`. Auto frames in flight then gives frames back |
| Monsters respawn although respawn is off | On Nightmare, Doom always respawns monsters; the Rules card shows it locked on |
