CREATE OR REPLACE FUNCTION doom.bytea_larger(a bytea, b bytea)
 RETURNS bytea
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$ SELECT CASE WHEN a >= b THEN a ELSE b END $function$;
