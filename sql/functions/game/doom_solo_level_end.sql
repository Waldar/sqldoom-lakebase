CREATE OR REPLACE FUNCTION doom.doom_solo_level_end(p_map_id integer)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  pthing integer;
  secret boolean;
  ep integer;
  lv integer;
  next_lv integer;
  next_id integer;
  kills integer;
  items integer;
  secrets integer;
  tics bigint;
  max_kills integer;
  max_items integer;
  max_secrets integer;
  par_tics bigint;
  found integer;
  _r1 record;
BEGIN

-- A single-player level has just ended by its exit (the referee calls this
-- right after the tic that ended it, while that tic's line events are still
-- in the tables): which exit, what comes next, and the intermission's
-- figures, as Doom's G_DoCompleted and WI_initStats (2026-11-21).
-- Returns 'stats' (the intermission starts) or 'finale' (the end of the
-- episode: E?M8 has no intermission in Doom, F_StartFinale at once).
pthing := NULL;
FOR _r1 IN SELECT mp.player_thing_id AS t FROM mp_players mp
  WHERE mp.map_id = doom_solo_level_end.p_map_id AND mp.role_name IS NOT NULL
  ORDER BY mp.slot LIMIT 1
LOOP pthing := _r1.t; END LOOP;

-- G_SecretExitLevel: the exit line was a secret one (E1M3's switch, 51),
-- crossed or used in this tic.
secret := EXISTS (
  SELECT 1 FROM line_special_events e
  JOIN mp_players mp ON mp.map_id = e.map_id AND mp.player_thing_id = e.player_thing_id
  JOIN linedefs ld ON ld.map_id = e.map_id AND ld.id = e.line_id
  JOIN line_special_defs d ON d.special = ld.special
  WHERE e.map_id = doom_solo_level_end.p_map_id AND e.trigger_type = 'cross' AND d.is_exit AND d.secret_exit
  UNION ALL
  SELECT 1 FROM line_use_results ur
  JOIN mp_players mp ON mp.map_id = ur.map_id AND mp.player_thing_id = ur.player_thing_id
  JOIN game_tic_commands c ON c.map_id = ur.map_id AND c.player_thing_id = ur.player_thing_id
  JOIN line_special_defs d ON d.special = ur.special
  WHERE ur.map_id = doom_solo_level_end.p_map_id AND ur.eligible AND c.use_requested
    AND d.is_exit AND d.secret_exit);

ep := 1; lv := 1;
FOR _r1 IN SELECT substring(m.name FROM 2 FOR 1)::int AS e, substring(m.name FROM 4 FOR 1)::int AS l
  FROM maps m WHERE m.map_id = doom_solo_level_end.p_map_id AND m.name ~ '^E[1-4]M[1-9]$'
LOOP ep := _r1.e; lv := _r1.l; END LOOP;

-- G_DoCompleted's wminfo.next: a secret exit leads to M9, M9 back to where
-- the episode's secret exit was (E1M4, E2M6, E3M7, E4M3), M8 ends the
-- episode, any other level is followed by the next one.
next_lv := CASE WHEN _cs.lv = 8 THEN NULL
                WHEN _cs.secret THEN 9
                WHEN _cs.lv = 9 THEN CASE _cs.ep WHEN 1 THEN 4 WHEN 2 THEN 6 WHEN 3 THEN 7 ELSE 3 END
                ELSE _cs.lv + 1 END;
next_id := NULL;
FOR _r1 IN SELECT m.map_id AS id FROM maps m WHERE m.name = 'E' || _cs.ep::text || 'M' || _cs.next_lv::text
LOOP next_id := _r1.id; END LOOP;

IF _cs.lv = 8 OR _cs.next_id IS NULL THEN
  -- the end of the episode (or a next level that is not loaded)
  UPDATE screen_state SET next_map_id = NULL, secret_exit = FALSE, accelerate = FALSE, tics = 0 WHERE id = 0;
  found := doom_finale_begin(_cs.ep);
  IF _cs.found <> 0 THEN
    RETURN 'finale';
  END IF;
  UPDATE screen_state SET screen = 'finale', finale_episode = _cs.ep, finale_count = 0, finale_stage = 1 WHERE id = 0;
  RETURN 'finale';
END IF;

-- The figures, as G_DoCompleted hands them to the intermission: kills of
-- the monsters that count, items that count (also those taken that came
-- back since, level_items_taken), secret sectors entered, the level's time.
kills := 0; items := 0; secrets := 0; tics := 0;
FOR _r1 IN SELECT count(*)::int AS n FROM thing_health h
  JOIN things t ON t.map_id = h.map_id AND t.id = h.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type AND d.counts_kill
  WHERE h.map_id = doom_solo_level_end.p_map_id AND NOT h.alive
LOOP kills := _r1.n; END LOOP;
FOR _r1 IN SELECT (SELECT count(*) FROM picked_up_items pu
                     JOIN things t ON t.map_id = pu.map_id AND t.id = pu.thing_id
                     WHERE pu.map_id = doom_solo_level_end.p_map_id
                       AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type AND d.counts_item))
                + COALESCE((SELECT sum(it.taken) FROM level_items_taken it
                     JOIN things t ON t.map_id = it.map_id AND t.id = it.thing_id
                     WHERE it.map_id = doom_solo_level_end.p_map_id
                       AND EXISTS (SELECT 1 FROM pickup_defs d WHERE d.thing_type = t.type AND d.counts_item)), 0) AS n
