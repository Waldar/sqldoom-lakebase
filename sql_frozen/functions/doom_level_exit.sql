CREATE OR REPLACE FUNCTION doom.doom_level_exit(p_map_id integer, p_player_thing_id integer, p_secret_exit boolean)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

PERFORM doom_finish_level(doom_level_exit.p_map_id,doom_level_exit.p_player_thing_id,doom_level_exit.p_secret_exit);
RETURN doom_intermission_begin(doom_level_exit.p_map_id,doom_level_exit.p_player_thing_id,doom_level_exit.p_secret_exit);
END _cs;
$function$;
