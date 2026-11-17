CREATE OR REPLACE VIEW doom.api_palettes AS
 SELECT pal,
    mapped_index AS idx,
    min(r) AS r,
    min(g) AS g,
    min(b) AS b
   FROM colormap_rgb
  GROUP BY pal, mapped_index;
