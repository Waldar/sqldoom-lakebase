CREATE OR REPLACE FUNCTION doom.doom_mp_level_done(p_map_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  playing boolean;
  done boolean;
  _r1 record;
  _r2 record;
  _r3 record;
BEGIN

playing := false;
FOR _r1 IN SELECT (m.state = 'playing') AS x FROM mp_match m WHERE m.map_id = doom_mp_level_done.p_map_id
LOOP playing := _r1.x; END LOOP;
done := false;
IF _cs.playing THEN
  FOR _r2 IN SELECT (m.timer_tics > 0 AND COALESCE(MAX(ps.level_tics), 0) >= m.timer_tics) AS d
  FROM mp_match m
  LEFT JOIN mp_players mp ON mp.map_id = m.map_id
  LEFT JOIN player_state ps ON ps.map_id = mp.map_id AND ps.player_thing_id = mp.player_thing_id
  WHERE m.map_id = doom_mp_level_done.p_map_id
  GROUP BY m.timer_tics
LOOP done := _r2.d; END LOOP;
END IF;
IF _cs.playing AND NOT _cs.done THEN
  FOR _r3 IN SELECT EXISTS (
    SELECT 1 FROM line_special_events e
    JOIN mp_players mp ON mp.map_id = e.map_id AND mp.player_thing_id = e.player_thing_id
    JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
    JOIN line_special_defs d ON d.special = ld.special
    WHERE e.map_id = doom_mp_level_done.p_map_id AND e.trigger_type = 'cross' AND d.is_exit
    UNION ALL
    SELECT 1 FROM line_use_results ur
    JOIN mp_players mp ON mp.map_id = ur.map_id AND mp.player_thing_id = ur.player_thing_id
    JOIN game_tic_commands c ON c.map_id = ur.map_id AND c.player_thing_id = ur.player_thing_id
    JOIN line_special_defs d ON d.special = ur.special
    WHERE ur.map_id = doom_mp_level_done.p_map_id AND ur.eligible AND c.use_requested AND d.is_exit
    UNION ALL
    SELECT 1 FROM player_state ps
    JOIN mp_players mp ON mp.map_id = ps.map_id AND mp.player_thing_id = ps.player_thing_id
    JOIN sectors s ON s.map_id = ps.map_id AND s.id = ps.sector_id
    JOIN sector_special_defs sd ON sd.special = s.special
    WHERE ps.map_id = doom_mp_level_done.p_map_id AND mp.role_name IS NOT NULL
      AND ps.health <= sd.exit_at_health
    UNION ALL
    SELECT 1 FROM (
      SELECT SUM(CASE WHEN h.alive THEN 1 ELSE 0 END) AS alive_bosses
      FROM boss_actions ba
      JOIN maps m ON m.name = ba.map_name AND m.map_id = doom_mp_level_done.p_map_id
      JOIN things t ON t.map_id = m.map_id AND t.type = ba.boss_type
      JOIN thing_health h ON h.map_id = t.map_id AND h.thing_id = t.id
      WHERE ba.action = 'exit_level'
      GROUP BY ba.map_name) q
    WHERE q.alive_bosses = 0
  ) AS e
LOOP done := _r3.e; END LOOP;
END IF;
RETURN _cs.done;
END _cs;
$function$;
