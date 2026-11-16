CREATE OR REPLACE FUNCTION doom.doom_mp_referee_release(p_map_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

DELETE FROM mp_referee WHERE map_id=doom_mp_referee_release.p_map_id;
RETURN 1;
END _cs;
$function$;
