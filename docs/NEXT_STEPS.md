# Next steps (planned 2026-11-18, not started)

State when this was written: `main` at `164e97f`, live on `sqldoom-ltap`. Full-detail frames from LBDoom's 2026-11-17 renderer (~45 ms at the database, 24 CU), 35 frames/s on 2 connections in the owner's browser once `localStorage.doomPipeline` was cleared. Ilia's code: Git folder `/Users/fabien.contaminard@databricks.com/LBDoom-latest` (his `main` `2bb97bd`; clone with the `github-databricks` credential, his GitHub has an IP allow list).

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

## 4. Low detail at least as fast as full detail (medium)

LBDoom has no low detail. Ours (`sql/frame_views/api_frame_idx_slotS_mM_low.sql`) is still the previous renderer (~90-105 ms, the full-detail views now ~45 ms), so it is slower than full detail.

* Make the low-detail template from the full-detail one (LBDoom's renderer as converted, `api_frame_idx_slotS_mM.sql`), as the old one was made from the old: the scene's columns stepped by two (160 instead of 320, `generate_series(lo, hi, 2)` where columns are generated, the column count and pixel arithmetic of the frame tail for 160 x 168), the status bar unchanged at 320 x 32. Output 37,121 bytes, which the page already expands (`expandLow`).
* A generator instead of a hand edit: `tools/make_low_detail.py` rewrites the full-detail template's anchors and fails if one is missing, so the next renderer update regenerates both.
* Test, strict: on the same pose, every low-detail scene pixel equals the full-detail frame's pixel at the even column (byte-identical after `expandLow`'s doubling, except where Doom's low detail itself differs: compare with the previous low view too); status bar identical; timing on all 9 maps with `tools/frame_compare.py` (adapted for the `_low` views): low must be faster than full detail.
