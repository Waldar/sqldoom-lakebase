-- CedarDB built-ins SQLDoom relies on that stock Postgres lacks.
-- Installed into the game schema (search_path) by run_on_lakebase.py; idempotent.
-- ARG_MAX is handled by a query rewrite in cedar2plpgsql.py instead (hot path).

-- MAX/MIN over bytea. STRICT transition => NULL inputs (the common
-- MAX(CASE WHEN .. THEN rgb END) pattern) never call the function.
CREATE OR REPLACE FUNCTION bytea_larger(a bytea, b bytea) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$ SELECT CASE WHEN a >= b THEN a ELSE b END $$;
CREATE OR REPLACE FUNCTION bytea_smaller(a bytea, b bytea) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$ SELECT CASE WHEN a <= b THEN a ELSE b END $$;
CREATE OR REPLACE AGGREGATE max(bytea) (SFUNC = bytea_larger, STYPE = bytea, COMBINEFUNC = bytea_larger, PARALLEL = SAFE);
CREATE OR REPLACE AGGREGATE min(bytea) (SFUNC = bytea_smaller, STYPE = bytea, COMBINEFUNC = bytea_smaller, PARALLEL = SAFE);

-- Float modulo (CedarDB: bigint % double works). fmod semantics: sign of the dividend,
-- like integer %. Only (float8, float8) is defined so int % int keeps the built-ins.
CREATE OR REPLACE FUNCTION float8_mod(a double precision, b double precision) RETURNS double precision
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$ SELECT a - b * trunc(a / b) $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_operator WHERE oprname = '%'
                 AND oprleft = 'float8'::regtype AND oprright = 'float8'::regtype) THEN
    CREATE OPERATOR % (LEFTARG = double precision, RIGHTARG = double precision, FUNCTION = float8_mod);
  END IF;
END $$;

-- render_segs: doors and lifts update f_floor/f_ceil of their segs every tic.
-- With the default fillfactor (100) the pages are full and 11% of those updates
-- could not stay on their page (non-HOT), so the table slowly bloats while
-- every frame reads it. 80% leaves room for in-page (HOT) updates (9 maps:
-- 208 -> 224 pages after VACUUM FULL, 2026-10-23). Takes effect for rows moved
-- by the next VACUUM FULL. Only set when different, because
-- ALTER TABLE makes every connection re-plan statements that read the table.
DO $$ BEGIN
  IF to_regclass('render_segs') IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM pg_class WHERE oid = to_regclass('render_segs')
         AND 'fillfactor=80' = ANY (COALESCE(reloptions, '{}'))) THEN
    ALTER TABLE render_segs SET (fillfactor = 80);
  END IF;
END $$;

-- Spatial index on wall geometry for the monster step / sight-line rewrites in
-- cedar2plpgsql.TARGETED_FIXES (box && box probes). GiST over (map_id, box):
-- map_id needs btree_gist. linedef_geom is a materialized view; the index
-- survives REFRESH. Static per map, ~35 ms to build. If btree_gist cannot be
-- created by this role the game still works, the probes are just not indexed.
DO $$ BEGIN
  IF to_regclass('linedef_geom') IS NOT NULL
     AND to_regclass('linedef_geom_box_gist') IS NULL THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS btree_gist;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'btree_gist unavailable (%), linedef_geom_box_gist not created', SQLERRM;
      RETURN;
    END;
    CREATE INDEX linedef_geom_box_gist ON linedef_geom USING gist
      (map_id, box(point(x1::double precision, y1::double precision),
                   point(x2::double precision, y2::double precision)));
    ANALYZE linedef_geom;
  END IF;
END $$;

-- Lines by special, for the monster door-use statement (cedar2plpgsql.
-- LIVE_TIC_FIXES, chase): its door lines are a handful of the map's ~500.
DO $$ BEGIN
  IF to_regclass('linedef_geom') IS NOT NULL AND to_regclass('linedef_geom_special') IS NULL THEN
    CREATE INDEX linedef_geom_special ON linedef_geom (map_id, special);
    ANALYZE linedef_geom;
  END IF;
END $$;

-- Frame BSP walk (cedar2plpgsql renderer fix R4): node_path_steps holds every
-- map's paths (32,770 rows for 9 maps); each frame needs one map's ~2-6K.
DO $$ BEGIN
  IF to_regclass('node_path_steps') IS NOT NULL
     AND to_regclass('node_path_steps_map_id') IS NULL THEN
    CREATE INDEX node_path_steps_map_id ON node_path_steps (map_id);
    ANALYZE node_path_steps;
  END IF;
