CREATE OR REPLACE FUNCTION doom.doom_attract_tic()
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  step integer;
  pagetic real;
  playing integer;
  n integer;
  slot integer;
  did integer;
  _r1 record;
  _r2 record;
  _r3 record;
BEGIN

step := -1;
pagetic := 0::real;
playing := NULL::int;
FOR _r1 IN SELECT attract_step, attract_pagetic, demo_playing FROM screen_state WHERE id=0
LOOP step := _r1.attract_step; pagetic := _r1.attract_pagetic; playing := _r1.demo_playing; END LOOP;
IF _cs.step < 0 OR _cs.playing IS NOT NULL THEN RETURN 'none'; END IF;
IF _cs.pagetic > 1 THEN
  UPDATE screen_state SET attract_pagetic = attract_pagetic - 1 WHERE id=0;
  RETURN 'none';
END IF;
step := _cs.step + 1;
n := 0;
FOR _r2 IN SELECT count(*)::int AS c FROM demos
LOOP n := _r2.c; END LOOP;
IF _cs.n = 0 THEN
  UPDATE screen_state SET attract_step=_cs.step, attract_pagetic=170, screen='title', cursor_index=0 WHERE id=0;
  RETURN 'page';
END IF;
slot := _cs.step % (2*_cs.n);
IF _cs.slot % 2 = 0 THEN
  UPDATE screen_state
  SET attract_step=_cs.step,
      attract_pagetic=CASE WHEN _cs.slot=0 THEN 170 ELSE 200 END,
      screen=CASE WHEN _cs.slot=0 THEN 'title' ELSE 'help2' END, cursor_index=0
  WHERE id=0;
  RETURN 'page';
END IF;
did := -1;
FOR _r3 IN SELECT q.demo_id AS i
FROM (SELECT d.demo_id, ROW_NUMBER() OVER (ORDER BY d.demo_id) AS rn FROM demos d) q
WHERE q.rn = _cs.slot/2 + 1
LOOP did := _r3.i; END LOOP;
UPDATE screen_state
SET attract_step=_cs.step, attract_pagetic=0, demo_playing=_cs.did, demo_recording=NULL,
    demo_tic=0, screen='game'
WHERE id=0;
RETURN 'demo:' || _cs.did::text;
END _cs;
$function$;
