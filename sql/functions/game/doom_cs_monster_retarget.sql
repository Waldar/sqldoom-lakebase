CREATE OR REPLACE FUNCTION doom.doom_cs_monster_retarget(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- Targets. NULL means "the player" for a single-player world; in a
-- deathmatch the tic passes a different live player each time, so a monster
-- that is up and has no target takes the one it is handed and keeps it until
-- that player dies or leaves.
UPDATE monster_ai ai
SET target_thing_id = NULL
WHERE ai.map_id = doom_cs_monster_retarget.p_map_id AND ai.target_thing_id IS NOT NULL
  AND (EXISTS (
    SELECT 1 FROM player_state ps
    WHERE ps.map_id = ai.map_id AND ps.player_thing_id = ai.target_thing_id
      AND (NOT ps.alive OR EXISTS (
        SELECT 1 FROM mp_players mp
        WHERE mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
          AND mp.role_name IS NULL)))
    OR EXISTS (
    SELECT 1 FROM thing_health th
    WHERE th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id AND NOT th.alive));

UPDATE monster_ai
SET target_thing_id = doom_cs_monster_retarget.p_player_thing_id
WHERE map_id = doom_cs_monster_retarget.p_map_id AND target_thing_id IS NULL AND state IN ('see', 'missile', 'pain');
RETURN;
END _cs;
$function$;
