CREATE OR REPLACE FUNCTION doom.api_slot()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  s integer;
  _r1 record;
BEGIN

s := -1;
FOR _r1 IN SELECT mp.slot AS n FROM mp_players mp
WHERE mp.role_name = doom_caller()
LOOP s := _r1.n; END LOOP;
RETURN _cs.s;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_slot() FROM PUBLIC;
