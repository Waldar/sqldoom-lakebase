CREATE OR REPLACE FUNCTION doom.doom_zlight_lut()
 RETURNS bytea
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT string_agg(set_byte('\x00'::bytea, 0,
         CASE WHEN r.k = 16 THEN 0
              WHEN r.k = 17 THEN 32
              -- d * 16.0 is a depth whose step is d exactly
              ELSE GREATEST(0, LEAST(31, r.k * 4 - doom_light_zdepth(d.d * 16.0)))
         END), ''::bytea ORDER BY r.k, d.d)
FROM generate_series(0, 17) r(k) CROSS JOIN generate_series(0, 127) d(d)
$function$;
