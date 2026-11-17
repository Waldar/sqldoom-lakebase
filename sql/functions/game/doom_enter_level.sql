CREATE OR REPLACE FUNCTION doom.doom_enter_level(p_map_id integer, p_player_thing_id integer, p_skill integer, p_from_map_id integer, p_from_player_thing_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

PERFORM doom_reset_stage(doom_enter_level.p_map_id,doom_enter_level.p_skill);
PERFORM doom_spawn_player(doom_enter_level.p_map_id,doom_enter_level.p_player_thing_id);
PERFORM doom_cs_secret(doom_enter_level.p_map_id,doom_enter_level.p_player_thing_id);
IF doom_enter_level.p_from_map_id IS NOT NULL THEN
  PERFORM doom_carry_player(doom_enter_level.p_from_map_id,doom_enter_level.p_from_player_thing_id,doom_enter_level.p_map_id,doom_enter_level.p_player_thing_id);
END IF;
UPDATE screen_state SET cheat_buffer='' WHERE id=0;
RETURN 1;
END _cs;
$function$;
