CREATE OR REPLACE FUNCTION doom.doom_mp_configure(p_map_id integer, p_skill integer, p_timer_tics integer, p_altdeath boolean, p_monsters boolean, p_respawn_monsters boolean, p_intermission_tics integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

DELETE FROM mp_match;
-- Closed until doom_mp_open: the referee opens the first map and compiles
-- the tic in peace, and no client writes meanwhile.
INSERT INTO mp_match (id, map_id, skill, state, timer_tics, altdeath, monsters, respawn_monsters, intermission_tics, intermission_until)
VALUES (0, doom_mp_configure.p_map_id, doom_mp_configure.p_skill, 'intermission', doom_mp_configure.p_timer_tics, doom_mp_configure.p_altdeath, doom_mp_configure.p_monsters, doom_mp_configure.p_respawn_monsters, doom_mp_configure.p_intermission_tics, now());
PERFORM doom_mp_world_flags(false);
RETURN 1;
END _cs;
$function$;
