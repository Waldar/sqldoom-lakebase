CREATE OR REPLACE FUNCTION doom.doom_cs_weapon_state(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  was_saw_up boolean;
  is_saw_up boolean;
BEGIN

-- P_BringUpWeapon: sfx_sawup when the chainsaw starts coming up (switched
-- to, or picked up: the pickup switches to it), 2026-11-20. Its raise is the
-- row becoming current weapon 8 in state 'up' (doom_weapon_decision: 'down'
-- done -> 'up' with the pending weapon, in one tic).
was_saw_up := COALESCE((SELECT w.current_weapon = 8 AND w.state = 'up' FROM player_weapons w
                        WHERE w.map_id = doom_cs_weapon_state.p_map_id
                          AND w.player_thing_id = doom_cs_weapon_state.p_player_thing_id), false);

UPDATE player_weapons w
SET state=d.n_state,seq_index=d.n_seq,tics=d.n_tics,
    current_weapon=d.n_current_weapon,pending_weapon=d.n_pending_weapon,
    flash_seq_index=d.n_flash_seq,flash_tics=d.n_flash_tics,
    sx=d.n_sx,sy=d.n_sy,
    shot_serial=w.shot_serial+CASE WHEN d.fires_now THEN 1 ELSE 0 END,
    fired_this_tick=d.fires_now
FROM doom_weapon_decision d
WHERE w.map_id=doom_cs_weapon_state.p_map_id AND w.player_thing_id=doom_cs_weapon_state.p_player_thing_id
  AND d.map_id=w.map_id AND d.player_thing_id=w.player_thing_id;

is_saw_up := COALESCE((SELECT w.current_weapon = 8 AND w.state = 'up' FROM player_weapons w
                       WHERE w.map_id = doom_cs_weapon_state.p_map_id
                         AND w.player_thing_id = doom_cs_weapon_state.p_player_thing_id), false);
IF _cs.is_saw_up AND NOT _cs.was_saw_up THEN
  INSERT INTO sound_events
    (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
  SELECT ps.map_id, 'saw-up:'||ps.player_thing_id::text||':'||ps.level_tics::text,
         ps.level_tics, 'DSSAWUP', ps.player_thing_id, t.x, t.y
  FROM player_state ps
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.map_id = doom_cs_weapon_state.p_map_id AND ps.player_thing_id = doom_cs_weapon_state.p_player_thing_id
  ON CONFLICT (map_id,event_key) DO NOTHING;
END IF;
RETURN;
END _cs;
$function$;
