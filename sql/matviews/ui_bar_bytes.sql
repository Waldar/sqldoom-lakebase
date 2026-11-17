CREATE MATERIALIZED VIEW doom.ui_bar_bytes AS
 SELECT cm.pal,
    string_agg(cm.rgb, '\x'::bytea ORDER BY s.y, s.x) AS rgb,
    string_agg(set_byte('\x00'::bytea, 0, (s.palette_index)::integer), '\x'::bytea ORDER BY s.y, s.x) AS idx
   FROM (ui_static_pixels s
     JOIN colormap_rgb cm ON (((cm.level = 0) AND (cm.palette_index = s.palette_index))))
  GROUP BY cm.pal
WITH DATA;
