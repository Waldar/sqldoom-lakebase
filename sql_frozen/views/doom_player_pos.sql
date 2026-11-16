CREATE OR REPLACE VIEW doom.doom_player_pos AS
 SELECT map_id,
    id AS player_thing_id,
    (x)::double precision AS px,
    (y)::double precision AS py
   FROM things t;
GRANT SELECT ON TABLE doom.doom_player_pos TO databricks_gateway;
GRANT SELECT ON TABLE doom.doom_player_pos TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.doom_player_pos TO databricks_superuser;
