CREATE OR REPLACE FUNCTION doom.doom_caller()
 RETURNS text
 LANGUAGE sql
 STABLE PARALLEL SAFE
AS $function$
  SELECT COALESCE(NULLIF(current_setting('doom.player', true), ''), CAST(session_user AS text))
$function$;
