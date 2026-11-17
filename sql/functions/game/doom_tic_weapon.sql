CREATE OR REPLACE FUNCTION doom.doom_tic_weapon(p_map_id integer, p integer, p_plan bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  out bigint;
  shot_serial bigint;
  impacts integer;
BEGIN

out := doom_tic_weapon.p_plan;
IF (doom_tic_weapon.p_plan & 16) <> 0 THEN
  shot_serial := doom_cs_weapon(doom_tic_weapon.p_map_id,doom_tic_weapon.p);
  out := doom_cs_plan(doom_tic_weapon.p_map_id,doom_tic_weapon.p);
  IF (_cs.out & 32) <> 0 THEN
    impacts := doom_cs_hitscan_fire(doom_tic_weapon.p_map_id,doom_tic_weapon.p);
    IF _cs.impacts >= 0 THEN PERFORM doom_cs_hitscan_apply(doom_tic_weapon.p_map_id,doom_tic_weapon.p,_cs.shot_serial); END IF;
  END IF;
END IF;
RETURN _cs.out;
END _cs;
$function$;
