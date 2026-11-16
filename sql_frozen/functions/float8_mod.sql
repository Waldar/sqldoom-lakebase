CREATE OR REPLACE FUNCTION doom.float8_mod(a double precision, b double precision)
 RETURNS double precision
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT a - b * trunc(a / b) $function$;
