CREATE OR REPLACE VIEW doom.api_things_spawn AS
 SELECT id,
    map_id,
    spawn_x,
    spawn_y,
    spawn_angle,
    type,
    flags
   FROM things;
GRANT SELECT ON TABLE doom.api_things_spawn TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_things_spawn TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_things_spawn TO databricks_superuser;
