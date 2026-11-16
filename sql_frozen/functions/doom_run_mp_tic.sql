CREATE OR REPLACE FUNCTION doom.doom_run_mp_tic(p_map_id integer, p_skill integer, p1 integer, p2 integer, p3 integer, p4 integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SET plan_cache_mode TO 'force_generic_plan'
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  upto bigint;
  _r1 record;
BEGIN

-- Consume every input row that exists now; rows a client appends during the
-- tic are next tic's.
upto := 0::bigint;
FOR _r1 IN SELECT COALESCE(MAX(seq),0)::bigint AS m FROM mp_inputs WHERE map_id=doom_run_mp_tic.p_map_id
LOOP upto := _r1.m; END LOOP;
PERFORM doom_mp_spawn_if_requested(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p1);
IF doom_run_mp_tic.p2 IS NOT NULL THEN PERFORM doom_mp_spawn_if_requested(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p2); END IF;
IF doom_run_mp_tic.p3 IS NOT NULL THEN PERFORM doom_mp_spawn_if_requested(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p3); END IF;
IF doom_run_mp_tic.p4 IS NOT NULL THEN PERFORM doom_mp_spawn_if_requested(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p4); END IF;
PERFORM doom_mp_begin_player(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p_skill,doom_run_mp_tic.p1,_cs.upto);
IF doom_run_mp_tic.p2 IS NOT NULL THEN PERFORM doom_mp_begin_player(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p_skill,doom_run_mp_tic.p2,_cs.upto); END IF;
IF doom_run_mp_tic.p3 IS NOT NULL THEN PERFORM doom_mp_begin_player(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p_skill,doom_run_mp_tic.p3,_cs.upto); END IF;
IF doom_run_mp_tic.p4 IS NOT NULL THEN PERFORM doom_mp_begin_player(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p_skill,doom_run_mp_tic.p4,_cs.upto); END IF;
DELETE FROM mp_inputs WHERE map_id=doom_run_mp_tic.p_map_id AND seq <= _cs.upto;
PERFORM doom_run_tic_core(doom_run_mp_tic.p_map_id,doom_run_mp_tic.p_skill,doom_run_mp_tic.p1,doom_run_mp_tic.p2,doom_run_mp_tic.p3,doom_run_mp_tic.p4);
-- TRUE when this tic ended the level: the referee then runs the intermission
-- and moves the match on (doom_mp_rotate).
RETURN doom_mp_level_done(doom_run_mp_tic.p_map_id);
END _cs;
$function$;
