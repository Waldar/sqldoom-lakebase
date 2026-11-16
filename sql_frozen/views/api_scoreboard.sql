CREATE OR REPLACE VIEW doom.api_scoreboard AS
 SELECT mp.slot,
    COALESCE(mp.display_name, mp.role_name) AS role_name,
    (mp.role_name IS NOT NULL) AS connected,
    ps.frags,
    ps.health,
    ps.alive,
    mp.role_name AS login
   FROM (mp_players mp
     JOIN player_state ps ON (((ps.map_id = mp.map_id) AND (ps.player_thing_id = mp.player_thing_id))))
  ORDER BY mp.slot;
GRANT SELECT ON TABLE doom.api_scoreboard TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_scoreboard TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_scoreboard TO databricks_superuser;
