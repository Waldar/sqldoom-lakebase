# Performance work

What landed, in the order it landed, with the measurement behind each change. Budget: one game tic in 28.6 ms (35 tics/s). CU = Lakebase compute units (4 CU is about 1 core, 32 CU about 8 cores; one Postgres query uses one core).

This is a log: the "Where" columns name the files and mechanisms of the time (rewrite lists in the translator, `postgres_compat.sql`, `doomapp/`). All of it now lives in the plain SQL under `sql/` and in `src/sqldoom/`. To measure today's code: `tools/bench.py` on a scratch branch, `tools/mb_harness.py` for replays.

## How changes were measured

* **Same state, same inputs.** For each variant, a fresh Lakebase branch from the same parent at the same LSN, the same scripted per-tic inputs, and an md5 hash of every game table (volatile columns such as event ids and timestamps excluded) every 10 or 20 tics.
* **Committed tics for timing.** Replaying tics inside one rolled-back transaction keeps every row version until the end, and scans slow down as it goes (30 to 62 ms over 240 tics on E1M9). Rolled-back replays are only used to compare game state; timings come from committed tics on a fresh branch (`mb_harness.committed_run`).
* **Match production.** Production passes all 4 player slots to every tic and does not VACUUM between tics; the benchmarks do the same.
* **Profiles.** `track_functions` and `auto_explain` are not available on Lakebase, so stages and statements are timed by wrapping each call in `clock_timestamp()` in an instrumented copy of the function (`mb_harness.instrument`, `instrument_statements`).
* **Frames.** Byte-for-byte comparison on 10 to 18 fixed camera poses, median of 5 runs.

## Game tic

| Change | Where | Before -> after | Check |
| --- | --- | --- | --- |
| Sector lookup evaluated once (`LATERAL`) instead of per sector row: `doom_sector_at` is a volatile PL/pgSQL BSP walk that Postgres re-ran for every row of the join | `TARGETED_FIXES`, `doom_cs_move` | Action tic p50/p95 51/75 -> 17.5/25 ms (E1M1, 1 CU) | 60 random moves, identical `player_state` |
| Constant lookups batched: consecutive `doom_const()` calls collapsed into one `SELECT ... FILTER` | transpiler (`batch_const_lookups`) | 84 of 89 calls in 16 functions | identical state |
| Review patches (monster think, sector lookup, chase, discover, sound) + 4 indexes | `TARGETED_FIXES`, `postgres_compat.sql` | E1M6, 4 players, 1 CU: 74.1 -> 52.1 ms, WAL 44.6 -> 26.0 KB/tic | 116 tables identical over 240 tics |
| Profile fixes: monster target CTE materialised, anti-joins in monster step, world sound cues once per tic | `TARGETED_FIXES` | E1M6: 44.1 -> 41.1 ms | 600 tics identical, including sound event ids |
| `synchronous_commit=off` per session: a tic commit does not wait for the WAL to be durable | `doomapp/lakebase.py` | about -4 ms per tic | |
| `params` CTEs `NOT MATERIALIZED` in 15 generated tic functions, so the planner sees the map and player ids | transpiler (`PARAMS_CTE_RE`), and rewritten in place at referee start | E1M1 Nightmare, 4 players, 28 awake, 8 CU: mean 49.0 -> 41.6 ms, p90 65 -> 45 ms | 240 tics identical |
| Monster thinking without nested loops: its CTEs are estimated at 1 row, so Postgres re-scanned the monster list once per monster (117 x 117 rows on E1M9) | `ALTER FUNCTION doom_cs_monster_think ... SET enable_nestloop = off` at referee start | E1M9, 8 CU: tic 34 -> 27 ms, think 7.4 -> 3.4 ms | 16 tables identical, 2 runs each |
| Empty player slots skip the per-player stages: the server passes all 4 slots, so a solo game ran plan, use, move, death, secrets, weapon, sound and sector effects 4 times | `tic_core_slot_gates` (transpiler) applied at referee start, `doom_slot_active` (compat) | E1M9, all 4 slots, 8 CU: 35-38 -> 30-33 ms. Live E1M9, 32 CU: 38-40 -> 33-35 ms | identical except puffs and blood (below) |
| Generic plans forced for the whole tic: in the default mode Postgres kept some statements on custom plans and re-planned them every tic (one monster chase statement: 0.7 ms to run, 2-3 ms to plan) | `ALTER FUNCTION doom_run_mp_tic ... SET plan_cache_mode = force_generic_plan` at referee start (the setting covers every function the tic calls) | E1M1 Ultra-Violence, 22 monsters awake, all 4 slots, 8 CU: 26.9 -> 20.4 ms, tics over budget 154 -> 12 of 480. E1M9 Nightmare: 34.4 -> 31.7 ms | 16 tables identical, 2 runs each |
| Statements the generic plans made slow (`LIVE_TIC_FIXES`, applied at referee start): monster door use paired every door line with every Thing on the map (now chasers x door lines, door lines found by a new `linedef_geom (map_id, special)` index); doors ran their 8 mover statements with no mover active (now gated on one `EXISTS`); player and monster line crossings hashed every vertex of the map twice (now index probes per crossable line) | transpiler (`LIVE_TIC_FIXES`, `live_tic_fix`), index in `postgres_compat.sql` | in those statements, timed in place: E1M1 3.36 -> 1.95 ms per tic, E1M9 5.57 -> 3.95 ms (door use 0.86 -> 0.33, doors 0.97 -> 0.34, crossings 0.68 -> 0.43 on E1M1) | same rows on 40-60 forced states per statement (909 door-use, 188 crossing rows); 16 tables identical |
| Monster plan and sound (`LIVE_TIC_FIXES`): the plan flags were seven `EXISTS` subqueries, computed twice per tic though the first call only reads the noise bit (now one pass over `monster_ai`, and the first call asks for the noise bit alone); sound computed sight and death cues for every awake or dead monster and the active-sound draw for every chaser before the dedupe threw almost all of them away (now filtered first, same key test) | transpiler (`LIVE_TIC_FIXES`) | E1M1: plan 0.85 -> 0.25 ms, sound 1.31 -> 0.86 ms. E1M9: plan 0.96 -> 0.37 ms, sound 2.01 -> 1.28 ms. Tic, 2 runs each: E1M1 19.4 -> 17.7 ms, E1M9 31.2 -> 30.6 ms | same flags on 250 random states; same sound rows on 350 random states (2,467 events, every kind); 16 tables identical |

