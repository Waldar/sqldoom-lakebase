CREATE OR REPLACE FUNCTION doom.api_weapon_cycle(p_step integer)
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
FOR _r1 IN WITH me AS (
  SELECT mp.map_id, mp.player_thing_id FROM mp_players mp
  WHERE mp.role_name = doom_caller()
),
owned AS (
  SELECT wd.weapon_id,
         ROW_NUMBER() OVER (ORDER BY wd.slot, wd.weapon_id) AS pos,
         COUNT(*) OVER () AS n
  FROM me JOIN player_weapon_owned o ON o.map_id=me.map_id AND o.player_thing_id=me.player_thing_id
  JOIN weapon_defs wd ON wd.weapon_id = o.weapon_id
),
here AS (
  SELECT o.pos, o.n
  FROM owned o JOIN me ON TRUE
  JOIN player_weapons pw ON pw.map_id = me.map_id AND pw.player_thing_id = me.player_thing_id
   AND pw.current_weapon = o.weapon_id
)
SELECT o.weapon_id AS id
FROM owned o CROSS JOIN here h
WHERE o.pos = ((h.pos - 1 + api_weapon_cycle.p_step + h.n) % h.n) + 1
LOOP w := _r1.id; END LOOP;
RETURN _cs.w;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_weapon_cycle(integer) FROM PUBLIC;
