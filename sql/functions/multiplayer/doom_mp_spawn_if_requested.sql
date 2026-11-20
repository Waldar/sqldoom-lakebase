CREATE OR REPLACE FUNCTION doom.doom_mp_spawn_if_requested(p_map_id integer, p integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  spawn boolean;
  _r1 record;
BEGIN

spawn := false;
FOR _r1 IN SELECT EXISTS(SELECT 1 FROM mp_join_requests r JOIN mp_players mp
              ON mp.map_id=r.map_id AND mp.slot=r.slot
              WHERE mp.map_id=doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id=doom_mp_spawn_if_requested.p) AS e
LOOP spawn := _r1.e; END LOOP;
IF _cs.spawn THEN
  UPDATE player_state SET frags=0 WHERE map_id=doom_mp_spawn_if_requested.p_map_id AND player_thing_id=doom_mp_spawn_if_requested.p;
  PERFORM doom_mp_respawn(doom_mp_spawn_if_requested.p_map_id,doom_mp_spawn_if_requested.p);
  -- the inventory brought from the previous level (single player, its exit;
  -- doom_mp_rotate), once: G_PlayerFinishLevel kept it, so no pistol start
  UPDATE player_state ps
  SET health = c.health, armor = c.armor, armor_class = c.armor_class, backpack = c.backpack,
      ammo_bullets = c.ammo_bullets, ammo_shells = c.ammo_shells, ammo_rockets = c.ammo_rockets,
      ammo_cells = c.ammo_cells, god_mode = c.god_mode, noclip = c.noclip
  FROM mp_carry c JOIN mp_players mp ON mp.slot = c.slot
  WHERE mp.map_id = doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id = doom_mp_spawn_if_requested.p
    AND ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id;
  IF FOUND THEN
    DELETE FROM player_weapon_owned o
    WHERE o.map_id = doom_mp_spawn_if_requested.p_map_id AND o.player_thing_id = doom_mp_spawn_if_requested.p;
    INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
    SELECT doom_mp_spawn_if_requested.p_map_id, doom_mp_spawn_if_requested.p, wid
    FROM mp_carry c JOIN mp_players mp ON mp.slot = c.slot, unnest(c.weapons) AS wid
    WHERE mp.map_id = doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id = doom_mp_spawn_if_requested.p;
    -- the new level raises the weapon that was in hand
    UPDATE player_weapons pw SET current_weapon = c.current_weapon, pending_weapon = NULL
    FROM mp_carry c JOIN mp_players mp ON mp.slot = c.slot
    WHERE mp.map_id = doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id = doom_mp_spawn_if_requested.p
      AND pw.map_id = mp.map_id AND pw.player_thing_id = mp.player_thing_id;
    DELETE FROM mp_carry c USING mp_players mp
    WHERE mp.slot = c.slot AND mp.map_id = doom_mp_spawn_if_requested.p_map_id
      AND mp.player_thing_id = doom_mp_spawn_if_requested.p;
  END IF;
  DELETE FROM mp_join_requests WHERE map_id=doom_mp_spawn_if_requested.p_map_id
    AND slot IN (SELECT mp.slot FROM mp_players mp
                 WHERE mp.map_id=doom_mp_spawn_if_requested.p_map_id AND mp.player_thing_id=doom_mp_spawn_if_requested.p);
END IF;
RETURN 1;
END _cs;
$function$;