The slot change has one visible effect: `doom_cs_weapon` ages bullet puffs and blood once per slot call, so a solo game aged them 4 times per tic and they vanished early. They now last their normal time in single player. Deathmatch with 4 seated players is unchanged.

## Renderer

| Change | Before -> after | Check |
| --- | --- | --- |
| Textures and sprites decompressed once per row instead of once per pixel (`GET_BYTE` on a TOAST-compressed `bytea` decompresses the whole value each call) | client frame p50 1251 -> 443 ms | 18 poses identical |
| Visplane clipping: one window pass instead of two quadratic `LATERAL`s | included above | identical |
| Floor and ceiling textures joined on an integer id resolved per span (762 rows) instead of a text key per pixel (37K rows) | p50 406 -> 347 ms | 60 frames identical |
| 12 Postgres rewrites of the renderer | server p50 298 -> 187 ms, mean 356 -> 216 ms (8 CU) | 14 poses identical |
| Review patches: sprite and weapon patches decoded once per frame, an optimizer hack for the original engine removed (it disabled the `render_segs` primary key and scanned 261K rows per frame), each wall texture decompressed once, BSP visibility once per frame | E1M1 232 -> 170 ms, E1M6 503 -> 189 ms (worst pose 1346 -> 299 ms), planning 79 -> 51 ms | 10 poses, indexed, low detail and RGB |
| Status-bar cache: a referee worker renders the status bar every 100 ms into `hud_cache` per seat; frames reuse the bytes while its key matches | -10 ms per frame | 0 mismatches on 30 states |
| Low-detail mode: 160 scene columns with `generate_series(lo, hi, 2)` (a `WHERE x % 2 = 0` filter made the planner estimate 0.5% of rows and was 48% slower than full detail) | p50 108 ms (-34%) | |
| Frame tail: depth by `DISTINCT ON`, colormap as one 256-byte row per palette and light level (`colormap_idx_lvl`), holes filled by one join over all pixels | full 182.6 -> 167.5 ms, low 105.6 -> 91.2 ms | 13 poses identical |
| Frame plan prepared once per connection | planning 0.06 ms per frame | |
| Leaner frame plan (`frame_lean_view_sql`): `render_settings` (all constants) `NOT MATERIALIZED` so its values fold into the per-pixel expressions; the hole join on the depth sort's pixel number (no second sort); the palette's 34 colormap rows as one in-query `bytea` instead of a join per pixel; the unread `plane_tex` CTE dropped (it made `plane_world` materialize). Planning ~50 -> ~100 ms, paid once per prepared statement | E1M9 full 211.9 -> 189.3 ms, low 126.0 -> 115.8 ms (14 poses); E1M1 full 194.3 -> 175.0 ms, low 107.3 -> 96.9 ms (10 poses), 8 CU | byte-identical on all poses |
| Per-column occlusion (`frame_occlusion_view_sql`): wall spans per screen column with their rounded depth; a wall column or floor/ceiling span is cut at the top or bottom where a strictly nearer wall covers it (floors and ceilings also lose ties), so those rows are never generated. Set-based (one self-join of the ~700 wall spans, one join of the ~600 plane spans): a first version with a `LATERAL` per span cost 2-3 ms on every frame | E1M9 full, 44 poses: mean 187.6 -> 182.8 ms, p90 225.1 -> 212.6 ms, overdraw poses -73 to -90 ms, median +1.1 ms; low 112.9 -> 110.3 ms; E1M1 full 176.1 -> 166.4 ms, low 96.8 -> 91.9 ms | byte-identical on 128 frames |
| Sprite occlusion (`frame_sprite_occlusion_view_sql`): sprite columns cut at the top or bottom where a wall span of the column is nearer or level (walls win ties against sprites), from the same `occ_rows`. Each Thing is expanded to its columns and hash-joined on the column; a range join Thing x wall span cost more than it saved | E1M9 full, 44 poses: mean 181.4 -> 177.4 ms, p90 213.9 -> 201.5 ms, median -2.3 ms; low 105.1 -> 103.1 ms; E1M1 full 186.9 -> 184.0 ms, low 112.7 -> 111.5 ms | byte-identical on 128 frames |
| Pipelined frame requests (`render_pool.js`): two request lanes per render connection on the primary, so the next camera + frame is queued on the server while the previous frame travels back; still one render per connection and core. Live before (2026-11-04, E1M1, 4 connections): 17.3 fps at 178 ms of database time per frame, ~50 ms of each connection's ~230 ms cycle idle. The relay times a queued request from the previous ReadyForQuery | simulated with the measured 178 ms render and ~52 ms round trip: 4 connections 16.7 -> 22.3 fps, 6 connections 24.7 -> 33.5 fps (35 fps cap); database busy 67% -> 93% per connection | `localStorage.doomPipeline = '0'` for A/B |

