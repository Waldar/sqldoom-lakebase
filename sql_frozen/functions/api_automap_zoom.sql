CREATE OR REPLACE FUNCTION doom.api_automap_zoom(p_factor double precision)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  m integer;
  p integer;
  _r1 record;
BEGIN

m := 0; p := 0;
FOR _r1 IN SELECT mp.map_id AS a, mp.player_thing_id AS b FROM mp_players mp WHERE mp.role_name = doom_caller()
LOOP m := _r1.a; p := _r1.b; END LOOP;
PERFORM doom_automap_zoom(_cs.m, _cs.p, api_automap_zoom.p_factor);
RETURN 1;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_automap_zoom(double precision) FROM PUBLIC;