END $$;

-- Tic review indexes (cedar2plpgsql.TARGETED_FIXES, REVIEW-TIC): first seg of a
-- subsector for doom_sector_at, and a sector's lines for doom_cs_discover.
-- Only once the tables exist (a fresh database runs this before the schema).
DO $$ BEGIN
  IF to_regclass('render_segs') IS NOT NULL AND to_regclass('sidedefs') IS NOT NULL
     AND to_regclass('linedefs') IS NOT NULL THEN
    CREATE INDEX IF NOT EXISTS render_segs_ssector ON render_segs (map_id, ssector_id, seg_id) INCLUDE (fsec);
    CREATE INDEX IF NOT EXISTS sidedefs_sector ON sidedefs (map_id, sector_id);
    CREATE INDEX IF NOT EXISTS linedefs_right_sd ON linedefs (map_id, right_sd_id);
    CREATE INDEX IF NOT EXISTS linedefs_left_sd ON linedefs (map_id, left_sd_id);
  END IF;
END $$;

-- No VACUUM truncation on game tables. The truncate step waits for an
-- exclusive lock for up to 5 s (VacuumTruncate, not bounded by lock_timeout);
-- the referee vacuums between tics, so the game froze for 5 s whenever frame
-- queries held the table. VACUUM FULL (referee) still shrinks the files.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::regclass AS rel FROM pg_class c
           WHERE c.relnamespace = current_schema()::regnamespace AND c.relkind = 'r'
             AND NOT ('vacuum_truncate=false' = ANY (COALESCE(c.reloptions, '{}')))
  LOOP
    EXECUTE format('ALTER TABLE %s SET (vacuum_truncate = false)', r.rel);
  END LOOP;
END $$;

-- Map chosen from the app page (POST /api/match/map). At most one row; the
-- referee writes it and ends the level, doom_mp_next_map returns it,
-- doom_mp_rotate deletes it, api_match shows it as next_map (see
-- cedar2plpgsql.TARGETED_FIXES and doomapp/referee.py). Only once the schema
-- exists: on a fresh database the first referee start creates it next time.
DO $$ BEGIN
  IF to_regclass('mp_match') IS NOT NULL THEN
    CREATE TABLE IF NOT EXISTS mp_map_request (
      id boolean PRIMARY KEY DEFAULT true CHECK (id),
      map_name text NOT NULL,
      requested_at timestamptz NOT NULL DEFAULT now());
  END IF;
END $$;

-- CedarDB assigns text to enum columns implicitly (e.g. SET mode = CASE .. THEN 'full' END).
-- Postgres needs an assignment cast per enum type. (cedar2plpgsql.ShimCursor also adds
-- this right after each CREATE TYPE .. AS ENUM on fresh installs.)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT t.oid::regtype AS typ FROM pg_type t
           WHERE t.typtype = 'e' AND t.typnamespace = current_schema()::regnamespace
             AND NOT EXISTS (SELECT 1 FROM pg_cast c WHERE c.castsource = 'text'::regtype AND c.casttarget = t.oid)
  LOOP
    EXECUTE format('CREATE CAST (text AS %s) WITH INOUT AS ASSIGNMENT', r.typ);
  END LOOP;
END $$;

-- Status-bar cache (cedar2plpgsql.hudcache_view_sql): one row per map and
-- slot, the 10240 status-bar bytes for the HUD state `key` describes. Written
-- by the referee's HUD worker on the primary; frame views use it only when
-- the key matches the live state.
CREATE TABLE IF NOT EXISTS hud_cache (
  map_id     int NOT NULL,
  slot       int NOT NULL,
  key        text NOT NULL,
  bar        bytea NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (map_id, slot)
);

