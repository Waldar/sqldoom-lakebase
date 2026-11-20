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
            -- sfx_stnmov is T_MoveFloor's and T_MoveCeiling's (crushers
            -- included): doors and lifts have one-shot sounds instead
            -- (doom_cs_doors), 2026-11-20
            AND (sm.mover_type)::text = ANY (ARRAY['floor_lower'::text, 'floor_raise'::text, 'ceiling_lower'::text, 'ceiling_raise'::text, 'crusher'::text])
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
          -- A_WeaponReady's sfx_sawidl in the ready state, A_Saw's sfx_sawful
          -- firing; nothing while it comes up (DSSAWUP plays) or goes down;
          -- while a bite's DSSAWHIT (doom_cs_hitscan_apply) is recent, no
          -- DSSAWFUL over it: A_Saw plays one or the other (2026-11-20)
          WHERE ((pw.current_weapon = 8) AND (pw.state <> ALL (ARRAY['down'::weapon_state, 'up'::weapon_state]))
            AND NOT ((pw.state = 'fire'::weapon_state) AND (EXISTS ( SELECT 1
                   FROM (sound_events se
                     JOIN player_state ps ON (((ps.map_id = se.map_id) AND (ps.player_thing_id = i.player_thing_id))))
                  WHERE ((se.map_id = i.map_id) AND (se.source_thing_id = i.player_thing_id) AND (se.sound_name = 'DSSAWHIT'::text)
                    AND (se.level_tic >= (ps.level_tics - 8)))))))
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
