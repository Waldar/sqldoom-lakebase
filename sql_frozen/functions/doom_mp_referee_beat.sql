CREATE OR REPLACE FUNCTION doom.doom_mp_referee_beat(p_map_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE mp_referee SET heartbeat=now() WHERE map_id=doom_mp_referee_beat.p_map_id;
RETURN 1;
END _cs;
$function$;
