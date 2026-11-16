CREATE OR REPLACE FUNCTION doom.doom_demo_play(p_name text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  did integer;
  _r1 record;
BEGIN

did := -1;
FOR _r1 IN SELECT d.demo_id AS i FROM demos d WHERE d.name=doom_demo_play.p_name
LOOP did := _r1.i; END LOOP;
IF _cs.did >= 0 THEN
  UPDATE screen_state SET demo_playing=_cs.did, demo_recording=NULL, demo_tic=0 WHERE id=0;
END IF;
RETURN _cs.did;
END _cs;
$function$;
