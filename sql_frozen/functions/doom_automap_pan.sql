CREATE OR REPLACE FUNCTION doom.doom_automap_pan(p_map_id integer, p_player_thing_id integer, p_dx double precision, p_dy double precision)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

PERFORM doom_automap_touch(doom_automap_pan.p_map_id, doom_automap_pan.p_player_thing_id);
UPDATE automap_view av
SET center_x = CASE WHEN av.follow THEN ps.position_x ELSE av.center_x END + doom_automap_pan.p_dx,
    center_y = CASE WHEN av.follow THEN ps.position_y ELSE av.center_y END + doom_automap_pan.p_dy,
    follow = FALSE
FROM player_state ps
WHERE av.map_id = doom_automap_pan.p_map_id AND av.player_thing_id = doom_automap_pan.p_player_thing_id
  AND ps.map_id = av.map_id AND ps.player_thing_id = av.player_thing_id;
RETURN 1;
END _cs;
$function$;
