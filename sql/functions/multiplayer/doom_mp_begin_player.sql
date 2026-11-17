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
       COALESCE(BOOL_OR(use_requested), FALSE) AS u
FROM mp_inputs WHERE map_id=doom_mp_begin_player.p_map_id AND player_thing_id=doom_mp_begin_player.p AND seq <= doom_mp_begin_player.p_upto
LOOP mf := _r1.f; ms := _r1.s; mr := _r1.r; mt := _r1.t; ma := _r1.a; mw := _r1.w; mu := _r1.u; END LOOP;
PERFORM doom_cs_begin(doom_mp_begin_player.p_map_id,doom_mp_begin_player.p,doom_mp_begin_player.p_skill,_cs.mf,_cs.ms,_cs.mr,_cs.mt,_cs.ma,_cs.mw,_cs.mu);
RETURN 1;
END _cs;
$function$;
