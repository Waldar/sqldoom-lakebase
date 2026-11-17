CREATE OR REPLACE FUNCTION doom.doom_mp_apply_mode()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE p text; cur_mode text; new_mode text;
BEGIN
  SELECT pending, mode INTO p, cur_mode FROM mp_match LIMIT 1;
  IF p IS NULL THEN
    RETURN 0;
  END IF;
  new_mode := CASE WHEN p IN ('deathmatch', 'stay') THEN 'deathmatch'
                   WHEN p IN ('final', 'solo') THEN 'solo'
                   ELSE cur_mode END;               -- 'restart', 'rules'
  UPDATE mp_match m SET mode = new_mode, pending = NULL, monsters = r.monsters, skill = r.skill
  FROM mp_rules r WHERE r.mode = new_mode;
  PERFORM doom_mp_rules_live();
  PERFORM doom_mp_world_flags(new_mode = 'deathmatch');
  RETURN 1;
END $function$;
