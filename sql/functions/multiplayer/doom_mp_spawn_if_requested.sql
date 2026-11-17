CREATE OR REPLACE FUNCTION doom.doom_mp_spawn_if_requested(p_map_id integer, p integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  spawn boolean;
  _r1 record;
BEGIN

spawn := false;
FOR _r1 IN SELECT EXISTS(SELECT 1 FROM mp_join_requests r JOIN mp_players mp
              ON mp.map_id=r.map_id AND mp.slot=r.slot
              WHERE mp.map_id=doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id=doom_mp_spawn_if_requested.p) AS e
LOOP spawn := _r1.e; END LOOP;
IF _cs.spawn THEN
  UPDATE player_state SET frags=0 WHERE map_id=doom_mp_spawn_if_requested.p_map_id AND player_thing_id=doom_mp_spawn_if_requested.p;
  PERFORM doom_mp_respawn(doom_mp_spawn_if_requested.p_map_id,doom_mp_spawn_if_requested.p);
  DELETE FROM mp_join_requests WHERE map_id=doom_mp_spawn_if_requested.p_map_id
    AND slot IN (SELECT mp.slot FROM mp_players mp
                 WHERE mp.map_id=doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id=doom_mp_spawn_if_requested.p);
END IF;
RETURN 1;
END _cs;
$function$;
