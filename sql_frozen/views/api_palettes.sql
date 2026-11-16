CREATE OR REPLACE VIEW doom.api_palettes AS
 SELECT pal,
    mapped_index AS idx,
    min(r) AS r,
    min(g) AS g,
    min(b) AS b
   FROM colormap_rgb
  GROUP BY pal, mapped_index;
GRANT SELECT ON TABLE doom.api_palettes TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_palettes TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_palettes TO databricks_superuser;
