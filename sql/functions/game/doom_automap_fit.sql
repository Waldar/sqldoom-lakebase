CREATE OR REPLACE FUNCTION doom.doom_automap_fit(p_map_id integer, p_player_thing_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  world_height double precision;
  lo double precision;
  hi double precision;
BEGIN

-- 3 constants in one scan (was 3 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'AUTOMAP_WORLD_HEIGHT'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'AUTOMAP_MIN_ZOOM'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'AUTOMAP_MAX_ZOOM'), 0)
  INTO world_height, lo, hi
  FROM doom_constants WHERE name IN ('AUTOMAP_MAX_ZOOM', 'AUTOMAP_MIN_ZOOM', 'AUTOMAP_WORLD_HEIGHT');
PERFORM doom_automap_touch(doom_automap_fit.p_map_id, doom_automap_fit.p_player_thing_id);
UPDATE automap_view av
SET center_x = b.cx::real, center_y = b.cy::real,
    zoom = GREATEST(_cs.lo, LEAST(_cs.hi, b.fit))::real,
    follow = FALSE
FROM (
  SELECT (MIN(LEAST(v1.x,v2.x)) + MAX(GREATEST(v1.x,v2.x))) / 2.0 AS cx,
         (MIN(LEAST(v1.y,v2.y)) + MAX(GREATEST(v1.y,v2.y))) / 2.0 AS cy,
         LEAST((320.0 - 96.0) / GREATEST(1.0, MAX(GREATEST(v1.x,v2.x)) - MIN(LEAST(v1.x,v2.x))),
               (200.0 - 144.0) / GREATEST(1.0, MAX(GREATEST(v1.y,v2.y)) - MIN(LEAST(v1.y,v2.y))))
           / (200.0 / _cs.world_height) AS fit
  FROM linedefs ld
  JOIN vertexes v1 ON v1.map_id = ld.map_id AND v1.id = ld.v1_id
  JOIN vertexes v2 ON v2.map_id = ld.map_id AND v2.id = ld.v2_id
  WHERE ld.map_id = doom_automap_fit.p_map_id
) b
WHERE av.map_id = doom_automap_fit.p_map_id AND av.player_thing_id = doom_automap_fit.p_player_thing_id;
RETURN 1;
END _cs;
$function$;
