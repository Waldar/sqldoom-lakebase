CREATE OR REPLACE FUNCTION doom.doom_automap_toggle(p_map_id integer, p_player_thing_id integer, p_what text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

PERFORM doom_automap_touch(doom_automap_toggle.p_map_id, doom_automap_toggle.p_player_thing_id);
UPDATE automap_view
SET follow = CASE WHEN doom_automap_toggle.p_what = 'follow' THEN NOT follow ELSE follow END,
    grid   = CASE WHEN doom_automap_toggle.p_what = 'grid'   THEN NOT grid   ELSE grid   END,
    cheat  = CASE WHEN doom_automap_toggle.p_what = 'cheat'  THEN ((cheat + 1) % 3)::smallint ELSE cheat END
WHERE map_id = doom_automap_toggle.p_map_id AND player_thing_id = doom_automap_toggle.p_player_thing_id;
RETURN 1;
END _cs;
$function$;
