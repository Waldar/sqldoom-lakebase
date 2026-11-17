CREATE OR REPLACE FUNCTION doom.doom_run_game_tic(p_map_id integer, p_player_thing_id integer, p_skill integer, p_move_fwd real, p_move_strafe real, p_running boolean, p_turn_degrees real, p_attack_held boolean, p_weapon_switch_to integer, p_use_requested boolean)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  playing integer;
  recording integer;
  dtic integer;
  have boolean;
  nobody integer;
  _r1 record;
  _r2 record;
BEGIN

PERFORM doom_cs_begin(
  doom_run_game_tic.p_map_id,doom_run_game_tic.p_player_thing_id,doom_run_game_tic.p_skill,doom_run_game_tic.p_move_fwd,doom_run_game_tic.p_move_strafe,
  doom_run_game_tic.p_running,doom_run_game_tic.p_turn_degrees,doom_run_game_tic.p_attack_held,doom_run_game_tic.p_weapon_switch_to,doom_run_game_tic.p_use_requested);
-- G_ReadDemoTiccmd / G_WriteDemoTiccmd: while a demo plays, its recorded
-- command replaces the client's; while one records, the command is appended.
-- Past the last recorded tic the demo ends, and if the attract loop started
-- it the title comes back for the loop's next page.
playing := NULL::int;
recording := NULL::int;
dtic := 0;
FOR _r1 IN SELECT demo_playing, demo_recording, demo_tic FROM screen_state WHERE id=0
LOOP playing := _r1.demo_playing; recording := _r1.demo_recording; dtic := _r1.demo_tic; END LOOP;
IF _cs.playing IS NOT NULL THEN
  have := false;
  FOR _r2 IN SELECT EXISTS (SELECT 1 FROM demo_tics d WHERE d.demo_id=_cs.playing AND d.tic=_cs.dtic) AS e
LOOP have := _r2.e; END LOOP;
  IF _cs.have THEN
    UPDATE game_tic_commands g
    SET move_fwd=d.move_fwd, move_strafe=d.move_strafe, running=d.running,
        turn_degrees=d.turn_degrees, attack_held=d.attack_held,
        weapon_switch_to=d.weapon_switch_to, use_requested=d.use_requested
    FROM demo_tics d
    WHERE d.demo_id=_cs.playing AND d.tic=_cs.dtic
      AND g.map_id=doom_run_game_tic.p_map_id AND g.player_thing_id=doom_run_game_tic.p_player_thing_id;
    UPDATE screen_state SET demo_tic=demo_tic+1 WHERE id=0;
  END IF;
  IF NOT _cs.have THEN
    UPDATE screen_state
    SET demo_playing=NULL, demo_tic=0,
        screen=CASE WHEN attract_step>=0 THEN 'title'::screen_kind ELSE screen END,
        attract_pagetic=0
    WHERE id=0;
  END IF;
END IF;
IF _cs.recording IS NOT NULL THEN
  INSERT INTO demo_tics
    (demo_id,tic,move_fwd,move_strafe,running,turn_degrees,attack_held,
     weapon_switch_to,use_requested)
  SELECT _cs.recording,_cs.dtic,g.move_fwd,g.move_strafe,g.running,g.turn_degrees,
         g.attack_held,g.weapon_switch_to,g.use_requested
  FROM game_tic_commands g
  WHERE g.map_id=doom_run_game_tic.p_map_id AND g.player_thing_id=doom_run_game_tic.p_player_thing_id
  ON CONFLICT (demo_id,tic) DO UPDATE SET
    move_fwd=EXCLUDED.move_fwd, move_strafe=EXCLUDED.move_strafe,
    running=EXCLUDED.running, turn_degrees=EXCLUDED.turn_degrees,
    attack_held=EXCLUDED.attack_held,
    weapon_switch_to=EXCLUDED.weapon_switch_to,
    use_requested=EXCLUDED.use_requested;
  UPDATE demos SET tic_count=GREATEST(tic_count,_cs.dtic+1) WHERE demo_id=_cs.recording;
  UPDATE screen_state SET demo_tic=demo_tic+1 WHERE id=0;
END IF;
nobody := NULL::int;
RETURN doom_run_tic_core(doom_run_game_tic.p_map_id,doom_run_game_tic.p_skill,doom_run_game_tic.p_player_thing_id,_cs.nobody,_cs.nobody,_cs.nobody);
END _cs;
$function$;
