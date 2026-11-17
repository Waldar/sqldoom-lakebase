CREATE OR REPLACE FUNCTION doom.doom_tic_secrets(p_map_id integer, p integer, p_plan bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  out bigint;
BEGIN

out := doom_tic_secrets.p_plan;
IF (doom_tic_secrets.p_plan & 8) <> 0 THEN
  PERFORM doom_cs_secret(doom_tic_secrets.p_map_id,doom_tic_secrets.p);
  PERFORM doom_cs_discover(doom_tic_secrets.p_map_id,doom_tic_secrets.p);
  PERFORM doom_cs_cross(doom_tic_secrets.p_map_id,doom_tic_secrets.p);
  PERFORM doom_cs_pickups(doom_tic_secrets.p_map_id,doom_tic_secrets.p);
  out := doom_cs_plan(doom_tic_secrets.p_map_id,doom_tic_secrets.p);
END IF;
RETURN _cs.out;
END _cs;
$function$;
