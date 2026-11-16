CREATE OR REPLACE FUNCTION doom.api_join()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  spectator boolean;
  pid integer;
  playing boolean;
  claim integer;
  claim_map integer;
  claim_slot integer;
  first boolean;
  _r1 record;
  _r2 record;
  _r3 record;
  _r4 record;
  _r5 record;
BEGIN

spectator := false;
FOR _r1 IN SELECT EXISTS (SELECT 1 FROM api_spectator_roles s WHERE s.role_name = doom_caller()) AS x
LOOP spectator := _r1.x; END LOOP;
IF _cs.spectator THEN RETURN -1; END IF;
pid := -1;
FOR _r2 IN SELECT mp.player_thing_id AS p FROM mp_players mp
WHERE mp.role_name = doom_caller()
LOOP pid := _r2.p; END LOOP;
IF _cs.pid < 0 THEN
  -- The queue: a caller without a slot is a waiter from its first call, and
  -- stays one while it keeps calling (the page asks once a second). Waiters
  -- quiet for five seconds have left. First come, first served: a free slot
  -- goes to the earliest waiter only.
  INSERT INTO mp_waiting (role_name, since, last_seen) VALUES (doom_caller(), now(), now())
  ON CONFLICT (role_name) DO UPDATE SET last_seen = now();
END IF;
-- Between maps nothing is claimed or written to the slot table: the referee
-- is moving the slots to the next map and a concurrent write would only make
-- it retry. The client asks again in a second; api_match says what is going on.
playing := false;
FOR _r3 IN SELECT (m.state = 'playing') AS x FROM mp_match m
LOOP playing := _r3.x; END LOOP;
IF NOT _cs.playing THEN RETURN -1; END IF;
claim := -1; claim_map := 0; claim_slot := 0;
first := false;
FOR _r4 IN SELECT NOT EXISTS (SELECT 1 FROM mp_waiting w, mp_waiting me
                   WHERE me.role_name = doom_caller() AND w.since < me.since) AS x
LOOP first := _r4.x; END LOOP;
IF _cs.pid < 0 AND _cs.first THEN
  FOR _r5 IN SELECT mp.map_id AS m, mp.slot AS s, mp.player_thing_id AS p FROM mp_players mp
  WHERE mp.role_name IS NULL ORDER BY mp.map_id, mp.slot LIMIT 1
LOOP claim_map := _r5.m; claim_slot := _r5.s; claim := _r5.p; END LOOP;
END IF;
IF _cs.claim >= 0 THEN
  UPDATE mp_players SET role_name = doom_caller(), claimed_at = now()
  WHERE map_id = _cs.claim_map AND slot = _cs.claim_slot AND role_name IS NULL;
  DELETE FROM mp_waiting WHERE role_name = doom_caller();
  INSERT INTO mp_join_requests (map_id, slot) VALUES (_cs.claim_map, _cs.claim_slot)
  ON CONFLICT DO NOTHING;
  pid := _cs.claim;
END IF;
IF _cs.pid >= 0 THEN
  UPDATE mp_players SET last_seen = now() WHERE role_name = doom_caller();
END IF;
IF _cs.claim >= 0 THEN
  -- A fresh claim gets a grace period before the reaper may take the slot
  -- back: the client compiles its frame statement next, which takes several
  -- seconds when several players join at once and would otherwise outlast
  -- IDLE_SECONDS. The heartbeats never shorten it (api_camera), so it is
  -- also how long a slot stays held after someone joins and leaves at once;
  -- 15 s covers the compile and keeps that wait short for the next in line.
  UPDATE mp_players SET last_seen = now() + interval '15 seconds'
  WHERE role_name = doom_caller();
END IF;
RETURN _cs.pid;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_join() FROM PUBLIC;
