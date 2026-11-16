CREATE MATERIALIZED VIEW doom.ui_hud_pixels AS
 SELECT name,
    dx,
    dy,
    palette_index
   FROM ui_patch_pixels
  WHERE ((name)::text ~~ 'ST%'::text)
WITH DATA;
GRANT SELECT ON TABLE doom.ui_hud_pixels TO databricks_gateway;
GRANT SELECT ON TABLE doom.ui_hud_pixels TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.ui_hud_pixels TO databricks_superuser;
