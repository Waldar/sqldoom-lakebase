CREATE OR REPLACE FUNCTION doom.doom_cs_monster_barrel(p_map_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- exploding-barrel radius damage
WITH
params AS NOT MATERIALIZED (SELECT doom_cs_monster_barrel.p_map_id::int AS map_id),
explosions AS (
  SELECT t.id AS source_id, t.x::double precision AS ex,
         t.y::double precision AS ey
  FROM monster_ai ai
  JOIN params p ON ai.map_id=p.map_id
  JOIN things t ON t.map_id=ai.map_id AND t.id=ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type=t.type AND cd.explodes
  WHERE ai.fired_this_tick
),
blast AS (SELECT MAX(blast_radius) AS r FROM thing_combat_defs WHERE explodes),
victims AS (
  SELECT DISTINCT h.map_id,h.thing_id,
         t.x::double precision AS vx,t.y::double precision AS vy
  FROM explosions e
  JOIN params p ON TRUE
  CROSS JOIN blast bl
  JOIN things t ON t.map_id=p.map_id
    AND t.x BETWEEN e.ex-bl.r AND e.ex+bl.r
    AND t.y BETWEEN e.ey-bl.r AND e.ey+bl.r
  JOIN thing_health h ON h.map_id=t.map_id AND h.thing_id=t.id AND h.alive
),
blocking_walls AS (
  SELECT DISTINCT ld.x1::double precision AS x1,ld.y1::double precision AS y1,
         ld.x2::double precision AS x2,ld.y2::double precision AS y2
  FROM explosions e
  JOIN params p ON TRUE
  CROSS JOIN blast bl
  JOIN linedef_geom ld ON ld.map_id=p.map_id
  LEFT JOIN sectors fr ON fr.map_id=ld.map_id AND fr.id=ld.fsec
  LEFT JOIN sectors bk ON bk.map_id=ld.map_id AND bk.id=ld.bsec
  WHERE (ld.left_sd_id=-1 OR ld.right_sd_id=-1
     OR fr.id IS NULL OR bk.id IS NULL
     OR LEAST(fr.ceil_height,bk.ceil_height)
          <= GREATEST(fr.floor_height,bk.floor_height))
    -- Both endpoints of any blocked sight line lie within 128 of the blast,
    -- so a wall that can block one has to reach into this box.
    AND LEAST(ld.x1,ld.x2) <= e.ex+bl.r
    AND GREATEST(ld.x1,ld.x2) >= e.ex-bl.r
    AND LEAST(ld.y1,ld.y2) <= e.ey+bl.r
    AND GREATEST(ld.y1,ld.y2) >= e.ey-bl.r
),
radial AS (
  SELECT v.map_id,v.thing_id,
         SUM(GREATEST(0,bl.r-FLOOR(d.dist)::int)::int)::int AS damage
  FROM explosions e CROSS JOIN victims v CROSS JOIN blast bl
  CROSS JOIN LATERAL (
    SELECT SQRT(POWER(v.vx-e.ex,2)+POWER(v.vy-e.ey,2)) AS dist
  ) d
  WHERE v.thing_id<>e.source_id AND d.dist<bl.r
    AND NOT EXISTS (
      SELECT 1 FROM blocking_walls b
      CROSS JOIN LATERAL (
        SELECT
          (e.ex-b.x1)*(b.y2-b.y1)-(e.ey-b.y1)*(b.x2-b.x1) AS d1,
          (v.vx-b.x1)*(b.y2-b.y1)-(v.vy-b.y1)*(b.x2-b.x1) AS d2,
          (b.x1-e.ex)*(v.vy-e.ey)-(b.y1-e.ey)*(v.vx-e.ex) AS d3,
          (b.x2-e.ex)*(v.vy-e.ey)-(b.y2-e.ey)*(v.vx-e.ex) AS d4
      ) sides
      WHERE sides.d1*sides.d2<0 AND sides.d3*sides.d4<0
    )
  GROUP BY v.map_id,v.thing_id
)
UPDATE thing_health h
SET health=h.health-r.damage,alive=h.health-r.damage>0
FROM radial r
WHERE h.map_id=r.map_id AND h.thing_id=r.thing_id;
RETURN;
END _cs;
$function$;
