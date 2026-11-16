CREATE OR REPLACE FUNCTION doom.doom_cs_monster_move(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

-- apply the staged pose
UPDATE things t
SET x = ms.new_x, y = ms.new_y, angle = ms.face_angle
FROM monster_steps ms
WHERE ms.map_id = doom_cs_monster_move.p_map_id AND t.map_id = doom_cs_monster_move.p_map_id AND t.id = ms.thing_id
  AND (ms.new_x <> ms.old_x OR ms.new_y <> ms.old_y);

-- monster-crossable walk-over lines
--  a monster trips only the teleports, the down-wait-up lifts and the plain raise-door, and nothing else.
-- The map's crossable lines with their vertices, once (a handful of index
-- probes); a generic plan hashed every vertex of the map twice instead.
WITH crossable AS MATERIALIZED (
  SELECT ld.map_id, ld.id, ld.cross_once,
         v1.x AS v1x, v1.y AS v1y, v2.x AS v2x, v2.y AS v2y
  FROM linedefs ld
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v1_id OFFSET 0) v1
  CROSS JOIN LATERAL (SELECT v.x, v.y FROM vertexes v
                      WHERE v.map_id=ld.map_id AND v.id=ld.v2_id OFFSET 0) v2
  WHERE ld.map_id = doom_cs_monster_move.p_map_id AND ld.monster_crossable
)
INSERT INTO line_special_events
  (map_id,player_thing_id,line_id,trigger_type,from_front)
SELECT e.map_id,e.thing_id,e.line_id,'cross',e.from_front
FROM (
  SELECT c.map_id, c.thing_id, c.line_id, c.from_front
  FROM (
    SELECT ms.map_id, ms.thing_id, ld.id AS line_id, ld.cross_once,
      ((v2.x-v1.x)::float8*(ms.old_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.old_x-v1.x)::float8) < 0 AS from_front,
      ABS((v2.x-v1.x)::float8*(ms.old_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.old_x-v1.x)::float8) AS old_side,
      ((v2.x-v1.x)::float8*(ms.new_y-v1.y)::float8
        - (v2.y-v1.y)::float8*(ms.new_x-v1.x)::float8) AS new_side,
      ((ms.new_x-ms.old_x)*(v1.y-ms.old_y)::float8
        - (ms.new_y-ms.old_y)*(v1.x-ms.old_x)::float8) AS v1_side,
      ((ms.new_x-ms.old_x)*(v2.y-ms.old_y)::float8
        - (ms.new_y-ms.old_y)*(v2.x-ms.old_x)::float8) AS v2_side
    FROM monster_steps ms
    JOIN crossable ld ON ld.map_id = ms.map_id
    CROSS JOIN LATERAL (SELECT ld.v1x AS x, ld.v1y AS y) v1
    CROSS JOIN LATERAL (SELECT ld.v2x AS x, ld.v2y AS y) v2
    WHERE ms.map_id = doom_cs_monster_move.p_map_id
      AND (ms.new_x <> ms.old_x OR ms.new_y <> ms.old_y)
  ) c
  WHERE c.old_side > 1e-7
    AND c.new_side <> 0
    AND ((c.from_front AND c.new_side > 0)
      OR (NOT c.from_front AND c.new_side < 0))
    AND c.v1_side * c.v2_side < 0
    AND NOT (c.cross_once AND EXISTS (
      SELECT 1 FROM line_activations a
      WHERE a.map_id = c.map_id AND a.line_id = c.line_id))
) e
ON CONFLICT (map_id,player_thing_id,line_id,trigger_type) DO NOTHING;

-- EV_Teleport for a monster
DELETE FROM monster_teleports WHERE map_id=doom_cs_monster_move.p_map_id;

