CREATE OR REPLACE FUNCTION doom.doom_mp_intermission_over()
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  over boolean;
  _r1 record;
BEGIN

over := false;
FOR _r1 IN SELECT (m.state = 'intermission' AND m.intermission_until <= now()) AS x FROM mp_match m
LOOP over := _r1.x; END LOOP;
RETURN _cs.over;
END _cs;
$function$;
