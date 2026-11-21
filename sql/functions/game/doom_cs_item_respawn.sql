CREATE OR REPLACE FUNCTION doom.doom_cs_item_respawn(p_map_id integer, p_player_thing_id integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  alt boolean;
  item_respawn_tics double precision;
  dropped_base double precision;
  fog_base double precision;
  tic_span double precision;
  due integer;
  _r1 record;
  _r2 record;
BEGIN

alt := false;
-- 4 constants in one scan (was 4 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'ITEM_RESPAWN_TICS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'DROPPED_THING_ID_BASE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'ITEM_FOG_EFFECT_ID_BASE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'EFFECT_ID_TIC_SPAN'), 0)
  INTO item_respawn_tics, dropped_base, fog_base, tic_span
  FROM doom_constants WHERE name IN ('DROPPED_THING_ID_BASE', 'EFFECT_ID_TIC_SPAN', 'ITEM_FOG_EFFECT_ID_BASE', 'ITEM_RESPAWN_TICS');
FOR _r1 IN SELECT m.altdeath AS a FROM mp_match m WHERE m.map_id = doom_cs_item_respawn.p_map_id AND m.state = 'playing'
LOOP alt := _r1.a; END LOOP;
IF _cs.alt THEN
-- Everything taken and not yet queued: the pickup stage inserted the row this
-- tic, so the 30 seconds start now.
INSERT INTO item_respawns (map_id, thing_id, respawn_tic)
SELECT pu.map_id, pu.thing_id, (ps.level_tics + _cs.item_respawn_tics)::bigint
FROM picked_up_items pu
JOIN things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
JOIN player_state ps ON ps.map_id = pu.map_id AND ps.player_thing_id = doom_cs_item_respawn.p_player_thing_id
-- A monster's drop is gone for good; only a real map item comes back.
WHERE pu.map_id = doom_cs_item_respawn.p_map_id AND pu.thing_id < _cs.dropped_base
  AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type)
  AND NOT EXISTS (SELECT 1 FROM item_respawns r WHERE r.map_id = pu.map_id AND r.thing_id = pu.thing_id);

due := -1;
FOR _r2 IN SELECT r.thing_id AS t
FROM item_respawns r
JOIN player_state ps ON ps.map_id = r.map_id AND ps.player_thing_id = doom_cs_item_respawn.p_player_thing_id
WHERE r.map_id = doom_cs_item_respawn.p_map_id AND ps.level_tics >= r.respawn_tic
ORDER BY r.respawn_tic, r.thing_id LIMIT 1
LOOP due := _r2.t; END LOOP;
IF _cs.due >= 0 THEN
  -- The item fog (IFOG) at the spot, and DSITMBK from it.
  INSERT INTO world_effects (map_id, effect_id, effect_type, x, y, z, sector_id, age)
  SELECT t.map_id, _cs.fog_base::bigint + t.id::bigint * _cs.tic_span
                   + (ps.level_tics % _cs.tic_span),
         'ifog', t.x, t.y, s.floor_height, rt.sector_id, 0
  FROM things t
  JOIN render_things rt ON rt.map_id = t.map_id AND rt.thing_id = t.id
  JOIN sectors s ON s.map_id = rt.map_id AND s.id = rt.sector_id
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = doom_cs_item_respawn.p_player_thing_id
  WHERE t.map_id = doom_cs_item_respawn.p_map_id AND t.id = _cs.due
  ON CONFLICT (map_id, effect_id) DO NOTHING;

  INSERT INTO sound_events (map_id, event_key, level_tic, sound_name, source_thing_id, source_x, source_y)
  SELECT t.map_id, 'itemrespawn:' || t.id::text || ':' || ps.level_tics::text, ps.level_tics,
         'DSITMBK', t.id, t.x, t.y
  FROM things t
  JOIN player_state ps ON ps.map_id = t.map_id AND ps.player_thing_id = doom_cs_item_respawn.p_player_thing_id
  WHERE t.map_id = doom_cs_item_respawn.p_map_id AND t.id = _cs.due
  ON CONFLICT (map_id, event_key) DO NOTHING;

  -- the intermission's Items count keeps it (migration 0009)
  INSERT INTO level_items_taken (map_id, thing_id, taken)
  SELECT pu.map_id, pu.thing_id, 1 FROM picked_up_items pu
  WHERE pu.map_id = doom_cs_item_respawn.p_map_id AND pu.thing_id = _cs.due
  ON CONFLICT (map_id, thing_id) DO UPDATE SET taken = level_items_taken.taken + 1;
  DELETE FROM picked_up_items WHERE map_id = doom_cs_item_respawn.p_map_id AND thing_id = _cs.due;
  DELETE FROM item_respawns WHERE map_id = doom_cs_item_respawn.p_map_id AND thing_id = _cs.due;
END IF;
END IF;
RETURN 1;
END _cs;
$function$;