INSERT INTO monster_teleports (map_id,thing_id,dest_x,dest_y,dest_angle,sector_id)
SELECT map_id,thing_id,dest_x,dest_y,dest_angle,sector_id FROM (
  SELECT c.*, ROW_NUMBER() OVER
    (PARTITION BY c.map_id,c.thing_id ORDER BY c.off_centre, c.dest_id) AS rn
  FROM (
    SELECT t.map_id, t.thing_id, t.sector_id,
           th.id AS dest_id, th.x AS dest_x, th.y AS dest_y,
           th.angle AS dest_angle,
           ABS(th.x - (t.min_x+t.max_x)/2.0)
             + ABS(th.y - (t.min_y+t.max_y)/2.0) AS off_centre
    FROM (
      SELECT e.map_id, e.player_thing_id AS thing_id, s.id AS sector_id,
             MIN(rs.x1) AS min_x, MAX(rs.x1) AS max_x,
             MIN(rs.y1) AS min_y, MAX(rs.y1) AS max_y
      FROM line_special_events e
      JOIN linedefs ld ON ld.map_id=e.map_id AND ld.id=e.line_id
      JOIN line_special_defs d ON d.special=ld.special AND d.mechanic='teleport'
      -- Monster-owned events only: the player's id is never in monster_ai.
      JOIN monster_ai ai ON ai.map_id=e.map_id AND ai.thing_id=e.player_thing_id
      JOIN sectors s ON s.map_id=e.map_id AND s.tag=ld.tag
      JOIN render_segs rs ON rs.map_id=s.map_id AND rs.fsec=s.id
      WHERE e.map_id=doom_cs_monster_move.p_map_id AND e.trigger_type='cross'
      GROUP BY e.map_id, e.player_thing_id, s.id
    ) t
    JOIN things th ON th.map_id=t.map_id
    JOIN thing_role_defs tr ON tr.thing_type=th.type AND tr.is_teleport_dest
     AND th.x BETWEEN t.min_x AND t.max_x
     AND th.y BETWEEN t.min_y AND t.max_y
  ) c
) q WHERE rn=1;

-- sfx_telept at the spot left behind and at the one arrived at, as
-- EV_Teleport's two MT_TFOGs do. The fog sprite itself is not modelled.
INSERT INTO sound_events
  (map_id,event_key,level_tic,sound_name,source_thing_id,source_x,source_y)
SELECT mt.map_id,'mon-tele-out:'||mt.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',mt.thing_id,ms.old_x,ms.old_y
FROM monster_teleports mt
JOIN monster_steps ms ON ms.map_id=mt.map_id AND ms.thing_id=mt.thing_id
JOIN player_state ps ON ps.map_id=mt.map_id
 AND ps.player_thing_id=doom_cs_monster_move.p_player_thing_id::int
WHERE mt.map_id=doom_cs_monster_move.p_map_id
UNION ALL
SELECT mt.map_id,'mon-tele-in:'||mt.thing_id::text||':'||ps.level_tics::text,
       ps.level_tics,'DSTELEPT',mt.thing_id,mt.dest_x,mt.dest_y
FROM monster_teleports mt
JOIN player_state ps ON ps.map_id=mt.map_id
 AND ps.player_thing_id=doom_cs_monster_move.p_player_thing_id::int
WHERE mt.map_id=doom_cs_monster_move.p_map_id
ON CONFLICT (map_id,event_key) DO NOTHING;

UPDATE things t
SET x=mt.dest_x, y=mt.dest_y, angle=mt.dest_angle
FROM monster_teleports mt
WHERE t.map_id=doom_cs_monster_move.p_map_id AND mt.map_id=doom_cs_monster_move.p_map_id AND t.id=mt.thing_id;

UPDATE monster_ai ai
SET sector_id=mt.sector_id
FROM monster_teleports mt
WHERE ai.map_id=doom_cs_monster_move.p_map_id AND mt.map_id=doom_cs_monster_move.p_map_id AND ai.thing_id=mt.thing_id
  AND ai.sector_id IS DISTINCT FROM mt.sector_id;
RETURN;
END _cs;
$function$;
