CREATE OR REPLACE FUNCTION doom.doom_automap_zoom(p_map_id integer, p_player_thing_id integer, p_factor double precision)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  lo double precision;
  hi double precision;
BEGIN

-- 2 constants in one scan (was 2 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'AUTOMAP_MIN_ZOOM'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'AUTOMAP_MAX_ZOOM'), 0)
  INTO lo, hi
  FROM doom_constants WHERE name IN ('AUTOMAP_MAX_ZOOM', 'AUTOMAP_MIN_ZOOM');
PERFORM doom_automap_touch(doom_automap_zoom.p_map_id, doom_automap_zoom.p_player_thing_id);
UPDATE automap_view
SET zoom = GREATEST(_cs.lo, LEAST(_cs.hi, zoom * doom_automap_zoom.p_factor))::real
WHERE map_id = doom_automap_zoom.p_map_id AND player_thing_id = doom_automap_zoom.p_player_thing_id;
RETURN 1;
END _cs;
$function$;
