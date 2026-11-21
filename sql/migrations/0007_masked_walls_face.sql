-- 2026-11-20 (owner: grates drawn as stripes, the face reacts less than Doom's).
--
-- See-through walls: a wall texture's coverage, one byte a texel, 1 where a
-- patch covers it (sqldoom.wad.loader.composite_wall_textures). NULL when
-- every texel is covered (all but the grates), and on a database loaded
-- before this migration until tools/backfill_texture_masks.py has run: the
-- renderer then draws the texture opaque, as before. Doom leaves an
-- uncovered texel of a two-sided line's middle texture undrawn
-- (R_RenderMaskedSegRange), so what is behind shows through.
ALTER TABLE doom.walltex_meta ADD COLUMN IF NOT EXISTS mask bytea;
DO $lz4$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_settings WHERE name = 'default_toast_compression' AND 'lz4' = ANY (enumvals)) THEN
    ALTER TABLE doom.walltex_meta ALTER COLUMN mask SET COMPRESSION lz4;
  END IF;
END
$lz4$;

-- The status bar face, as Doom's ST_updateFaceWidget (doom_cs_face): the
-- patch shown, the level tic it lasts until (st_facecount as an end, so the
-- row only changes when the face does; NULL: this tic only, a face held
-- while its condition lasts), its priority, the health one tic ago
-- (st_oldhealth), the tic fire started being held (lastattackdown; NULL
-- when not held), the weapons owned as a bitmask (oldweaponsowned; -1: take
-- the current ones, at a spawn) and who last hurt the player
-- (plyr->attacker, a things.id; NULL for the world: nukage, a crusher).
ALTER TABLE doom.player_state
  ADD COLUMN IF NOT EXISTS face_patch text NOT NULL DEFAULT 'STFST00',
  ADD COLUMN IF NOT EXISTS face_until integer,
  ADD COLUMN IF NOT EXISTS face_priority integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS face_old_health integer NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS face_fire_since integer,
  ADD COLUMN IF NOT EXISTS face_weapons integer NOT NULL DEFAULT -1,
  ADD COLUMN IF NOT EXISTS attacker_id integer;
