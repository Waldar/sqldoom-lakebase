-- The status bar's patches as runs: each row of a patch's opaque pixels cut
-- into maximal horizontal runs, with their bytes at light level 0 of each
-- palette (rgb for the RGB frame views, idx for the indexed ones). The frame
-- views splice a few hundred of these into the static bar instead of ~2,000
-- single pixels. From LBDoom's sql/schema.sql (2026-11-17).
CREATE MATERIALIZED VIEW doom.ui_hud_runs AS
WITH px AS (
  SELECT name, dy, dx, palette_index,
         dx - ROW_NUMBER() OVER (PARTITION BY name, dy ORDER BY dx) AS grp
  FROM ui_hud_pixels
)
SELECT cm.pal, px.name, px.dy, MIN(px.dx)::int AS dx, count(*)::int AS len,
       string_agg(cm.rgb, ''::bytea ORDER BY px.dx) AS rgb,
       string_agg(set_byte('\x00'::bytea, 0, cm.mapped_index::int), ''::bytea
                  ORDER BY px.dx) AS idx
FROM px
JOIN colormap_rgb cm ON cm.level = 0 AND cm.palette_index = px.palette_index
GROUP BY cm.pal, px.name, px.dy, px.grp
WITH DATA;
