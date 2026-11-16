CREATE OR REPLACE VIEW doom.api_map_geometry AS
 SELECT x1,
    y1,
    x2,
    y2,
    ssector_id,
    (bsec IS NULL) AS solid
   FROM render_segs
  WHERE (map_id = ( SELECT m.map_id
           FROM mp_match m));
GRANT SELECT ON TABLE doom.api_map_geometry TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_map_geometry TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_map_geometry TO databricks_superuser;
