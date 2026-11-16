CREATE OR REPLACE FUNCTION doom.api_set_name(p_name text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

UPDATE mp_players
SET display_name = NULLIF(TRIM(UPPER(LEFT(REGEXP_REPLACE(COALESCE(api_set_name.p_name, ''), '[^A-Za-z0-9 _-]', '', 'g'), 12))), '')
WHERE role_name = doom_caller();
RETURN 1;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_set_name(text) FROM PUBLIC;
