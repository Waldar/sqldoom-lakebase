CREATE OR REPLACE VIEW doom.api_sound_loops AS
 WITH input AS (
         SELECT ( SELECT mp.map_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller())) AS map_id,
            ( SELECT mp.player_thing_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller())) AS player_thing_id
        ), listener AS (
         SELECT (t.x)::double precision AS px,
            (t.y)::double precision AS py,
            radians((t.angle)::double precision) AS angle
           FROM (things t
             JOIN input i ON (((t.map_id = i.map_id) AND (t.id = i.player_thing_id))))
        ), loops AS (
         SELECT ('mover:'::text || (sm.sector_id)::text) AS loop_key,
            'DSSTNMOV'::text AS sound_name,
            (so.x)::double precision AS source_x,
            (so.y)::double precision AS source_y
           FROM ((sector_movers sm
             JOIN input i ON ((i.map_id = sm.map_id)))
             JOIN sector_sound_origins so ON (((so.map_id = sm.map_id) AND (so.sector_id = sm.sector_id))))
          WHERE (sm.direction = ANY (ARRAY['-1'::integer, 1]))
        UNION ALL
         SELECT ('chainsaw:'::text || (i.player_thing_id)::text),
                CASE
                    WHEN (pw.state = 'fire'::weapon_state) THEN 'DSSAWFUL'::text
                    ELSE 'DSSAWIDL'::text
                END AS "case",
            NULL::double precision AS float8,
            NULL::double precision AS float8
           FROM (input i
             JOIN player_weapons pw ON (((pw.map_id = i.map_id) AND (pw.player_thing_id = i.player_thing_id))))
          WHERE ((pw.current_weapon = 8) AND (pw.state <> 'down'::weapon_state))
        ), positioned AS (
         SELECT l.loop_key,
            l.sound_name,
                CASE
                    WHEN (l.source_x IS NULL) THEN (0.0)::double precision
                    ELSE sqrt((power((l.source_x - p.px), (2)::double precision) + power((l.source_y - p.py), (2)::double precision)))
                END AS distance,
                CASE
                    WHEN (l.source_x IS NULL) THEN (0.0)::double precision
                    -- minus: left is pan -1 for the page's StereoPannerNode (see
                    -- api_sound_events)
                    ELSE (- sin((atan2((l.source_y - p.py), (l.source_x - p.px)) - p.angle)))
                END AS pan
           FROM (loops l
             CROSS JOIN listener p)
        )
 SELECT loop_key,
    sound_name,
        CASE
            WHEN (distance <= (160.0)::double precision) THEN (1.0)::double precision
            WHEN (distance >= (1200.0)::double precision) THEN (0.0)::double precision
            ELSE ((1.0)::double precision - ((distance - (160.0)::double precision) / (1040.0)::double precision))
        END AS volume,
    GREATEST(('-1.0'::numeric)::double precision, LEAST((1.0)::double precision, pan)) AS pan
   FROM positioned
  ORDER BY loop_key;
