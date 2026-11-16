CREATE OR REPLACE FUNCTION doom.doom_slot_active(p_map_id integer, p_player_thing_id integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT EXISTS (SELECT 1 FROM mp_players mp WHERE mp.map_id = p_map_id
                   AND mp.player_thing_id = p_player_thing_id AND mp.role_name IS NOT NULL)
      OR EXISTS (SELECT 1 FROM player_state ps WHERE ps.map_id = p_map_id
                   AND ps.player_thing_id = p_player_thing_id AND ps.alive)
$function$;
