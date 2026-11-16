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
GRANT SELECT ON TABLE doom.colormap_bytes TO databricks_gateway;
GRANT SELECT ON TABLE doom.colormap_bytes TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.colormap_bytes TO databricks_superuser;
