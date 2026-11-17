CREATE OR REPLACE FUNCTION doom.doom_mp_referee_claim(p_map_id integer, p_stale_seconds integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  busy boolean;
  _r1 record;
BEGIN

busy := false;
FOR _r1 IN SELECT EXISTS(SELECT 1 FROM mp_referee r WHERE r.map_id=doom_mp_referee_claim.p_map_id
              AND EXTRACT(EPOCH FROM (now() - r.heartbeat)) < doom_mp_referee_claim.p_stale_seconds) AS e
LOOP busy := _r1.e; END LOOP;
IF NOT _cs.busy THEN
  DELETE FROM mp_referee WHERE map_id=doom_mp_referee_claim.p_map_id;
  INSERT INTO mp_referee (map_id, heartbeat) VALUES (doom_mp_referee_claim.p_map_id, now());
END IF;
RETURN NOT _cs.busy;
END _cs;
$function$;
