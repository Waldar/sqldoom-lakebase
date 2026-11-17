CREATE OR REPLACE FUNCTION doom.doom_cs_monster_plan(p_map_id integer)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  flags bigint;
  _r1 record;
BEGIN

flags := 0::bigint;
FOR _r1 IN SELECT
  EXISTS (SELECT 1 FROM player_weapons pw
          WHERE pw.map_id=doom_cs_monster_plan.p_map_id AND pw.fired_this_tick) AS noise_due,
  COALESCE(bool_or(ai.state='see' AND f.seq_index IS NOT NULL AND cd.thing_type IS NOT NULL AND NOT cd.explodes
                   AND (ai.state_tics=f.tics OR ai.state_tics=FLOOR(f.tics/2.0)::int)), FALSE) AS stepping_due,
  COALESCE(bool_or(ai.state IN ('see','missile') AND cd.floats), FALSE) AS floater_due,
  COALESCE(bool_or(ai.state='see'), FALSE) AS chasing_due,
  COALESCE(bool_or(ai.fired_this_tick), FALSE) AS attacking_due,
  COALESCE(bool_or(ai.fired_this_tick AND cd.explodes), FALSE) AS barrel_due,
  EXISTS (SELECT 1 FROM projectile_impacts
          WHERE map_id=doom_cs_monster_plan.p_map_id AND projectile_type='rocket') AS rocket_due
FROM monster_ai ai
LEFT JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
LEFT JOIN thing_combat_defs cd ON cd.thing_type=t.type
LEFT JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see' AND f.seq_index=ai.seq_index
WHERE ai.map_id=doom_cs_monster_plan.p_map_id
LOOP
  IF _r1.noise_due THEN flags := _cs.flags + 1; END IF;
  IF _r1.stepping_due THEN flags := _cs.flags + 2; END IF;
  IF _r1.floater_due THEN flags := _cs.flags + 4; END IF;
  IF _r1.chasing_due THEN flags := _cs.flags + 8; END IF;
  IF _r1.attacking_due THEN flags := _cs.flags + 16; END IF;
  IF _r1.barrel_due THEN flags := _cs.flags + 32; END IF;
  IF _r1.barrel_due OR _r1.rocket_due THEN flags := _cs.flags + 64; END IF;
END LOOP;
RETURN _cs.flags;
END _cs;
$function$;
