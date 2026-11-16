# SQLDoom on Databricks Lakebase

The full [SQLDoom](https://github.com/cedardb/sqldoom), the 1993 Doom with its game logic and its renderer written in SQL, running on Databricks Lakebase (Postgres 17) and served as a Databricks App.

Upstream SQLDoom runs on CedarDB and uses CedarDB's `cedarscript` language for its 106 game functions. This port translated that code to PL/pgSQL once (`cedar2plpgsql.py`), tuned it for Postgres, and keeps the result as plain Postgres SQL in `sql_frozen/`. A Databricks App runs one game per Lakebase branch: it creates the branch, runs the game loop and streams frames to the browser.

* Game state and game logic: Postgres tables and PL/pgSQL functions in schema `doom`, one game step (tic) 35 times a second.
* Rendering: each frame is one SQL query returning the 320x200 frame buffer.
* Up to 4 players, one per browser tab, in single player or deathmatch, on all 9 maps of the shareware episode (E1M1-E1M9).

## How it works

```
browser tab  --HTTPS/WebSocket-->  Databricks App (FastAPI, app.py)
  page (web/)                        relay: Postgres wire protocol over WebSocket,
  render pool (1-6 frames             OAuth login injected by the app, statement allow-list,
  in flight)                          frame deltas + deflate
                                     game manager (doomapp/games.py): one branch per game
                                     referee per game (child process): upstream doom_server
                                       loop, 35 tics/s, VACUUM policy, status-bar cache, rules
                                          |
                                          v
        Lakebase project (Postgres 17)
          production       lobby (one row per game), 1 CU
          game-template    schema doom: WAD assets, game state, the SQL from sql_frozen/
          g-<id>           one copy-on-write branch per game, 24 CU solo / 32 CU multi
```

* A game's branch is created from `game-template` in about 3 s and deleted when the game ends.
* Every browser tab gets its own seat. The app logs every browser in as its service principal, so the player identity is a per-connection setting (`doom.player`: user email from the app's forwarded header plus a per-tab token), read by `doom_caller()`.
* Frames are SQL views per map and seat (`api_frame_idx_slot<n>_m<map>`, plus `_low` for low detail). The page keeps 1 to 6 frame queries in flight, each on its own connection.

## Repository layout

| Path | What it is |
| --- | --- |
| `sql_frozen/` | The game's SQL as plain Postgres: 125 functions, 2 aggregates, 19 views, 7 materialized views, 15 indexes, the 180 per-map frame views as 5 templates; applied to `game-template` by the app |
| `cedar2plpgsql.py` | `cedarscript` to PL/pgSQL transpiler and the Postgres rewrites that produced `sql_frozen/` (used by the map loader, and to regenerate from a new upstream) |
| `run_on_lakebase.py` | Runs any upstream script against Lakebase: fresh OAuth DSN, installs `postgres_compat.sql`, wraps `psycopg2` so `cedarscript` is translated on the fly (the map loader, and upstream's client statements in the game loop) |
| `postgres_compat.sql` | CedarDB built-ins missing in Postgres, game-mode and rules tables, indexes, helper tables (idempotent) |
| `DEPLOY_WITH_GENIE.md` | Deployment runbook for an assistant (Genie Code) in another workspace |
| `setup_notebook.ipynb`, `setup_workspace.py` | Setting up a new workspace: Lakebase project, maps, SQL, template, app (idempotent steps; `Setup.status()` checks them) |
| `setup_doom_owner.sql` | Shared `doom_owner` role that owns the schema; the app's service principal is granted it |
| `table_settings.sql` | Autovacuum and fillfactor settings of the tables the tic writes |
| `app.py`, `app.yaml` | Databricks App entry point and its configuration |
| `doomapp/` | App internals: `games.py` (one branch per game, template refresh), `frozen.py` (dump, check and apply `sql_frozen/`), `referee.py` (game loop, VACUUM policy, loading screen between maps), `lakebase.py` (endpoints, OAuth), `relay.py` (WebSocket to Postgres), `rules.py` (match rules API), `metrics.py`, `render_pool.js`, `appjs_patch.py` |
| `web/` | The page: 3-column layout (rendering stats, game, scoreboard and rules) |
| `bench.py` | Tic and frame latency benchmark |
| `static_check.py` | Plans (never runs) every SQL statement embedded in the ported functions, to catch errors on code paths not yet executed |
| `mb_harness.py` | Benchmark harness used for the tic work: committed replays on fresh Lakebase branches, game-state hashing, per-function and per-statement profiles |
| `docs/DEPLOYMENT.md` | Deploying in another workspace, step by step |
| `docs/PERFORMANCE.md` | The optimisations that landed, with measurements |
| `sqldoom/` | Vendored upstream SQLDoom at commit `95753a2`, with password-free DSN examples (the app imports it at runtime) |

## Quick start

To deploy in another workspace with an assistant, ask Genie Code:

> Deploy the app described in https://github.com/Waldar/sqldoom-lakebase/blob/main/DEPLOY_WITH_GENIE.md

[DEPLOY_WITH_GENIE.md](DEPLOY_WITH_GENIE.md) tells it what to ask you, what to run and how to check the result.

By hand:

1. Clone `https://github.com/Waldar/sqldoom-lakebase.git` as a Git folder. This repository is public; no access to the original private monorepo is needed.
2. Upload `DOOM1.WAD` to a Unity Catalog volume.
3. Open [`setup_notebook`](setup_notebook.ipynb), set its three widgets (project, app, WAD path) and run it on serverless compute. It creates the Lakebase project, loads the maps, installs the game's SQL, creates `game-template` and the app, and can deploy it.
4. Give players Can use on the app.

The app and its setup notebook are at the **repository root**. For Git-based App deployment, select branch `main` and source code path `.` (not a nested `sqldoom-lakebase/` directory).

**Cost and access:** setup creates billable Databricks resources: a Medium App, a Lakebase lobby endpoint, and a 24 CU single-player or 32 CU multiplayer endpoint per active game. Use a dedicated project, review the setup prompts, and grant access only to intended players. This is a community demo, not an officially supported Databricks product.

The details, the steps the notebook automates and troubleshooting are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Performance today

Budget: 28.6 ms per tic (35 tics/s).

| Measure | Result |
| --- | --- |
| Tic, E1M1, 1 player (8 CU) | about 11 ms |
| Tic, E1M1 Ultra-Violence, 22 monsters awake (8 CU) | 20.4 ms mean (was 26.9) |
| Tic, E1M9, 1 player, about 25 monsters awake (32 CU, live) | 33-35 ms mean (was 38-40) |
| Frame, full detail (server) | about 160-170 ms |
| Frame, low detail (server) | about 90 ms |

The big maps (E1M6, E1M9: 120-140 monsters) are still above the tic budget in fights. Details and the full history of fixes: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## Validation method

Every performance change was checked for identical behaviour, not only speed:

* Two Lakebase branches created from the same parent at the same LSN, the same scripted inputs on both, and a hash of every game table every 10 or 20 tics. A change lands only when the hashes match (or the difference is understood and documented).
* Frames compared byte for byte on 10 to 18 fixed camera poses.

## Credits and license

* SQLDoom by CedarDB: https://github.com/cedardb/sqldoom ([write-up](https://cedardb.com/blog/sqldoom)). Doom by id Software.
* Postgres renderer adaptations by Ilia Chibaev (LBDoom), vendored in `lbdoom/` under GPL-2.0; integration notes are in `doomapp/lbdoom.py`.
* This standalone distribution was extracted from the `sqldoom-lakebase/` project in `Waldar/databricks`, source revision `babcadf8f756c64e5808f3e3a17660a022c27c8a`, on 2026-11-16. Game logic and frozen SQL were copied unchanged; deployment documentation, ignore patterns and example connection strings were adapted for public distribution.
* SQLDoom is GPL-2.0. This port transpiles and patches its code, so this repository is distributed under the same license: see [LICENSE](LICENSE).
* The shareware `DOOM1.WAD` is not included; get it from a legitimate source.
