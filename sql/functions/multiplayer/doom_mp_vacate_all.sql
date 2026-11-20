CREATE OR REPLACE FUNCTION doom.doom_mp_vacate_all(p_map_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE player_state ps
SET alive=FALSE, health=0, killer_id=NULL, death_health=NULL, death_tics=36,
    momentum_x=0, momentum_y=0, momentum_z=0
FROM mp_players mp
WHERE mp.map_id=ps.map_id AND mp.player_thing_id=ps.player_thing_id
  AND mp.map_id=doom_mp_vacate_all.p_map_id;
UPDATE mp_players SET role_name=NULL, last_seen=NULL, display_name=NULL WHERE map_id=doom_mp_vacate_all.p_map_id;
DELETE FROM mp_join_requests WHERE map_id=doom_mp_vacate_all.p_map_id;
RETURN 1;
END _cs;
$function$;
