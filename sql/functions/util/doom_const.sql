CREATE OR REPLACE FUNCTION doom.doom_const(p_name text)
 RETURNS double precision
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  v double precision;
  _r1 record;
BEGIN

v := 0::double precision;
FOR _r1 IN SELECT value AS x FROM doom_constants WHERE name = doom_const.p_name
LOOP v := _r1.x; END LOOP;
RETURN _cs.v;
END _cs;
$function$;
