CREATE OR REPLACE VIEW doom.mp_stats AS
 SELECT m.map_id,
    ma.name AS map_name,
    m.state,
    m.timer_tics,
    m.maps_played,
    ( SELECT COALESCE(max(ps.level_tics), (0)::bigint) AS "coalesce"
           FROM (player_state ps
             JOIN mp_players mp ON (((mp.map_id = ps.map_id) AND (mp.player_thing_id = ps.player_thing_id))))
          WHERE (mp.map_id = m.map_id)) AS level_tics,
    ( SELECT count(*) AS count
           FROM ((thing_health h
             JOIN things t ON (((t.map_id = h.map_id) AND (t.id = h.thing_id))))
             JOIN thing_combat_defs d ON (((d.thing_type = t.type) AND d.counts_kill)))
          WHERE ((h.map_id = m.map_id) AND h.alive)) AS monsters_alive,
    ( SELECT count(*) AS count
           FROM ((thing_health h
             JOIN things t ON (((t.map_id = h.map_id) AND (t.id = h.thing_id))))
             JOIN thing_combat_defs d ON (((d.thing_type = t.type) AND d.counts_kill)))
          WHERE (h.map_id = m.map_id)) AS monsters_total,
    ( SELECT count(*) AS count
           FROM (monster_ai ai
             JOIN thing_health h ON (((h.map_id = ai.map_id) AND (h.thing_id = ai.thing_id))))
          WHERE ((ai.map_id = m.map_id) AND h.alive AND (ai.state <> 'stand'::actor_state))) AS monsters_awake,
    ( SELECT count(*) AS count
           FROM monster_projectiles p
          WHERE (p.map_id = m.map_id)) AS projectiles,
    ( SELECT count(*) AS count
           FROM world_effects e
          WHERE (e.map_id = m.map_id)) AS effects,
    ( SELECT count(*) AS count
           FROM ((picked_up_items pu
             JOIN things t ON (((t.map_id = pu.map_id) AND (t.id = pu.thing_id))))
             JOIN pickup_defs d ON ((d.thing_type = t.type)))
          WHERE (pu.map_id = m.map_id)) AS items_out,
    ( SELECT count(*) AS count
           FROM item_respawns r
          WHERE (r.map_id = m.map_id)) AS items_queued,
    ( SELECT count(*) AS count
           FROM sector_movers sm
          WHERE (sm.map_id = m.map_id)) AS movers,
    ( SELECT count(*) AS count
           FROM mp_inputs i) AS input_backlog,
    ( SELECT count(*) AS count
           FROM sound_events e
          WHERE (e.map_id = m.map_id)) AS sound_rows,
    ( SELECT count(*) AS count
           FROM pg_stat_activity a
          WHERE (a.state IS NOT NULL)) AS sessions,
    ( SELECT count(*) AS count
           FROM mp_waiting w
          WHERE (EXTRACT(epoch FROM (now() - w.last_seen)) <= (5)::numeric)) AS waiting
   FROM (mp_match m
     JOIN maps ma ON ((ma.map_id = m.map_id)));
GRANT SELECT ON TABLE doom.mp_stats TO databricks_gateway;
GRANT SELECT ON TABLE doom.mp_stats TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.mp_stats TO databricks_superuser;
