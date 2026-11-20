CREATE OR REPLACE VIEW doom.api_sound_events AS
 WITH listener AS (
         SELECT (t.x)::double precision AS px,
            (t.y)::double precision AS py,
            radians((t.angle)::double precision) AS angle,
            t.id AS pid,
            -- S_AdjustSoundParams: on map 8 (E1M8, the barons) nothing fades
            -- below 15 of 127, however far (2026-11-20)
            (EXISTS ( SELECT 1 FROM maps mm WHERE ((mm.map_id = t.map_id) AND ((mm.name)::text ~ '^E[0-9]M8$'::text)))) AS boss_map
           FROM things t
          WHERE ((t.map_id = ( SELECT mp.map_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller()))) AND (t.id = ( SELECT mp.player_thing_id
                   FROM mp_players mp
                  WHERE (mp.role_name = doom_caller()))))
        ), positioned AS (
         SELECT e.event_id,
            e.sound_name,
            l.boss_map,
                CASE
                    WHEN (e.source_x IS NULL) THEN (0.0)::double precision
                    -- S_StartSoundAtVolume: a sound whose origin is the
                    -- listener is not positioned: centred, full volume. Ours
                    -- were placed where the player stood when made, so they
                    -- panned once it moved (2026-11-20: pistol shots while
                    -- walking and turning panned +0.50 to -0.99). Only the
                    -- player's own kinds: doors, teleport fogs, impacts and
                    -- switches popping back also carry it as their source.
                    WHEN ((e.source_thing_id = l.pid) AND (split_part(e.event_key, ':'::text, 1) = ANY (ARRAY['player-fire'::text, 'pickup'::text, 'use'::text, 'plr-pain'::text, 'plr-death'::text, 'punch'::text, 'saw-hit'::text, 'saw-up'::text, 'bfg'::text, 'oof'::text]))) THEN (0.0)::double precision
                    ELSE sqrt((power((e.source_x - l.px), (2)::double precision) + power((e.source_y - l.py), (2)::double precision)))
                END AS distance,
                CASE
                    WHEN (e.source_x IS NULL) THEN (0.0)::double precision
                    WHEN ((e.source_thing_id = l.pid) AND (split_part(e.event_key, ':'::text, 1) = ANY (ARRAY['player-fire'::text, 'pickup'::text, 'use'::text, 'plr-pain'::text, 'plr-death'::text, 'punch'::text, 'saw-hit'::text, 'saw-up'::text, 'bfg'::text, 'oof'::text]))) THEN (0.0)::double precision
                    -- times 0.75: S_STEREO_SWING, 96 of 128, keeps some sound in
                    -- the far ear (2026-11-20; was the full -1..+1).
                    -- minus: a source to the left (Doom's angles turn counter-clockwise,
                    -- so +90 degrees from the view) is pan -1 for the page's
                    -- StereoPannerNode (-1 left, +1 right). Without it left and right
                    -- were swapped (owner, 2026-11-19; LBDoom's sound_events.sql has the same sign).
                    ELSE ((- sin((atan2((e.source_y - l.py), (e.source_x - l.px)) - l.angle))) * (0.75)::double precision)
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
            WHEN boss_map THEN (((15.0)::double precision / (127.0)::double precision) + (((112.0)::double precision / (127.0)::double precision) * (((1200.0)::double precision - LEAST(distance, (1200.0)::double precision)) / (1040.0)::double precision)))
            WHEN (distance >= (1200.0)::double precision) THEN (0.0)::double precision
            ELSE ((1.0)::double precision - ((distance - (160.0)::double precision) / (1040.0)::double precision))
        END AS volume,
    GREATEST(('-1.0'::numeric)::double precision, LEAST((1.0)::double precision, pan)) AS pan
   FROM positioned;
