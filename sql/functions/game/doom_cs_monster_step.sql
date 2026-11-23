CREATE OR REPLACE FUNCTION doom.doom_cs_monster_step(p_map_id integer, p_player_thing_id integer)
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  blockmap_cell double precision;
  min_walk_opening double precision;
  max_step double precision;
  player_radius double precision;
  monster_step double precision;
  chase_deadband double precision;
  chase_swap_chance double precision;
  chase_movecount_mask double precision;
  stepped boolean;
  _r1 record;
BEGIN

-- 8 constants in one scan (was 8 doom_const() calls)
SELECT
       COALESCE(max(value) FILTER (WHERE name = 'BLOCKMAP_CELL'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'MIN_WALK_OPENING'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'MAXSTEP'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'PLAYER_RADIUS'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'MONSTER_STEP'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'CHASE_AXIS_DEADBAND'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'CHASE_SWAP_CHANCE'), 0),
       COALESCE(max(value) FILTER (WHERE name = 'CHASE_MOVECOUNT_MASK'), 0)
  INTO blockmap_cell, min_walk_opening, max_step, player_radius, monster_step, chase_deadband, chase_swap_chance, chase_movecount_mask
  FROM doom_constants WHERE name IN ('BLOCKMAP_CELL', 'CHASE_AXIS_DEADBAND', 'CHASE_MOVECOUNT_MASK', 'CHASE_SWAP_CHANCE', 'MAXSTEP', 'MIN_WALK_OPENING', 'MONSTER_STEP', 'PLAYER_RADIUS');

