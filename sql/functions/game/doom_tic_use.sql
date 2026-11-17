CREATE OR REPLACE FUNCTION doom.doom_tic_use(p_map_id integer, p integer, p_plan bigint)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  queued boolean;
BEGIN

queued := false;
IF (doom_tic_use.p_plan & 1) <> 0 THEN queued := doom_cs_use(doom_tic_use.p_map_id,doom_tic_use.p); END IF;
RETURN _cs.queued;
END _cs;
$function$;
