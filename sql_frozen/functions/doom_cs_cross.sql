CREATE OR REPLACE FUNCTION doom.doom_cs_cross(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- Queue every player-crossable special linedef traversed by this tic's
-- accepted movement.
WITH
params AS NOT MATERIALIZED (
  SELECT ps.map_id,ps.player_thing_id,
         ps.previous_x::float8 AS ox,ps.previous_y::float8 AS oy,
         ps.position_x::float8 AS nx,ps.position_y::float8 AS ny
  FROM player_state ps
  WHERE ps.map_id=doom_cs_cross.p_map_id::int AND ps.player_thing_id=doom_cs_cross.p_player_thing_id::int
),
crossed AS (
  SELECT ld.id AS line_id, ld.special, ld.cross_once,
    ((v2.x-v1.x)::float8*(p.oy-v1.y)::float8
      - (v2.y-v1.y)::float8*(p.ox-v1.x)::float8) < 0 AS from_front,
    ABS((v2.x-v1.x)::float8*(p.oy-v1.y)::float8
      - (v2.y-v1.y)::float8*(p.ox-v1.x)::float8) AS old_side,
    ((v2.x-v1.x)::float8*(p.ny-v1.y)::float8
      - (v2.y-v1.y)::float8*(p.nx-v1.x)::float8) AS new_side,
    ((p.nx-p.ox)*(v1.y-p.oy)::float8 - (p.ny-p.oy)*(v1.x-p.ox)::float8)
      AS v1_side,
    ((p.nx-p.ox)*(v2.y-p.oy)::float8 - (p.ny-p.oy)*(v2.x-p.ox)::float8)
      AS v2_side
  FROM params p
  JOIN linedefs ld ON ld.map_id=p.map_id
  -- One index probe per crossable line (a handful); a generic plan hashed
  -- every vertex of the map twice instead. OFFSET 0 keeps the probes.
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v1_id OFFSET 0) v1
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v2_id OFFSET 0) v2
  WHERE ld.cross_activated
),
eligible AS (
  SELECT c.* FROM crossed c CROSS JOIN params p
  WHERE c.old_side > 1e-7
    AND c.new_side <> 0
    AND ((c.from_front AND c.new_side > 0)
      OR (NOT c.from_front AND c.new_side < 0))
    -- The step must actually reach the segment, not merely its extension.
    AND c.v1_side * c.v2_side < 0
    AND NOT (
      -- W1 rather than WR: fires once and then stays activated.
      c.cross_once
      AND EXISTS (
        SELECT 1 FROM line_activations a
        WHERE a.map_id=p.map_id AND a.line_id=c.line_id
      )
    )
)
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT p.map_id,p.player_thing_id,e.line_id,'cross',e.from_front
FROM eligible e CROSS JOIN params p
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;
RETURN;
END _cs;
$function$;
