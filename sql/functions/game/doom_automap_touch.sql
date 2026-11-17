CREATE OR REPLACE FUNCTION doom.doom_automap_touch(p_map_id integer, p_player_thing_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

INSERT INTO automap_view (map_id, player_thing_id, center_x, center_y)
SELECT doom_automap_touch.p_map_id, doom_automap_touch.p_player_thing_id, ps.position_x, ps.position_y
FROM player_state ps
WHERE ps.map_id = doom_automap_touch.p_map_id AND ps.player_thing_id = doom_automap_touch.p_player_thing_id
ON CONFLICT (map_id, player_thing_id) DO NOTHING;
RETURN 1;
END _cs;
$function$;
