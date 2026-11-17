CREATE MATERIALIZED VIEW doom.ui_hud_pixels AS
 SELECT name,
    dx,
    dy,
    palette_index
   FROM ui_patch_pixels
  WHERE ((name)::text ~~ 'ST%'::text)
WITH DATA;
