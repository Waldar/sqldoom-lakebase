CREATE OR REPLACE FUNCTION doom.doom_light_zdepth(p_depth double precision)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT FLOOR(80.0 / (LEAST(127, FLOOR(p_depth / 16.0)::int) + 1))::int
$function$;