-- Who is calling, for the player API. Upstream resolves the player by
-- session_user (one database role per player). In the app every browser logs
-- in as the app's identity, so the relay names the player in the session's
-- startup options (-c doom.player=<email>#<tab>); the browser cannot change
-- it (the relay only lets the page's own statements through). Without the
-- setting this is session_user, as upstream. cedar2plpgsql rewrites every
-- session_user::text in the API to doom_caller() (CAST form here on purpose).
CREATE OR REPLACE FUNCTION doom_caller() RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE AS $$
  SELECT COALESCE(NULLIF(current_setting('doom.player', true), ''), CAST(session_user AS text))
$$;

-- Game modes (doomapp/referee.py drives the switches):
--   solo        one player: monsters, nothing respawns, single-player items.
--   deathmatch  2+ players: no monsters, items respawn after 30 s, weapons
--               stay on the ground (DM 1.0), multiplayer-only items appear,
--               keys are not in the level and every player holds all three.
-- mp_match.mode is the current mode; mp_match.pending is what the running
-- intermission leads to: 'deathmatch' (countdown, a 2nd player joined),
-- 'final' (deathmatch over, waiting for the choice; single player when
-- it times out), 'stay' / 'solo' (the choice). doom_mp_rotate calls
-- doom_mp_apply_mode before it opens the map (cedar2plpgsql.TARGETED_FIXES).
-- Also 'restart' (solo death with "restart the level", the tic sets it) and
-- 'rules' (Player 1 changed monsters or difficulty): the same map again, same
-- mode, after a 3 s intermission.
DO $$ BEGIN
  IF to_regclass('mp_match') IS NOT NULL THEN
    ALTER TABLE mp_match ADD COLUMN IF NOT EXISTS mode text NOT NULL DEFAULT 'solo';
    ALTER TABLE mp_match ADD COLUMN IF NOT EXISTS pending text;
    ALTER TABLE mp_match ADD COLUMN IF NOT EXISTS weapons_stay boolean NOT NULL DEFAULT false;
    ALTER TABLE mp_match ADD COLUMN IF NOT EXISTS death_restart boolean NOT NULL DEFAULT false;
  END IF;
END $$;

-- The rules of each mode, set by Player 1 (the player seated longest) from
-- the page (POST /api/match/rules). Fixed by mode, not here: keys (in the
-- level in solo, everyone holds all in deathmatch), multiplayer-only items
-- (off / on) and death (solo may restart the level; deathmatch respawns).
-- monsters and skill need a level restart; the rest applies at once.
CREATE TABLE IF NOT EXISTS mp_rules (
  mode              text PRIMARY KEY CHECK (mode IN ('solo', 'deathmatch')),
  monsters          boolean NOT NULL,
  skill             int     NOT NULL CHECK (skill BETWEEN 0 AND 4),
  monster_respawn   boolean NOT NULL,
  monster_respawn_s int     NOT NULL CHECK (monster_respawn_s BETWEEN 1 AND 600),
  item_respawn      boolean NOT NULL,
  item_respawn_s    int     NOT NULL CHECK (item_respawn_s BETWEEN 1 AND 600),
  weapons_stay      boolean NOT NULL,
  death_restart     boolean NOT NULL,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        text
);
INSERT INTO mp_rules (mode, monsters, skill, monster_respawn, monster_respawn_s, item_respawn, item_respawn_s,
                      weapons_stay, death_restart)
VALUES ('solo',       true,  2, false, 12, false, 30, false, true),
       ('deathmatch', false, 2, false, 12, true,  30, true,  false)
ON CONFLICT (mode) DO NOTHING;

-- The live rules of the current mode into the match row and the two respawn
-- delays (doom_const reads doom_constants on every call).
CREATE OR REPLACE FUNCTION doom_mp_rules_live() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE r mp_rules%ROWTYPE;
BEGIN
  SELECT x.* INTO r FROM mp_rules x JOIN mp_match m ON m.mode = x.mode LIMIT 1;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  UPDATE mp_match SET respawn_monsters = r.monster_respawn, altdeath = r.item_respawn,
                      weapons_stay = r.weapons_stay, death_restart = r.death_restart AND r.mode = 'solo';
  UPDATE doom_constants SET value = r.item_respawn_s * 35 WHERE name = 'ITEM_RESPAWN_TICS' AND value <> r.item_respawn_s * 35;
  UPDATE doom_constants SET value = r.monster_respawn_s * 35 WHERE name = 'MONSTER_RESPAWN_TICS' AND value <> r.monster_respawn_s * 35;
  RETURN 1;
END $$;

-- Things whose flags differ between the modes: multiplayer-only items
-- (MTF_NOTSINGLE, flag 16) lose the flag in deathmatch, keys gain it (vanilla
-- MF_NOTDMATCH: no keys in a deathmatch). Every stage already skips flag-16
-- things, so flipping ~70 rows changes the world without touching the tic or
-- the renderer.
CREATE TABLE IF NOT EXISTS mp_dm_things (
  map_id     int NOT NULL,
  thing_id   int NOT NULL,
  solo_flags int NOT NULL,
  dm_flags   int NOT NULL,
  PRIMARY KEY (map_id, thing_id)
);

CREATE OR REPLACE FUNCTION doom_mp_world_flags(p_dm boolean) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
  -- Recorded from the solo flags, once per thing (a flipped thing no longer
  -- matches the condition, and ON CONFLICT keeps the first record).
  INSERT INTO mp_dm_things (map_id, thing_id, solo_flags, dm_flags)
  SELECT t.map_id, t.id, t.flags,
         CASE WHEN d.kind::text LIKE 'key\_%' THEN t.flags | 16 ELSE t.flags & ~16 END
  FROM things t JOIN pickup_defs d ON d.thing_type = t.type
  WHERE ((t.flags & 16) <> 0) <> (d.kind::text LIKE 'key\_%')
  ON CONFLICT (map_id, thing_id) DO NOTHING;
  UPDATE things t
  SET flags = CASE WHEN p_dm THEN x.dm_flags ELSE x.solo_flags END
  FROM mp_dm_things x
  WHERE t.map_id = x.map_id AND t.id = x.thing_id
    AND t.flags <> CASE WHEN p_dm THEN x.dm_flags ELSE x.solo_flags END;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION doom_mp_apply_mode() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE p text; cur_mode text; new_mode text;
BEGIN
  SELECT pending, mode INTO p, cur_mode FROM mp_match LIMIT 1;
  IF p IS NULL THEN
    RETURN 0;
  END IF;
  new_mode := CASE WHEN p IN ('deathmatch', 'stay') THEN 'deathmatch'
                   WHEN p IN ('final', 'solo') THEN 'solo'
                   ELSE cur_mode END;               -- 'restart', 'rules'
  UPDATE mp_match m SET mode = new_mode, pending = NULL, monsters = r.monsters, skill = r.skill
  FROM mp_rules r WHERE r.mode = new_mode;
  PERFORM doom_mp_rules_live();
  PERFORM doom_mp_world_flags(new_mode = 'deathmatch');
  RETURN 1;
END $$;

-- A tic slot with something to do: its player is seated or still alive
-- (cedar2plpgsql.tic_core_slot_gates). doom_server passes all 4 slots to
-- every tic; an empty, dead slot skips the per-player stages.
CREATE OR REPLACE FUNCTION doom_slot_active(p_map_id integer, p_player_thing_id integer) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM mp_players mp WHERE mp.map_id = p_map_id
                   AND mp.player_thing_id = p_player_thing_id AND mp.role_name IS NOT NULL)
      OR EXISTS (SELECT 1 FROM player_state ps WHERE ps.map_id = p_map_id
                   AND ps.player_thing_id = p_player_thing_id AND ps.alive)
$$;

-- COLORMAP for the indexed frame views as one 256-byte row per palette and
-- light level (14 x 34 = 476 rows): a frame reads a pixel's colour with
-- substring(bytes FROM palette_index + 1 FOR 1) instead of joining the
-- palette's 8,704 colormap_rgb rows (cedar2plpgsql.frame_tail_view_sql).
-- Small rows on purpose: one 8.7 KB string per palette is TOASTed and was read
-- again for every pixel (+225 ms per frame). Rebuilt when the WAD's colormap
-- changes (row count or content).
DO $$
BEGIN
  IF to_regclass('colormap_rgb') IS NULL THEN
    RETURN;
  END IF;
  IF to_regclass('colormap_idx_lvl') IS NULL THEN
    CREATE TABLE colormap_idx_lvl (pal smallint NOT NULL, level integer NOT NULL, bytes bytea NOT NULL,
                                   PRIMARY KEY (pal, level));
  END IF;
  IF (SELECT md5(string_agg(pal || ':' || level || ':' || encode(bytes, 'hex'), ',' ORDER BY pal, level)) FROM colormap_idx_lvl)
     IS DISTINCT FROM
     (SELECT md5(string_agg(pal || ':' || level || ':' || encode(bytes, 'hex'), ',' ORDER BY pal, level))
        FROM (SELECT pal, level, string_agg(set_byte('\x00'::bytea, 0, mapped_index::int), ''::bytea ORDER BY palette_index) AS bytes
                FROM colormap_rgb GROUP BY pal, level) s) THEN
    DELETE FROM colormap_idx_lvl;
    INSERT INTO colormap_idx_lvl (pal, level, bytes)
    SELECT pal, level, string_agg(set_byte('\x00'::bytea, 0, mapped_index::int), ''::bytea ORDER BY palette_index)
    FROM colormap_rgb GROUP BY pal, level;
    ANALYZE colormap_idx_lvl;
  END IF;
END $$;