WITH
params AS NOT MATERIALIZED (SELECT doom_cs_monster_step.p_map_id::int AS map_id, doom_cs_monster_step.p_player_thing_id::int AS player_thing_id),
player_pos AS (
  SELECT pp.px, pp.py
  FROM doom_player_pos pp JOIN params p ON pp.map_id = p.map_id
   AND pp.player_thing_id = p.player_thing_id
),
-- MF_SHADOW on the target, which for the player means the blur sphere.
shadow AS (
  SELECT sh.shadowed, sh.level_tics
  FROM doom_player_shadow sh JOIN params p ON sh.map_id = p.map_id
   AND sh.player_thing_id = p.player_thing_id
),
chasers AS (
  SELECT ai.thing_id, t.x::double precision AS mx, t.y::double precision AS my,
         d.radius::double precision AS radius,
         d.floats, ai.movedir, ai.movecount,
         COALESCE(mc.speed, _cs.monster_step)::double precision AS speed
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  JOIN things t ON t.map_id = ai.map_id AND t.id = ai.thing_id
  JOIN thing_combat_defs d ON d.thing_type = t.type
  LEFT JOIN monster_chase_defs mc ON mc.thing_type = t.type
  JOIN thing_ai_frames f ON f.thing_type=t.type AND f.state='see'
    AND f.seq_index=ai.seq_index
  -- A_Chase at the frame's start, and again half-way through the frames that
  -- stand for two of Doom's run states (monster_chase_defs.calls_per_frame)
  WHERE ai.state='see' AND NOT d.explodes
    AND (ai.state_tics=f.tics
      OR (COALESCE(mc.calls_per_frame, 2) = 2 AND ai.state_tics=FLOOR(f.tics/2.0)::int))
),
mon_target AS MATERIALIZED (
  SELECT ai.thing_id,
         COALESCE(tt.x::double precision, pp.px) AS tx,
         COALESCE(tt.y::double precision, pp.py) AS ty,
         ai.target_thing_id
  FROM monster_ai ai
  JOIN params p ON ai.map_id = p.map_id
  CROSS JOIN player_pos pp
  LEFT JOIN (SELECT map_id, thing_id FROM thing_health WHERE alive
             UNION ALL SELECT map_id, player_thing_id FROM player_state WHERE alive) th
    ON th.map_id = ai.map_id AND th.thing_id = ai.target_thing_id
  LEFT JOIN things tt ON tt.map_id = ai.map_id AND tt.id = th.thing_id
),
walk AS (
  SELECT c.thing_id, c.mx, c.my, c.radius, c.floats, c.movedir, c.movecount, c.speed,
         old.opposite AS turnaround,
         CASE WHEN mt.tx - c.mx >  _cs.chase_deadband THEN 0
              WHEN mt.tx - c.mx < -_cs.chase_deadband THEN 4 END AS dx_dir,
         CASE WHEN mt.ty - c.my < -_cs.chase_deadband THEN 6
              WHEN mt.ty - c.my >  _cs.chase_deadband THEN 2 END AS dy_dir,
         diag.dir AS diag,
         (doom_prandom(c.thing_id, sh.level_tics, 50) > _cs.chase_swap_chance
          OR ABS(mt.ty - c.my) > ABS(mt.tx - c.mx)) AS swap,
         (doom_prandom(c.thing_id, sh.level_tics, 51) & 1) = 1 AS sweep_up,
         (doom_prandom(c.thing_id, sh.level_tics, 52) & _cs.chase_movecount_mask::int)
           AS fresh_movecount,
         (c.movecount > 0 AND c.movedir IS NOT NULL) AS keep_going
  FROM chasers c
  JOIN mon_target mt ON mt.thing_id = c.thing_id
  CROSS JOIN shadow sh
  LEFT JOIN chase_dir_defs old ON old.dir = c.movedir
  JOIN chase_dir_defs diag ON diag.is_diagonal
   AND (diag.dx > 0) = (mt.tx - c.mx > 0)
   AND (diag.dy > 0) = (mt.ty - c.my >= 0)
),
-- P_NewChaseDir tries directions in a fixed order and takes the first that works.
ranked AS (
  SELECT w.thing_id, d.dir,
    LEAST(
      CASE WHEN w.keep_going AND d.dir = w.movedir THEN -1 ELSE 99 END,
      CASE WHEN w.dx_dir IS NOT NULL AND w.dy_dir IS NOT NULL AND d.dir = w.diag
            AND w.diag IS DISTINCT FROM w.turnaround THEN 0 ELSE 99 END,
      CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dy_dir ELSE w.dx_dir END)
            AND d.dir IS DISTINCT FROM w.turnaround THEN 1 ELSE 99 END,
      CASE WHEN d.dir = (CASE WHEN w.swap THEN w.dx_dir ELSE w.dy_dir END)
            AND d.dir IS DISTINCT FROM w.turnaround THEN 2 ELSE 99 END,
      CASE WHEN d.dir = w.movedir THEN 3 ELSE 99 END,
      CASE WHEN d.dir IS DISTINCT FROM w.turnaround
           THEN 4 + CASE WHEN w.sweep_up THEN d.dir ELSE last.dir - d.dir END
           ELSE 99 END,
      CASE WHEN d.dir = w.turnaround THEN 12 ELSE 99 END
    ) AS pri
  FROM walk w CROSS JOIN chase_dir_defs d
  CROSS JOIN (SELECT MAX(dir) AS dir FROM chase_dir_defs) last
),
desired AS (
  SELECT r.pri, w.thing_id, w.mx, w.my, w.radius, w.floats,
         -- one A_Chase stride: mobjinfo's speed (monster_chase_defs, 2026-11-24)
         w.mx + w.speed * d.dx AS nx, w.my + w.speed * d.dy AS ny,
         d.angle AS face_angle, d.dir,
         CASE WHEN r.pri = -1 THEN w.movecount - 1
              ELSE w.fresh_movecount END AS next_movecount
  FROM ranked r
  JOIN walk w ON w.thing_id = r.thing_id
  JOIN chase_dir_defs d ON d.dir = r.dir
  WHERE r.pri < 99
),
blocking AS (
  SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
         ld.x2::double precision AS x2, ld.y2::double precision AS y2,
         -- blocked only by the 24-unit step rule: no wall for a floater
         (NOT (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0)
          AND NOT (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
                   AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                   AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < _cs.min_walk_opening))
           AS floor_step_only
  FROM linedef_geom ld
  JOIN params p ON ld.map_id = p.map_id
  LEFT JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  LEFT JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.left_sd_id = -1 OR ld.right_sd_id = -1
     OR (ld.flags & 1) <> 0
     OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND ABS(sb.floor_height - sf.floor_height) > _cs.max_step)
     OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
         AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
         AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < _cs.min_walk_opening)
),
-- PIT_CheckThing for monsters. Everything solid blocks everything else, so a
-- monster is stopped by another monster, by a barrel, by a solid decoration
-- and by the player
solid_things AS (
  SELECT tt.id AS thing_id, tt.x::double precision AS tx,
         tt.y::double precision AS ty, cd.radius::double precision AS radius,
         FLOOR(tt.x / _cs.blockmap_cell)::int AS cellx,
         FLOOR(tt.y / _cs.blockmap_cell)::int AS celly
  FROM things tt
  JOIN params p ON tt.map_id = p.map_id
  JOIN thing_combat_defs cd ON cd.thing_type = tt.type
  JOIN thing_health hh ON hh.map_id = tt.map_id AND hh.thing_id = tt.id
   AND hh.alive
  UNION ALL
  -- Solid decorations
  SELECT tt.id, tt.x::double precision, tt.y::double precision,
         bd.radius::double precision,
         FLOOR(tt.x / _cs.blockmap_cell)::int, FLOOR(tt.y / _cs.blockmap_cell)::int
  FROM things tt
  JOIN params p ON tt.map_id = p.map_id
  JOIN thing_blocking_defs bd ON bd.thing_type = tt.type
  JOIN game_tic_commands g ON g.map_id = tt.map_id
   AND g.player_thing_id = p.player_thing_id
  WHERE (tt.flags & g.skill_bit) <> 0 AND (tt.flags & 16) = 0
  UNION ALL
  -- Every live player
  SELECT ps.player_thing_id, t.x::double precision, t.y::double precision, _cs.player_radius,
         FLOOR(t.x / _cs.blockmap_cell)::int, FLOOR(t.y / _cs.blockmap_cell)::int
  FROM player_state ps
  JOIN params p ON ps.map_id = p.map_id
  JOIN things t ON t.map_id = ps.map_id AND t.id = ps.player_thing_id
  WHERE ps.alive
),
candidates AS (
  SELECT d.pri, d.thing_id, d.nx AS cx, d.ny AS cy,
         d.mx AS old_x, d.my AS old_y, d.radius, d.face_angle, d.floats,
         d.dir, d.next_movecount
  FROM desired d
),
thing_hit AS MATERIALIZED (
  SELECT c.pri, c.thing_id, TRUE AS hit
  FROM candidates c
  -- The 3x3 block of cells around the candidate: the largest radius sum in
  -- play is well under a cell, so a neighbour cell is as far as an overlap
  -- can reach.
  CROSS JOIN (SELECT generate_series(-1,1) AS d) gx
  CROSS JOIN (SELECT generate_series(-1,1) AS d) gy
  JOIN solid_things st
    ON st.cellx = FLOOR(c.cx / _cs.blockmap_cell)::int + gx.d
   AND st.celly = FLOOR(c.cy / _cs.blockmap_cell)::int + gy.d
   AND st.thing_id <> c.thing_id
   AND ABS(st.tx - c.cx) < st.radius + c.radius
   AND ABS(st.ty - c.cy) < st.radius + c.radius
  GROUP BY c.pri, c.thing_id
),
wall_block AS MATERIALIZED (
  -- Candidates against the walls whose box overlaps the step, aggregated to
  -- one verdict per candidate.
  -- Spatial: probe the GiST index on linedef_geom (map_id, box) with each
  -- candidate's step box, then apply the live blocking rule (sector heights)
  -- only to the few walls found, instead of testing every blocking wall of
  -- the map against every candidate.
  -- A step that would bring the body onto a blocking line is refused, as
  -- PIT_CheckLine refuses it; one that takes a monster already touching a line
  -- (a door that closed on its edge, a lift that dropped beside it) further
  -- from it is not, or that monster would never move again (2026-11-24).
  SELECT c.pri, c.thing_id,
         BOOL_OR((dd.dist < c.radius AND dd.dist <= dd0.dist) OR xing.intersects) AS blocked
  FROM candidates c
  CROSS JOIN params p
  JOIN linedef_geom ld
    ON ld.map_id = p.map_id
   AND box(point(ld.x1::double precision, ld.y1::double precision),
           point(ld.x2::double precision, ld.y2::double precision))
       && box(point(LEAST(c.cx, c.old_x) - c.radius - 2.0, LEAST(c.cy, c.old_y) - c.radius - 2.0),
              point(GREATEST(c.cx, c.old_x) + c.radius + 2.0, GREATEST(c.cy, c.old_y) + c.radius + 2.0))
  LEFT JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  LEFT JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  CROSS JOIN LATERAL (
    SELECT ld.x1::double precision AS x1, ld.y1::double precision AS y1,
           ld.x2::double precision AS x2, ld.y2::double precision AS y2,
           (ld.left_sd_id = -1 OR ld.right_sd_id = -1
            OR (ld.flags & 1) <> 0
            OR (sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                AND ABS(sb.floor_height - sf.floor_height) > _cs.max_step)
            OR (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
                AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < _cs.min_walk_opening)) AS is_blocking,
           (NOT (ld.left_sd_id = -1 OR ld.right_sd_id = -1 OR (ld.flags & 1) <> 0)
            AND NOT (sb.ceil_height IS NOT NULL AND sf.ceil_height IS NOT NULL
                     AND sb.floor_height IS NOT NULL AND sf.floor_height IS NOT NULL
                     AND (LEAST(sf.ceil_height, sb.ceil_height) - GREATEST(sf.floor_height, sb.floor_height)) < _cs.min_walk_opening))
             AS floor_step_only
  ) b
  CROSS JOIN LATERAL (
    SELECT LEAST(1.0, GREATEST(0.0,
      ((c.cx - b.x1) * (b.x2 - b.x1) + (c.cy - b.y1) * (b.y2 - b.y1))
      / NULLIF((b.x2 - b.x1) * (b.x2 - b.x1) + (b.y2 - b.y1) * (b.y2 - b.y1), 0.0)
    )) AS t
  ) lt
  CROSS JOIN LATERAL (
    SELECT sqrt((c.cx - (b.x1 + lt.t * (b.x2 - b.x1)))^2 + (c.cy - (b.y1 + lt.t * (b.y2 - b.y1)))^2) AS dist
  ) dd
  CROSS JOIN LATERAL (
    SELECT sqrt((c.old_x - (b.x1 + t0.t * (b.x2 - b.x1)))^2 + (c.old_y - (b.y1 + t0.t * (b.y2 - b.y1)))^2) AS dist
    FROM (SELECT LEAST(1.0, GREATEST(0.0,
      ((c.old_x - b.x1) * (b.x2 - b.x1) + (c.old_y - b.y1) * (b.y2 - b.y1))
      / NULLIF((b.x2 - b.x1) * (b.x2 - b.x1) + (b.y2 - b.y1) * (b.y2 - b.y1), 0.0))) AS t) t0
  ) dd0
  CROSS JOIN LATERAL (
    SELECT
      (c.old_x - b.x1) * (b.y2 - b.y1) - (c.old_y - b.y1) * (b.x2 - b.x1) AS d1,
      (c.cx - b.x1) * (b.y2 - b.y1) - (c.cy - b.y1) * (b.x2 - b.x1) AS d2,
      (b.x1 - c.old_x) * (c.cy - c.old_y) - (b.y1 - c.old_y) * (c.cx - c.old_x) AS d3,
      (b.x2 - c.old_x) * (c.cy - c.old_y) - (b.y2 - c.old_y) * (c.cx - c.old_x) AS d4
  ) sides
  CROSS JOIN LATERAL (
    SELECT ((sides.d1 * sides.d2 < 0) AND (sides.d3 * sides.d4 < 0)) AS intersects
  ) xing
  WHERE b.is_blocking AND NOT (b.floor_step_only AND c.floats)
  GROUP BY c.pri, c.thing_id
),
candidate_blocked AS (
  SELECT c.pri, c.thing_id, c.cx, c.cy, c.old_x, c.old_y, c.face_angle,
         c.dir, c.next_movecount,
         FALSE AS blocked
  FROM candidates c
  WHERE NOT EXISTS (SELECT 1 FROM wall_block wb WHERE wb.pri = c.pri AND wb.thing_id = c.thing_id AND wb.blocked)
    AND NOT EXISTS (SELECT 1 FROM thing_hit th2 WHERE th2.pri = c.pri AND th2.thing_id = c.thing_id AND th2.hit)
),
best_pos AS (
  SELECT thing_id, cx, cy, old_x, old_y, face_angle, dir, next_movecount FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY thing_id ORDER BY pri) AS rn
    FROM candidate_blocked WHERE NOT blocked
  ) r WHERE rn = 1
),
stuck AS (
  SELECT w.thing_id, w.mx, w.my, w.fresh_movecount
  FROM walk w
  WHERE NOT EXISTS (SELECT 1 FROM best_pos bp WHERE bp.thing_id = w.thing_id)
)
INSERT INTO monster_steps
  (map_id,thing_id,old_x,old_y,new_x,new_y,face_angle,movedir,movecount)
SELECT doom_cs_monster_step.p_map_id::int, bp.thing_id, bp.old_x, bp.old_y, bp.cx, bp.cy,
       bp.face_angle, bp.dir, GREATEST(0, bp.next_movecount)
FROM best_pos bp
UNION ALL
SELECT doom_cs_monster_step.p_map_id::int, s.thing_id, s.mx, s.my, s.mx, s.my, 0, NULL, s.fresh_movecount
FROM stuck s;

-- A_Chase's bookkeeping
UPDATE monster_ai ai
SET movedir = ms.movedir, movecount = ms.movecount
FROM monster_steps ms
WHERE ai.map_id = doom_cs_monster_step.p_map_id AND ms.map_id = doom_cs_monster_step.p_map_id
  AND ai.thing_id = ms.thing_id
  AND (ai.movedir IS DISTINCT FROM ms.movedir OR ai.movecount <> ms.movecount);
stepped := false;
FOR _r1 IN SELECT EXISTS (SELECT 1 FROM monster_steps
               WHERE map_id=doom_cs_monster_step.p_map_id
                 AND (new_x <> old_x OR new_y <> old_y)) AS e
LOOP stepped := _r1.e; END LOOP;
RETURN _cs.stepped;
END _cs;
$function$;
