CREATE OR REPLACE FUNCTION doom.api_input(p_fwd real, p_strafe real, p_run boolean, p_turn real, p_fire boolean, p_weapon integer, p_use boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  playing boolean;
  taken_as bigint;
  _r1 record;
BEGIN

playing := false;
taken_as := 0;
FOR _r1 IN SELECT (m.state = 'playing') AS x FROM mp_match m
LOOP playing := _r1.x; END LOOP;
IF _cs.playing THEN
-- Returns the input's number (mp_inputs.seq; 0 when not playing): the page
-- times it to the first frame stamped with it (migration 0005).
FOR _r1 IN WITH ins AS (
INSERT INTO mp_inputs
  (map_id,player_thing_id,move_fwd,move_strafe,running,turn_degrees,
   attack_held,weapon_switch_to,use_requested)
SELECT mp.map_id, mp.player_thing_id,
       LEAST(1.0, GREATEST(-1.0, COALESCE(api_input.p_fwd, 0)))::real,
       LEAST(1.0, GREATEST(-1.0, COALESCE(api_input.p_strafe, 0)))::real,
       COALESCE(api_input.p_run, FALSE),
       LEAST(180.0, GREATEST(-180.0, COALESCE(api_input.p_turn, 0)))::real,
       COALESCE(api_input.p_fire, FALSE),
       CASE WHEN api_input.p_weapon BETWEEN 1 AND 8 THEN api_input.p_weapon END,
       COALESCE(api_input.p_use, FALSE)
FROM mp_players mp WHERE mp.role_name = doom_caller()
RETURNING seq)
SELECT MAX(seq) AS s FROM ins
LOOP taken_as := COALESCE(_r1.s, 0); END LOOP;
END IF;
-- capped: past 2^31 the probe stops, the input still goes in
RETURN LEAST(_cs.taken_as, 2147483647)::int;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_input(real,real,boolean,real,boolean,integer,boolean) FROM PUBLIC;
