CREATE OR REPLACE VIEW doom.api_match AS
 SELECT m.state,
    m.map_id,
    ma.name AS map_name,
    m.timer_tics,
    m.altdeath,
    m.monsters,
    m.maps_played,
    ( SELECT COALESCE(max(ps.level_tics), (0)::bigint) AS "coalesce"
           FROM (player_state ps
             JOIN mp_players mp ON (((mp.map_id = ps.map_id) AND (mp.player_thing_id = ps.player_thing_id))))
          WHERE (mp.map_id = m.map_id)) AS level_tics,
    (GREATEST((0)::numeric, COALESCE(EXTRACT(epoch FROM (m.intermission_until - now())), (0)::numeric)))::integer AS intermission_seconds,
        CASE m.pending
            WHEN 'deathmatch'::text THEN 'DEATHMATCH'::text
            WHEN 'stay'::text THEN 'DEATHMATCH'::text
            WHEN 'final'::text THEN 'FINAL'::text
            WHEN 'solo'::text THEN 'SINGLE PLAYER'::text
            WHEN 'restart'::text THEN 'RESTART'::text
            WHEN 'rules'::text THEN 'RESTART'::text
            ELSE COALESCE(( SELECT q.map_name
               FROM mp_map_request q), ( SELECT r.map_name
               FROM mp_rotation r
              WHERE (r."position" > COALESCE(( SELECT r2."position"
                       FROM mp_rotation r2
                      WHERE (r2.map_name = ma.name)), '-1'::integer))
              ORDER BY r."position"
             LIMIT 1), ( SELECT r.map_name
               FROM mp_rotation r
              ORDER BY r."position"
             LIMIT 1), ma.name)
        END AS next_map,
    ( SELECT count(*) AS count
           FROM mp_waiting w
          WHERE (EXTRACT(epoch FROM (now() - w.last_seen)) <= (5)::numeric)) AS waiting,
    ( SELECT count(*) AS count
           FROM (mp_waiting w
             JOIN mp_waiting me ON ((me.role_name = doom_caller())))
          WHERE ((w.since < me.since) AND (EXTRACT(epoch FROM (now() - w.last_seen)) <= (5)::numeric))) AS ahead_of_me,
    m.hold_seconds,
    ( SELECT (EXTRACT(epoch FROM (now() - mp.claimed_at)))::integer AS "extract"
           FROM mp_players mp
          WHERE ((mp.map_id = m.map_id) AND (mp.role_name = doom_caller()))) AS my_seat_seconds
   FROM (mp_match m
     JOIN maps ma ON ((ma.map_id = m.map_id)));
