CREATE OR REPLACE FUNCTION doom.doom_cs_monster_respawn(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  respawn_fog_base double precision;
  tic_span double precision;
BEGIN

-- 2 constants in one scan (was 2 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'MONSTER_RESPAWN_EFFECT_ID_BASE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'EFFECT_ID_TIC_SPAN'), 0)
  INTO respawn_fog_base, tic_span
  FROM doom_constants WHERE name IN ('EFFECT_ID_TIC_SPAN', 'MONSTER_RESPAWN_EFFECT_ID_BASE');
-- teleport fog, old spot and new
-- P_NightmareRespawn spawns an MT_TFOG at each end and starts sfx_telept on
-- both.
INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
SELECT r.map_id, _cs.respawn_fog_base::bigint + r.thing_id::bigint * _cs.tic_span * 2
                 + (ps.level_tics % _cs.tic_span) * 2 + e.k,
       'tfog', CASE e.k WHEN 0 THEN r.old_x ELSE t.spawn_x::real END,
       CASE e.k WHEN 0 THEN r.old_y ELSE t.spawn_y::real END,
       s.floor_height, CASE e.k WHEN 0 THEN rt.sector_id ELSE rt.spawn_sector_id END, 0
FROM monster_respawns r
JOIN things t ON t.map_id=r.map_id AND t.id=r.thing_id
JOIN render_things rt ON rt.map_id=r.map_id AND rt.thing_id=r.thing_id
JOIN player_state ps ON ps.map_id=r.map_id AND ps.player_thing_id=doom_cs_monster_respawn.p_player_thing_id::int
CROSS JOIN (VALUES (0), (1)) AS e (k)
JOIN sectors s ON s.map_id=r.map_id
 AND s.id=CASE e.k WHEN 0 THEN rt.sector_id ELSE COALESCE(rt.spawn_sector_id, rt.sector_id) END
WHERE r.map_id=doom_cs_monster_respawn.p_map_id::int
ON CONFLICT (map_id, effect_id) DO NOTHING;

INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT r.map_id,'respawn-out:'||r.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',r.thing_id,r.old_x,r.old_y
FROM monster_respawns r
JOIN player_state ps ON ps.map_id=r.map_id
  AND ps.player_thing_id=doom_cs_monster_respawn.p_player_thing_id::int
WHERE r.map_id=doom_cs_monster_respawn.p_map_id::int
UNION ALL
SELECT r.map_id,'respawn-in:'||r.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',r.thing_id,t.spawn_x::real,t.spawn_y::real
FROM monster_respawns r
JOIN things t ON t.map_id=r.map_id AND t.id=r.thing_id
JOIN player_state ps ON ps.map_id=r.map_id
  AND ps.player_thing_id=doom_cs_monster_respawn.p_player_thing_id::int
WHERE r.map_id=doom_cs_monster_respawn.p_map_id::int
ON CONFLICT (map_id,event_key) DO NOTHING;

-- Its sight and death cues are latched by a stable per-monster key, so they
-- have to be released or the monster comes back mute for the rest of the map.
DELETE FROM sound_events e
USING monster_respawns r
WHERE e.map_id=r.map_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int
  AND e.event_key IN ('mon-sight:'||r.thing_id::text,
                      'mon-death:'||r.thing_id::text);

-- put the monster back
UPDATE things t
SET x=t.spawn_x, y=t.spawn_y, angle=t.spawn_angle
FROM monster_respawns r
WHERE t.map_id=r.map_id AND t.id=r.thing_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int;

UPDATE thing_health h
SET health=h.max_health, alive=TRUE
FROM monster_respawns r
WHERE h.map_id=r.map_id AND h.thing_id=r.thing_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int;

-- Back to sleep at the spawn point, exactly as P_SpawnMobj leaves it
UPDATE render_things rt
SET sector_id=rt.spawn_sector_id
FROM monster_respawns r
WHERE rt.map_id=r.map_id AND rt.thing_id=r.thing_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int
  AND rt.spawn_sector_id IS NOT NULL AND rt.sector_id<>rt.spawn_sector_id;

UPDATE monster_ai ai
SET state='stand', state_tics=-1, seq_index=0, attack_cooldown=18,
    fired_this_tick=FALSE, sector_id=rt.sector_id
FROM monster_respawns r
JOIN render_things rt ON rt.map_id=r.map_id AND rt.thing_id=r.thing_id
WHERE ai.map_id=r.map_id AND ai.thing_id=r.thing_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int;

DELETE FROM monster_deaths d
USING monster_respawns r
WHERE d.map_id=r.map_id AND d.thing_id=r.thing_id AND r.map_id=doom_cs_monster_respawn.p_map_id::int;
RETURN;
END _cs;
$function$;
