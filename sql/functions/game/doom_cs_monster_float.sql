CREATE OR REPLACE FUNCTION doom.doom_cs_monster_float(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  view_height double precision;
  player_height double precision;
  skull_speed double precision;
  skull_reach double precision;
  ticrate double precision;
BEGIN

-- 5 constants in one scan (was 5 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'VIEWHEIGHT'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PLAYER_HEIGHT'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SKULL_CHARGE_SPEED'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'SKULL_HIT_REACH'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'TICRATE'), 0)
  INTO view_height, player_height, skull_speed, skull_reach, ticrate
  FROM doom_constants WHERE name IN ('PLAYER_HEIGHT', 'SKULL_CHARGE_SPEED', 'SKULL_HIT_REACH', 'TICRATE', 'VIEWHEIGHT');
-- P_ZMovement's float
-- A floater drifts 4 units a tic toward its target's mid-height once it is
-- close enough horizontally (within three times the height difference), and
-- stays between its sector's floor and the ceiling minus its own height.
UPDATE things t
SET z = LEAST(q.ceil_height - q.height, GREATEST(q.floor_height,
          t.z + CASE WHEN q.delta > 0 AND q.dist < q.delta * 3 THEN 4
                     WHEN q.delta < 0 AND q.dist < -q.delta * 3 THEN -4 ELSE 0 END))::real
FROM (
  SELECT ai.thing_id, s.floor_height, s.ceil_height, d.height,
         ((ps.base_z - _cs.view_height) + _cs.player_height/2.0) - th.z AS delta,
         SQRT(POWER(pt.x - th.x, 2) + POWER(pt.y - th.y, 2)) AS dist
  FROM monster_ai ai
  JOIN things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
  LEFT JOIN render_things rt ON rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
  JOIN sectors s ON s.map_id = ai.map_id AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  JOIN player_state ps ON ps.map_id = ai.map_id
   AND ps.player_thing_id = COALESCE(ai.target_thing_id, doom_cs_monster_float.p_player_thing_id::int)
  JOIN things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
  JOIN thing_combat_defs d ON d.thing_type = th.type
  WHERE ai.map_id = doom_cs_monster_float.p_map_id AND d.floats AND ai.state IN ('see','missile')
) q
WHERE t.map_id = doom_cs_monster_float.p_map_id AND t.id = q.thing_id;

-- A_SkullAttack
-- The lost soul's attack frame hurls it at its target at 20 units a tic;
-- doom_cs_thing_physics carries the momentum and stops it at walls, and the
-- charge is over when it lands (below), hits a wall, or runs out.
UPDATE things t
SET mom_x = (_cs.skull_speed * (q.tx - t.x) / q.len)::real,
    mom_y = (_cs.skull_speed * (q.ty - t.y) / q.len)::real
FROM (
  SELECT ai.thing_id, pt.x::float8 AS tx, pt.y::float8 AS ty,
         SQRT(POWER(pt.x - th.x, 2) + POWER(pt.y - th.y, 2)) AS len
  FROM monster_ai ai
  JOIN things th ON th.map_id = ai.map_id AND th.id = ai.thing_id
  JOIN things pt ON pt.map_id = ai.map_id
   AND pt.id = COALESCE(ai.target_thing_id, doom_cs_monster_float.p_player_thing_id::int)
  JOIN thing_combat_defs d ON d.thing_type = th.type AND d.skull_fly
  WHERE ai.map_id = doom_cs_monster_float.p_map_id AND ai.fired_this_tick
) q
WHERE t.map_id = doom_cs_monster_float.p_map_id AND t.id = q.thing_id AND q.len > 0;

UPDATE monster_ai ai
SET charge_tics = CASE WHEN ai.fired_this_tick THEN _cs.ticrate ELSE GREATEST(0, ai.charge_tics - 1) END
FROM things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
WHERE ai.map_id = doom_cs_monster_float.p_map_id AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND (ai.fired_this_tick OR ai.charge_tics > 0);

-- The charge lands: 3d8 to a player within reach, and the skull stops.
UPDATE player_state ps
SET armor = ps.armor - d.saved,
    armor_class = CASE WHEN ps.armor - d.saved <= 0 THEN 0 ELSE ps.armor_class END,
    health = GREATEST(0, ps.health - (d.dmg - d.saved)),
    damage_count = LEAST(100, ps.damage_count + (d.dmg - d.saved)),
    pain_face_tics = 12,
    alive = (ps.health - (d.dmg - d.saved)) > 0,
    killer_id = CASE WHEN (ps.health - (d.dmg - d.saved)) <= 0 THEN -1 ELSE ps.killer_id END
FROM (
  SELECT ps2.map_id, ps2.player_thing_id, q.dmg,
         LEAST(ps2.armor, CASE ps2.armor_class WHEN 2 THEN q.dmg / 2 WHEN 1 THEN q.dmg / 3 ELSE 0 END) AS saved
  FROM player_state ps2
  JOIN (
    SELECT ps3.player_thing_id,
           SUM((doom_prandom(t.id, ps3.level_tics, 21) % d.charge_sides + 1)
               * d.charge_mult)::int AS dmg
    FROM monster_ai ai
    JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
    JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
    JOIN player_state ps3 ON ps3.map_id = ai.map_id AND ps3.alive
    JOIN things pt ON pt.map_id = ps3.map_id AND pt.id = ps3.player_thing_id
    WHERE ai.map_id = doom_cs_monster_float.p_map_id AND ai.charge_tics > 0
      AND ABS(pt.x - t.x) < _cs.skull_reach AND ABS(pt.y - t.y) < _cs.skull_reach
    GROUP BY ps3.player_thing_id
  ) q ON q.player_thing_id = ps2.player_thing_id
  WHERE ps2.map_id = doom_cs_monster_float.p_map_id AND NOT ps2.god_mode AND ps2.invuln_tics <= 0
) d
WHERE ps.map_id = d.map_id AND ps.player_thing_id = d.player_thing_id;

UPDATE things t
SET mom_x = 0, mom_y = 0
FROM monster_ai ai JOIN thing_combat_defs d ON TRUE
WHERE (d.thing_type = t.type AND d.skull_fly) AND ( t.map_id = doom_cs_monster_float.p_map_id AND ai.map_id = t.map_id AND ai.thing_id = t.id
  AND ai.charge_tics > 0
  AND EXISTS (SELECT 1 FROM player_state ps JOIN things pt ON pt.map_id = ps.map_id AND pt.id = ps.player_thing_id
              WHERE ps.map_id = t.map_id AND ABS(pt.x - t.x) < _cs.skull_reach AND ABS(pt.y - t.y) < _cs.skull_reach));

UPDATE monster_ai ai
SET charge_tics = 0
FROM things t JOIN thing_combat_defs d ON d.thing_type = t.type AND d.skull_fly
WHERE ai.map_id = doom_cs_monster_float.p_map_id AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND ai.charge_tics > 0 AND t.mom_x = 0 AND t.mom_y = 0 AND NOT ai.fired_this_tick;
RETURN;
END _cs;
$function$;
