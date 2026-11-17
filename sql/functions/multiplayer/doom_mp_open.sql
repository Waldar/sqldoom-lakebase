CREATE OR REPLACE FUNCTION doom.doom_mp_open()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE mp_match SET state = 'playing', intermission_until = NULL;
RETURN 1;
END _cs;
$function$;
