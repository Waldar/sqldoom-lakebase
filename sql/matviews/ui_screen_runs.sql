-- The patches single player's screens between levels draw over their
-- background (api_screen_frame, 2026-11-21): the intermission's (WI*: level
-- names, labels, digits, splats, the arrow) and the HU font of the episode's
-- end text (STCFN*). Each row of a patch's opaque pixels cut into maximal
-- horizontal runs, as ui_hud_runs, with the WAD's own palette indices (Doom
-- draws these screens with V_DrawPatch: no colormap).
CREATE MATERIALIZED VIEW doom.ui_screen_runs AS
WITH px AS (
  SELECT name, dy, dx, palette_index,
         dx - ROW_NUMBER() OVER (PARTITION BY name, dy ORDER BY dx) AS grp
  FROM ui_patch_pixels
  WHERE (name ~ '^WI' AND name !~ '^WIMAP') OR name ~ '^STCFN'
)
SELECT name, dy::int AS dy, MIN(dx)::int AS dx, count(*)::int AS len,
       string_agg(set_byte('\x00'::bytea, 0, palette_index::int), ''::bytea ORDER BY dx) AS b
FROM px
GROUP BY name, dy, grp
WITH DATA;
