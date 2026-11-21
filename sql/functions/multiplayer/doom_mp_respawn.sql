CREATE OR REPLACE FUNCTION doom.doom_mp_respawn(p_map_id integer, p_player_thing_id integer)
 RETURNS integer
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
       COALESCE(max(value) FILTER (WHERE name = 'PLAYER_RESPAWN_EFFECT_ID_BASE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'EFFECT_ID_TIC_SPAN'), 0)
  INTO respawn_fog_base, tic_span
  FROM doom_constants WHERE name IN ('EFFECT_ID_TIC_SPAN', 'PLAYER_RESPAWN_EFFECT_ID_BASE');
WITH me AS (
  SELECT level_tics FROM player_state
  WHERE map_id=doom_mp_respawn.p_map_id AND player_thing_id=doom_mp_respawn.p_player_thing_id
),
others AS (
  SELECT t.x::float8 AS x, t.y::float8 AS y
  FROM player_state ps
  JOIN things t ON t.map_id=ps.map_id AND t.id=ps.player_thing_id
  WHERE ps.map_id=doom_mp_respawn.p_map_id AND ps.player_thing_id<>doom_mp_respawn.p_player_thing_id AND ps.alive
),
starts AS (
  -- Thing type 11 is a deathmatch start. P_CheckSpot would refuse one with a
  -- body in it; a 64-unit box around every other live player stands in.
  SELECT t.id, t.x, t.y, t.angle,
         ROW_NUMBER() OVER (ORDER BY t.id) AS rn, COUNT(*) OVER () AS n
  FROM things t
  WHERE t.map_id=doom_mp_respawn.p_map_id AND t.type=11
    AND NOT EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'solo')
    AND NOT EXISTS (SELECT 1 FROM others o
                    WHERE ABS(o.x-t.x)<64.0 AND ABS(o.y-t.y)<64.0)
  UNION ALL
  -- single player: the slot's own player start (the WAD position)
  SELECT t.id, t.spawn_x, t.spawn_y, t.spawn_angle, 1::bigint, 1::bigint
  FROM things t
  WHERE t.map_id=doom_mp_respawn.p_map_id AND t.id=doom_mp_respawn.p_player_thing_id
    AND EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'solo')
),
pick AS (
  SELECT s.* FROM starts s CROSS JOIN me
  WHERE s.rn = (doom_prandom(doom_mp_respawn.p_player_thing_id, me.level_tics, 41) % s.n) + 1
)
UPDATE things t
SET x=pk.x, y=pk.y, angle=pk.angle, mom_x=0, mom_y=0
FROM pick pk
WHERE t.map_id=doom_mp_respawn.p_map_id AND t.id=doom_mp_respawn.p_player_thing_id;

-- G_PlayerReborn: full health, no armour, fist and pistol with 50 bullets.
-- The frag count is the one thing that survives.
UPDATE player_state ps
SET health=100, alive=TRUE, armor=0, armor_class=0, backpack=FALSE,
    ammo_bullets=50, ammo_shells=0, ammo_rockets=0, ammo_cells=0,
    key_blue=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),
    key_yellow=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),
    key_red=EXISTS (SELECT 1 FROM mp_match mm WHERE mm.mode = 'deathmatch'),
    radsuit_tics=0, invis_tics=0, light_amp_tics=0, invuln_tics=0,
    berserk=FALSE, power_map=FALSE, god_mode=FALSE, noclip=FALSE,
    pain_face_tics=0, damage_count=0, bonus_count=0,
    death_tics=0, killer_id=NULL, death_health=NULL, sprite_frame='A',
    view_dip=0, view_dip_delta=0,
    momentum_x=0, momentum_y=0, momentum_z=0, bob_strength=0,
    -- the face starts over (ST_initData; migration 0007, doom_cs_face): its
    -- weapons are taken as they are now, at the face's first tic
    face_patch='STFST00', face_until=NULL, face_priority=0, face_old_health=100,
    face_fire_since=NULL, face_weapons=-1, attacker_id=NULL
WHERE ps.map_id=doom_mp_respawn.p_map_id AND ps.player_thing_id=doom_mp_respawn.p_player_thing_id;

DELETE FROM player_weapon_owned
WHERE map_id=doom_mp_respawn.p_map_id AND player_thing_id=doom_mp_respawn.p_player_thing_id;

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
VALUES (doom_mp_respawn.p_map_id, doom_mp_respawn.p_player_thing_id, 1), (doom_mp_respawn.p_map_id, doom_mp_respawn.p_player_thing_id, 2);

DELETE FROM player_weapons
WHERE map_id=doom_mp_respawn.p_map_id AND player_thing_id=doom_mp_respawn.p_player_thing_id;

INSERT INTO player_weapons (map_id, player_thing_id)
VALUES (doom_mp_respawn.p_map_id, doom_mp_respawn.p_player_thing_id);

-- The death cue is latched per player so it plays once per death; a new life
-- needs it released.
DELETE FROM sound_events
WHERE map_id=doom_mp_respawn.p_map_id AND event_key='plr-death:'||doom_mp_respawn.p_player_thing_id::text;

PERFORM doom_spawn_player(doom_mp_respawn.p_map_id, doom_mp_respawn.p_player_thing_id);

-- The teleport fog at the new spot, and its sound.
INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
SELECT ps.map_id, _cs.respawn_fog_base::bigint + ps.player_thing_id::bigint * _cs.tic_span
                  + (ps.level_tics % _cs.tic_span),
       'tfog', ps.position_x, ps.position_y, s.floor_height, ps.sector_id, 0
FROM player_state ps
JOIN sectors s ON s.map_id=ps.map_id AND s.id=ps.sector_id
WHERE ps.map_id=doom_mp_respawn.p_map_id AND ps.player_thing_id=doom_mp_respawn.p_player_thing_id
ON CONFLICT (map_id, effect_id) DO NOTHING;

INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT ps.map_id,'respawn:'||ps.player_thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',ps.player_thing_id,ps.position_x,ps.position_y
FROM player_state ps
WHERE ps.map_id=doom_mp_respawn.p_map_id AND ps.player_thing_id=doom_mp_respawn.p_player_thing_id
ON CONFLICT (map_id,event_key) DO NOTHING;
RETURN 1;
END _cs;
$function$;
