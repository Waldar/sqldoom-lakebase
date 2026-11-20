CREATE OR REPLACE FUNCTION doom.doom_cs_monster_deaths(p_map_id integer, p_player_thing_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  monster_respawn_tics double precision;
  any_respawn boolean;
  respawn_on boolean;
  nightmare boolean;
  _r1 record;
BEGIN

monster_respawn_tics := doom_const('MONSTER_RESPAWN_TICS');
respawn_on := false; nightmare := false;
FOR _r1 IN SELECT EXISTS (SELECT 1 FROM mp_match m WHERE m.map_id=doom_cs_monster_deaths.p_map_id::int AND m.respawn_monsters) AS r,
                  COALESCE((SELECT g.skill FROM game_tic_commands g
                            WHERE g.map_id=doom_cs_monster_deaths.p_map_id::int
                              AND g.player_thing_id=doom_cs_monster_deaths.p_player_thing_id::int) = 4, false) AS n
LOOP respawn_on := _r1.r; nightmare := _r1.n; END LOOP;
-- record when a corpse settled
INSERT INTO monster_deaths (map_id,thing_id,death_tic)
SELECT ai.map_id,ai.thing_id,ps.level_tics
FROM monster_ai ai
JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill
JOIN player_state ps ON ps.map_id=ai.map_id
  AND ps.player_thing_id=doom_cs_monster_deaths.p_player_thing_id::int
WHERE ai.map_id=doom_cs_monster_deaths.p_map_id::int AND ai.state='dead'
ON CONFLICT (map_id,thing_id) DO NOTHING;

-- choose this tic's respawn set. Staged into a table because the statements
-- below all have to agree on the same set.
-- * The "monsters respawn" rule (mp_match.respawn_monsters, the menu's
--   seconds in MONSTER_RESPAWN_TICS): exactly that long after the corpse
--   settled, as items (owner, 2026-11-20; it was Doom's roll below after the
--   rule's time, so a corpse came back 1-70 s late).
-- * Nightmare without the rule: Doom's P_NightmareRespawn: movecount >=
--   12*TICRATE, then a check only on every 32nd tic, then P_Random() <= 4 --
--   five values in 256, rolled per corpse.
-- Either way not while something else stands on the spot (P_CheckPosition).
-- The spot check is a scan per corpse: in the same statement as the timer
-- tests the planner ran it (an anti-join) for every corpse on every tic,
-- 28.9 ms a tic with 107 corpses on E1M3 (the tic 8 -> 37 ms as a map is
-- cleared; 2026-11-20, owner: "E1M3 feels slow"). So two steps: the corpses
-- whose time has come, then those whose spot is taken dropped. Neither the
-- rule nor Nightmare (the usual case): nothing at all.
DELETE FROM monster_respawns WHERE map_id=doom_cs_monster_deaths.p_map_id::int;

IF _cs.respawn_on OR _cs.nightmare THEN
INSERT INTO monster_respawns (map_id,thing_id,old_x,old_y)
SELECT md.map_id,md.thing_id,t.x,t.y
FROM monster_deaths md
JOIN things t ON t.map_id=md.map_id AND t.id=md.thing_id
JOIN player_state ps ON ps.map_id=md.map_id
  AND ps.player_thing_id=doom_cs_monster_deaths.p_player_thing_id::int
WHERE md.map_id=doom_cs_monster_deaths.p_map_id::int
  AND ps.level_tics - md.death_tic >= CASE WHEN _cs.respawn_on THEN _cs.monster_respawn_tics ELSE 12 * 35 END
  AND (_cs.respawn_on OR ((ps.level_tics & 31) = 0 AND doom_prandom(md.thing_id, ps.level_tics, 40) <= 4));
-- P_CheckPosition: no respawn while something else is standing on the spot
-- (only the few corpses chosen above are checked)
IF FOUND THEN
  DELETE FROM monster_respawns r
  USING things t, thing_combat_defs md2
  WHERE r.map_id=doom_cs_monster_deaths.p_map_id::int
    AND t.map_id=r.map_id AND t.id=r.thing_id AND md2.thing_type=t.type
    AND EXISTS (
      SELECT 1
      FROM thing_health oh
      JOIN things ot ON ot.map_id=oh.map_id AND ot.id=oh.thing_id
      JOIN thing_combat_defs od ON od.thing_type=ot.type
      WHERE oh.map_id=r.map_id AND oh.alive AND oh.thing_id<>r.thing_id
        AND POWER(ot.x-t.spawn_x,2)+POWER(ot.y-t.spawn_y,2)
              < POWER(od.radius+md2.radius,2));
END IF;
END IF;
any_respawn := false;
FOR _r1 IN SELECT EXISTS (SELECT 1 FROM monster_respawns WHERE map_id=doom_cs_monster_deaths.p_map_id) AS e
LOOP any_respawn := _r1.e; END LOOP;
RETURN _cs.any_respawn;
END _cs;
$function$;