## Renderer and frame delivery, 2026-11-17 to 11-20

The frame views now use LBDoom's renderer (Ilia Chibaev's `sql/renderer.sql`, converted for our views: see the header of `sql/frame_views/api_frame_idx_slotS_mM.sql`), and the frames are rendered in the app next to the database and pushed to the page (`src/sqldoom/server/frames.py`). A frame is about 45-55 ms at the database on 24 CU, E1M9 Nightmare; 35 frames/s takes 2-4 render threads.

| Change | Where | Before -> after | Check |
| --- | --- | --- | --- |
| Camera pose read once (`pos AS MATERIALIZED`): inlined, its `mp_players` lookup ran ~8,000 times a frame | frame template | 7,996 -> 54 pages per frame; live frames had been 85-126 ms | identical frames |
| Low detail generated from the full template (`tools/make_low_detail.py`; `--check` fails when the copy is stale) | `api_frame_idx_slotS_mM_low.sql` | 17-28% faster than full detail | 76/76 poses pixel-exact |
| Frame clock at 35 Hz, round robin over the connections; a slot no connection can take is owed (at most 2) instead of lost | `web/game/app.js` | simulated, 10% of answers stalled 150-250 ms, 2 connections: 30.3 -> 33.3 frames/s, pool full 11.8% -> 3.3% | |
| Frames rendered in the app: per tab, render threads with their own connections (about 1 ms from the database), the newest frame pushed XOR-coded over one WebSocket; the network delays the picture, not the frame rate | `frames.py`, route `/frames` | live: 35 frames/s on 3 threads, auto settling there | frames byte-identical to the views, decoded by the page's own code |
| Frames start on each tic commit (the referee's tic sample, `Metrics.wait_tic`); 5 frames/s when no tic for 200 ms | `frames.py`, `metrics.py` | stand-in game loop at 35 tics/s: 34.8 frames/s, 100% started on a tic | |
| Camera from `player_state` (the newest tic) instead of an `api_camera` write before every frame; `api_camera` once a second per thread for `last_seen` | frame template, `frames.py` | `mp_players` updates: one per frame (~172 in 5 s) -> 16 | 60/60 poses on 3 maps byte-identical, full and low |
| The viewer's `player_state` row read once (`me_state AS MATERIALIZED ... LIMIT 1`): with that table's fresh statistics (the referee's re-plan `ANALYZE`) the frame planned bitmap scans and a nested loop in `plane_span_info` | frame template | analyzed: full 63.0 -> 54.8 ms, low 41.3 -> 39.7 ms; not analyzed: unchanged | 11 poses identical, full and low |
| Auto render threads: straight to the needed count when pool full > 15%; remembers the frame time at each count and tries one fewer after 30 s at target (frames are slower with more threads: 81 ms on 4, 49-53 ms on 3, one live game) | `web/host.js` | simulated: 2 -> 4 in 2 s instead of 10-12 s of short frames; contention case 5 -> 3 | |
| lz4 for the columns a frame decompresses (textures, flats, sprite pixels and masks, status bar, colormaps) | `sql/migrations/0002_lz4_textures.sql`, two matviews | decompressing all of them 4.0 -> 2.8 ms; frame full 43.8 -> 43.2 ms, low 32.0 -> 31.8 ms (12 E1M9 poses) | byte-identical |

Where a frame's time goes (12 E1M9 Nightmare poses on a copy of `game-template`, each step timed by cutting the view after it): floors and ceilings add 8.2 ms of 42.7 ms on average, up to 21.4 ms in open views, and ~90% of that is `plane_lanes`, the per-pixel texel (about 0.44 µs a flat pixel, 0.30 µs a sky pixel). The spans, their dedupe and the per-span and per-row work cost about 1.3 ms together.

Frame spikes, live E1M9 Nightmare (80 frames with `EXPLAIN (ANALYZE, BUFFERS)`): slow frames do more work, not the same work slower. The floor and ceiling spans in view (correlation 0.74) and the sprites (0.55) explain 65% of the frame time (`28.7 ms + 5.3 ms per 1,000 geometry rows + 0.09 ms per sprite`); 2 frames in 80 were more than 12 ms over that. No temporary files, sorts on disk or multi-batch hashes. On a copy, the frame time did not move with real tics at 35 Hz next to it, with 5 other frames rendering, or with two CPU-bound sessions (all within 1 ms).

## Postgres 19, 2026-11-20

Lakebase offers Postgres 19 (server 19.0; lz4 is the default TOAST compression there). Measured on 24 CU against Postgres 17, each side a project or branch with all 9 maps, the same code (`356a29b75e660904`) and the referee's statistics step before timing:

| | Postgres 17 | Postgres 19 | Check |
| --- | --- | --- | --- |
| Frame, full detail (12 E1M9 Nightmare poses) | 43.3 ms | 40.1 ms (-7.4%, faster at 12/12) | pictures byte-identical |
| Frame, low detail | 31.8 ms | 29.3 ms (-7.9%, faster at 12/12) | byte-identical |
| Tic, E1M9 with combat (player firing every tic, 52 monsters awake), p50 / p90 / p99, two runs | 26.7 / 35.8 / 42.6 and 26.5 / 35.9 / 42.2 ms | 21.2 / 26.1 / 31.3 and 21.4 / 30.3 / 36.1 ms | game state identical after 525 tics |
| Tic, E1M1 with combat (22 awake) | 16.1 / 21.2 / 26.2 ms | 12.9 / 17.7 / 22.8 ms | identical |

A first Postgres 19 project with only 2 maps loaded showed frames 18-23% faster: smaller tables, not the version. The app moved the same day (commit `c48deea`): a new project `projects/sqldoom-19` built with `setup/setup_workspace.py`, the menu's rules copied over, the app's database resource switched and the app deployed; the old project stays as the rollback. A fresh `production` has no `mp_match` row, which made the menu's rules request fail until `rules.py` handled it.

## Input to picture, 2026-11-20

From a key or button change in the browser to the first frame drawn that has it (`a18abb9`, as LBDoom's `?lag=1`). Each input statement returns its number (`api_input`); every tic stores the newest one it took (`game_tic_commands.inputs_upto`, migration `0005`); the app stamps each frame it pushes with the newest input the game had taken, read in the frame's own statement; the page times each input to the first frame drawn with a stamp at or past it. Copy stats shows p50 and p90 over the last 200-300 inputs.

Live, owner's browser, frames from the app, full detail, Postgres 19 (17:15 and 17:18 UTC: E1M9 on Ultra-Violence, then E1M8 on Nightmare): input to picture **p50 115 and 111 ms, p90 133 and 131 ms**. Alongside: 35.1-35.7 frames/s, frames 51-54 ms in the app, every frame started on a tic, frames 28-30 ms apart (p50), tic p50 14.3-14.6 ms, ping 27-28 ms.

Where the 113 ms goes (the network parts are half the ping, an estimate; the rest from the same Copy stats):

| Part | ms | Share |
| --- | --- | --- |
| The frame, started as the tic commits | 51-54 | ~46% |
| The network, input in and frame out | ~28 | ~25% |
| Waiting for the next tic (0-28.6 ms) | ~14 | ~12% |
| The tic | ~14 | ~12% |
| Transfer, decode, drawing | a few | the rest |

The p50-to-p90 spread (~20 ms) is the wait for the next tic. Moving input to the frame socket changes only the input's way in: the same network trip, and the app would still write the input to the database; about 1 ms, so it was not built. Shorter input to picture would come from the frame (low detail, about 30-40 ms) or a region nearer the player.

The frame socket carries about 2.2 MB/s before the WebSocket's deflate, and XOR against the previous frame saves only ~3% of it (2,191 of 2,257 KB/s): when the view moves, almost every pixel changes. The deflated size is not visible to the page. It does not show on the owner's link (frames on time); a slow link would see late or skipped frames, not input lag.

The referee's re-plan 60 s into a map (ANALYZE + DISCARD PLANS) costs a few slow tics while the tic statements are planned again: in the 17:18 snapshot, 5 s after the re-plan on E1M8, tic p99 63.7 ms, max 88.4 ms, 3 over budget, p50 unchanged at 14.3 ms.

## Maintenance and planner stability

* **Plan invalidation.** Any VACUUM or ANALYZE of a table a cached plan reads forces a re-plan (15-110 ms spikes; a VACUUM every tic costs about 13 ms per tic on E1M9). Auto-ANALYZE is off on the per-tic tables; the referee runs ANALYZE and `DISCARD PLANS` once after a map change.
* **Bloat on tiny hot tables.** 35 tics/s write about 17,000 dead rows a minute; `player_state` once held 8 live rows in 621 pages, costing about 6 ms per tic and 35% slower frames. Fix: `fillfactor` on the hottest tables, VACUUM FULL when the referee starts, when the first player joins, on a map change and when a table regrows, plain VACUUM every 1050 tics.
* **`work_mem`** 64 MB at database level (8 MB: +6 ms per tic).
* **Generic plans** for the whole tic (forced custom plans are 2.5x slower; the default mode re-planned some statements every tic, see the table above). A generic plan is built from the statistics at its first run, which is why the referee runs ANALYZE and `DISCARD PLANS` again about 60 s into a map, once monsters are awake.
* **The re-plan's statistics reach the frames too** (2026-11-19): statistics are shared, so the frames are planned with the tic's. Only `player_state`'s changed a frame (55 -> 61 ms; `things`, `thing_health`, `monster_ai`, `render_segs`, `sectors` and 25 other game tables: no slowdown, each tested alone on a fresh copy). Leaving it out of the re-plan made the tic 0.7-0.9 ms slower (p50, 2 rounds of 525 tics), so the frame reads it once instead (`me_state`, above).
* **Autovacuum settings** (3-way test, 2026-11-18): ours (`fillfactor` 10 on `player_state`, `monster_ai`, `game_tic_commands`; autovacuum after 1,000 changes) kept the tables small; autovacuum off without `fillfactor` grew `player_state` from 1 to 157 pages in 4 minutes.

## Tried and not kept

| Idea | Result |
| --- | --- |
| `enable_nestloop = off` on all tic functions, or on 12 other heavy ones | slower or noise (projectiles +40 ms) |
| Hashed `NOT IN` in monster step | faster under `EXPLAIN ANALYZE`, not in the game |
| Sight lines as `EXISTS` (with or without `MATERIALIZED`) | 42.8-100 ms, worse |
| One-row CTEs `NOT MATERIALIZED` in the renderer | planning 48 -> 95 ms |
| One colormap string per palette | +225 ms (decompressed per pixel) |
| `doom_const` as an inlinable SQL function | 0 |
| `jit = off`, numeric casts, narrower wall or sprite fences, light lookup table | 0 |
| Postgres 18 | tic about equal, frames 10% slower; stayed on 17. Measured with the previous renderer (Ilia measured LBDoom's renderer on 18 with frames equal and the tic 20-30% faster). Not re-tested: Postgres 19 was measured instead and adopted (above) |
| Leaving `player_state` out of the referee's re-plan `ANALYZE` (2026-11-19) | frames 4-7 ms faster, tic 0.7-0.9 ms slower; replaced by `me_state` (frames as fast, tic unchanged) |
| Sky column by column (2026-11-20): a matview of each sky column stored twice, a lane's 16 sky texels as one `substring` | pictures identical, frames 0.7 ms slower (full) and 0.5 ms (low): a pixel's cost is evaluating its expression (`CASE`, range test, key), not computing the texel's position |
| `REPEATABLE READ` for frames | not run: a frame is one `SELECT`, which already reads one snapshot in `READ COMMITTED` |
| Input on the frame socket (2026-11-20) | not built: measured first (input to picture, above), the input's way in is ~14 of ~113 ms and the same network trip on either socket; about 1 ms to gain |
| Rendering on 4 read replicas | 25 FPS low detail but 9-20 tics of replica lag; overlapping renders stall replay (`hot_standby_feedback` is off) |

## What is left

On E1M9 (8 CU) the tic is about 27-31 ms, spread over many stages, none above 4 ms: monster step 3.8, monster think 3.4, projectiles 2, doors 2, monster chase 1.9, sound 1.8, movement 1.5. Further gains need several small changes. Live on 24 CU with the frames rendered in the app (E1M9 Nightmare, 2026-11-19), the tic was p50 24-25 ms, p99 about 30 ms; on Postgres 19 (2026-11-20, E1M9 Ultra-Violence then E1M8 Nightmare) p50 14.3-14.6 ms.

Input to picture is about 113 ms p50, half of it the frame (above).

The frame: the per-pixel work of floors and ceilings (`plane_lanes`) is the largest single cost; low detail draws half the columns (a frame 43.2 -> 31.8 ms on the 12 E1M9 poses). Frame-time spikes follow the scene (see above). VACUUM FULL during play is off by default (`DOOM_VACUUM_FULL_IN_GAME`); the app logs slow frames with the tic time and the referee's VACUUM / ANALYZE next to them (`frames slow ...` lines, `DOOM_FRAMES_SLOW_LOG=0` to turn off).
