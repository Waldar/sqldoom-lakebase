CREATE OR REPLACE VIEW doom.doom_player_shadow AS
 SELECT map_id,
    player_thing_id,
    (invis_tics > 0) AS shadowed,
    level_tics
   FROM player_state ps;
GRANT SELECT ON TABLE doom.doom_player_shadow TO databricks_gateway;
GRANT SELECT ON TABLE doom.doom_player_shadow TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.doom_player_shadow TO databricks_superuser;
