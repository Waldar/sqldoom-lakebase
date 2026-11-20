CREATE OR REPLACE FUNCTION doom.doom_mp_reap(p_map_id integer, p_seconds integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  freed integer;
  playing boolean;
  _r1 record;
  _r2 record;
BEGIN

DELETE FROM mp_waiting WHERE EXTRACT(EPOCH FROM (now() - last_seen)) > 5;
freed := 0;
-- Nobody can heartbeat between maps (the API is quiet then), so nobody is
-- idle either.
playing := false;
FOR _r1 IN SELECT (m.state = 'playing') AS x FROM mp_match m
LOOP playing := _r1.x; END LOOP;
IF _cs.playing THEN
FOR _r2 IN SELECT count(*)::int AS n FROM mp_players mp
WHERE mp.map_id=doom_mp_reap.p_map_id AND mp.role_name IS NOT NULL
  AND (mp.last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - mp.last_seen)) > doom_mp_reap.p_seconds)
LOOP freed := _r2.n; END LOOP;
END IF;
IF _cs.freed > 0 THEN
  UPDATE player_state ps
  SET alive=FALSE, health=0, killer_id=NULL, death_health=NULL, death_tics=36,
      momentum_x=0, momentum_y=0, momentum_z=0
  FROM mp_players mp
  WHERE mp.map_id=ps.map_id AND mp.player_thing_id=ps.player_thing_id
    AND mp.map_id=doom_mp_reap.p_map_id AND mp.role_name IS NOT NULL
    AND (mp.last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - mp.last_seen)) > doom_mp_reap.p_seconds);
  UPDATE mp_players SET role_name=NULL, last_seen=NULL, display_name=NULL
  WHERE map_id=doom_mp_reap.p_map_id AND role_name IS NOT NULL
    AND (last_seen IS NULL OR EXTRACT(EPOCH FROM (now() - last_seen)) > doom_mp_reap.p_seconds);
END IF;
RETURN _cs.freed;
END _cs;
$function$;
