CREATE OR REPLACE FUNCTION doom.doom_mp_begin_player(p_map_id integer, p_skill integer, p integer, p_upto bigint)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  mf real;
  ms real;
  mr boolean;
  mt real;
  ma boolean;
  mw integer;
  mu boolean;
  n bigint;
  _r1 record;
BEGIN

mf := 0::real; ms := 0::real; mr := false; mt := 0::real;
ma := false; mw := NULL::int; mu := false;
FOR _r1 IN SELECT COALESCE(((array_agg(move_fwd ORDER BY seq DESC, move_fwd DESC) FILTER (WHERE (seq) IS NOT NULL AND (move_fwd) IS NOT NULL))[1]), 0)::real AS f,
       COALESCE(((array_agg(move_strafe ORDER BY seq DESC, move_strafe DESC) FILTER (WHERE (seq) IS NOT NULL AND (move_strafe) IS NOT NULL))[1]), 0)::real AS s,
       COALESCE(((array_agg(running ORDER BY seq DESC, running DESC) FILTER (WHERE (seq) IS NOT NULL AND (running) IS NOT NULL))[1]), FALSE) AS r,
       COALESCE(SUM(turn_degrees), 0)::real AS t,
       COALESCE(BOOL_OR(attack_held), FALSE) AS a,
       MAX(weapon_switch_to)::int AS w,
       COALESCE(BOOL_OR(use_requested), FALSE) AS u,
       COUNT(*) AS n
FROM mp_inputs WHERE map_id=doom_mp_begin_player.p_map_id AND player_thing_id=doom_mp_begin_player.p AND seq <= doom_mp_begin_player.p_upto
LOOP mf := _r1.f; ms := _r1.s; mr := _r1.r; mt := _r1.t; ma := _r1.a; mw := _r1.w; mu := _r1.u; n := _r1.n; END LOOP;
-- No input row this tic (the page's 35 Hz timer is not the game's clock):
-- the keys held last tic are still held, as Doom builds a tic from the keys
-- down, for at most 3 tics in a row (migration 0008). Turning, a weapon
-- switch and use are events, not keys: none.
IF _cs.n = 0 THEN
  FOR _r1 IN SELECT g.move_fwd, g.move_strafe, g.running, g.attack_held, g.empty_tics FROM game_tic_commands g
             WHERE g.map_id=doom_mp_begin_player.p_map_id AND g.player_thing_id=doom_mp_begin_player.p AND g.empty_tics < 3
  LOOP mf := _r1.move_fwd; ms := _r1.move_strafe; mr := _r1.running; ma := _r1.attack_held; END LOOP;
END IF;
PERFORM doom_cs_begin(doom_mp_begin_player.p_map_id,doom_mp_begin_player.p,doom_mp_begin_player.p_skill,_cs.mf,_cs.ms,_cs.mr,_cs.mt,_cs.ma,_cs.mw,_cs.mu);
-- written only when it changes: a tic with input after a tic with input
-- (nearly all of them) leaves it at 0, and it stops at 3 (no page: idle)
UPDATE game_tic_commands g SET empty_tics = CASE WHEN _cs.n = 0 THEN g.empty_tics + 1 ELSE 0 END
WHERE g.map_id=doom_mp_begin_player.p_map_id AND g.player_thing_id=doom_mp_begin_player.p
  AND CASE WHEN _cs.n = 0 THEN g.empty_tics < 3 ELSE g.empty_tics <> 0 END;
RETURN 1;
END _cs;
$function$;
