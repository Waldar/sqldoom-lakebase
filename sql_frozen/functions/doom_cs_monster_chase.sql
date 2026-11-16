CREATE OR REPLACE FUNCTION doom.doom_cs_monster_chase(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- a blocked monster opens the door
-- P_Move, when its step fails, retries the lines it hit as use-specials, and
-- P_UseSpecialLine lets a monster through exactly four door types (1, 32, 33,
-- 34 -- key doors included, since the key check is skipped for anything that
-- is not a player). ML_SECRET lines are never opened.
-- Chasers and monster-usable lines first, then their pairs: the generic plan
-- of the one-join form tested every door line against every Thing on the map.
WITH chasers AS MATERIALIZED (
  SELECT ai.map_id, ai.thing_id, t.x, t.y, cd.radius, pt.x AS px, pt.y AS py
  FROM monster_ai ai
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_combat_defs cd ON cd.thing_type = t.type
  JOIN things pt ON pt.map_id = ai.map_id AND pt.id = doom_cs_monster_chase.p_player_thing_id::int
  WHERE ai.map_id = doom_cs_monster_chase.p_map_id::int
    AND ai.state = 'see'
    AND NOT cd.explodes
),
door_lines AS MATERIALIZED (
  SELECT ld.map_id, ld.linedef_id, ld.x1, ld.y1, ld.x2, ld.y2, ld.left_sd_id
  FROM linedef_geom ld
  WHERE ld.map_id = doom_cs_monster_chase.p_map_id::int
    AND (ld.flags & 32) = 0
    AND ld.special = ANY (ARRAY(SELECT d.special FROM line_special_defs d WHERE d.monster_usable))
)
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT DISTINCT doom_cs_monster_chase.p_map_id::int, t.thing_id, ld.linedef_id, 'use', TRUE
FROM chasers t
JOIN door_lines ld ON ld.map_id = t.map_id
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(t.px - t.x, 2) + POWER(t.py - t.y, 2))::double precision AS dist
) toward
CROSS JOIN LATERAL (
  SELECT t.x + 8.0 * (t.px - t.x) / NULLIF(toward.dist, 0) AS sx,
         t.y + 8.0 * (t.py - t.y) / NULLIF(toward.dist, 0) AS sy
) step
CROSS JOIN LATERAL (
  SELECT LEAST(1.0, GREATEST(0.0,
    ((step.sx - ld.x1) * (ld.x2 - ld.x1) + (step.sy - ld.y1) * (ld.y2 - ld.y1))
    / NULLIF(POWER(ld.x2 - ld.x1, 2) + POWER(ld.y2 - ld.y1, 2), 0.0))) AS u
) proj
CROSS JOIN LATERAL (
  SELECT SQRT(POWER(step.sx - (ld.x1 + proj.u * (ld.x2 - ld.x1)), 2)
            + POWER(step.sy - (ld.y1 + proj.u * (ld.y2 - ld.y1)), 2)) AS gap
) near
LEFT JOIN sidedefs back ON back.map_id = ld.map_id AND back.id = ld.left_sd_id
LEFT JOIN sector_movers sm ON sm.map_id = ld.map_id
  AND sm.sector_id = back.sector_id AND sm.direction <> -1
WHERE near.gap < t.radius
  AND sm.sector_id IS NULL
  -- Necessary condition, exact: a line within cd.radius of the step point (8 units from the
  -- monster) has its box within cd.radius + 8 of the monster. Lets the GiST index pick the lines.
  AND box(point(ld.x1::double precision, ld.y1::double precision),
          point(ld.x2::double precision, ld.y2::double precision))
      && box(point(t.x - t.radius - 9.0, t.y - t.radius - 9.0),
             point(t.x + t.radius + 9.0, t.y + t.radius + 9.0))
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;

-- live sector for monsters now in 'see'
WITH RECURSIVE
params AS NOT MATERIALIZED (SELECT doom_cs_monster_chase.p_map_id::int AS map_id),
movers AS (
  -- A monster's sector can only change on a tic it stepped, so only those
  -- descend the BSP again -- plus any chaser that has never been placed.
  -- Descending for every chaser was ~3/4 of this statement.
  SELECT ai.thing_id, t.x::double precision AS mx, t.y::double precision AS my
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  WHERE ai.state = 'see'
    AND (ai.sector_id IS NULL
         OR EXISTS (SELECT 1 FROM monster_steps ms
                    WHERE ms.map_id = ai.map_id AND ms.thing_id = ai.thing_id))
),
bsp AS (
  SELECT m.thing_id, 1 AS depth, n.id AS node_id, NULL::int AS ssec_id
  FROM movers m
  CROSS JOIN LATERAL (
    SELECT n.id FROM nodes n JOIN params p ON n.map_id = p.map_id
    ORDER BY n.id DESC LIMIT 1
  ) n
  UNION ALL
  SELECT w.thing_id, w.depth + 1, c.node_id, c.ssec_id
  FROM bsp w
  JOIN movers m ON m.thing_id = w.thing_id
  CROSS JOIN LATERAL (
    SELECT CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END AS node_id,
           CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END AS ssec_id
    FROM nodes n
    JOIN node_children nc ON nc.map_id = n.map_id AND nc.node_id = n.id
     AND nc.side = CASE
       WHEN (m.mx - n.x)::float8 * n.dy::float8
            - (m.my - n.y)::float8 * n.dx::float8 > 0
       THEN 'R' ELSE 'L' END
    WHERE n.map_id = doom_cs_monster_chase.p_map_id::int AND n.id = w.node_id
  ) c
  WHERE w.node_id IS NOT NULL
),
subsector AS (
  SELECT thing_id, ssec_id FROM (
    SELECT thing_id, ssec_id, ROW_NUMBER() OVER
      (PARTITION BY thing_id ORDER BY depth, ssec_id) AS rn
    FROM bsp WHERE ssec_id IS NOT NULL
  ) r WHERE rn = 1
),
sector_of AS (
  SELECT ss.thing_id, s.id AS sector_id,
    ROW_NUMBER() OVER (PARTITION BY ss.thing_id ORDER BY seg.id) AS rn
  FROM subsector ss
  JOIN params p ON TRUE
  JOIN ssectors sst ON sst.map_id = p.map_id AND sst.id = ss.ssec_id
  JOIN segs seg ON seg.map_id = p.map_id
    AND seg.id >= sst.first_seg_id AND seg.id < sst.first_seg_id + sst.seg_count
  JOIN linedefs ld ON ld.map_id = p.map_id AND ld.id = seg.linedef_id
  JOIN sidedefs sd ON sd.map_id = p.map_id
    AND sd.id = CASE WHEN seg.direction = 0 THEN ld.right_sd_id ELSE ld.left_sd_id END
  JOIN sectors s ON s.map_id = p.map_id AND s.id = sd.sector_id
)
UPDATE monster_ai ai
SET sector_id = so.sector_id
FROM sector_of so
WHERE so.rn = 1 AND ai.map_id = doom_cs_monster_chase.p_map_id AND ai.thing_id = so.thing_id
  -- A monster that did not move is still in the sector it was in
  AND ai.sector_id IS DISTINCT FROM so.sector_id;

-- keep the render cache's sector in step
UPDATE render_things rt
SET sector_id = ai.sector_id
FROM monster_ai ai
WHERE rt.map_id = doom_cs_monster_chase.p_map_id AND ai.map_id = doom_cs_monster_chase.p_map_id
  AND ai.thing_id = rt.thing_id
  AND ai.sector_id IS NOT NULL
  AND rt.sector_id <> ai.sector_id;
RETURN;
END _cs;
$function$;
