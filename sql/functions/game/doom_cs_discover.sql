CREATE OR REPLACE FUNCTION doom.doom_cs_discover(p_map_id integer, p_player_thing_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- Reveal the automap as the player walks it.
INSERT INTO mapped_lines (map_id, line_id)
SELECT DISTINCT ps.map_id, ld.id
FROM player_state ps
JOIN sidedefs sd ON sd.map_id = ps.map_id AND sd.sector_id = ps.sector_id
JOIN linedefs ld ON ld.map_id = sd.map_id AND (ld.right_sd_id = sd.id OR ld.left_sd_id = sd.id)
WHERE ps.map_id = doom_cs_discover.p_map_id::int
  AND ps.player_thing_id = doom_cs_discover.p_player_thing_id::int
  AND ps.sector_id IS NOT NULL
ON CONFLICT (map_id, line_id) DO NOTHING;
RETURN 0;
END _cs;
$function$;
