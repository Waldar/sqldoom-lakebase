# Next steps (planned 2026-11-18; status 2026-11-26)

## Status

Every step of the plan below has shipped, and both ideas of section 5:

* **0. Frames in flight:** shipped (`1843bd3`, growth rule fixed the next day); with step 3 the rule moved to the app's render threads.
* **1. Cheat codes:** shipped (`aab9a36`): `api_cheat_key`, single player only, through the relay's allow-list.
* **2. Music:** shipped (`dcb57bc`), with audio: `src/sqldoom/wad/midi.py` renders with `tinysoundfont` and the TimGM6mb soundfont next to the WAD, as a setup step (`music`) or `tools/render_music.py`; the Music box became a volume slider (`34301a1`).
* **3. Frames rendered in the app:** shipped (`src/sqldoom/server/frames.py`; details in section 3), frames started on each tic, the camera read from `player_state`. Input on the same socket: measured first, then dropped (below).
* **4. Low detail:** generated from the full-detail template by `tools/make_low_detail.py` (`--check` fails when stale); 17-28% faster than full detail (`docs/PERFORMANCE.md`).
* **5. Ideas:** the "I'M A SHAMELESS CHEATER" list in single player, and "Always run" (on by default, Shift walks).

Also done since (2026-11-20):

* lz4 for the columns every frame decompresses (`cb3b353`, migration `0002`).
* The app moved to Postgres 19, project `projects/sqldoom-19` (`c48deea`, `a0c8e58`, `dfa66f9`; measurements in `docs/PERFORMANCE.md`). The old Postgres 17 project `projects/sqldoom` is kept as the rollback for a few days.
* Sounds checked against the Doom source and fixed (`4734a1f`, `609d543`): fist, doors, lifts, switches, use, power-ups, teleporter, bites, chainsaw, the player's own sounds centred, BFG on the charge, landing "oof", stereo width, E1M8's volume floor.
* Players gib (`ee275c1`, migration `0003`): the killing blow's unclamped health, `DSSLOP` and the gib frames.
* No fixed-rules notes under the rules form.
* The view dips after a hard landing, as Doom's `P_CalcHeight` (`0195049`, migration `0004`).
* Input to picture measured in the page (`a18abb9`, migration `0005`): frames stamped with the newest input the game had taken, the first frame drawn with an input timed from its key or button event, in Copy stats. Live: 111-115 ms p50, 131-133 ms p90 (`docs/PERFORMANCE.md`, "Input to picture").
* A spare single-player branch made ahead (`efb1677`): Postgres 19 has no warm compute pool yet (LKB-19068), so a new branch takes 15-24 s to start; a game takes the spare and is ready in about 1.5 s.
* Monsters respawn exactly the set time after death when the rule is on, as items; Nightmare without it keeps Doom's own respawn (12 s or more, at random).
* Single player keeps health, armor, backpack, ammo, weapons and cheats from one level to the next (its exit only; keys and power-ups go, as Doom's `G_PlayerFinishLevel`; migration `0006`).
* Quick save / quick load (F6 / F9, one save per player) on Lakebase branches (`docs/DEPLOYMENT.md`, "Quick save and quick load").
* Single player's screens between levels (2026-11-21, migration `0009`): Doom's map order (E1M3's secret exit to E1M9, E1M9 back to E1M4, E1M8 ends the episode), the intermission (stats counting up with Doom's timings and sounds, then the episode map with splats and the blinking arrow) with `D_INTER`, and the end of Episode 1 (the text typed over `FLOOR4_8`, then `HELP2`) with `D_VICTOR`, then back to the lobby. SQL: `doom_solo_level_end`, `doom_solo_screen_tic`, the view `api_screen_frame` (drawn by the app's frame threads while the referee runs the screens). Deathmatch keeps its rotation and frag table.

Also done since (2026-11-22 to 11-25):

* The intermission's episode map moves as Doom's `wi_stuff.c` (`1789b11`, migration `0010`), and its frames are back to 12-14 ms (`89bda5a`).
* Monsters as Doom's `A_Chase`, `A_Look`, `P_CheckSight` and `P_CheckMissileRange` (`e39d12e`, migration `0011`), from three owner reports: a shove stops when the body touches a wall, a ledge or a closed door, and a monster touching a line may step away (no more monsters stuck in walls or lifts); sight is narrowed by every opening's height (no shots through windows); missiles with Doom's timing and distance dice; a deaf monster that hears the player wakes only when it sees them; Doom's walking speeds (`monster_chase_defs`). E1M9 combat tic p50 28.8 -> 21.6 ms (16 CU).
* Crossing another W1 line of the same tag after its door is open (the four around E1M6's red key) no longer replays the opening sound (`39f146e`).
* A closing door goes back up for a monster whose body reaches under it from the next sector, not only for one whose centre is in it (`de331b4`).
* Single player defaults: Hurt me plenty, no monster or item respawn (2026-11-25, `doom.mp_rules` on `production` and `game-template`; the seed already had them).
* The repository's QR code on the page, first card of the right column (`94abd5c`).
* Frame profile on Postgres 19, the status-bar cache writer off (`b24e285`) and the never-taken texel checks removed (`a5177bf`, about 1%): `docs/PERFORMANCE.md`, "Frame profile on Postgres 19".

Considered and dropped (2026-11-24 to 11-26): DHTP high-resolution textures (they show only at 640x400 or more, an estimated 150-250 ms a frame); a no-shimmer frame view for frames without spectres (3 ms slower once the choice is made inside the view); a CPU for the tic, frames on read replicas (the lag made an older version unplayable); `REPACK (CONCURRENTLY)` instead of `VACUUM FULL` (little bloat in a game's branch, slower than plain `REPACK`). Measurements in `docs/PERFORMANCE.md`, "Tried and not kept".

Dropped (owner, 2026-11-20):

* Input on the frame socket (step 3): the input's way in is about 14 ms of the 113 ms, the same network trip on either socket, and the database write stays; it would save about 1 ms.
* Doom's approximate sound distance (`P_AproxDistance`). (`D_INTER` came back with the intermission, 2026-11-21.)

Open:

* Delete `projects/sqldoom` once Postgres 19 has run for a few days.
* Input to picture with low detail on: the frame is about half of it, low detail should take 15-20 ms off (not measured yet).

The plan as written on 2026-11-18 follows, with the progress notes added while it was done.

State when this was written: `main` at `164e97f`, live on `sqldoom-ltap`. Full-detail frames from LBDoom's 2026-11-17 renderer (~45 ms at the database, 24 CU), 35 frames/s on 2 connections in the owner's browser once `localStorage.doomPipeline` was cleared. Ilia's code: Git folder `/Users/fabien.contaminard@databricks.com/LBDoom-latest` (his `main` `2bb97bd`; clone with the `github-databricks` credential, his GitHub has an IP allow list).

Progress (2026-11-19, superseded by the status above): 0 shipped (`1843bd3`; growth rule fixed after the owner saw auto still climb to 6, see 0), 1 shipped (`aab9a36`, works), 2 shipped (`dcb57bc`: the Music box is there, no audio yet: the tracks need a General MIDI soundfont on the workspace, then `tools/render_music.py` on game-template and production). 3 and 4 not started; 4 is bigger than planned (below).

Order: 0 first (small, and its rule carries over to 3); 1 and 2 are small and independent; 3 is the big one; 4 can come before or after 3 (the frame views do not change with 3).

## 0. Frames in flight: the fewest connections that keep 35 frames/s (small)

Today (`web/host.js`, "auto"): every 2 s it looks at the tic only: 34+ tics/s with a p75 under 27 ms adds a frame connection, up to 6; under 32 tics/s or a p75 over 32 ms takes one away, down to 2. It never looks at the frame rate, so it climbs to 6 even when 2 already give 35 frames/s (2026-11-18: 34.9 frames/s on 2 connections, ~45 ms a frame at the database). And each request paces itself (`pace()` in `web/game/app.js`: one every max(28.6 ms, average round trip / requests in flight)), not a common clock.

Goal (owner's call): aim at 35 frames/s, with the number of connections that rate needs, frames handed out in turn; the tic keeps priority.

* **One 35 Hz clock, round robin:** every 28.6 ms the page sends the next frame request (camera + frame) to the next connection in turn that has fewer than 2 requests outstanding (the pipeline depth). If every connection is full, that slot is skipped and counted ("pool full"). Replaces the per-request `pace()`; sequence numbers and dropping a frame older than one already drawn stay.
* **Connections needed:** with 2 requests queued, a connection delivers up to 1000 / (frame time at the database) frames/s, so needed = ceil(35 x frame ms / 1000 x 1.15). That is 2 at ~45 ms (full detail now), 4 at ~90 ms (low detail before step 4). The page already knows the database time of each frame (the relay's `frame_ms`).
* **Controller, every 2 s** (in `host.js`, which already polls the tic):
  * tic slow (p75 > 27 ms or under 34 tics/s): one connection fewer, down to 1, even if frames/s drop: the game first;
  * else frames/s under 33.5, or "pool full" more than 5% of slots: one more, up to min(needed + 1, 6);
  * else 35 frames/s and more connections than needed for 10 s: one fewer (hysteresis, so it does not oscillate).
* **Stats:** Copy stats and the side panel show the connections needed, "pool full" %, and frames/s against the 35 target.
* **Size:** ~150 lines in `web/game/app.js` (clock, round robin, "pool full") and `web/host.js` (controller, stats). The manual choices (1, 2, 4, 6) stay.
* **Tests:** in the browser: E1M1 full detail settles on 2 at 35 frames/s; low detail (still ~90-105 ms until step 4) on 4; a big fight on E1M9 that slows the tic takes connections away; switching full/low detail re-settles within 10 s; the frame rate no worse than with today's auto at every point. Copy stats before/after.
* **Fix (2026-11-19):** the first version also grew on frames/s under 33.5 alone, and the owner saw auto climb to 6: with every slot taken, a frame rate short for another reason (network, frames out of order) kept adding connections, each slowing every frame a little, which raised "needed" and so the cap. Now it grows only when pool full > 5%, undoes a growth that did not raise the frame rate by 1 within 6 s (that size is then the most for 60 s), and also shrinks when pool full stays under 1%.
* **With step 3** the same rule moves server-side: renders in flight per seat, started on each tic (LBDoom's `_pace_renderers` only watches the tic; ours adds the 35 frames/s target).

## 1. Cheat codes, single player only (small)

The SQL is there (`sql/functions/game/doom_cheat_key.sql`, `doom_cheat.sql`, `doom_cheat_arsenal.sql`, from SQLDoom), nothing calls it.

* `sql/functions/api/api_cheat_key.sql`: `api_cheat_key(p_key text) RETURNS text`, SECURITY DEFINER like the other `api_*`: the caller's seat (`doom_caller()`), only when the match is in solo mode, then `doom_cheat_key` for that map and player; returns what the page must act on (as LBDoom's `cheat_key` statement, `doom_sql.py`).
* Relay: add the statement to the allow-list (`src/sqldoom/server/relay.py`).
* Page (`web/game/app.js`): while playing in solo, letters typed go to `api_cheat_key` (not while the automap or a menu takes them); show the answer ("Degreelessness mode on") as Doom's message line does.
* Check which cheats need more than SQL: `idclev` (level warp) changes map, so it must go through the referee's rotation (or be left out at first); `idmus` changes music (with 2).
* Test: on a scratch branch, `iddqd`, `idkfa`, `idfa`, `idclip`, `idbehold*` each change the player's state as Doom does; in a multiplayer match the function refuses.

## 2. Music, single player only, with a music box next to Low detail (small to medium)

The page plays music already (`Audio.setMusic`, `api_stage_music`), but `music_assets` has no audio: `src/sqldoom/wad/midi.py` only renders through `libfluidsynth`, which the setup's compute does not have ("Music will have no rendered audio").

* `src/sqldoom/wad/midi.py`: add LBDoom's fallback (`midi_render.py`): `tinysoundfont` + `soundfile` from pip, with a General MIDI soundfont (`DOOM_SOUNDFONT`, or one of the usual paths). Check the soundfont's licence before shipping one; else the setup asks for its path.
* `tools/render_music.py` (as LBDoom's `scripts/render_music.py`): renders the 13 tracks once and writes `music_assets.audio_data` on a branch; then a setup step `music` (idempotent: only tracks without audio), and a one-off run on `game-template`. Data, not code: the installer does not touch it.
* Page: a "Music" box next to "Low detail" in `web/index.html` / `web/host.js`, shown in single player only, remembered per browser (like low detail); off = `stopMusic()` and no `api_stage_music` fetch. Multiplayer: no music (as today).
* Test: 13 tracks with audio; E1M1 plays D_E1M1 and a map change switches track; the box off stops it at once; no music in a multiplayer game.

## 3. Frames rendered in the app, pushed to the browser (big)

**First version shipped 2026-11-19** (`src/sqldoom/server/frames.py`, route `/frames`): per player tab, render threads in the app (its own connections, logged in as the player) on one 35 Hz clock in turn, the same camera + frame views, one sender pushing the newest frame XOR-coded; the page's first render connection stands in for the stream (camera answered at once, a frame = the next one pushed), so its clock, drawing and stats are unchanged; the automap stays on that connection; auto's connection count, the view and pause go to the app; the page falls back to its own connections if the socket fails; `localStorage.doomServerFrames = '0'` forces the old path. Checked on a scratch branch: frames byte-identical to the views (full and low detail, decoded by the page's own code), 35 frames/s on 3 threads, pause, view check. The owner saw it hold 35 frames/s on 3 render threads, auto settling there by itself. **Then (same day): frames start on each tic commit** (Metrics.wait_tic, notified when the referee's tic sample arrives, right after the committed tic statement; no tic for 200 ms: 5 frames/s; DOOM_FRAMES_ON_TIC=0: the 35 Hz clock), checked with a stand-in game loop at 35 tics/s: 34.8 frames/s, 100% started on a tic, 5/s once the tics stopped; and Copy stats describes this mode (database time in the app, started-on-tic share, the frame socket's KB/s, no network share). **Then: the camera from player_state** (the frame views' pos reads the newest tic's pose with api_camera's alpha-1 arithmetic through real: 60/60 poses on 3 maps byte-identical to the api_camera(1.0) pose, full and low detail, moving and turning across 0/360); the app calls api_camera about once a second per thread, only for the seat's last_seen (16 mp_players updates in 5 s instead of one per frame, ~172). **And auto accounts for contention** (frames slower with more threads): the frame time at each count is remembered, one fewer is tried after 30 s at target with pool full 0 unless the time at n - 1 says too few; simulated with frames +10 ms per thread: 5 -> 3 and stays, 2 s under 34 frames/s in 5 minutes. Not yet: input on the same socket.

Why: the browser asks for every frame across the internet (~15-30 ms each way here). Pipelining hides it for the frame rate, but each frame still starts on the browser's clock and after a trip to the app. LBDoom's app (`webapp/engine.py`) renders next to the database and pushes finished frames: a frame starts the moment a tic commits and draws that tic; the network only delays the picture.

Design (LBDoom's, fitted to ours):

* **Where:** in the referee's child process (one per game, `src/sqldoom/game/server.py`), which already owns the tic and knows when it commits. Render threads, each with its own connection (`jit = off`, `plan_cache_mode = force_generic_plan`, `synchronous_commit = off`, `work_mem = 8MB` as LBDoom), `SET doom.player` to the seat's player so the frame views work unchanged.
* **When:** each render waits for a tic no frame has drawn yet (LBDoom `_claim_tic`), at most 35 a second. Renders in flight per seat adapted every half second to keep the tic under budget (LBDoom `_pace_renderers`: down above 26 ms at p75, up under 22 ms).
* **Camera:** with frames on the tic, `api_camera`'s per-frame write is no longer needed: the view's `pos` can read the pose from `player_state` (its newest tic). That also stops the per-frame churn of `mp_players`.
* **Transport:** child -> app parent (a pipe per game), parent -> each player's tab over one WebSocket (`/frames?game=&tab=`), with the relay's delta + deflate (`DeltaCoder`). Input can stay on the page's Postgres connection at first (it already goes out at once on key changes), or move to the same socket later.
* **Page:** the render pool (`web/game/app.js`) replaced by a frame receiver: decode, draw newest, drop older (LBDoom's `drawNewest`); stats from the server (database time, renders in flight, tic->frame) plus the browser's own (arrival, decode). Keep the old pool behind a switch for A/B (shown in Copy stats).
* **Multiplayer:** each seated player gets its own renders; CPU is the same as today (the frames are the same queries), the app's deflate work moves from the relay to the frame socket.
* **Size:** about 600-900 lines changed: the child's render threads and tic signal (~250), the parent's frame socket and per-tab routing (~200), the page's receiver and stats (~250, minus the pool), docs. One or two sessions, then a play test solo and with 2-4 tabs.
* **Tests:** frames byte-identical to today's views for the same tic (same SQL); 35 frames/s on 2 renders per seat on 12 and 24 CU; tic p50/p99 no worse than today (`tools/bench.py` and the play harness used for the vacuum comparison); input -> first frame with it, measured in the page (LBDoom's `?lag=1` is the model).

## 4. Low detail at least as fast as full detail (medium to large)

Found when starting it (2026-11-19): the old low detail drew even columns only (`generate_series(a + (a & 1), b, 2)`) and laid the 160 x 168 view out pixel by pixel. LBDoom's renderer packs eight palette indices per 64-bit word (`view_rows` r0..r15: 40 groups of 8 columns, bands of 16 rows, around lines 2430-2550 of the template), so low detail needs its own packing for 160 columns (20 groups), not just the even-column rewrite. The column ranges to step by two: lines ~474 (occlusion), 639 (walls), 1107 and 1128 (player sector planes), 1725 (sprites), 2034 (weapon); `occlusion_arr` (496) is indexed by column and stays 320 wide.

LBDoom has no low detail. Ours (`sql/frame_views/api_frame_idx_slotS_mM_low.sql`) is still the previous renderer (~90-105 ms, the full-detail views now ~45 ms), so it is slower than full detail.

* Make the low-detail template from the full-detail one (LBDoom's renderer as converted, `api_frame_idx_slotS_mM.sql`), as the old one was made from the old: the scene's columns stepped by two (160 instead of 320, `generate_series(lo, hi, 2)` where columns are generated, the column count and pixel arithmetic of the frame tail for 160 x 168), the status bar unchanged at 320 x 32. Output 37,121 bytes, which the page already expands (`expandLow`).
* A generator instead of a hand edit: `tools/make_low_detail.py` rewrites the full-detail template's anchors and fails if one is missing, so the next renderer update regenerates both.
* Test, strict: on the same pose, every low-detail scene pixel equals the full-detail frame's pixel at the even column (byte-identical after `expandLow`'s doubling, except where Doom's low detail itself differs: compare with the previous low view too); status bar identical; timing on all 9 maps with `tools/frame_compare.py` (adapted for the `_low` views): low must be faster than full detail.

## 5. Ideas (owner, 2026-11-19; not planned yet)

* **"I'M A SHAMELESS CHEATER" in single player:** the scoreboard card (right column of `web/index.html`, filled by `renderScoreCard` in `web/host.js`) is pointless with one player; in a single-player game, replace it with a box "I'M A SHAMELESS CHEATER" that opens a menu listing Doom's cheat codes (iddqd, idkfa, idfa, idclip/idspispopd, idbehold v/s/i/r/a/l, idchoppers, idclev EM, idmus EM, iddt, idmypos) and what each does. A list only: the player still types them (step 1). Multiplayer keeps the scoreboard. Small: host page only.
* **Run by default, Shift to walk:** today Shift runs (`web/game/app.js`, `const run = enabled && down('ShiftLeft', 'ShiftRight')`, sent to `api_input` as its run flag). Invert it: run unless Shift is held, as Doom's "always run" (`joyb_speed 29`). Probably a setting next to Low detail and Music (remembered per browser), default on; the help text and the key list on the page to match. Small: page only, the tic already takes the flag.
