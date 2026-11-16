CREATE OR REPLACE FUNCTION doom.doom_cs_monster_blast(p_map_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- P_DamageMobj's thrust
-- The last thing P_DamageMobj does is shove the target away from whatever hurt
-- it: `thrust = damage*(FRACUNIT>>3)*100/mass`, which is damage*12.5/mass map
-- units a tic, along the angle from the inflictor to the target. It is what
-- makes one barrel throw the next -- and, through the same statement, what
-- makes a rocket knock a trooper back.
WITH
params AS NOT MATERIALIZED (SELECT doom_cs_monster_blast.p_map_id::int AS map_id),
explosions AS (
  SELECT i.projectile_id, mp.owner_thing_id AS source_id,
         i.x::double precision AS ex, i.y::double precision AS ey
  FROM projectile_impacts i
  JOIN monster_projectiles mp ON mp.map_id=i.map_id
   AND mp.projectile_id=i.projectile_id
  JOIN params p ON i.map_id=p.map_id
  WHERE i.projectile_type='rocket'
  UNION ALL
  SELECT -ai.thing_id, ai.thing_id, t.x::double precision, t.y::double precision
  FROM monster_ai ai
  JOIN params p ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
  WHERE ai.fired_this_tick
),
shoved AS (
  SELECT v.id AS thing_id,
         SUM(ROUND(GREATEST(0,128-FLOOR(d.dist)::int) * 12.5
             / GREATEST(1,cd.mass) * d.dx / NULLIF(d.dist,0) * 65536.0)) / 65536.0 AS push_x,
         SUM(ROUND(GREATEST(0,128-FLOOR(d.dist)::int) * 12.5
             / GREATEST(1,cd.mass) * d.dy / NULLIF(d.dist,0) * 65536.0)) / 65536.0 AS push_y
  FROM explosions e
  JOIN things v ON v.map_id=doom_cs_monster_blast.p_map_id::int
  JOIN thing_combat_defs cd ON cd.thing_type=v.type
  CROSS JOIN LATERAL (
    SELECT v.x-e.ex AS dx, v.y-e.ey AS dy,
           SQRT(POWER(v.x-e.ex,2)+POWER(v.y-e.ey,2)) AS dist
  ) d
  WHERE v.id<>e.source_id AND d.dist<128.0 AND d.dist>0.0
  GROUP BY v.id
)
UPDATE things t
SET mom_x = (t.mom_x + s.push_x)::real,
    mom_y = (t.mom_y + s.push_y)::real
FROM shoved s
WHERE t.map_id=doom_cs_monster_blast.p_map_id::int AND t.id=s.thing_id;
RETURN;
END _cs;
$function$;
