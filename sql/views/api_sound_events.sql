CREATE OR REPLACE VIEW doom.api_sound_events AS
 WITH listener AS (
         SELECT (t.x)::double precision AS px,
            (t.y)::double precision AS py,
            radians((t.angle)::double precision) AS angle
           FROM things t
          WHERE ((t.map_id = ( SELECT mp.map_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller()))) AND (t.id = ( SELECT mp.player_thing_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller()))))
        ), positioned AS (
         SELECT e.event_id,
            e.sound_name,
                CASE
                    WHEN (e.source_x IS NULL) THEN (0.0)::double precision
                    ELSE sqrt((power((e.source_x - l.px), (2)::double precision) + power((e.source_y - l.py), (2)::double precision)))
                END AS distance,
                CASE
                    WHEN (e.source_x IS NULL) THEN (0.0)::double precision
                    ELSE sin((atan2((e.source_y - l.py), (e.source_x - l.px)) - l.angle))
                END AS pan
           FROM (sound_events e
             CROSS JOIN listener l)
          WHERE (e.map_id = ( SELECT mp.map_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller())))
        )
 SELECT event_id,
    sound_name,
        CASE
            WHEN (distance <= (160.0)::double precision) THEN (1.0)::double precision
            WHEN (distance >= (1200.0)::double precision) THEN (0.0)::double precision
            ELSE ((1.0)::double precision - ((distance - (160.0)::double precision) / (1040.0)::double precision))
        END AS volume,
    GREATEST(('-1.0'::numeric)::double precision, LEAST((1.0)::double precision, pan)) AS pan
   FROM positioned;
