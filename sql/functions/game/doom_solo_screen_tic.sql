CREATE OR REPLACE FUNCTION doom.doom_solo_screen_tic(p_accel boolean)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  r record;
  accel boolean;
  bcnt integer;
  st integer;
  cnt integer;
  k integer;
  i integer;
  s integer;
  t integer;
  p integer;
  sounds text[];
  result text;
  _r1 record;
BEGIN

-- One 35 Hz step of single player's screens between levels (2026-11-21),
-- run by the referee while the world stands still. p_accel: fire or use was
-- pressed since the last step (WI_checkForAccelerate, a new press only).
--
-- The intermission, as wi_stuff.c (WI_Ticker, single player):
--   sp_state 1..10  WI_updateStats: one second's pause (odd states), then
--                   kills, items and secrets (2 % a tic) and time and par
--                   (3 s a tic), DSPISTOL every 4th tic while counting,
--                   DSBAREXP when a figure is done; 10 waits for a press
--                   (DSSGCOCK). A press before then fills every figure in.
--   sp_state 11     WI_updateShowNextLoc: the episode map, 4 s or a press
--   sp_state 12     WI_updateNoState: 10 tics, then the next level
--   sp_state 13     over: the referee moves the match on (next_map_id)
-- The end of the episode, as f_finale.c (F_Ticker): the text
-- (doom_finale_tic: a letter every 3 tics, then 250 tics), then the picture,
-- which a press leaves (finale_stage 2: back to the lobby).
--
-- Returns 'stats', 'next', 'done', 'text', 'picture' or 'over'.
SELECT * INTO r FROM screen_state WHERE id = 0;
IF NOT FOUND THEN
  RETURN 'over';
END IF;
accel := COALESCE(doom_solo_screen_tic.p_accel, FALSE);
bcnt := r.tics + 1;
sounds := ARRAY[]::text[];

IF r.screen = 'finale' THEN
  IF r.finale_stage >= 2 THEN
    RETURN 'over';
  END IF;
  IF r.finale_stage = 1 THEN
    UPDATE screen_state SET tics = _cs.bcnt, finale_stage = CASE WHEN _cs.accel THEN 2 ELSE 1 END WHERE id = 0;
    RETURN CASE WHEN _cs.accel THEN 'over' ELSE 'picture' END;
  END IF;
  PERFORM doom_finale_tic();
  UPDATE screen_state SET tics = _cs.bcnt WHERE id = 0;
  result := 'text';
  FOR _r1 IN SELECT finale_stage AS f FROM screen_state WHERE id = 0
  LOOP result := CASE WHEN _r1.f >= 1 THEN 'picture' ELSE 'text' END; END LOOP;
  RETURN _cs.result;
END IF;
IF r.screen <> 'intermission' THEN
  RETURN 'done';
END IF;

st := r.sp_state; cnt := r.cnt_pause;
k := r.kills_pct; i := r.items_pct; s := r.secrets_pct; t := r.time_secs; p := r.par_secs;
IF _cs.st <= 10 THEN
  IF _cs.accel AND _cs.st <> 10 THEN
    k := r.tgt_kills; i := r.tgt_items; s := r.tgt_secrets; t := r.tgt_time; p := r.tgt_par;
    sounds := sounds || 'DSBAREXP'::text;
    st := 10; accel := FALSE;
  END IF;
  IF _cs.st = 2 THEN
    k := _cs.k + 2;
    IF _cs.bcnt % 4 = 0 THEN sounds := sounds || 'DSPISTOL'::text; END IF;
    IF _cs.k >= r.tgt_kills THEN k := r.tgt_kills; sounds := sounds || 'DSBAREXP'::text; st := 3; END IF;
  ELSIF _cs.st = 4 THEN
    i := _cs.i + 2;
    IF _cs.bcnt % 4 = 0 THEN sounds := sounds || 'DSPISTOL'::text; END IF;
    IF _cs.i >= r.tgt_items THEN i := r.tgt_items; sounds := sounds || 'DSBAREXP'::text; st := 5; END IF;
  ELSIF _cs.st = 6 THEN
    s := _cs.s + 2;
    IF _cs.bcnt % 4 = 0 THEN sounds := sounds || 'DSPISTOL'::text; END IF;
    IF _cs.s >= r.tgt_secrets THEN s := r.tgt_secrets; sounds := sounds || 'DSBAREXP'::text; st := 7; END IF;
  ELSIF _cs.st = 8 THEN
    IF _cs.bcnt % 4 = 0 THEN sounds := sounds || 'DSPISTOL'::text; END IF;
    t := _cs.t + 3;
    IF _cs.t >= r.tgt_time THEN t := r.tgt_time; END IF;
    p := _cs.p + 3;
    IF _cs.p >= r.tgt_par THEN
      p := r.tgt_par;
      IF _cs.t >= r.tgt_time THEN sounds := sounds || 'DSBAREXP'::text; st := 9; END IF;
    END IF;
  ELSIF _cs.st = 10 THEN
    IF _cs.accel THEN
      sounds := sounds || 'DSSGCOCK'::text;
      st := 11; cnt := 140;          -- WI_initShowNextLoc: SHOWNEXTLOCDELAY * TICRATE
    END IF;
  ELSIF _cs.st % 2 = 1 THEN
    cnt := _cs.cnt - 1;
    IF _cs.cnt <= 0 THEN st := _cs.st + 1; cnt := 35; END IF;
  END IF;
ELSIF _cs.st = 11 THEN
  cnt := _cs.cnt - 1;
  IF _cs.cnt <= 0 OR _cs.accel THEN st := 12; cnt := 10; END IF;   -- WI_initNoState
ELSIF _cs.st = 12 THEN
  cnt := _cs.cnt - 1;
  IF _cs.cnt <= 0 THEN st := 13; END IF;
END IF;

UPDATE screen_state
SET sp_state = _cs.st, cnt_pause = _cs.cnt, tics = _cs.bcnt, accelerate = FALSE,
    kills_pct = _cs.k, items_pct = _cs.i, secrets_pct = _cs.s, time_secs = _cs.t, par_secs = _cs.p
WHERE id = 0;

-- The screen's sounds: no origin, so centred at full volume (api_sound_events).
IF cardinality(_cs.sounds) > 0 THEN
  INSERT INTO sound_events (map_id, event_key, level_tic, sound_name)
  SELECT m.map_id, 'wi:' || _cs.bcnt::text || ':' || u.n::text,
         COALESCE((SELECT max(ps.level_tics) FROM player_state ps WHERE ps.map_id = m.map_id), 0),
         u.snd
  FROM mp_match m CROSS JOIN unnest(_cs.sounds) WITH ORDINALITY AS u(snd, n)
  ON CONFLICT (map_id, event_key) DO NOTHING;
END IF;

RETURN CASE WHEN _cs.st <= 10 THEN 'stats' WHEN _cs.st <= 12 THEN 'next' ELSE 'done' END;
END _cs;
$function$;
