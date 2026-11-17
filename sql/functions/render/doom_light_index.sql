CREATE OR REPLACE FUNCTION doom.doom_light_index(p_sector_light double precision, p_extra integer, p_attenuation integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT GREATEST(0, LEAST(31,
  (15 - LEAST(15, GREATEST(0, FLOOR(p_sector_light / 16.0)::int + p_extra))) * 4
  - p_attenuation))
$function$;
