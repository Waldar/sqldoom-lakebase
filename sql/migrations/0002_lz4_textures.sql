-- lz4 for the texture and sprite columns every frame decompresses (the frame
-- views' frame_walltex, frame_flats and sprite patches: || ''::bytea once a
-- frame). 2026-11-20, on two copies of game-template at 12 E1M9 Nightmare
-- poses: decompressing all of them 4.0 -> 2.8 ms, a frame 43.8 -> 43.2 ms
-- full detail and 32.0 -> 31.8 ms low, pictures byte-identical. Stored a
-- little larger (lz4 compresses less than pglz). The status bar and colormap
-- bytes are materialized views: their files set it (sql/matviews).
-- Existing rows are rewritten once (SET COMPRESSION only applies to new
-- values); on an empty schema the WAD loader's inserts take lz4. A build
-- without lz4 keeps pglz.
DO $lz4$
DECLARE
  c record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_settings WHERE name = 'default_toast_compression'
                 AND 'lz4' = ANY (enumvals)) THEN
    RAISE NOTICE 'lz4 not available in this build: texture columns stay pglz';
    RETURN;
  END IF;
  FOR c IN SELECT * FROM (VALUES ('walltex_meta', 'palette_indices'), ('flat_textures', 'palette_indices'),
                                 ('sprite_lumps', 'pixels'), ('sprite_lumps', 'mask')) v(tbl, col)
  LOOP
    EXECUTE format('ALTER TABLE doom.%I ALTER COLUMN %I SET COMPRESSION lz4', c.tbl, c.col);
    EXECUTE format('UPDATE doom.%I SET %I = %I || ''''::bytea', c.tbl, c.col, c.col);
  END LOOP;
END
$lz4$;
