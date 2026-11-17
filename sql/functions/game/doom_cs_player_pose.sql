CREATE OR REPLACE FUNCTION doom.doom_cs_player_pose(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE player_state ps
SET sprite_frame = (CASE
  WHEN NOT ps.alive THEN
    CASE WHEN ps.health < -100
         THEN CHR(ASCII('O') + LEAST(8, ps.death_tics / 5))
         ELSE CHR(ASCII('H') + LEAST(6, ps.death_tics / 10)) END
  WHEN ps.pain_face_tics >= 9 THEN 'G'
  WHEN pw.flash_seq_index IS NOT NULL THEN 'F'
  WHEN pw.state NOT IN ('ready','up','down') THEN 'E'
  WHEN ps.bob_strength > 0.05 OR ABS(ps.momentum_x) + ABS(ps.momentum_y) > 0.1
    THEN SUBSTRING('ABCD' FROM ((ps.level_tics / 4) % 4)::int + 1 FOR 1)
  ELSE 'A' END)::char(1)
FROM player_weapons pw
WHERE ps.map_id=doom_cs_player_pose.p_map_id AND ps.player_thing_id=doom_cs_player_pose.p_player_thing_id
  AND pw.map_id=ps.map_id AND pw.player_thing_id=ps.player_thing_id;
RETURN;
END _cs;
$function$;
