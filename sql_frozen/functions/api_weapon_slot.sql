CREATE OR REPLACE FUNCTION doom.api_weapon_slot(p_slot integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  w integer;
  _r1 record;
BEGIN

w := -1;
FOR _r1 IN SELECT wd.weapon_id AS id
FROM mp_players mp
JOIN player_weapon_owned o ON o.map_id=mp.map_id AND o.player_thing_id=mp.player_thing_id
JOIN weapon_defs wd ON wd.weapon_id=o.weapon_id
JOIN player_weapons pw ON pw.map_id=o.map_id AND pw.player_thing_id=o.player_thing_id
WHERE mp.role_name = doom_caller() AND wd.slot=api_weapon_slot.p_slot
ORDER BY CASE
  WHEN api_weapon_slot.p_slot=1 AND pw.current_weapon=8 AND wd.weapon_id=1 THEN 0
  WHEN api_weapon_slot.p_slot=1 AND pw.current_weapon<>8 AND wd.weapon_id=8 THEN 0
  WHEN wd.weapon_id=pw.current_weapon THEN 2 ELSE 1 END,
  wd.weapon_id DESC
LIMIT 1
LOOP w := _r1.id; END LOOP;
RETURN _cs.w;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_weapon_slot(integer) FROM PUBLIC;
