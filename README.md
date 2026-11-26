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
                                       loop, 35 tics/s, VACUUM policy, rules
                                          |
                                          v
        Lakebase project (Postgres 19)
          production       lobby (one row per game), 1 CU
          game-template    schema doom: WAD assets, game state, the SQL from sql/
          g-<id>           one copy-on-write branch per game, 16 CU solo / 32 CU multi
```

* A game's branch is created from `game-template` in about 3 s and deleted when the game ends.
* Quick save and quick load (single player, F6 / F9, one save per player): a save is a child branch of the game's branch, there in about a second, with its compute disabled; a load is a new game branch made from it, the game loop going on from the saved tic.
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
| `src/sqldoom/game/` | The game loop (`server.py`), its supervisor (`referee.py`: VACUUM policy, map changes, loading screen; its status-bar cache writer is off by default since 2026-11-24, no frame view reads `hud_cache`) and its statements |
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
2. Upload `DOOM1.WAD` to a Unity Catalog volume. That is the only file to bring: the music's General MIDI soundfont ships with the repository (`assets/soundfont/TimGM6mb.sf2`, GPL-2 like the code, `TimGM6mb.copyright` next to it).
3. Open [`setup/setup_notebook`](setup/setup_notebook.ipynb), set its widgets (project, app, WAD path) and run it on serverless compute. It creates the Lakebase project, installs the tables and the game's SQL, loads the maps, renders the music, creates the app and `game-template`, and can deploy it.
4. Give players Can use on the app.

The app deploys from the **repository root** (`app.yaml` is there and runs the package in `src/`). For Git-based App deployment, select branch `main` and leave the source code path empty.

**Changing the game's SQL:** edit the file under `sql/` and deploy. At its next start the app installs the new version on `game-template` (new games get it; running games keep theirs). A change to a table is a new file in `sql/migrations/`.

**Cost and access:** setup creates billable Databricks resources: a Medium App, a Lakebase lobby endpoint, and a 16 CU single-player or 32 CU multiplayer endpoint per active game. Use a dedicated project, review the setup prompts, and grant access only to intended players. This is a community demo, not an officially supported Databricks product.

The details, the steps the notebook automates and troubleshooting are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## Performance today

Budget: 28.6 ms per tic (35 tics/s). Postgres 19 on Lakebase.

| Measure | Result |
| --- | --- |
| Live game in the browser, single player, full detail (2026-11-20) | 35.1-35.7 frames/s, tic p50 14.3-14.6 ms |
| Live, a heavy E1M9 scene (2026-11-24, 16 CU) | 34.5 frames/s, 75 ms a frame with 3 render threads, tic p50 25.3 / p99 34.5 ms |
| Input to picture, live (key press to the first frame that shows it, 2026-11-20) | p50 111-115 ms, p90 131-133 ms |
| Tic, E1M1 with combat, 22 monsters awake (2026-11-20, 24 CU) | p50 12.9 ms, p90 17.7 ms |
| Tic, E1M9 with combat, 52 monsters awake (2026-11-20, 24 CU) | p50 21.2 ms, p90 26.1 ms |
| Tic, E1M9, 350 tics of combat, after the monster changes (2026-11-23, 16 CU) | p50 21.6 ms (28.8 before them, same run on 16 CU) |
| Frame, full detail (server, 12 E1M9 poses, 2026-11-20, 24 CU) | 40.1 ms |
| Frame, low detail (server, same poses) | 29.3 ms |
| Frame, full detail, heaviest of 6-13 poses per map (2026-11-24, 16 CU, rendered alone) | 52-60 ms |

The heaviest fights on the big maps can still go past the budget (E1M9 with combat: p99 31-36 ms): three frames and the 35 Hz tic run side by side on the same compute, and a frame is one Postgres process, so idle cores do not shorten it. Details and the full history of fixes: [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

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