LOOP items := _r1.n; END LOOP;
FOR _r1 IN SELECT count(DISTINCT sd.sector_id)::int AS n FROM level_secret_discoveries sd
  WHERE sd.map_id = doom_solo_level_end.p_map_id
LOOP secrets := _r1.n; END LOOP;
FOR _r1 IN SELECT ps.level_tics AS t FROM player_state ps
  WHERE ps.map_id = doom_solo_level_end.p_map_id AND ps.player_thing_id = _cs.pthing
LOOP tics := _r1.t; END LOOP;
-- The level's totals and par (doom_reset_stage, at the level's start);
-- WI_initVariables: a total of 0 counts as 1.
max_kills := 1; max_items := 1; max_secrets := 1; par_tics := 0;
FOR _r1 IN SELECT ls.total_kills AS k, ls.total_items AS i, ls.total_secrets AS s, ls.par_tics AS p
  FROM level_stats ls WHERE ls.map_id = doom_solo_level_end.p_map_id
  ORDER BY ls.player_thing_id LIMIT 1
LOOP
  max_kills := GREATEST(1, _r1.k); max_items := GREATEST(1, _r1.i); max_secrets := GREATEST(1, _r1.s);
  par_tics := COALESCE(_r1.p, 0);
END LOOP;

-- WI_initStats: the figures start at -1 (not drawn) and count up from their
-- own state; one second's pause first. didsecret: set by leaving M9.
UPDATE screen_state s
SET screen = 'intermission', cursor_index = 0,
    inter_episode = _cs.ep, inter_level = _cs.lv, inter_next = _cs.next_lv,
    next_map_id = _cs.next_id, secret_exit = _cs.secret,
    did_secret = s.did_secret OR _cs.lv = 9,
    tgt_kills = _cs.kills * 100 / _cs.max_kills,
    tgt_items = _cs.items * 100 / _cs.max_items,
    tgt_secrets = _cs.secrets * 100 / _cs.max_secrets,
    tgt_time = (_cs.tics / 35)::int,
    tgt_par = (_cs.par_tics / 35)::int,
    kills_pct = -1, items_pct = -1, secrets_pct = -1, time_secs = -1, par_secs = -1,
    sp_state = 1, cnt_pause = 35, accelerate = FALSE, tics = 0
WHERE s.id = 0;
RETURN 'stats';
END _cs;
$function$;
