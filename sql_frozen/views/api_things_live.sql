CREATE OR REPLACE VIEW doom.api_things_live AS
 SELECT t.map_id,
    t.id AS thing_id,
    'monster'::text AS kind,
    d.name,
    t.x,
    t.y,
    t.angle,
    h.alive
   FROM ((things t
     JOIN thing_combat_defs d ON (((d.thing_type = t.type) AND d.counts_kill)))
     JOIN thing_health h ON (((h.map_id = t.map_id) AND (h.thing_id = t.id))))
  WHERE h.alive
UNION ALL
 SELECT ps.map_id,
    ps.player_thing_id AS thing_id,
    'player'::text AS kind,
    COALESCE(mp.display_name, mp.role_name) AS name,
    ps.position_x AS x,
    ps.position_y AS y,
    ps.view_angle AS angle,
    ps.alive
   FROM (player_state ps
     JOIN mp_players mp ON (((mp.map_id = ps.map_id) AND (mp.player_thing_id = ps.player_thing_id))))
  WHERE (mp.role_name IS NOT NULL);
GRANT SELECT ON TABLE doom.api_things_live TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_things_live TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_things_live TO databricks_superuser;
