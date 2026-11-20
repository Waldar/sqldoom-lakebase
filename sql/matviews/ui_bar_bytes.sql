CREATE MATERIALIZED VIEW doom.ui_bar_bytes AS
 SELECT cm.pal,
    string_agg(cm.rgb, '\x'::bytea ORDER BY s.y, s.x) AS rgb,
    string_agg(set_byte('\x00'::bytea, 0, (s.palette_index)::integer), '\x'::bytea ORDER BY s.y, s.x) AS idx
   FROM (ui_static_pixels s
     JOIN colormap_rgb cm ON (((cm.level = 0) AND (cm.palette_index = s.palette_index))))
  GROUP BY cm.pal
WITH DATA;
-- lz4 (decompressed once a frame), where the build has it: see
-- sql/migrations/0002_lz4_textures.sql. REFRESH stores the rows again with it.
DO $lz4$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_settings WHERE name = 'default_toast_compression' AND 'lz4' = ANY (enumvals)) THEN
    ALTER MATERIALIZED VIEW doom.ui_bar_bytes ALTER COLUMN idx SET COMPRESSION lz4;
    REFRESH MATERIALIZED VIEW doom.ui_bar_bytes;
  END IF;
END $lz4$;
