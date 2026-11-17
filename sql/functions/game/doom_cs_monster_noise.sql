CREATE OR REPLACE FUNCTION doom.doom_cs_monster_noise(p_map_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

WITH RECURSIVE
noise_origin AS (
  SELECT ps.sector_id
  FROM player_state ps
  JOIN player_weapons pw ON pw.map_id = ps.map_id
   AND pw.player_thing_id = ps.player_thing_id
  WHERE ps.map_id = doom_cs_monster_noise.p_map_id::int
    AND ps.alive AND pw.fired_this_tick AND ps.sector_id IS NOT NULL
),
sound_edges AS MATERIALIZED (
  SELECT ld.fsec AS a, ld.bsec AS b,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END AS block
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = doom_cs_monster_noise.p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
  UNION ALL
  SELECT ld.bsec, ld.fsec,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = doom_cs_monster_noise.p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
),
flood AS (
  SELECT sector_id, 0 AS block FROM noise_origin
  UNION
  SELECT e.b, f.block + e.block
  FROM flood f JOIN sound_edges e ON e.a = f.sector_id
  WHERE f.block + e.block <= 1
)
UPDATE monster_ai ai
SET state = 'see', seq_index = 0, state_tics = 0
FROM things t, render_things rt, flood fl
WHERE ai.map_id = doom_cs_monster_noise.p_map_id::int
  AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
  AND ai.state = 'stand'
  AND NOT EXISTS (SELECT 1 FROM thing_combat_defs cd
                  WHERE cd.thing_type = t.type AND cd.explodes)
  AND COALESCE(ai.sector_id, rt.sector_id) = fl.sector_id;
RETURN;
END _cs;
$function$;
