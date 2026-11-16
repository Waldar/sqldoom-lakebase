CREATE OR REPLACE FUNCTION doom.doom_intermission_tic()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  result text;
  pre_accel boolean;
  pre_state integer;
  _r1 record;
  _r2 record;
BEGIN

-- One 35 Hz step of WI_updateStats
--   sp_state 2 kills, 4 items, 6 secrets  -- +2 percent a tic
--   sp_state 8 time and par               -- +3 seconds a tic
--   odd states                            -- a one-second pause
--   sp_state 10                           -- everything shown, waiting
--
-- Returns 'counting' while the tally runs, 'waiting' once it is all on
-- screen, and 'done' when a keypress has dismissed it.
result := 'counting';
pre_accel := false;
pre_state := 0;
FOR _r1 IN SELECT accelerate AS a, sp_state AS st FROM screen_state WHERE id=0
LOOP pre_accel := _r1.a; pre_state := _r1.st; END LOOP;

UPDATE screen_state s
SET
  -- An accelerating keypress fills every figure in at once.
  kills_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_kills
      WHEN s.sp_state = 2 THEN LEAST(s.tgt_kills, s.kills_pct + 2)
      ELSE s.kills_pct END,
  items_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_items
      WHEN s.sp_state = 4 THEN LEAST(s.tgt_items, s.items_pct + 2)
      ELSE s.items_pct END,
  secrets_pct = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_secrets
      WHEN s.sp_state = 6 THEN LEAST(s.tgt_secrets, s.secrets_pct + 2)
      ELSE s.secrets_pct END,
  time_secs = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_time
      WHEN s.sp_state = 8 THEN LEAST(s.tgt_time, s.time_secs + 3)
      ELSE s.time_secs END,
  par_secs = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN s.tgt_par
      WHEN s.sp_state = 8 THEN LEAST(s.tgt_par, s.par_secs + 3)
      ELSE s.par_secs END,
  sp_state = CASE
      WHEN s.accelerate AND s.sp_state <> 10 THEN 10
      -- A counting state ends when its figure reaches the target.
      WHEN s.sp_state = 2 AND s.kills_pct + 2 >= s.tgt_kills THEN 3
      WHEN s.sp_state = 4 AND s.items_pct + 2 >= s.tgt_items THEN 5
      WHEN s.sp_state = 6 AND s.secrets_pct + 2 >= s.tgt_secrets THEN 7
      WHEN s.sp_state = 8 AND s.time_secs + 3 >= s.tgt_time
                          AND s.par_secs + 3 >= s.tgt_par THEN 10
      -- A pause state ends when its second runs out.
      WHEN s.sp_state IN (1,3,5,7,9) AND s.cnt_pause <= 1 THEN s.sp_state + 1
      ELSE s.sp_state END,
  cnt_pause = CASE
      WHEN s.sp_state IN (1,3,5,7,9) AND s.cnt_pause > 1 THEN s.cnt_pause - 1
      WHEN s.sp_state IN (1,3,5,7,9) THEN 35
      ELSE s.cnt_pause END,
  accelerate = FALSE
WHERE s.id = 0;

FOR _r2 IN SELECT CASE WHEN screen <> 'intermission' THEN 'done'
            WHEN sp_state >= 10 THEN 'waiting'
            ELSE 'counting' END AS r
FROM screen_state WHERE id=0
LOOP result := _r2.r; END LOOP;
IF _cs.pre_accel AND _cs.pre_state >= 10 THEN
  UPDATE screen_state SET screen='game', sp_state=0, cnt_pause=0 WHERE id=0;
  result := 'done';
END IF;
RETURN _cs.result;
END _cs;
$function$;
