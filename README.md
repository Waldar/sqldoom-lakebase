# SQLDoom on Databricks Lakebase

The full [SQLDoom](https://github.com/cedardb/sqldoom), the 1993 Doom with its game logic and its renderer written in SQL, running on Databricks Lakebase (Postgres 19) and served as a Databricks App.

SQLDoom was written by CedarDB for CedarDB, with its 106 game functions in CedarDB's `cedarscript` language. This project ported it to Postgres: the functions were translated to PL/pgSQL once ([`tools/cedar2plpgsql.py`](tools/cedar2plpgsql.py), kept as the record of the port), then tuned for Postgres by hand. The result lives in [`sql/`](sql/) as plain Postgres; nothing in the app or the setup depends on CedarDB code any more. A Databricks App runs one game per Lakebase branch: it creates the branch, runs the game loop and streams frames to the browser.

* Game state and game logic: Postgres tables and PL/pgSQL functions in schema `doom`, one game step (tic) 35 times a second.
* Rendering: each frame is one SQL query returning the 320x200 frame buffer.
* Up to 4 players, one per browser tab, in single player or deathmatch, on all 9 maps of the shareware episode (E1M1-E1M9).

## How it works

```
browser tab  --HTTPS/WebSocket-->  Databricks App (FastAPI, sqldoom.server.app)
  page (web/, web/game/)             relay: Postgres wire protocol over WebSocket,
  render pool (1-4 frames             OAuth login injected by the app, statement allow-list,
  in flight)                          frame deltas + deflate
                                     game manager (sqldoom.lakebase.games): one branch per game
                                     referee per game (child process, sqldoom.game): the game
                                       loop, 35 tics/s, VACUUM policy, status-bar cache, rules
                                          |
                                          v
        Lakebase project (Postgres 19)
          production       lobby (one row per game), 1 CU
          game-template    schema doom: WAD assets, game state, the SQL from sql/
          g-<id>           one copy-on-write branch per game, 24 CU solo / 32 CU multi
```

* A game's branch is created from `game-template` in about 3 s and deleted when the game ends.
* Every browser tab gets its own seat. The app logs every browser in as its service principal, so the player identity is a per-connection setting (`doom.player`: user email from the app's forwarded header plus a per-tab token), read by `doom_caller()`.
* Frames are SQL views per map and seat (`api_frame_idx_slot<n>_m<map>`, plus `_low` for low detail). The app renders them next to the database on 1 to 4 render threads per player, each with its own connection, and pushes them to the page over one WebSocket (`src/sqldoom/server/frames.py`); the page's own connections, 1 to 4, are the fallback.

## Repository layout

| Path | What it is |
| --- | --- |
| `sql/migrations/` | The tables and types: `0001_baseline.sql`, then one numbered file per later change, each applied once (recorded in `doom.schema_migrations`) |
| `sql/functions/` | The game's functions, one per file: `api/` (what the page calls), `game/` (the tic: movement, weapons, monsters, doors ...), `multiplayer/` (match, seats, modes), `render/`, `util/` |
| `sql/views/`, `sql/matviews/`, `sql/indexes.sql` | Views, materialized views (static geometry, status-bar pixels) and indexes |
| `sql/frame_views/` | The 5 frame-view templates as SQL functions (the low-detail one generated from the full-detail one by `tools/make_low_detail.py`) and `doom.create_frame_views()`, which builds the 180 per-map, per-seat frame views |
| `sql/seed/` | The game's definitions (things, weapons, line specials, menus, constants) and each mode's default rules, loaded with the maps |
| `src/sqldoom/db/` | Installs and upgrades the database from `sql/`: pending migrations, then the code when it changed (`doom.schema_version`) |
| `src/sqldoom/wad/` | Loads a Doom WAD (palettes, textures, sprites, sounds, music, maps) into the tables, then the derived data and the frame views |
| `src/sqldoom/game/` | The game loop (`server.py`), its supervisor (`referee.py`: VACUUM policy, map changes, loading screen, status-bar cache) and its statements |
| `src/sqldoom/lakebase/` | Lakebase connections (OAuth) and one branch per game (`games.py`: create, warm, end, template refresh) |
| `src/sqldoom/server/` | The app: routes (`app.py`), the frames rendered next to the database and pushed to the page (`frames.py`), the browser's Postgres relay, match rules, metrics |
| `web/` | The page (`index.html`, `host.js`: menu, stats, scoreboard, rules) and the game itself in `web/game/` (canvas, input, render pool, Postgres wire protocol in the browser) |
| `app.yaml`, `pyproject.toml`, `requirements.txt` | The Databricks App's command and settings, the Python package |
| `setup/` | A new workspace: `setup_notebook.ipynb` and `setup_workspace.py` (idempotent steps, `Setup.status()` checks them), `doom_owner.sql`, and `DEPLOY_WITH_GENIE.md`, the runbook for an assistant |
| `tools/` | `bench.py` (tic and frame latency), `mb_harness.py` (replays on scratch branches with game-state hashing, used for the tic work), `frame_compare.py` (a changed frame-view template against the installed one on a scratch branch: identical bytes, timings), `make_low_detail.py` (regenerates the low-detail frame view; `--check` fails when it is stale), `render_music.py` (renders the music with a soundfont), `cedar2plpgsql.py` (the port's translator, not used any more) |
| `docs/` | `DEPLOYMENT.md` (step by step, troubleshooting), `PERFORMANCE.md` (the optimisations, with measurements), `NEXT_STEPS.md` (the plan of 2026-11-18 and its progress) |

## Quick start

To deploy in another workspace with an assistant, ask Genie Code:

> Deploy the app described in https://github.com/Waldar/sqldoom-lakebase/blob/main/setup/DEPLOY_WITH_GENIE.md

[setup/DEPLOY_WITH_GENIE.md](setup/DEPLOY_WITH_GENIE.md) tells it what to ask you, what to run and how to check the result.

By hand:

1. Clone `https://github.com/Waldar/sqldoom-lakebase.git` as a Git folder. This repository is public; no access to the original private monorepo is needed.
2. Upload `DOOM1.WAD` to a Unity Catalog volume.
3. Open [`setup/setup_notebook`](setup/setup_notebook.ipynb), set its widgets (project, app, WAD path, and optionally the music's soundfont) and run it on serverless compute. It creates the Lakebase project, installs the tables and the game's SQL, loads the maps, renders the music, creates the app and `game-template`, and can deploy it.
4. Give players Can use on the app.

The app deploys from the **repository root** (`app.yaml` is there and runs the package in `src/`). For Git-based App deployment, select branch `main` and leave the source code path empty.

**Changing the game's SQL:** edit the file under `sql/` and deploy. At its next start the app installs the new version on `game-template` (new games get it; running games keep theirs). A change to a table is a new file in `sql/migrations/`.

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

## Credits

* **SQLDoom** by CedarDB, Copyright (C) 2026 CedarDB GmbH, GPL-2.0: https://github.com/cedardb/sqldoom ([write-up](https://cedardb.com/blog/sqldoom)). This project is a port of it: the game's SQL in `sql/`, the WAD loader in `src/sqldoom/wad/`, the game loop in `src/sqldoom/game/server.py` and the game page in `web/game/` derive from SQLDoom's code (commit `95753a2`), translated and changed for Postgres and Lakebase. SQLDoom itself runs on CedarDB; see its repository for the original code.
* **Doom** by id Software. The shareware `DOOM1.WAD` is not included; get it from a legitimate source.
* **LBDoom**: Postgres renderer adaptations by Ilia Chibaev, GPL-2.0, now part of the frame views in `sql/frame_views/`.
* The project's history before 2026-11-16 is in the `sqldoom-lakebase/` folder of `Waldar/databricks`.

## License

GPL-2.0, as SQLDoom: see [LICENSE](LICENSE).
