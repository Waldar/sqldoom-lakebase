CREATE OR REPLACE FUNCTION doom.doom_demo_begin(p_name text, p_map_id integer, p_player_thing_id integer, p_skill integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  did integer;
  _r1 record;
BEGIN

did := 0;
FOR _r1 IN SELECT COALESCE((SELECT d.demo_id FROM demos d WHERE d.name=doom_demo_begin.p_name),
                (SELECT COALESCE(MAX(x.demo_id),0)+1 FROM demos x)) AS i
LOOP did := _r1.i; END LOOP;
DELETE FROM demo_tics WHERE demo_id=_cs.did;
INSERT INTO demos (demo_id,name,map_id,player_thing_id,skill,tic_count)
VALUES (_cs.did,doom_demo_begin.p_name,doom_demo_begin.p_map_id,doom_demo_begin.p_player_thing_id,doom_demo_begin.p_skill,0)
ON CONFLICT (demo_id) DO UPDATE
SET name=EXCLUDED.name, map_id=EXCLUDED.map_id,
    player_thing_id=EXCLUDED.player_thing_id, skill=EXCLUDED.skill,
    tic_count=0, recorded_at=NOW();
UPDATE screen_state SET demo_recording=_cs.did, demo_playing=NULL, demo_tic=0 WHERE id=0;
RETURN _cs.did;
END _cs;
$function$;
