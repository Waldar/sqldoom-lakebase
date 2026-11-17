CREATE OR REPLACE FUNCTION doom.doom_sector_at(p_map_id integer, p_x double precision, p_y double precision)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  sector integer;
  _r1 record;
BEGIN

sector := NULL::int;
FOR _r1 IN WITH RECURSIVE bsp AS (
  -- The root is the highest-numbered node
  (SELECT 1 AS depth, n.id AS node_id, NULL::int AS ssector_id
   FROM nodes n WHERE n.map_id = doom_sector_at.p_map_id
   ORDER BY n.id DESC LIMIT 1)
  UNION ALL
  SELECT w.depth + 1, c.node_id, c.ssector_id
  FROM bsp w
  CROSS JOIN LATERAL (
    SELECT CASE WHEN nc.child_kind = 'NODE' THEN nc.child_node_id END AS node_id,
           CASE WHEN nc.child_kind = 'SSECTOR' THEN nc.child_ssector_id END AS ssector_id
    FROM nodes n
    JOIN node_children nc ON nc.map_id = n.map_id AND nc.node_id = n.id
     AND nc.side = CASE
       WHEN (doom_sector_at.p_x - n.x) * n.dy::float8 - (doom_sector_at.p_y - n.y) * n.dx::float8 > 0
       THEN 'R' ELSE 'L' END
    WHERE n.map_id = doom_sector_at.p_map_id AND n.id = w.node_id
  ) c
  WHERE w.node_id IS NOT NULL
)
SELECT (SELECT rs.fsec FROM render_segs rs
        WHERE rs.map_id = doom_sector_at.p_map_id AND rs.ssector_id = b.ssector_id
        ORDER BY rs.seg_id LIMIT 1) AS f
FROM bsp b
WHERE b.ssector_id IS NOT NULL
LIMIT 1
LOOP sector := _r1.f; END LOOP;
RETURN _cs.sector;
END _cs;
$function$;
