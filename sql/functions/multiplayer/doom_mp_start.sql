CREATE OR REPLACE FUNCTION doom.doom_mp_start(p_map_id integer, p_skill integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  monsters boolean;
  q1 integer;
  q2 integer;
  q3 integer;
  q4 integer;
  n integer;
  _r1 record;
  _r2 record;
  _r3 record;
  _r4 record;
  _r5 record;
  _r6 record;
BEGIN

PERFORM doom_reset_stage(doom_mp_start.p_map_id, doom_mp_start.p_skill);

-- One match at a time: every slot of every map is cleared.
DELETE FROM mp_players;

-- Slot n is the player-n start's Thing: the row the player IS, wherever the
-- deathmatch start puts it. Slots open free; api_join claims them.
INSERT INTO mp_players (map_id, slot, player_thing_id, skill)
SELECT doom_mp_start.p_map_id, t.type, MIN(t.id), doom_mp_start.p_skill
FROM things t WHERE t.map_id=doom_mp_start.p_map_id AND t.type IN (1,2,3,4)
GROUP BY t.type;

-- doom_reset_stage created the player rows for the type-1 start; the same
-- rows, same shape, for slots 2 to 4.
INSERT INTO player_weapons (map_id, player_thing_id)
SELECT map_id, player_thing_id FROM mp_players WHERE map_id=doom_mp_start.p_map_id AND slot>=2;

INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
SELECT mp.map_id, mp.player_thing_id, w.weapon_id
FROM mp_players mp CROSS JOIN (VALUES (1), (2)) AS w (weapon_id)
WHERE mp.map_id=doom_mp_start.p_map_id AND mp.slot>=2;

INSERT INTO player_state (
  map_id,player_thing_id,health,alive,ammo_bullets,
  previous_x,previous_y,position_x,position_y,base_z,view_z,view_angle
)
SELECT t.map_id,t.id,100,TRUE,50,t.x,t.y,t.x,t.y,t.z,t.z,t.angle
FROM mp_players mp
JOIN things t ON t.map_id=mp.map_id AND t.id=mp.player_thing_id
WHERE mp.map_id=doom_mp_start.p_map_id AND mp.slot>=2;

-- -nomonsters, unless the match keeps them: everything that would count as
-- a kill is not spawned. Barrels stay. A Thing without health or AI would
-- still be drawn standing there by the renderer, so it is hidden the way a
-- taken item is.
monsters := false;
FOR _r1 IN SELECT m.monsters AS x FROM mp_match m
LOOP monsters := _r1.x; END LOOP;
IF NOT _cs.monsters THEN
INSERT INTO picked_up_items (map_id, thing_id)
SELECT h.map_id, h.thing_id
FROM thing_health h
JOIN things t ON t.map_id=h.map_id AND t.id=h.thing_id
JOIN thing_combat_defs d ON d.thing_type=t.type AND d.counts_kill
WHERE h.map_id=doom_mp_start.p_map_id
ON CONFLICT (map_id, thing_id) DO NOTHING;

DELETE FROM monster_ai ai
USING things t, thing_combat_defs d
WHERE ai.map_id=doom_mp_start.p_map_id AND t.map_id=ai.map_id AND t.id=ai.thing_id
  AND d.thing_type=t.type AND d.counts_kill;

DELETE FROM thing_health h
USING things t, thing_combat_defs d
WHERE h.map_id=doom_mp_start.p_map_id AND t.map_id=h.map_id AND t.id=h.thing_id
  AND d.thing_type=t.type AND d.counts_kill;
END IF;

DELETE FROM mp_inputs WHERE map_id=doom_mp_start.p_map_id;

-- Every slot gets a reborn loadout at a deathmatch start, then lies dead and
-- free: no input ever reaches an unclaimed slot, so P_DeathThink never
-- respawns it, and the claim (api_join, via the next tic) respawns it fresh.
q1 := NULL::int; q2 := NULL::int; q3 := NULL::int; q4 := NULL::int;
FOR _r2 IN SELECT player_thing_id FROM mp_players WHERE map_id=doom_mp_start.p_map_id AND slot=1
LOOP q1 := _r2.player_thing_id; END LOOP;
FOR _r3 IN SELECT player_thing_id FROM mp_players WHERE map_id=doom_mp_start.p_map_id AND slot=2
LOOP q2 := _r3.player_thing_id; END LOOP;
FOR _r4 IN SELECT player_thing_id FROM mp_players WHERE map_id=doom_mp_start.p_map_id AND slot=3
LOOP q3 := _r4.player_thing_id; END LOOP;
FOR _r5 IN SELECT player_thing_id FROM mp_players WHERE map_id=doom_mp_start.p_map_id AND slot=4
LOOP q4 := _r5.player_thing_id; END LOOP;
IF _cs.q1 IS NOT NULL THEN PERFORM doom_mp_respawn(doom_mp_start.p_map_id, _cs.q1); END IF;
IF _cs.q2 IS NOT NULL THEN PERFORM doom_mp_respawn(doom_mp_start.p_map_id, _cs.q2); END IF;
IF _cs.q3 IS NOT NULL THEN PERFORM doom_mp_respawn(doom_mp_start.p_map_id, _cs.q3); END IF;
IF _cs.q4 IS NOT NULL THEN PERFORM doom_mp_respawn(doom_mp_start.p_map_id, _cs.q4); END IF;
PERFORM doom_mp_vacate_all(doom_mp_start.p_map_id);
n := 0;
FOR _r6 IN SELECT count(*)::int AS c FROM mp_players WHERE map_id=doom_mp_start.p_map_id
LOOP n := _r6.c; END LOOP;
RETURN _cs.n;
END _cs;
$function$;
