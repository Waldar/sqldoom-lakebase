CREATE MATERIALIZED VIEW doom.ui_static_pixels AS
 WITH static_layers(name, layer, x, y) AS (
         VALUES ('STBAR'::text,0,0,168), ('STTPRCNT'::text,1,90,172), ('STTPRCNT'::text,1,221,172), ('STARMS'::text,1,104,168)
        ), candidates AS (
         SELECT l.layer,
            ((l.x - p.left_offset) + px.dx) AS x,
            ((l.y - p.top_offset) + px.dy) AS y,
            px.palette_index,
            row_number() OVER (PARTITION BY ((l.x - p.left_offset) + px.dx), ((l.y - p.top_offset) + px.dy) ORDER BY l.layer DESC, l.name) AS rn
           FROM ((static_layers l
             JOIN ui_patches p ON (((p.name)::text = l.name)))
             JOIN ui_patch_pixels px ON (((px.name)::text = l.name)))
        )
 SELECT c.x,
    c.y,
    cm.rgb,
    c.palette_index
   FROM (candidates c
     JOIN colormap_rgb cm ON (((cm.pal = 0) AND (cm.level = 0) AND (cm.palette_index = c.palette_index))))
  WHERE (c.rn = 1)
WITH DATA;
