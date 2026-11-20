CREATE MATERIALIZED VIEW doom.colormap_bytes AS
 SELECT pal,
        CASE
            WHEN (count(*) = ((max(level) + 1) * 256)) THEN (string_agg(rgb, '\x'::bytea ORDER BY level, palette_index) || decode(repeat(encode('\x000000'::bytea, 'hex'::text), ((63 - max(level)) * 256)), 'hex'::text))
            ELSE NULL::bytea
        END AS rgb,
        CASE
            WHEN (count(*) = ((max(level) + 1) * 256)) THEN (string_agg(set_byte('\x00'::bytea, 0, (mapped_index)::integer), '\x'::bytea ORDER BY level, palette_index) || decode(repeat(encode('\x00'::bytea, 'hex'::text), ((63 - max(level)) * 256)), 'hex'::text))
            ELSE NULL::bytea
        END AS idx
   FROM colormap_rgb
  GROUP BY pal
WITH DATA;
-- lz4 (decompressed once a frame), where the build has it: see
-- sql/migrations/0002_lz4_textures.sql. REFRESH stores the rows again with it.
DO $lz4$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_settings WHERE name = 'default_toast_compression' AND 'lz4' = ANY (enumvals)) THEN
    ALTER MATERIALIZED VIEW doom.colormap_bytes ALTER COLUMN idx SET COMPRESSION lz4;
    REFRESH MATERIALIZED VIEW doom.colormap_bytes;
  END IF;
END $lz4$;
