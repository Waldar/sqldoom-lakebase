CREATE OR REPLACE FUNCTION doom.doom_cs_plan(p_map_id integer, p_player_thing_id integer)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  flags bigint;
  pos_epsilon double precision;
  psprite_epsilon double precision;
  psprite_rest_x double precision;
  psprite_rest_y double precision;
  _r1 record;
BEGIN

flags := 0::bigint;
-- 4 constants in one scan (was 4 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'POS_EPSILON'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PSPRITE_EPSILON'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PSPRITE_REST_X'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PSPRITE_REST_Y'), 0)
  INTO pos_epsilon, psprite_epsilon, psprite_rest_x, psprite_rest_y
  FROM doom_constants WHERE name IN ('POS_EPSILON', 'PSPRITE_EPSILON', 'PSPRITE_REST_X', 'PSPRITE_REST_Y');
-- SQL-generated execution plan for the current tic.
FOR _r1 IN WITH input AS (
  SELECT g.*,ps.previous_x,ps.previous_y,ps.position_x,ps.position_y,
         ps.bob_strength,ps.alive,ps.pain_face_tics,
         pw.state AS weapon_state,pw.flash_seq_index,pw.fired_this_tick,
         pw.sx AS weapon_sx,pw.sy AS weapon_sy,
         pw.current_weapon
  FROM game_tic_commands g
  JOIN player_state ps ON ps.map_id=g.map_id
    AND ps.player_thing_id=g.player_thing_id
  JOIN player_weapons pw ON pw.map_id=g.map_id
    AND pw.player_thing_id=g.player_thing_id
  WHERE g.map_id=doom_cs_plan.p_map_id::int AND g.player_thing_id=doom_cs_plan.p_player_thing_id::int
)
SELECT
  i.use_requested,
  -- Any queued event on the map by any actor?
  EXISTS (
    SELECT 1 FROM line_special_events e WHERE e.map_id=i.map_id
  ) AS specials_due,
  (EXISTS (SELECT 1 FROM sector_movers sm
           WHERE sm.map_id=i.map_id AND sm.direction<>2)
   OR EXISTS (SELECT 1 FROM line_buttons b
              WHERE b.map_id=i.map_id AND b.countdown>0)) AS movers_due,
  i.movement_mode,
  (ABS(i.position_x-i.previous_x)>_cs.pos_epsilon
   OR ABS(i.position_y-i.previous_y)>_cs.pos_epsilon) AS moved,
  (i.attack_held OR i.weapon_switch_to IS NOT NULL
   OR EXISTS (SELECT 1 FROM pickup_grants pg
              WHERE pg.map_id=i.map_id
                AND pg.player_thing_id=i.player_thing_id)
   OR i.weapon_state<>'ready' OR i.flash_seq_index IS NOT NULL
   OR i.bob_strength>_cs.psprite_epsilon
   OR ABS(i.weapon_sx-_cs.psprite_rest_x)>_cs.psprite_epsilon
   OR ABS(i.weapon_sy-_cs.psprite_rest_y)>_cs.psprite_epsilon
   OR EXISTS (SELECT 1 FROM world_effects we WHERE we.map_id=i.map_id))
    AS weapon_due,
  (i.fired_this_tick AND wd.pellet_count>0) AS hitscan_due,
  (EXISTS (SELECT 1 FROM monster_projectiles mp WHERE mp.map_id=i.map_id)
   OR (i.fired_this_tick AND wd.projectile_type IS NOT NULL)
   OR EXISTS (
     SELECT 1 FROM monster_ai ai
     JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
     JOIN thing_combat_defs d ON d.thing_type=t.type
     WHERE ai.map_id=i.map_id AND ai.fired_this_tick AND d.missile_type IS NOT NULL
   )) AS projectiles_due,
  (i.use_requested OR i.fired_this_tick
   OR EXISTS (SELECT 1 FROM pickup_touches pt
              WHERE pt.map_id=i.map_id
                AND pt.player_thing_id=i.player_thing_id)
   OR EXISTS (SELECT 1 FROM monster_ai ai
              WHERE ai.map_id=i.map_id AND ai.fired_this_tick)
   OR EXISTS (SELECT 1 FROM projectile_impacts pi WHERE pi.map_id=i.map_id)
   OR EXISTS (SELECT 1 FROM sector_movers sm
              WHERE sm.map_id=i.map_id AND sm.direction IN (-1,1))
   OR (wd.idle_loop_sound IS NOT NULL AND i.weapon_state<>'down')
   OR EXISTS (SELECT 1 FROM monster_ai ai
              WHERE ai.map_id=i.map_id AND ai.state <> 'stand')
   OR NOT i.alive
   OR i.pain_face_tics > 0) AS sound_due
FROM input i
JOIN weapon_defs wd ON wd.weapon_id=i.current_weapon
LOOP
  IF _r1.use_requested THEN flags := _cs.flags + 1; END IF;
  IF _r1.specials_due THEN flags := _cs.flags + 2; END IF;
  IF _r1.movers_due THEN flags := _cs.flags + 4; END IF;
  IF _r1.moved THEN flags := _cs.flags + 8; END IF;
  IF _r1.weapon_due THEN flags := _cs.flags + 16; END IF;
  IF _r1.hitscan_due THEN flags := _cs.flags + 32; END IF;
  IF _r1.projectiles_due THEN flags := _cs.flags + 64; END IF;
  IF _r1.sound_due THEN flags := _cs.flags + 128; END IF;
END LOOP;
RETURN _cs.flags;
END _cs;
$function$;
