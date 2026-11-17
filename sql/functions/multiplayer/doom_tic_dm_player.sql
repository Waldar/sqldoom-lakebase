CREATE OR REPLACE FUNCTION doom.doom_tic_dm_player(p_map_id integer, p integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  rs boolean;
  restart_rule boolean;
  _r1 record;
  _r2 record;
BEGIN

PERFORM doom_cs_player_pose(doom_tic_dm_player.p_map_id,doom_tic_dm_player.p);
rs := false;
restart_rule := false;
FOR _r1 IN SELECT (NOT ps.alive AND ps.death_tics > 35 AND (g.attack_held OR g.use_requested)) AS r
FROM player_state ps
JOIN game_tic_commands g ON g.map_id=ps.map_id AND g.player_thing_id=ps.player_thing_id
WHERE ps.map_id=doom_tic_dm_player.p_map_id AND ps.player_thing_id=doom_tic_dm_player.p
LOOP rs := _r1.r; END LOOP;
IF _cs.rs THEN
  FOR _r2 IN SELECT EXISTS (SELECT 1 FROM mp_match m WHERE m.mode = 'solo' AND m.death_restart) AS x
LOOP restart_rule := _r2.x; END LOOP;
END IF;
-- the referee sees pending = 'restart' and reopens the map (pistol start)
IF _cs.rs AND _cs.restart_rule THEN
  UPDATE mp_match SET pending = 'restart' WHERE pending IS NULL AND state = 'playing';
END IF;
IF _cs.rs AND NOT _cs.restart_rule THEN PERFORM doom_mp_respawn(doom_tic_dm_player.p_map_id,doom_tic_dm_player.p); END IF;
RETURN 1;
END _cs;
$function$;
