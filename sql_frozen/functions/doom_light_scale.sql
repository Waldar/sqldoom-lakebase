CREATE OR REPLACE FUNCTION doom.doom_light_scale(p_depth double precision)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT FLOOR(LEAST(47.0, GREATEST(0.0, 2560.0 / NULLIF(p_depth, 0.0))) / 2.0)::int
$function$;
