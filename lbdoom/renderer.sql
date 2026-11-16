-- The one-row CTEs that are pure constants or the pose (render_context, pos,
-- render_settings, cam) are NOT MATERIALIZED: Postgres materializes a CTE
-- that is referenced more than once, and a materialized one is opaque to
-- the planner -- every reference became a nested loop over a one-row scan,
-- dozens of them per pixel stream, and 320 or 0.5 stayed unknowns it could
-- neither fold nor estimate with. Inlined, the settings fold into constants.
WITH RECURSIVE render_context AS NOT MATERIALIZED (
    SELECT $1::int AS map_id,
           $2::int AS player_thing_id,
           -- Doom's 0..4 skill
           $3::int AS skill,
           CASE WHEN $3::int<=1 THEN 1 WHEN $3::int=2 THEN 2 ELSE 4 END
             AS skill_bit
), pos AS NOT MATERIALIZED (
    -- The camera pose is passed in rather than read from the player Thing, so
    -- the client can render intermediate poses between the 35 Hz gameplay tics.
    SELECT $4::float8 AS x, $5::float8 AS y, $6::float8 AS z, $7::float8 AS angle
), frame_clock AS (
    -- The gameplay clock, for the effects below that are pure functions of it.
    SELECT COALESCE(MAX(ps.level_tics), 0)::bigint AS t
    FROM player_state ps CROSS JOIN render_context rc
    WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
), animated_light AS (
    -- Doom hangs a light thinker off every animated sector. Here the effect is
    -- a pure function of the tic count and the two endpoints resolved at level
    -- start into sector_light_fx, so it is evaluated for the frame being drawn.
    SELECT k.sector_id,
      LEAST(255::smallint, GREATEST(0::smallint,
    CASE k.special
      -- Strobes: 5 tics bright, then 15 (fast) or 35 (slow) dark.
      WHEN 2  THEN CASE WHEN ((k.t + k.phase) % 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 13 THEN CASE WHEN (k.t % 20) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 3  THEN CASE WHEN ((k.t + k.phase) % 40) < 5 THEN k.base_light ELSE k.dark_light END
      WHEN 12 THEN CASE WHEN (k.t % 40) < 5 THEN k.base_light ELSE k.dark_light END
      -- Irregular flicker
      WHEN 1  THEN CASE WHEN ((k.sector_id*2654435761 + (k.t / 4)) % 8) < 2
                        THEN k.dark_light ELSE k.base_light END
      -- Fire flicker
      WHEN 17 THEN GREATEST(k.dark_light,
                     k.base_light - ((((((k.t / 3) % 1000) * (((k.t / 3) % 1000))
                                        * 1103515245) + k.sector_id * 40503)
                                      % 1009) % 4
                       * GREATEST(1, (k.base_light - k.dark_light) / 4))::int)
      -- Glow
      WHEN 8  THEN (k.dark_light + 8 * (
                      CASE WHEN ((k.t + k.phase) % (2*k.glow_steps)) < k.glow_steps
                           THEN ((k.t + k.phase) % (2*k.glow_steps))
                           ELSE 2*k.glow_steps - ((k.t + k.phase) % (2*k.glow_steps))
                      END))
      ELSE k.base_light
    END
      ))::smallint AS light_level
    FROM (
      SELECT f.sector_id, f.base_light, f.dark_light, f.special,
             (f.sector_id*7919) % 64 AS phase,
             GREATEST(1, (f.base_light - f.dark_light) / 8) AS glow_steps,
             fc.t
      FROM sector_light_fx f
      CROSS JOIN render_context rc
      CROSS JOIN frame_clock fc
      WHERE f.map_id = rc.map_id
    ) k
), sectors_lit AS (
    -- sectors with the animated light applied
    SELECT s.map_id, s.id, s.floor_height, s.ceil_height,
           s.spawn_floor_height, s.spawn_ceil_height, s.spawn_floor_tex,
           s.spawn_light_level, s.floor_tex, s.ceil_tex,
           COALESCE(a.light_level, s.light_level) AS light_level,
           s.special, s.tag
    FROM sectors s
    CROSS JOIN render_context rc
    LEFT JOIN animated_light a ON a.sector_id = s.id
    WHERE s.map_id = rc.map_id
), scrolling_segs AS (
    -- Special 48 scrolls its wall one unit a tic
    SELECT ld.id AS linedef_id
    FROM linedefs ld CROSS JOIN render_context rc
    WHERE ld.map_id = rc.map_id AND ld.scrolls
), render_settings AS NOT MATERIALIZED (
    -- CedarDB resolves a select-list alias inside the same list (cx from
    -- screen_w, focal from fov_rad); Postgres does not, so the three base
    -- values come from a subquery and everything derived reads them from it.
    SELECT
      b.screen_w,
      b.screen_h,
      b.fov_rad,
      -- Every derived value is float8: a decimal literal is numeric in
      -- Postgres, and numeric arithmetic (software decimal) in the per-pixel
      -- stages costs several times what float8 does.
      (b.screen_w/2.0)::float8 AS cx,
      (b.screen_h/2.0)::float8 AS cy,
      ((b.screen_w/2.0)/tan(b.fov_rad/2.0))::float8 AS focal,
      tan(b.fov_rad/2.0)::float8   AS tan_half_fov,
      1e-3::float8 AS near,
      -- A flat is 64 world units across, so once one screen pixel steps more
      -- than a quarter of that the surface stops resembling its texture and
      -- turns to noise. The horizontal step of a plane is depth/focal, so this
      -- caps a plane's drawable depth.
      (16.0 * ((b.screen_w/2.0)/tan(b.fov_rad/2.0)))::float8 AS max_plane_depth,
      202.5::float8 AS rotation_offset,
      45.0::float8  AS rotation_span,
      32::int AS light_index_invuln,
      23::int AS light_psprite_bias,
      256.0::float8 AS sky_columns,
      90.0::float8  AS sky_degrees,
      128::int      AS sky_rows,
      100::int      AS sky_horizon_y,
      64::int AS flat_size
    FROM (SELECT 320::int AS screen_w,
                 168::int AS screen_h,  -- 200 minus the real 32px status bar
                 radians(90.0)::float8 AS fov_rad) b
), frame_walltex AS MATERIALIZED (
    -- The textures are stored compressed (TOAST), and GET_BYTE decompresses
    -- its whole argument on every call: per pixel, that was most of the
    -- frame. Concatenating with '' hands back a plain in-memory copy, and a
    -- MATERIALIZED CTE keeps it, so every pixel below reads that copy. Only
    -- the textures of the segs in view (heights, below) and the sky, about
    -- 20: all 30-60 of the map's took 2-3.5 ms a frame to decompress on
    -- Lakebase.
    SELECT m.name, m.width, m.height, (m.palette_indices || ''::bytea) AS palette_indices
    FROM walltex_meta m
    WHERE m.name IN (
      SELECT t.tex FROM heights h
      CROSS JOIN LATERAL (VALUES (h.upper_tex), (h.mid_tex), (h.lower_tex)) t(tex)
      UNION
      SELECT ma.sky_texture FROM maps ma JOIN render_context rc ON rc.map_id = ma.map_id)
), frame_flats AS MATERIALIZED (
    -- The flats of this map's sectors, detoasted for the same reason.
    SELECT f.name, (f.palette_indices || ''::bytea) AS palette_indices
    FROM flat_textures f
    WHERE f.name IN (SELECT s.floor_tex FROM sectors_lit s
                     UNION SELECT s.ceil_tex FROM sectors_lit s)
), cam AS NOT MATERIALIZED (
    SELECT
    pos.x as px,
    pos.y as py,
    pos.z as pz,  -- eye height above floor
    -- Inlined, an expression here would be evaluated wherever it is used,
    -- per pixel; a scalar subquery is an InitPlan, evaluated once a frame.
    (SELECT radians(p.angle) FROM pos p) as view_rad,
    (SELECT COS(radians(p.angle)) FROM pos p) AS cos_v,
    (SELECT SIN(radians(p.angle)) FROM pos p) AS sin_v,
    (SELECT COS(-radians(p.angle)) FROM pos p) AS cos_nv,
    (SELECT SIN(-radians(p.angle)) FROM pos p) AS sin_nv
    FROM pos
), weapon_runtime AS (
    -- 'up'/'down' show the ready sprite while sx/sy slide.
    SELECT rc.map_id, rc.player_thing_id,
           COALESCE(w.sx, 1) AS sx, COALESCE(w.sy, 32) AS sy,
           -- The light amplification visor forces maximum brightness for
           -- its duration
           CASE WHEN COALESCE(ps2.light_amp_tics, 0) > 0 THEN 16
                ELSE COALESCE(w.flash_seq_index, -1) + 1 END AS extra_light,
           -- Invulnerability points Doom's fixedcolormap at COLORMAP row 32,
           -- the inverted one
           COALESCE(ps2.invuln_tics, 0) > 0 AS invuln,
           wd.sprite, wd.flash_sprite,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.frame ELSE mf.frame END AS frame,
           CASE WHEN COALESCE(w.state, 'ready') IN ('up', 'down')
                THEN rf.fullbright ELSE mf.fullbright END AS fullbright,
           ff.frame AS flash_frame, ff.fullbright AS flash_fullbright
    FROM render_context rc
    LEFT JOIN player_weapons w ON w.map_id = rc.map_id
      AND w.player_thing_id = rc.player_thing_id
    LEFT JOIN player_state ps2 ON ps2.map_id = rc.map_id
      AND ps2.player_thing_id = rc.player_thing_id
    JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
    LEFT JOIN weapon_frames rf ON rf.weapon_id = wd.weapon_id
      AND rf.state = 'ready' AND rf.seq_index = 0
    LEFT JOIN weapon_frames mf ON mf.weapon_id = wd.weapon_id
      AND mf.state = COALESCE(w.state, 'ready') AND mf.seq_index = COALESCE(w.seq_index, 0)
    LEFT JOIN weapon_frames ff ON ff.weapon_id = wd.weapon_id
      AND ff.state = 'flash' AND ff.seq_index = w.flash_seq_index
),
-- Conservative view-frustum test per node_children row. A child is skipped only when ALL FOUR of its
-- bbox corners lie strictly outside one of the 3 view half-planes (near clip, left FOV edge, right FOV edge).
-- MATERIALIZED: once per child (~500 rows) and a hash join, rather than
-- inlined into bsp_order as an index probe and a fresh test per path step
-- (~2,200).
visible_children AS MATERIALIZED (
  SELECT
    nc.map_id, nc.node_id, nc.side,
    -- Whether this child is the side of its node's splitter the camera is
    -- on: per node here, rather than per path step in bsp_order.
    nc.side = CASE
                WHEN (p.x - n.x)::bigint * n.dy::bigint - (p.y - n.y)::bigint * n.dx::bigint > 0
                  THEN 'R' ELSE 'L'
              END AS is_front,
    (c.px BETWEEN nc.bbox_left AND nc.bbox_right
     AND c.py BETWEEN nc.bbox_bottom AND nc.bbox_top)
    OR (
      -- MIN over the box of L = vy - vx*tan(halfFOV); keep unless proven
      -- fully outside the left edge.
      ((c.sin_nv - rs.tan_half_fov*c.cos_nv)
         * (CASE WHEN (c.sin_nv - rs.tan_half_fov*c.cos_nv) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (c.cos_nv + rs.tan_half_fov*c.sin_nv)
         * (CASE WHEN (c.cos_nv + rs.tan_half_fov*c.sin_nv) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (-c.px*c.sin_nv - c.py*c.cos_nv
          + rs.tan_half_fov*(c.px*c.cos_nv - c.py*c.sin_nv))
      ) <= 0.5
      AND
      -- MIN over the box of R = -vy - vx*tan(halfFOV); right edge.
      ((-c.sin_nv - rs.tan_half_fov*c.cos_nv)
         * (CASE WHEN (-c.sin_nv - rs.tan_half_fov*c.cos_nv) >= 0
                 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (-c.cos_nv + rs.tan_half_fov*c.sin_nv)
         * (CASE WHEN (-c.cos_nv + rs.tan_half_fov*c.sin_nv) >= 0
                 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (c.px*c.sin_nv + c.py*c.cos_nv
          + rs.tan_half_fov*(c.px*c.cos_nv - c.py*c.sin_nv))
      ) <= 0.5
      AND
      -- MIN over the box of N = near - vx; near clip plane.
      ((-c.cos_nv)
         * (CASE WHEN (-c.cos_nv) >= 0 THEN nc.bbox_left ELSE nc.bbox_right END)
       + (c.sin_nv)
         * (CASE WHEN c.sin_nv >= 0 THEN nc.bbox_bottom ELSE nc.bbox_top END)
       + (rs.near + c.px*c.cos_nv - c.py*c.sin_nv)
      ) <= 0.5
    ) AS keep
  FROM node_children nc
  JOIN nodes n ON n.map_id = nc.map_id AND n.id = nc.node_id
  CROSS JOIN pos p
  CROSS JOIN cam c
  CROSS JOIN render_settings rs
  CROSS JOIN render_context rctx
  WHERE nc.map_id = rctx.map_id
),
-- Front-to-back order over subsectors.
-- A nice property of Doom is that the BSP tree tells us exactly in which order we have
-- to render sectors without having to worry about overlaps - just start rendering at the first node
-- and continue filling pixels that haven't been set yet, until the bsp tree is fully traversed - divide and conquer!
-- We just have to traverse the bsp tree to our sector and record the front/back choices
-- along the way.
-- We cheat a little bit: SQL does set-oriented processing, which makes traversal expensive
-- and hard to express. So we just pre-compute all paths in node_path_steps.
-- And aggregate over that (~6k rows).
-- We then pack the choices we made into one bigint: back = 1 at bit (40 - depth), front = 0.
-- By sorting the keys lexicographically, we get an order in which to render segments.
-- We also apply pruning: A subsector under any culled child box is left out from further steps.
-- Sounds a little bit like cheating but even John Carmack himself set in 1993 that he is sure
-- there's going to be a future where rendering DOOM can just be brute-forced. Not sure if he
-- had SQL in mind, though.
bsp_order AS (
  SELECT s.ssector_id, ROW_NUMBER() OVER (ORDER BY s.sort_key) AS bsp_seq
  FROM (
    SELECT st.ssector_id,
           SUM(CASE WHEN vc.is_front THEN 0::bigint
                    ELSE (1::bigint << (40 - st.depth)) END) AS sort_key,
           BOOL_AND(vc.keep) AS visible
    FROM node_path_steps st
    CROSS JOIN render_context rc
    -- visible_children holds this map's children only
    JOIN visible_children vc ON vc.node_id = st.node_id AND vc.side = st.side
    WHERE st.map_id = rc.map_id
    GROUP BY st.ssector_id
  ) s
  WHERE s.visible
),
player_sector AS (
  -- The first subsector in the front-to-back walk contains the camera.
  SELECT sec.*
  FROM bsp_order bo
  JOIN render_context rc ON TRUE
  JOIN render_segs sg ON sg.map_id = rc.map_id
    AND sg.ssector_id = bo.ssector_id
  JOIN sectors_lit sec ON sec.map_id = rc.map_id AND sec.id = sg.fsec
  WHERE bo.bsp_seq = 1
  ORDER BY sg.seg_id
  LIMIT 1
),
segs_with_verts AS (
  SELECT
    s.seg_id,
    s.direction,
    s.linedef_id,
    s.map_id,
    s.x1, s.y1, s.x2, s.y2,
    s.seg_u1, s.seg_u2,
    bo.bsp_seq                       -- which subsector, in walk order
  FROM render_segs s
  -- Only segs the BSP walk actually reached
  JOIN bsp_order bo ON bo.ssector_id = s.ssector_id
  CROSS JOIN pos
  CROSS JOIN render_context rc
  WHERE s.map_id = rc.map_id
    -- A Doom seg is directed so that its front sector lies on its right.
    -- Two-sided linedefs normally occur twice in SEGS, once per subsector and
    -- in opposite directions. Keep only the copy facing the camera.
    AND (s.x2 - s.x1)::bigint * (pos.y - s.y1)::bigint
      - (s.y2 - s.y1)::bigint * (pos.x - s.x1)::bigint < 0
),
viewspace AS (
    -- translate to camera origin and rotate by -view_rad in one step.
    SELECT
        s.seg_id,
        s.direction,
        s.linedef_id,
        s.map_id,
        s.seg_u1, s.seg_u2, s.bsp_seq,
        (s.x1 - c.px) * c.cos_nv - (s.y1 - c.py) * c.sin_nv AS x1,
        -((s.x1 - c.px) * c.sin_nv + (s.y1 - c.py) * c.cos_nv) AS y1,
        (s.x2 - c.px) * c.cos_nv - (s.y2 - c.py) * c.sin_nv AS x2,
        -((s.x2 - c.px) * c.sin_nv + (s.y2 - c.py) * c.cos_nv) AS y2
    FROM segs_with_verts s CROSS JOIN cam c
),
visible AS (
    SELECT * FROM viewspace WHERE x1 > 0 OR x2 > 0
),
clipped AS (
    SELECT
        seg_id,
        direction,
        linedef_id,
        map_id,
        seg_u1,
        seg_u2,
        bsp_seq,
        CASE WHEN x1 < near then near ELSE x1 END AS cx1,
        CASE WHEN x1 < near THEN y1 + (near - x1)*(y2 - y1)/(x2 - x1) ELSE y1 END AS cy1,
        CASE WHEN x2 < near then near ELSE x2 END AS cx2,
        CASE WHEN x2 < near THEN y2 + (near - x2)*(y1 - y2)/(x1 - x2) ELSE y2 END AS cy2
    FROM visible, render_settings
),
projected AS (
    SELECT
        seg_id,
        direction,
        linedef_id,
        map_id,
        cx1, cy1, cx2, cy2,
        cx + focal*(cy1/cx1) AS screen_x1,
        cx + focal*(cy2/cx2) AS screen_x2,
        1.0/cx1 AS invx1,
        1.0/cx2 AS invx2,
        seg_u1,
        seg_u2,
        bsp_seq
    FROM clipped, render_settings
),
on_screen AS (
  -- Frustum reject. A segment is retained when its clipped projected interval overlaps any part of the screen.
  -- this also keeps segments whose two endpoints lie outside opposite edges (ask me how I found this out the hard way).
  SELECT p.*
  FROM projected p
  CROSS JOIN render_settings rs
  WHERE GREATEST(p.screen_x1, p.screen_x2) >= 0
    AND LEAST(p.screen_x1, p.screen_x2) < rs.screen_w
),
heights AS (
  SELECT
    p.*, s.fsec, s.bsec,
    (s.x_offset + CASE WHEN sc.linedef_id IS NULL THEN 0 ELSE fc.t END) AS x_offset,
    s.y_offset,
    s.upper_tex, s.mid_tex, s.lower_tex, s.flags,
    s.f_floor, s.f_ceil, s.f_ceil_tex,
    -- f_light/b_light are the sector's static light, an animated sector's value is computed above
    COALESCE(alf.light_level, s.f_light) AS f_light,
    s.b_floor, s.b_ceil, s.b_ceil_tex,
    COALESCE(alb.light_level, s.b_light) AS b_light,
    -- Doom gives horizontal walls one darker light step and vertical
    -- walls one brighter step, so edges/corners are easier to see
    s.light_bias
  FROM on_screen p
  -- (CedarDB needed `s.seg_id + 0` here to pick its join order; in Postgres
  -- that expression hides the primary key and every seg scanned the map.)
  JOIN render_segs s ON s.map_id = p.map_id AND s.seg_id = p.seg_id
  CROSS JOIN frame_clock fc
  LEFT JOIN animated_light alf ON alf.sector_id = s.fsec
  LEFT JOIN animated_light alb ON alb.sector_id = s.bsec
  LEFT JOIN scrolling_segs sc ON sc.linedef_id = s.linedef_id
),
occluders AS (
  -- segs that fully block anything farther
  -- one-sided walls, or two-sided walls whose back sector is degenerate
  -- (closed door / dummy sector)
  SELECT h.seg_id, h.screen_x1, h.screen_x2, h.bsp_seq
  FROM heights h
  WHERE h.bsec IS NULL OR h.b_ceil <= h.b_floor
),
occlusion_cols AS (
  SELECT generate_series(
           GREATEST(0, FLOOR(LEAST(o.screen_x1, o.screen_x2))::int),
           LEAST(rs.screen_w - 1, CEIL(GREATEST(o.screen_x1, o.screen_x2))::int)
         ) AS col_x,
         o.bsp_seq
  FROM occluders o
  CROSS JOIN render_settings rs
  WHERE o.screen_x1 <> o.screen_x2
),
min_occlusion AS (
  -- nearest (smallest bsp_seq) fully-solid occluder covering each column;
  -- anything with a strictly larger bsp_seq in that column is behind it and
  -- can be ignored
  SELECT col_x, MIN(bsp_seq) AS min_bsp_seq
  FROM occlusion_cols
  GROUP BY col_x
),
wall_parts AS (
  -- SOLID (one-sided)
  SELECT seg_id, 'solid' AS part, mid_tex AS tex, x_offset, y_offset, flags,
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 16)<>0 THEN f_floor ELSE f_ceil END AS v_anchor_base,
         (flags & 16)<>0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NULL
  AND f_ceil > f_floor            -- skip zero/inverted-height (dummy) sectors

  UNION ALL
  -- UPPER (two-sided, when back ceiling < front ceiling)
  SELECT seg_id, 'upper', upper_tex, x_offset, y_offset, flags,
         b_ceil AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 8)<>0 THEN f_ceil ELSE b_ceil END AS v_anchor_base,
         (flags & 8)=0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil < f_ceil
  -- Doom joins adjacent sky ceilings visually even when their numeric heights
  -- differ. Drawing this upper wall creates a fake floating overhang whose
  -- "underside" is (correctly) still sky.
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')

  UNION ALL
  -- CEILING OPEN-UP (two-sided, back ceiling at or above the front ceiling).
  -- There is no wall surface on the camera-facing side, but the front ceiling
  -- ends at this portal. Keep it as a clip-only boundary.
  SELECT seg_id, 'upper_open', NULL::text, x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base,FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil > f_ceil
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')

  UNION ALL
  -- CEILING FLUSH BOUNDARY (two-sided, both ceilings at the same height).
  -- Draws no wall, but unlike upper_open it DOES close the near ceiling:
  -- beyond this line the ceiling belongs to the back sector.
  SELECT seg_id, 'upper_flush', NULL::text, x_offset, y_offset, flags,
         f_ceil AS z_bot, b_ceil AS z_top,
         b_ceil AS v_anchor_base,FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_ceil = f_ceil
  AND (f_ceil_tex IS DISTINCT FROM 'F_SKY1'
       OR b_ceil_tex IS DISTINCT FROM 'F_SKY1')

  UNION ALL
  -- LOWER step-up (two-sided, back floor higher than front floor)
  SELECT seg_id, 'lower', lower_tex, x_offset, y_offset, flags,
         f_floor AS z_bot, b_floor AS z_top,
         CASE WHEN (flags & 16)<>0 THEN f_ceil ELSE b_floor END AS v_anchor_base,
         FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor > f_floor

  UNION ALL
  -- FLOOR OPEN-DOWN (two-sided, back floor at or below the front floor). The
  -- riser faces the opposite side, so this camera-facing copy is clip-only.
  SELECT seg_id, 'lower_down', NULL::text, x_offset, y_offset, flags,
         b_floor AS z_bot, f_floor AS z_top,
         f_floor AS v_anchor_base,FALSE AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND b_floor <= f_floor

  UNION ALL
  -- MID MASKED (two-sided decorative; draws over the opening)
  SELECT seg_id, 'midmask', mid_tex, x_offset, y_offset, flags,
         /* pegging will decide exact vertical placement; provisional full height */
         f_floor AS z_bot, f_ceil AS z_top,
         CASE WHEN (flags & 16)<>0 THEN GREATEST(f_floor,b_floor)
              ELSE LEAST(f_ceil,b_ceil) END AS v_anchor_base,
         (flags & 16)<>0 AS v_anchor_add_tex_h,
         f_light, fsec, invx1, invx2, screen_x1, screen_x2, cx1, cx2, cy1, cy2, seg_u1, seg_u2,
         bsp_seq, light_bias
  FROM heights
  WHERE bsec IS NOT NULL
  AND mid_tex IS NOT NULL
  AND mid_tex <> '-' -- TODO
  AND f_ceil > f_floor            -- skip zero/inverted-height (dummy) sectors
),
wall_parts_tex AS (
  -- The texture is a property of the seg part, so its size is looked up here,
  -- once per visible seg part (a few hundred rows). Its bytes are not: they
  -- would ride along into `vertical`, which is materialized, and a
  -- materialized row holds its own copy of every value -- a whole texture per
  -- screen column, ~15 MB a frame written to temp files. clamped_spans_lit
  -- fetches them per span instead.
  SELECT wp.*,
         COALESCE(m.width, 64)  AS tex_w,
         COALESCE(m.height, 64) AS tex_h,
         m.width                AS tex_width
  FROM wall_parts wp
  LEFT JOIN walltex_meta m ON m.name = wp.tex
),
columns AS (
  SELECT
    w.*,
    (w.x_offset + w.seg_u1) AS u1,   -- wall U at the two endpoints
    (w.x_offset + w.seg_u2) AS u2,
    w.x AS col_x,
    w.x AS screen_x_clamped,         -- already clamped by bounds below
    -- clamp t to [0,1]: the generate_series range is FLOOR/CEIL of the
    -- projected span, which can extend one column past each endpoint at
    -- T-junctions. Without clamping, t leaves [0,1] and extrapolates the
    -- wall across the crack, producing 1px vertical strips of the wrong wall.
    LEAST(1.0, GREATEST(0.0,
      (w.x - w.screen_x1) / NULLIF(w.screen_x2 - w.screen_x1, 1e-6))) AS t
  FROM (
    -- one row per screen column of a seg part, from a select-list
    -- generate_series (see fragments)
    SELECT w.*, generate_series(b.x_lo, b.x_hi) AS x
    FROM wall_parts_tex w
    CROSS JOIN render_settings rs
    CROSS JOIN LATERAL (
      SELECT
        -- quick reject if the entire projected span is off-screen
        NOT (GREATEST(w.screen_x1, w.screen_x2) < 0 OR LEAST(w.screen_x1, w.screen_x2) >= rs.screen_w) AS on_screen,
        GREATEST(0, FLOOR(LEAST(w.screen_x1, w.screen_x2))::int)    AS x_lo,
        LEAST  (rs.screen_w-1, CEIL (GREATEST(w.screen_x1, w.screen_x2))::int) AS x_hi
    ) b
    WHERE b.on_screen
      AND w.screen_x1 <> w.screen_x2
  ) w
  LEFT JOIN min_occlusion mo ON mo.col_x = w.x
  -- occlusion: skip columns where a nearer (smaller bsp_seq) fully-solid
  -- wall has already closed off anything farther
  WHERE w.bsp_seq <= COALESCE(mo.min_bsp_seq, w.bsp_seq)
  -- A subquery of its own, so t is computed once per column: inlined into
  -- per_column and vertical it would be re-evaluated at each of its seven
  -- uses (through invx, u_over_x, depth_x, u_col and scale).
  OFFSET 0
),
per_column AS (
  SELECT
    c.*,
    iv.invx,
    iv.u_over_x,
    1.0 / iv.invx                       AS depth_x,
    iv.u_over_x / NULLIF(iv.invx, 1e-6) AS u_col,
    -- scale factor at this column
    rs.focal * iv.invx                  AS scale
  FROM columns c
  CROSS JOIN render_settings rs
  CROSS JOIN LATERAL (
    SELECT
      -- inverse depth and perspective-correct U, interpolated per column
      c.invx1 + c.t * (c.invx2 - c.invx1)                       AS invx,
      (c.u1 * c.invx1) + c.t * ((c.u2 * c.invx2) - (c.u1 * c.invx1)) AS u_over_x
  ) iv
),
vertical AS (
  -- Materialized (clamped_spans and panel_cols both read it), and a
  -- materialized CTE computes and stores every column it has: so only the
  -- ones those two read, not the ~45 the stages above it carry.
  SELECT
    p.seg_id, p.part, p.tex, p.y_offset, p.f_light,
    p.tex_w, p.tex_h, p.tex_width, p.bsp_seq, p.light_bias,
    p.col_x, p.screen_x_clamped, p.depth_x, p.u_col, p.scale,
    c.pz AS view_z,rs.cy AS screen_cy,
    (rs.cy - p.scale * (p.z_top - c.pz)) AS y_top_f,
    (rs.cy - p.scale * (p.z_bot - c.pz)) AS y_bot_f,
    -- tex_w / tex_h (texture size, 64x64 if missing) come with the seg part
    p.v_anchor_base
      + CASE WHEN p.v_anchor_add_tex_h THEN p.tex_h ELSE 0 END
      AS v_anchor_z
  FROM per_column p
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
clamped_spans AS (
  SELECT
    t.*,
    -- Doom samples wall V in world units. Inverting the perspective
    -- projection gives world_z at the first visible pixel; advancing one
    -- screen row changes V by 1/scale.
    t.v_anchor_z
      - (t.view_z+(t.screen_cy-t.y_start::float8)/NULLIF(t.scale,1e-9))
      + t.y_offset::float8 AS v0,
    1.0/NULLIF(t.scale,1e-9) AS v_step
  FROM (
    SELECT
      v.*,
      -- clamp to [0 .. screen_h-1] in FLOAT, then cast
      CEIL (
        LEAST( rs.screen_h - 1.0::float8,
               GREATEST(0.0::float8, LEAST(v.y_top_f, v.y_bot_f))
        )
      )::int AS y_start,
      FLOOR(
        LEAST( rs.screen_h - 1.0::float8,
               GREATEST(0.0::float8, GREATEST(v.y_top_f, v.y_bot_f))
        )
      )::int AS y_end
    FROM vertical v
    CROSS JOIN render_settings rs
    -- keep only spans that intersect the screen vertically
    WHERE LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
      AND GREATEST(v.y_top_f, v.y_bot_f) >= 0
  ) t
  -- final guard: ignore empty/inverted spans
  WHERE t.y_end >= t.y_start
),
clamped_spans_lit AS (
  SELECT c.*, cu.u_i, wt.palette_indices AS tex_pi,
         -- The texel offset below can only leave the texture through U (V is
         -- an integer modulo of tex_h): when this column's U is inside and
         -- the texture is whole, every pixel of the span reads in range.
         (wt.palette_indices IS NOT NULL AND cu.u_i >= 0 AND cu.u_i < c.tex_width
          AND OCTET_LENGTH(wt.palette_indices) >= c.tex_width * c.tex_h) AS texel_safe,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              ELSE doom_light_index(c.f_light, c.light_bias + wr.extra_light,
                                    doom_light_scale(c.depth_x))
         END AS light_index,
         (c.seg_id::bigint*8 + CASE c.part
            WHEN 'solid' THEN 0 WHEN 'upper' THEN 1 WHEN 'lower' THEN 2
            WHEN 'lower_down' THEN 3 ELSE 7 END)::bigint AS stable_id
  FROM clamped_spans c
  CROSS JOIN LATERAL (
    -- integerized, positive-modulo U: one texture column per screen column
    SELECT (FLOOR(c.u_col - c.tex_w * FLOOR(c.u_col / c.tex_w))::int) AS u_i
  ) cu
  LEFT JOIN frame_walltex wt ON wt.name = c.tex
  CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
wall_spans AS (
  -- The depth-resolve key (see ranked_fragments) of a wall pixel is the same
  -- all the way down its span except for the texel in the low byte, so all
  -- of it but the texel is computed here, once per span (~900 rows) instead
  -- of once per pixel (~35k). OR-ing the texel in per pixel gives the same
  -- bits.
  --
  -- OFFSET 0 is what makes "once per span" true. Inlined into the pixel
  -- query, every expression of this CTE and of the ones it reads
  -- (clamped_spans_lit, clamped_spans, ...) would be evaluated where it is
  -- used: per pixel, because the select-list generate_series below
  -- re-evaluates its whole select list for every row it emits. As a subquery
  -- of its own, a span is computed once and its pixels read the result.
  SELECT c.*,
         ((GREATEST(0.0::float8, LEAST(c.depth_x, 131071.0))*4096)::bigint << 34)
         | ((2::bigint - 2::bigint) << 32)
         | (LEAST(0::bigint, 3::bigint) << 30)
         | (LEAST(65535::bigint, GREATEST(0::bigint, c.stable_id + 32768)) << 14)
         | (c.light_index::bigint << 8) AS key_hi
  FROM clamped_spans_lit c
  WHERE c.tex IS NOT NULL AND c.tex <> '-'
  OFFSET 0
),
fragments AS (
  -- One row per wall pixel: its screen offset and its key. The rows come
  -- from generate_series in a select list (ProjectSet), which streams them,
  -- rather than from a lateral function scan, which writes each into a
  -- tuplestore first. The span brings only the columns read here: the
  -- ProjectSet copies every column it has into each row it emits, and a
  -- span's whole row (~55 columns) made that a third of a pixel's cost.
  SELECT f.y * rs.screen_w + f.screen_x_clamped AS pix,
         -- Sample the original PLAYPAL index; COLORMAP applies the actual
         -- Doom shade. Postgres evaluates an inlined expression once per
         -- reference, so the bounds checks cost three more V computations per
         -- pixel; a span known to be in range (texel_safe) skips them.
         f.key_hi | (CASE
           WHEN f.texel_safe THEN GET_BYTE(f.tex_pi, (vv.v_i * f.tex_width + f.u_i)::int)
           WHEN f.tex_pi IS NULL
             OR (vv.v_i * f.tex_width + f.u_i) < 0
             OR (vv.v_i * f.tex_width + f.u_i) >= OCTET_LENGTH(f.tex_pi)
           THEN 0 ELSE
           GET_BYTE(f.tex_pi, (vv.v_i * f.tex_width + f.u_i)::int)
         END)::bigint AS winner_key
  FROM (SELECT w.screen_x_clamped, w.key_hi, w.texel_safe, w.tex_pi, w.tex_width,
               w.tex_h, w.u_i, w.v0, w.v_step, w.y_start,
               generate_series(w.y_start, w.y_end) AS y
        FROM wall_spans w) f
  CROSS JOIN render_settings rs
  -- integerized, positive-modulo V
  CROSS JOIN LATERAL (
    SELECT ((FLOOR(f.v0 + (f.y - f.y_start)*f.v_step)::int % f.tex_h + f.tex_h) % f.tex_h) AS v_i
  ) vv
),

-- VISPLANES!
-- You thought it was complicated before? This is where the fun starts!
-- Visplanes are a very elegant concept in a 2.5D game that is written in an
-- imperative language like C.
-- They are absolut hell in SQL.
--
-- Walls are correctly rendered now. We're missing floors and ceilings:
-- Everything that is not a wall is either a floor or a ceiling (called visplane in Doom).
-- This is a pretty ingenous hack to get 3D-y looking frames without having to
-- think about perspective - Doom just uses a pretty simple and fast floodfill algorithm.
--
-- We have to be more careful here and abuse window functions:
-- We go front-to-back per column. We maintain one open band [cc, fc] (ceiling-clip,
-- floor-clip) per column.
-- Each wall panel is either top-anchored (solid/upper: pushes cc down to its y_bot)
-- or bottom-anchored (solid/lower: pushes fc up to its y_top).
-- The pixel NOT covered by a wall, but inside the current open band,
-- is filled with the FRONT sector's ceiling (above) or floor (below). Through a
-- two-sided portal the upper+lower walls shrink the band from both sides.
-- Farther walls then fill that opening with the back sector's planes.
panel_cols AS (
  -- Drawable walls only matter when their vertical span intersects the screen.
  -- Unfortunately, we also have to look at portals completely off-screen:
  -- their projected front plane can still bound a visible floor or ceiling.
  SELECT
    v.col_x,
    v.seg_id,
    v.bsp_seq,
    v.part,
    v.depth_x,
    v.y_top_f,
    v.y_bot_f,
    -- Screen rows where this seg's front planes meet the boundary.
    CASE WHEN v.part = 'lower_down' THEN v.y_top_f ELSE v.y_bot_f END AS f_floor_y_f,
    CASE WHEN v.part = 'upper_open' THEN v.y_bot_f ELSE v.y_top_f END AS f_ceil_y_f,
    h.fsec,
    h.f_light,
    h.f_floor,
    h.f_ceil,
    (h.f_ceil_tex = 'F_SKY1') AS f_ceil_is_sky
  FROM vertical v
  JOIN heights h ON h.seg_id = v.seg_id
  CROSS JOIN render_settings rs
  WHERE v.part IN ('upper_open','upper_flush','lower_down')
     OR (LEAST(v.y_top_f, v.y_bot_f) < rs.screen_h
         AND GREATEST(v.y_top_f, v.y_bot_f) >= 0)
),
panel_seq AS (
  -- The front-to-back position of each panel within its column
  SELECT p.*,
         ROW_NUMBER() OVER (
           PARTITION BY p.col_x
           ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
         ) AS seq
  FROM panel_cols p
),
panel_clips AS (
  -- The panel carried into each panel is the nearest earlier one in its
  -- column whose ceiling is above (floor below) the eye. CedarDB ran that as
  -- two LATERAL lookups; Postgres re-scans the whole CTE for each of them.
  -- Here the running MAX that finds the carried panel carries its fields
  -- too: each value packs the panel's seq above the fields it carries, so
  -- the largest is the latest qualifying panel and its low bits are that
  -- panel's fields. That replaces two self-joins of panel_seq. A field packs
  -- as value + 2^31 (int) or + 2^15 (smallint), with a flag bit for NULL, so
  -- the decoded value is exactly the panel's own.
  SELECT
    p.*,
    CASE WHEN p.ceil_k IS NULL OR (p.ceil_k >> 32) & 1 = 1 THEN NULL
         ELSE ((p.ceil_k & 4294967295) - 2147483648)::int END AS carried_ceil_sec,
    CASE WHEN p.ceil_zl IS NULL OR (p.ceil_zl >> 18) & 262143 >= 131072 THEN NULL
         ELSE (((p.ceil_zl >> 18) & 262143) - 32768)::smallint END AS carried_ceil_z,
    CASE WHEN p.ceil_zl IS NULL OR p.ceil_zl & 262143 >= 131072 THEN NULL
         ELSE ((p.ceil_zl & 262143) - 32768)::smallint END AS carried_ceil_light,
    COALESCE((p.ceil_zl >> 36) & 1 = 1, FALSE) AS carried_ceil_is_sky,
    CASE WHEN p.floor_k IS NULL OR (p.floor_k >> 32) & 1 = 1 THEN NULL
         ELSE ((p.floor_k & 4294967295) - 2147483648)::int END AS carried_floor_sec,
    CASE WHEN p.floor_zl IS NULL OR (p.floor_zl >> 18) & 262143 >= 131072 THEN NULL
         ELSE (((p.floor_zl >> 18) & 262143) - 32768)::smallint END AS carried_floor_z,
    CASE WHEN p.floor_zl IS NULL OR p.floor_zl & 262143 >= 131072 THEN NULL
         ELSE ((p.floor_zl & 262143) - 32768)::smallint END AS carried_floor_light
  FROM (
    SELECT
      p.*,
      COALESCE(
        MAX(CASE
              WHEN part IN ('solid','upper')
                THEN FLOOR(LEAST(rs.screen_h - 1.0, GREATEST(0.0, y_bot_f)))::int + 1
              -- A flush boundary draws no wall.
              WHEN part = 'upper_flush'
                THEN GREATEST(0, FLOOR(LEAST(rs.screen_h - 1.0, y_bot_f))::int + 1)
            END)
          OVER w_before,
        0
      ) AS cc_before,
      -- A lower wall raises floorclip to the top of the riser (the bottom of the
      -- portal opening). A solid wall closes it in the same direction.
      COALESCE(
        MIN(CASE WHEN part IN ('solid','lower','lower_down')
                 THEN LEAST(rs.screen_h - 1, CEIL(GREATEST(0.0, y_top_f))::int - 1) END)
          OVER w_before,
        rs.screen_h - 1
      ) AS fc_before,
      -- Doom starts a ceiling visplane only for a ceiling that is higher then the viewer.
      -- We need to continue drawing the ceiling that is already in porgress until we hit a wall.
      -- So let's carry it here: seq | sector, and seq | sky | height | light.
      MAX(CASE WHEN p.f_ceil > c.pz THEN
            (p.seq << 33)
            | CASE WHEN p.fsec IS NULL THEN 4294967296 ELSE p.fsec::bigint + 2147483648 END
          END) OVER w_before AS ceil_k,
      MAX(CASE WHEN p.f_ceil > c.pz THEN
            (p.seq << 37)
            | (CASE WHEN p.f_ceil_is_sky THEN 1::bigint ELSE 0::bigint END << 36)
            | (CASE WHEN p.f_ceil IS NULL THEN 131072 ELSE p.f_ceil::bigint + 32768 END << 18)
            | CASE WHEN p.f_light IS NULL THEN 131072 ELSE p.f_light::bigint + 32768 END
          END) OVER w_before AS ceil_zl,
      MAX(CASE WHEN p.f_floor < c.pz THEN
            (p.seq << 33)
            | CASE WHEN p.fsec IS NULL THEN 4294967296 ELSE p.fsec::bigint + 2147483648 END
          END) OVER w_before AS floor_k,
      MAX(CASE WHEN p.f_floor < c.pz THEN
            (p.seq << 36)
            | (CASE WHEN p.f_floor IS NULL THEN 131072 ELSE p.f_floor::bigint + 32768 END << 18)
            | CASE WHEN p.f_light IS NULL THEN 131072 ELSE p.f_light::bigint + 32768 END
          END) OVER w_before AS floor_zl
    FROM panel_seq p
    CROSS JOIN render_settings rs
    CROSS JOIN cam c
    -- panel_seq's own order, so seq and these share one sort: seq numbers
    -- the panels in exactly this order.
    WINDOW w_before AS (PARTITION BY p.col_x
                        ORDER BY p.depth_x ASC, p.bsp_seq ASC, p.part, p.seg_id
                        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
  ) p
),
nearest_floor_panel AS (
  -- An upper wall changes only the ceiling and must not truncate the near
  -- floor. Bound it with the first solid/lower transition in each column.
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','lower','lower_down')
  GROUP BY col_x
),
nearest_ceiling_panel AS (
  -- Conversely, lower walls do not affect the ceiling. Bound the near ceiling
  -- with the first solid/upper transition.
  SELECT col_x, MIN(depth_x) AS depth_x
  FROM panel_cols
  WHERE part IN ('solid','upper','upper_open','upper_flush')
  GROUP BY col_x
),
plane_spans_raw AS (
  -- Ceiling fill up to the projected FRONT ceiling. upper_open is clip-only:
  -- it ends the near ceiling without drawing a wall or tightening cc.
  SELECT
    k.col_x,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.fsec    ELSE k.carried_ceil_sec   END AS sector_id,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_ceil  ELSE k.carried_ceil_z     END AS plane_z,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_light ELSE k.carried_ceil_light END AS sector_light,
    CASE WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky
         THEN k.f_ceil_is_sky ELSE k.carried_ceil_is_sky END AS is_sky,
    'ceil'::text AS plane, 1::int AS source_priority,
    GREATEST(0, k.cc_before) AS y0,
    b.y1
  FROM panel_clips k
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN LATERAL (
    SELECT CEIL(LEAST(rs.screen_h - 1.0, GREATEST(0.0,
      CASE
        -- The panel's own ceiling is bounded by the panel's own top edge.
        WHEN k.f_ceil > c.pz OR k.f_ceil_is_sky THEN k.f_ceil_y_f
        -- A carried ceiling has no wall of its own to end it, so it would run
        -- to the horizon and be sampled at thousands of map units per pixel.
        -- Stop it where sampling would alias.
        ELSE LEAST(k.f_ceil_y_f,
                   rs.cy - rs.focal * (k.carried_ceil_z - c.pz)
                           / rs.max_plane_depth)
      END
    )))::int - 1 AS y1
  ) b
  WHERE k.part IN ('solid','upper','upper_open','upper_flush','midmask')
    AND b.y1 >= k.cc_before
    -- Sky is unbounded, so Doom fills any ceiling region that is not otherwise filled.
    AND (k.f_ceil > c.pz OR k.f_ceil_is_sky
         OR k.carried_ceil_is_sky OR k.cc_before > 0)
  UNION ALL
  -- A wall triggers a floor for it's "FRONT" sector. Starting from its floor boundary
  -- down to the floor clip established by nearer walls.
  -- This rule handles solid walls, step-up and step-down portals.
  -- We don't have to care abou the "BACK" sector, as farther, camera-facing
  -- sector sides should fill that later on.
  SELECT
    k.col_x,
    CASE WHEN k.f_floor < c.pz THEN k.fsec    ELSE k.carried_floor_sec   END AS sector_id,
    CASE WHEN k.f_floor < c.pz THEN k.f_floor ELSE k.carried_floor_z     END AS plane_z,
    CASE WHEN k.f_floor < c.pz THEN k.f_light ELSE k.carried_floor_light END AS sector_light,
    FALSE AS is_sky,
    'floor'::text AS plane, 1::int AS source_priority,
    b.y0,
    LEAST(rs.screen_h - 1, k.fc_before) AS y1
  FROM panel_clips k
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN LATERAL (
    SELECT FLOOR(LEAST(rs.screen_h - 1.0, GREATEST(0.0,
      CASE
        WHEN k.f_floor < c.pz THEN k.f_floor_y_f
        ELSE GREATEST(k.f_floor_y_f,
                      rs.cy - rs.focal * (k.carried_floor_z - c.pz)
                              / rs.max_plane_depth)
      END
    )))::int + 1 AS y0
  ) b
  WHERE k.part IN ('solid','midmask','lower','lower_down')
    AND b.y0 <= k.fc_before
    AND (k.f_floor < c.pz OR k.fc_before < rs.screen_h - 1)
  UNION ALL
  -- Seed the floor immediately around the camera.
  -- It continues until it reaches the nearest wall depth.
  SELECT
    x AS col_x,
    ps.id AS sector_id,
    ps.floor_height AS plane_z,
    ps.light_level AS sector_light,
    FALSE AS is_sky,
    'floor'::text AS plane,
    0::int AS source_priority,
    CASE WHEN np.depth_x IS NULL THEN FLOOR(rs.cy)::int + 1
         ELSE FLOOR(LEAST(rs.screen_h - 1.0, GREATEST(0.0,
           rs.cy - rs.focal * (ps.floor_height - c.pz) / np.depth_x
         )))::int + 1
    END AS y0,
    rs.screen_h - 1 AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  CROSS JOIN LATERAL generate_series(0, rs.screen_w - 1) AS x
  LEFT JOIN nearest_floor_panel np ON np.col_x = x
  UNION ALL
  -- Same for the ceiling.
  SELECT
    x AS col_x,
    ps.id AS sector_id,
    ps.ceil_height AS plane_z,
    ps.light_level AS sector_light,
    (ps.ceil_tex = 'F_SKY1') AS is_sky,
    'ceil'::text AS plane,
    0::int AS source_priority,
    0 AS y0,
    CASE WHEN np.depth_x IS NULL THEN CEIL(rs.cy)::int - 1
         ELSE CEIL(LEAST(rs.screen_h - 1.0, GREATEST(0.0,
           rs.cy - rs.focal * (ps.ceil_height - c.pz) / np.depth_x
         )))::int - 1
    END AS y1
  FROM render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  CROSS JOIN LATERAL generate_series(0, rs.screen_w - 1) AS x
  LEFT JOIN nearest_ceiling_panel np ON np.col_x = x
),
plane_spans AS (
  -- A floor is only ever the top surface, visible from above (pz > plane_z);
  -- a ceiling is only ever the underside, visible from below (pz < plane_z).
  SELECT ps.*
  FROM plane_spans_raw ps
  CROSS JOIN cam c
  -- Vanilla's one exception (R_StoreWallRange): a ceiling below the viewer is
  -- skipped as "below view plane" ONLY when it is not the sky flat.
  WHERE (ps.plane = 'floor' AND ps.plane_z < c.pz)
     OR (ps.plane = 'ceil'  AND (ps.plane_z > c.pz OR ps.is_sky))
),
plane_spans_deduped AS (
  -- The near-camera seed and the nearest wall's front plane describe the same surface over the same rows.
  -- Collapse identical spans of one surface (same column, sector, height and side) before they are
  -- expanded: ~2k span rows instead of ~90k pixel rows.
  SELECT col_x, sector_id, plane_z, plane, is_sky, y0, y1,
         MIN(sector_light)    AS sector_light,
         MIN(source_priority) AS source_priority
  FROM plane_spans
  WHERE y1 >= y0
  GROUP BY col_x, sector_id, plane_z, plane, is_sky, y0, y1
),
plane_span_tex AS (
  -- Everything about a span that is constant down its column, looked up once
  -- per span (~1-2k rows) instead of once per pixel (~27k): the sector's flat
  -- (or the sky), the texture's bytes, the column's ray and its sky column.
  -- CedarDB's version joined sectors, flats and the sky texture per pixel;
  -- in Postgres those three hash probes were most of the plane cost.
  SELECT ps.col_x, ps.sector_id, ps.plane_z, ps.plane, ps.y0, ps.y1,
         ps.sector_light, ps.source_priority,
         ps.is_sky AS span_is_sky,       -- the panel's view: sets the depth
         t.tex_name,
         (t.tex_name = 'F_SKY1') AS is_sky, -- the sector's flat: picks the sampler
         ft.palette_indices AS flat_pi,
         wt.palette_indices AS sky_pi, wt.width AS sky_w,
         (OCTET_LENGTH(ft.palette_indices) >= rs.flat_size * rs.flat_size) AS flat_whole,
         (wt.width >= rs.sky_columns::int
          AND OCTET_LENGTH(wt.palette_indices) >= wt.width * rs.sky_rows) AS sky_whole,
         t.tan_alpha,
         ((FLOOR(degrees(c.view_rad - ATAN(t.tan_alpha)) * (rs.sky_columns/rs.sky_degrees))::int
           % rs.sky_columns::int) + rs.sky_columns::int) % rs.sky_columns::int AS sky_u
  FROM plane_spans_deduped ps
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  JOIN sectors_lit s ON s.id = ps.sector_id AND s.map_id = rc.map_id
  CROSS JOIN LATERAL (
    SELECT CASE WHEN ps.plane = 'floor' THEN s.floor_tex ELSE s.ceil_tex END AS tex_name,
           (ps.col_x - rs.cx) / rs.focal AS tan_alpha
  ) t
  LEFT JOIN frame_flats ft
    ON t.tex_name <> 'F_SKY1' AND ft.name = t.tex_name
  CROSS JOIN (SELECT m.sky_texture AS name
              FROM maps m JOIN render_context rc2 ON rc2.map_id = m.map_id) sk
  LEFT JOIN frame_walltex wt
    ON t.tex_name = 'F_SKY1' AND wt.name = sk.name
),
plane_span_keyed AS (
  -- What the per-pixel stage below needs that does not change down a span,
  -- computed once per span: the depth numerator, the key bits other than
  -- depth, light and texel (see ranked_fragments), and the row of
  -- doom_zlight_lut its pixels' light comes from: the sector's light step
  -- (15 - clamp(floor(l/16) + e), the per-span part of doom_light_index),
  -- or the fixed light of the sky or of invulnerability. OFFSET 0 for the
  -- reason wall_spans gives: inlined, all of it -- and the sky column's ATAN
  -- in plane_span_tex -- would be evaluated per pixel.
  SELECT ps.*,
         rs.focal * (ps.plane_z - c.pz) AS depth_num,
         ((2::bigint - 0::bigint) << 32)
         | (LEAST(ps.source_priority::bigint, 3::bigint) << 30)
         | (LEAST(65535::bigint, GREATEST(0::bigint,
             (ps.sector_id::bigint*2
              + CASE WHEN ps.plane='floor' THEN 0 ELSE 1 END)::bigint + 32768)) << 14)
           AS key_hi,
         -- Sky is drawn unlit; invulnerability fixes the colormap.
         CASE WHEN ps.is_sky THEN 16 WHEN wr.invuln THEN 17
              ELSE 15 - LEAST(15, GREATEST(0, FLOOR(ps.sector_light::float8 / 16.0)::int
                                              + wr.extra_light))
         END * 128 AS light_row
  FROM plane_span_tex ps
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN weapon_runtime wr
  OFFSET 0
),
plane_rays AS (
  -- invert the wall projection: y_screen = cy - focal*(z-pz)/x_view
  -- => x_view (depth) = focal*(plane_z - pz)/(cy - y)
  -- One row per plane pixel. OFFSET 0 keeps this a subquery of its own, so
  -- depth_x is computed once per pixel: inlined, its expression would be
  -- copied into each of the seven places below that read it. Only the
  -- columns read below, for the reason fragments gives.
  SELECT r.col_x, r.y, r.span_is_sky, r.is_sky, r.key_hi, r.light_row,
         r.flat_pi, r.flat_whole, r.sky_pi, r.sky_w, r.sky_whole, r.sky_u, r.tan_alpha,
         -- Sky has no depth: plane_fragments indexes it by view angle and
         -- screen row. Give it one far sentinel.
         CASE WHEN r.span_is_sky THEN 1e7::float8
              ELSE r.depth_num / NULLIF(rs.cy - r.y, 0.0)
         END AS depth_x
  FROM (SELECT ps.col_x, ps.span_is_sky, ps.is_sky, ps.key_hi, ps.light_row,
               ps.flat_pi, ps.flat_whole, ps.sky_pi, ps.sky_w,
               ps.sky_whole, ps.sky_u, ps.tan_alpha, ps.depth_num,
               generate_series(ps.y0, ps.y1) AS y
        FROM plane_span_keyed ps) r
  CROSS JOIN render_settings rs
  OFFSET 0
),
plane_fragments AS (
  -- Inverse of the (now screen-correct) wall/sprite projection, straight to
  -- texture coordinates, then the flat's or the sky's texel, the zlight
  -- shade and the key.
  SELECT r.y * rs.screen_w + r.col_x AS pix,
         -- (depth_x is above zero here: the WHERE keeps only those and sky)
         ((LEAST(r.depth_x, 131071.0)*4096)::bigint << 34)
         | r.key_hi
         -- R_InitLightTables' zlight selection by distance step, looked up
         -- in a table the planner computes once (doom_zlight_lut).
         | (GET_BYTE(doom_zlight_lut(),
                     r.light_row + LEAST(127, FLOOR(r.depth_x / 16.0)::int))::bigint << 8)
         -- sample the sector's floor/ceiling flat, or the sky wall-texture for F_SKY1
         | (CASE
             -- In range by construction for a whole texture: one offset, no checks.
             WHEN NOT r.is_sky AND r.flat_whole
             THEN GET_BYTE(r.flat_pi, (uv.v_i * rs.flat_size + uv.u_i)::int)
             WHEN r.is_sky AND r.sky_whole
             THEN GET_BYTE(r.sky_pi, (uv.v_i * r.sky_w + uv.u_i)::int)
             WHEN NOT r.is_sky AND r.flat_pi IS NOT NULL
               AND (uv.v_i * rs.flat_size + uv.u_i) >= 0
               AND (uv.v_i * rs.flat_size + uv.u_i) < OCTET_LENGTH(r.flat_pi)
             THEN
               GET_BYTE(r.flat_pi, (uv.v_i * rs.flat_size + uv.u_i)::int)
             WHEN r.is_sky AND r.sky_pi IS NOT NULL THEN
               CASE
                 WHEN (uv.v_i * r.sky_w + uv.u_i) >= 0
                   AND (uv.v_i * r.sky_w + uv.u_i) < OCTET_LENGTH(r.sky_pi)
                 THEN GET_BYTE(r.sky_pi, (uv.v_i * r.sky_w + uv.u_i)::int)
                 ELSE 0
               END
             ELSE 0
           END)::bigint AS winner_key
  FROM plane_rays r
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN LATERAL (
    SELECT
      CASE WHEN r.is_sky
        -- sky pans with view angle only (x4 around a full turn, matching
        -- vanilla Doom's 90fov-per-quarter-texture sky scroll rate)
        THEN r.sky_u
        -- positive-modulo flat coordinates (64x64 repeating flats): with a
        -- power of two the modulo is a mask
        ELSE FLOOR(c.px + r.depth_x * c.cos_v + (r.tan_alpha * r.depth_x) * c.sin_v)::int
             & (rs.flat_size - 1)
      END AS u_i,
      CASE WHEN r.is_sky
        -- sky is drawn view-angle/row indexed
        -- row 100 (screen half-height) lines up with the texture's row 100
        THEN (r.y - rs.sky_horizon_y) & (rs.sky_rows - 1)
        ELSE FLOOR(c.py + r.depth_x * c.sin_v - (r.tan_alpha * r.depth_x) * c.cos_v)::int
             & (rs.flat_size - 1)
      END AS v_i
  ) uv
  WHERE r.span_is_sky OR r.depth_x > rs.near
),

-- Next up: Sprites.
-- In Doom, they're just called things.
-- Each thing is just a 2D sprite that always faces you (so no real 3D object).
-- Their BSP-resolved sector and initial state sprite are pre-materialized at load time
-- in render_things
-- We only have to do view projection, select the right sprite variant (depending on the direction),
-- do sparse opaque-pixel sampling, and do the depth resolve.
thing_view AS (
  SELECT
    t.id::bigint AS thing_id, t.x::real, t.y::real, t.angle,
    -- Sprite lump name never changes across a monster's own states.
    -- Only the frame letter changes. Vanilla Doom always keeps one 4-letter
    -- sprite per mobj type. It only ever changes for the terminal death
    -- sprite (e.g. exploding barrels: BAR1 -> BEXP).
    CASE WHEN COALESCE(d.explodes, FALSE) AND ai.state='die' THEN d.death_sprite
         WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
         THEN d.death_sprite ELSE rt.sprite END AS sprite,
    -- A gibbed corpse has a special frame (def. an 18+ game back in the day).
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN CASE WHEN h.health < -h.max_health AND d.xdeath_frame IS NOT NULL
                     THEN d.xdeath_frame ELSE d.death_frame END
         WHEN f.frame IS NOT NULL THEN f.frame
         ELSE rt.frame END AS frame,
    CASE WHEN h.alive = FALSE AND (ai.state IS NULL OR ai.state = 'dead')
           THEN d.death_fullbright
         WHEN f.frame IS NOT NULL THEN f.fullbright
         ELSE rt.fullbright END AS fullbright,
    CASE WHEN rt.spawn_ceiling THEN s.ceil_height - rt.thing_height
         -- a live floater is drawn where it hovers; a dead one has dropped
         WHEN d.floats AND COALESCE(h.alive, TRUE) THEN t.z
         ELSE s.floor_height END::real AS base_z,
    s.floor_height, s.ceil_height, s.light_level AS sector_light,
    (t.x - c.px) * COS(c.view_rad)
      + (t.y - c.py) * SIN(c.view_rad) AS depth,
    (t.x - c.px) * SIN(c.view_rad)
      - (t.y - c.py) * COS(c.view_rad) AS side,
    (((FLOOR((
        DEGREES(ATAN2(t.y - c.py, t.x - c.px))
        - t.angle + rs.rotation_offset
      ) / rs.rotation_span)::int % 8) + 8) % 8 + 1)::smallint AS wanted_rotation,
    COALESCE(d.fuzzy, FALSE) AS fuzz
  FROM render_things rt
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things t ON t.map_id = rt.map_id AND t.id = rt.thing_id
  LEFT JOIN thing_health h ON h.map_id = rt.map_id AND h.thing_id = rt.thing_id
  LEFT JOIN thing_combat_defs d ON d.thing_type = t.type
  -- Live AI state overrides the static spawn placement once a monster has
  -- been ticked (sector_id starts NULL and only gets set once it moves).
  LEFT JOIN monster_ai ai ON ai.map_id = rt.map_id AND ai.thing_id = rt.thing_id
  LEFT JOIN thing_ai_frames f ON f.thing_type = t.type AND f.state = ai.state
    AND f.seq_index = ai.seq_index
  -- Collected pickups stop rendering entirely
  LEFT JOIN picked_up_items pu ON pu.map_id = rt.map_id AND pu.thing_id = rt.thing_id
  JOIN sectors_lit s ON s.map_id = rt.map_id AND s.id = COALESCE(ai.sector_id, rt.sector_id)
  CROSS JOIN cam c
  WHERE rt.map_id = rc.map_id
    -- Single-player spawn filtering from Doom Thing options, gated by the
    -- client's selected difficulty (rc.skill_bit: 1/2/4, derived from the
    -- 0..4 skill).
    AND (t.flags & rc.skill_bit) <> 0
    AND (t.flags & 16) = 0
    AND pu.thing_id IS NULL
    -- Vanilla removes a barrel after BEXP E; other corpses remain visible.
    AND NOT (COALESCE(d.explodes, FALSE) AND ai.state='dead')
  UNION ALL
  SELECT
    -e.effect_id AS thing_id, e.x, e.y, 0::smallint,
    ed.sprite,
    -- One letter per tics_per_frame
    SUBSTRING(ed.frame_sequence
              FROM LEAST(LENGTH(ed.frame_sequence) - 1,
                         e.age / ed.tics_per_frame) + 1 FOR 1),
    ed.fullbright, e.z,
    s.floor_height, s.ceil_height, COALESCE(s.light_level, ps.light_level),
    (e.x - c.px) * COS(c.view_rad) + (e.y - c.py) * SIN(c.view_rad),
    (e.x - c.px) * SIN(c.view_rad) - (e.y - c.py) * COS(c.view_rad),
    0::smallint, FALSE
  FROM world_effects e
  CROSS JOIN render_context rc
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN effect_sprite_defs ed ON ed.effect_type = e.effect_type
  LEFT JOIN sectors_lit s ON s.map_id=e.map_id AND s.id=e.sector_id
  WHERE e.map_id=rc.map_id
  UNION ALL
  -- The other players of a deathmatch.
  -- A blur sphere makes them fuzzy like a spectre.
  SELECT
    ot.id::bigint, ot.x::real, ot.y::real, ot.angle,
    'PLAY'::varchar(4), op.sprite_frame, FALSE,
    s.floor_height::real, s.floor_height, s.ceil_height, s.light_level,
    (ot.x - c.px) * COS(c.view_rad) + (ot.y - c.py) * SIN(c.view_rad),
    (ot.x - c.px) * SIN(c.view_rad) - (ot.y - c.py) * COS(c.view_rad),
    (((FLOOR((DEGREES(ATAN2(ot.y - c.py, ot.x - c.px))
        - ot.angle + rs.rotation_offset) / rs.rotation_span)::int % 8)
        + 8) % 8 + 1)::smallint,
    (op.invis_tics > 0)
  FROM player_state op
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  JOIN things ot ON ot.map_id = op.map_id AND ot.id = op.player_thing_id
  JOIN sectors_lit s ON s.map_id = op.map_id AND s.id = op.sector_id
  CROSS JOIN cam c
  WHERE op.map_id = rc.map_id AND op.player_thing_id <> rc.player_thing_id
  UNION ALL
  SELECT
    -(1000000000000::bigint+mp.projectile_id) AS thing_id,
    mp.x,mp.y,DEGREES(ATAN2(mp.vy,mp.vx))::smallint,
    (CASE WHEN mp.state='fly' THEN pd.fly_sprite
          ELSE pd.impact_sprite END)::varchar(4),
    CASE
      WHEN mp.projectile_type='rocket' THEN
        CASE WHEN mp.state='fly' THEN 'A' WHEN mp.age<8 THEN 'B'
             WHEN mp.age<14 THEN 'C' ELSE 'D' END
      WHEN mp.projectile_type='plasma' THEN
        CASE WHEN mp.state='fly' THEN CASE WHEN (mp.age%12)<6 THEN 'A' ELSE 'B' END
             WHEN mp.age<4 THEN 'A' WHEN mp.age<8 THEN 'B'
             WHEN mp.age<12 THEN 'C' WHEN mp.age<16 THEN 'D' ELSE 'E' END
      WHEN mp.projectile_type='bfg' THEN
        CASE WHEN mp.state='fly' THEN CASE WHEN (mp.age%8)<4 THEN 'A' ELSE 'B' END
             WHEN mp.age<8 THEN 'A' WHEN mp.age<16 THEN 'B'
             WHEN mp.age<24 THEN 'C' WHEN mp.age<32 THEN 'D'
             WHEN mp.age<40 THEN 'E' ELSE 'F' END
      ELSE CASE WHEN mp.state='fly'
             THEN CASE WHEN (mp.age%8)<4 THEN 'A' ELSE 'B' END
             WHEN mp.age<5 THEN 'C' WHEN mp.age<10 THEN 'D' ELSE 'E' END
    END,
    TRUE,mp.z,
    COALESCE(s.floor_height,ps.floor_height),
    COALESCE(s.ceil_height,ps.ceil_height),
    COALESCE(s.light_level,ps.light_level),
    (mp.x-c.px)*COS(c.view_rad)+(mp.y-c.py)*SIN(c.view_rad),
    (mp.x-c.px)*SIN(c.view_rad)-(mp.y-c.py)*COS(c.view_rad),
    CASE WHEN mp.state='fly' THEN
      (((FLOOR((DEGREES(ATAN2(mp.y-c.py,mp.x-c.px))
          -DEGREES(ATAN2(mp.vy,mp.vx))+rs.rotation_offset)
          /rs.rotation_span)::int%8)+8)%8+1)::smallint
      ELSE 0::smallint END, FALSE
  FROM monster_projectiles mp
  CROSS JOIN render_context rc
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
  CROSS JOIN player_sector ps
  JOIN projectile_defs pd ON pd.projectile_type = mp.projectile_type
  LEFT JOIN sectors_lit s ON s.map_id=mp.map_id AND s.id=mp.sector_id
  WHERE mp.map_id=rc.map_id
),
thing_projected AS MATERIALIZED (
  -- Each thing in front of the camera with the sprite frame it shows. Its
  -- pixels are fetched in thing_spans, once it is known to be on screen.
  SELECT
    tv.*, sf.lump_name, sf.flipped, sf.width, sf.height,
    sf.left_offset, sf.top_offset,
    rs.focal / tv.depth AS scale,
    rs.cx + rs.focal * tv.side / tv.depth AS origin_x
  FROM thing_view tv
  CROSS JOIN render_settings rs
  CROSS JOIN LATERAL (
    SELECT f.*
    FROM sprite_frames f
    WHERE f.sprite = tv.sprite AND f.frame = tv.frame
      AND f.rotation IN (0, tv.wanted_rotation)
    ORDER BY CASE WHEN f.rotation = tv.wanted_rotation THEN 0 ELSE 1 END
    LIMIT 1
  ) sf
  WHERE tv.depth >= 4.0
    -- Coarse reject leaves room for wide sprites whose origin is off-screen.
    AND ABS(tv.side) <= tv.depth * 2.0
),
thing_bounds AS (
  SELECT
    tp.*,
    tp.origin_x - tp.scale * tp.left_offset AS x_left_f,
    tp.origin_x + tp.scale * (tp.width - tp.left_offset) AS x_right_f,
    rs.cy - tp.scale * (tp.base_z + tp.top_offset - c.pz) AS y_top_f,
    rs.cy - tp.scale
      * (tp.base_z + tp.top_offset - tp.height - c.pz) AS y_bottom_f
  FROM thing_projected tp
  CROSS JOIN render_settings rs
  CROSS JOIN cam c
),
thing_bounds_lit AS (
  -- A sprite's shade is per thing, not per pixel: one depth, one sector
  -- light. ~50 things instead of ~8,000 pixels through the light arithmetic.
  SELECT tb.*,
         CASE WHEN wr.invuln THEN rs.light_index_invuln
              WHEN tb.fullbright THEN 0
              ELSE doom_light_index(tb.sector_light, wr.extra_light,
                                    doom_light_scale(tb.depth))
         END AS base_light
  FROM thing_bounds tb
  CROSS JOIN weapon_runtime wr CROSS JOIN render_settings rs
),
thing_spans AS (
  -- A visible sprite's screen box and its player colour slot, once per
  -- thing. The sprite pixel stages are subqueries of their own (OFFSET 0) for
  -- the reason wall_spans gives: what is constant per thing, per column or
  -- per pixel is computed once at that level instead of wherever it is used.
  -- The sprite's pixels and mask, detoasted for the reason frame_walltex
  -- gives: once per visible thing, then sampled per pixel below.
  SELECT tb.*, mpl.slot AS mp_slot,
         (sl.pixels || ''::bytea) AS pixels, (sl.mask || ''::bytea) AS mask,
         GREATEST(0, FLOOR(tb.x_left_f)::int) AS x_lo,
         LEAST(rs.screen_w - 1, CEIL(tb.x_right_f)::int - 1) AS x_hi,
         GREATEST(0, FLOOR(tb.y_top_f)::int) AS y_lo,
         LEAST(rs.screen_h - 1, CEIL(tb.y_bottom_f)::int - 1) AS y_hi
  FROM thing_bounds_lit tb
  JOIN sprite_lumps sl ON sl.lump_name = tb.lump_name
  CROSS JOIN render_settings rs
  CROSS JOIN render_context rc
  LEFT JOIN mp_players mpl ON mpl.map_id = rc.map_id AND mpl.player_thing_id = tb.thing_id
  WHERE tb.x_right_f > 0 AND tb.x_left_f < rs.screen_w
    AND tb.y_bottom_f > 0 AND tb.y_top_f < rs.screen_h
  OFFSET 0
),
thing_columns AS (
  -- One row per screen column of a sprite, with the patch column it shows.
  SELECT c.thing_id, c.screen_x, c.depth, c.fuzz, c.base_light, c.mp_slot,
         c.pixels, c.mask, c.width, c.height, c.y_top_f, c.scale, c.y_lo, c.y_hi,
         CASE WHEN c.flipped THEN c.width - 1 - uu.raw_u ELSE uu.raw_u END AS col_off
  FROM (SELECT t.thing_id, t.depth, t.fuzz, t.base_light, t.mp_slot, t.pixels,
               t.mask, t.width, t.height, t.y_top_f, t.scale, t.y_lo, t.y_hi,
               t.flipped, t.x_left_f,
               generate_series(t.x_lo, t.x_hi) AS screen_x
        FROM thing_spans t) c
  CROSS JOIN LATERAL (
    SELECT LEAST(c.width - 1, GREATEST(0,
             FLOOR((c.screen_x - c.x_left_f) / c.scale)::int)) AS raw_u
  ) uu
  OFFSET 0
),
thing_texels AS (
  -- One row per pixel of a sprite's box, with its offset into the patch.
  SELECT p.thing_id, p.screen_x, p.screen_y, p.depth, p.fuzz, p.base_light,
         p.mp_slot, p.pixels, p.mask,
         LEAST(p.height - 1, GREATEST(0,
           FLOOR((p.screen_y - p.y_top_f) / p.scale)::int)) * p.width + p.col_off AS off
  FROM (SELECT c.thing_id, c.screen_x, c.depth, c.fuzz, c.base_light, c.mp_slot,
               c.pixels, c.mask, c.width, c.height, c.y_top_f, c.scale, c.col_off,
               generate_series(c.y_lo, c.y_hi) AS screen_y
        FROM thing_columns c) p
  OFFSET 0
),
thing_pixels AS (
  -- The box's opaque pixels.
  SELECT
    t.thing_id, t.screen_x AS x, t.screen_y AS y,
    t.depth, t.fuzz, t.base_light,
    -- R_InitTranslationTables: the PLAY sprite's green range (0x70..0x7F) is
    -- remapped per player: Slot 2 indigo (0x60), 3 brown (0x40), 4 red
    -- (0x20).
    CASE WHEN t.mp_slot > 1 AND px.raw BETWEEN 112 AND 127
         THEN px.raw - 112 + CASE t.mp_slot WHEN 2 THEN 96 WHEN 3 THEN 64 ELSE 32 END
         ELSE px.raw END AS palette_index
  FROM thing_texels t
  CROSS JOIN LATERAL (SELECT GET_BYTE(t.pixels, t.off) AS raw) px
  WHERE GET_BYTE(t.mask, t.off) <> 0
),
sprite_fragments AS (
  SELECT sp.y * rs.screen_w + sp.x AS pix,
         ((GREATEST(0.0::float8, LEAST(sp.depth, 131071.0))*4096)::bigint << 34)
         | ((2::bigint - 1::bigint) << 32)
         | (LEAST(0::bigint, 3::bigint) << 30)
         | (LEAST(65535::bigint, GREATEST(0::bigint, sp.thing_id + 32768)) << 14)
         -- Doom draws a Spectre with R_DrawFuzzColumn: the sprite's own colour is
         -- discarded and the pixel is re-read from the screen a row away through
         -- colormap 6, which looks like a shimmer. A set-based renderer resolves all
         -- pixels at once and has no finished screen to sample, so this instead
         -- keeps the silhouette and drives it to near-black with a per-pixel
         -- wobble.
         | ((CASE WHEN sp.fuzz THEN
               (26 + ((sp.x * 7 + sp.y * 13 + sp.depth::int) % 5))::int
             ELSE sp.base_light
             END)::bigint << 8)
         | sp.palette_index::bigint AS winner_key
  FROM thing_pixels sp
  CROSS JOIN render_settings rs
),

-- HU_Drawer: the pickup line, in the small STCFN font at the top-left of the
-- view. Only the glyphs of the message join ui_patch_pixels, and only while
-- one is up -- an empty message makes every CTE below empty.
message_glyphs AS (
  SELECT gs.i AS pos,
         substring(UPPER(pu.message) FROM gs.i FOR 1) AS ch
  FROM player_ui_state pu
  CROSS JOIN LATERAL generate_series(1, length(pu.message)) AS gs(i)
  WHERE pu.message IS NOT NULL AND pu.message_tics > 0
),
message_placed AS (
  -- HUlib_drawTextLine walks the line accumulating each glyph's own width; a
  -- space has no patch and advances by 4.
  SELECT g.pos, g.ch,
         CASE WHEN g.ch = ' ' THEN NULL
              ELSE 'STCFN' || LPAD(ASCII(g.ch)::text, 3, '0') END AS patch,
         SUM(CASE WHEN g.ch = ' ' THEN 4
                  ELSE COALESCE((SELECT p.width FROM ui_patches p
                                 WHERE p.name = 'STCFN'
                                    || LPAD(ASCII(g.ch)::text, 3, '0')), 4)
             END) OVER (ORDER BY g.pos ROWS BETWEEN UNBOUNDED PRECEDING
                                             AND 1 PRECEDING) AS pen
  FROM message_glyphs g
),
message_pixels AS (
  SELECT COALESCE(mp.pen, 0)::int + px.dx AS x, 1 + px.dy AS y,
         px.palette_index
  FROM message_placed mp
  JOIN ui_hud_pixels px ON px.name = mp.patch
  WHERE mp.patch IS NOT NULL
),
ranked_fragments AS (
  -- The whole resolve key packed into one bigint, every field oriented so
  -- that smaller wins: depth first, then wall > sprite > plane, then the
  -- lower source_priority, then stable_id to keep exact ties from depending
  -- on sort input order:
  --   (depth*4096 << 34) | ((2 - surface) << 32) | (source << 30)
  --   | (stable_id + 32768 << 14) | (light_index << 8) | palette_index
  -- with surface 2 for walls, 1 for sprites and 0 for planes. Each stream
  -- builds its own keys, the parts that are constant along a span once per
  -- span.
  SELECT pix, winner_key FROM fragments
  UNION ALL
  SELECT pix, winner_key FROM sprite_fragments
  UNION ALL
  SELECT pix, winner_key FROM plane_fragments
  -- The weapon and the pickup message are drawn over the view regardless of
  -- depth. CedarDB's version resolved the view first and then overlaid them
  -- with two joins over all 53760 pixels; here they join the same MIN as
  -- negative keys, which every view fragment (depth >= 0) loses to: the
  -- message beats the flash (layer 2), which beats the weapon (layer 1).
  UNION ALL
  SELECT p.y*rs.screen_w+p.x,
         ((-(p.layer::bigint + 1)) << 32)
         | (p.light_index::bigint << 8)
         | p.palette_index::bigint
  FROM psprite_lit p CROSS JOIN render_settings rs
  UNION ALL
  SELECT m.y*rs.screen_w+m.x, ((-8)::bigint << 32) | m.palette_index::bigint
  FROM message_pixels m CROSS JOIN render_settings rs
  WHERE m.x BETWEEN 0 AND rs.screen_w - 1 AND m.y BETWEEN 0 AND rs.screen_h - 1
),
resolved AS NOT MATERIALIZED (
  -- Nearest fragment per screen pixel: the first by key, which is MIN(key).
  -- A sort and a Unique cost less than a HashAggregate's per-row MIN, and
  -- leave the pixels in screen order, which the frame below reads without
  -- sorting them again. NOT MATERIALIZED: storing its 53,760 rows to read
  -- them back cost ~6 ms a frame on Lakebase. Only a frame with holes reads
  -- it twice, and runs the pixel stages again for that.
  SELECT DISTINCT ON (pix) pix, winner_key
  FROM ranked_fragments
  ORDER BY pix, winner_key
),
-- Shotgun psprites
psprite_layers AS (
  SELECT 1 AS layer, wr.sprite, wr.frame::char(1) AS frame,
         wr.sx::double precision AS sx, wr.sy::double precision AS sy,
         COALESCE(wr.fullbright, FALSE) AS fullbright
  FROM weapon_runtime wr
  UNION ALL
  SELECT 2, wr.flash_sprite, wr.flash_frame::char(1) AS frame,
         wr.sx, wr.sy, COALESCE(wr.flash_fullbright, TRUE)
  FROM weapon_runtime wr
  WHERE wr.flash_sprite IS NOT NULL AND wr.flash_frame IS NOT NULL
),
psprite_patches AS MATERIALIZED (
  SELECT p.*, sf.width, sf.height, sf.left_offset, sf.top_offset,
         (sl.pixels || ''::bytea) AS pixels, (sl.mask || ''::bytea) AS mask,
         p.sx - sf.left_offset AS x_left_f,
         p.sy - sf.top_offset + rs.cy - 100.0 - 0.5 AS y_top_f
  FROM psprite_layers p
  CROSS JOIN render_settings rs
  JOIN sprite_frames sf ON sf.sprite=p.sprite AND sf.frame=p.frame
    AND sf.rotation=0
  JOIN sprite_lumps sl ON sl.lump_name=sf.lump_name
),
psprite_pixels AS (
  -- The weapon's pixels, from select-list generate_series (see fragments)
  SELECT q.layer, q.x, q.y, q.fullbright,
         GET_BYTE(q.pixels, (q.y - q.y0)*q.width + (q.x - q.x0)) AS palette_index
  FROM (SELECT c.*, generate_series(GREATEST(0, c.y0),
                                    LEAST(rs.screen_h - 1, c.y0 + c.height - 1)) AS y
        FROM (SELECT p.layer, p.fullbright, p.pixels, p.mask, p.width, p.height,
                     FLOOR(p.x_left_f)::int AS x0, FLOOR(p.y_top_f)::int AS y0,
                     generate_series(GREATEST(0, FLOOR(p.x_left_f)::int),
                                     LEAST(rs.screen_w - 1, FLOOR(p.x_left_f)::int + p.width - 1)) AS x
              FROM psprite_patches p CROSS JOIN render_settings rs) c
        CROSS JOIN render_settings rs) q
  WHERE GET_BYTE(q.mask, (q.y - q.y0)*q.width + (q.x - q.x0)) <> 0
),
psprite_lit AS (
  -- Every psprite pixel with its layer's light; the top layer wins in
  -- ranked_fragments.
  SELECT p.layer,p.x,p.y,p.palette_index,
    CASE WHEN wr.invuln THEN rs.light_index_invuln
         WHEN p.fullbright THEN 0
         ELSE doom_light_index(ps.light_level, wr.extra_light,
                               rs.light_psprite_bias)
    END AS light_index
  FROM psprite_pixels p
  CROSS JOIN player_sector ps CROSS JOIN weapon_runtime wr
  CROSS JOIN render_settings rs
),
psprite_resolved AS (
  -- (only the debug overlay's pixel count reads this)
  SELECT DISTINCT x, y FROM psprite_lit
),
player_ui_state AS (
  SELECT ps.health, ps.alive, ps.pain_face_tics, ps.armor,
         ps.ammo_bullets, ps.ammo_shells, ps.ammo_rockets, ps.ammo_cells,
         ps.key_blue,ps.key_yellow,ps.key_red,
         ps.damage_count, ps.bonus_count, ps.radsuit_tics,
         ps.message, ps.message_tics, ps.backpack,
         wd.ammo_type AS current_ammo_type
  FROM player_state ps
  CROSS JOIN render_context rc
  LEFT JOIN player_weapons w ON w.map_id = ps.map_id
    AND w.player_thing_id = ps.player_thing_id
  LEFT JOIN weapon_defs wd ON wd.weapon_id = COALESCE(w.current_weapon, 2)
  WHERE ps.map_id = rc.map_id AND ps.player_thing_id = rc.player_thing_id
),
active_palette AS (
  -- ST_doPaletteStuff, verbatim:
  --   if (cnt)            palette = min((cnt+7)>>3, NUMREDPALS-1)   + STARTREDPALS
  --   else if (bonus)     palette = min((b+7)>>3, NUMBONUSPALS-1) + STARTBONUSPALS
  --   else if (ironfeet > 4*32 || ironfeet & 8)  palette = RADIATIONPAL
  --   else                palette = 0
  -- with STARTREDPALS 1, NUMREDPALS 8, STARTBONUSPALS 9, NUMBONUSPALS 4 and
  -- RADIATIONPAL 13. The & 8 is what makes the radiation suit's green blink
  -- as it runs out.
  SELECT CASE
    WHEN pu.damage_count > 0
      THEN LEAST(7, (pu.damage_count + 7) / 8) + 1
    WHEN pu.bonus_count > 0
      THEN LEAST(3, (pu.bonus_count + 7) / 8) + 9
    WHEN pu.radsuit_tics > 128 OR (pu.radsuit_tics & 8) <> 0
      THEN 13
    ELSE 0
  END::smallint AS pal
  FROM player_ui_state pu
),
weapon_ownership AS (
  SELECT slot.weapon_id,
         EXISTS (
           SELECT 1 FROM player_weapon_owned o CROSS JOIN render_context rc
           WHERE o.map_id=rc.map_id AND o.player_thing_id=rc.player_thing_id
             AND o.weapon_id=slot.weapon_id
         ) AS owned
  FROM generate_series(2,7) slot(weapon_id)
),
weapon_layers AS (
  -- Vanilla's ARMS panel shows weapon slots 2..7: gray while unavailable,
  -- yellow once owned. Fist/chainsaw share slot 1 and are not listed here.
  SELECT 2 AS layer,
         (CASE WHEN owned THEN 'STYSNUM' ELSE 'STGNUM' END)
           || weapon_id::text AS patch,
         111+((weapon_id-2)%3)*12 AS x,
         172+((weapon_id-2)/3)*10 AS y
  FROM weapon_ownership
),
ui_face AS (
  SELECT
    CASE
      WHEN NOT pu.alive THEN 'STFDEAD0'
      WHEN pu.pain_face_tics > 0 THEN
        'STFOUCH' || LEAST(4, GREATEST(0, (100 - GREATEST(0, LEAST(100, pu.health))) / 20))::text
      ELSE
        'STFST' || LEAST(4, GREATEST(0, (100 - GREATEST(0, LEAST(100, pu.health))) / 20))::text || '0'
    END AS face_patch
  FROM player_ui_state pu
),
status_bar AS NOT MATERIALIZED (
  SELECT
    rs.screen_h     AS top_y,
    rs.screen_h + 4 AS digit_y,
    90::int         AS health_right_x,
    221::int        AS armor_right_x,
    44::int         AS ammo_right_x,
    288::int        AS ammo_box_right_x,
    314::int        AS max_ammo_right_x,
    239::int        AS key_x,
    143::int        AS face_x,
    14::int         AS tall_digit_w,
    4::int          AS short_digit_w 
  FROM render_settings rs
),
health_digits AS (SELECT pu.health AS value, sb.health_right_x AS right_x
                  FROM player_ui_state pu CROSS JOIN status_bar sb),
armor_digits AS (SELECT pu.armor AS value, sb.armor_right_x AS right_x
                 FROM player_ui_state pu CROSS JOIN status_bar sb),
ammo_digits AS (
  SELECT
    CASE pu.current_ammo_type
      WHEN 'bullets' THEN pu.ammo_bullets WHEN 'shells' THEN pu.ammo_shells
      WHEN 'rockets' THEN pu.ammo_rockets WHEN 'cells' THEN pu.ammo_cells
    END AS value,
    sb.ammo_right_x AS right_x
  FROM player_ui_state pu CROSS JOIN status_bar sb
  WHERE pu.current_ammo_type IS NOT NULL
),
-- The small always-visible sub-box showing all 4 ammo types at once, independent of which
-- weapon is currently equipped.
ammo_type_values AS (
  SELECT pu.ammo_bullets AS value, sb.ammo_box_right_x AS right_x, 173 AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_shells, sb.ammo_box_right_x, 179
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_rockets, sb.ammo_box_right_x, 185
  FROM player_ui_state pu CROSS JOIN status_bar sb
  UNION ALL
  SELECT pu.ammo_cells, sb.ammo_box_right_x, 191
  FROM player_ui_state pu CROSS JOIN status_bar sb
),
ammo_max_values AS (
  SELECT (CASE WHEN pu.backpack THEN ad.backpack_cap ELSE ad.cap END) AS value,
         sb.max_ammo_right_x AS right_x,
         (CASE ad.ammo_type WHEN 'bullets' THEN 173 WHEN 'shells' THEN 179
                            WHEN 'rockets' THEN 185 ELSE 191 END) AS y
  FROM player_ui_state pu CROSS JOIN status_bar sb
  CROSS JOIN ammo_defs ad
),
key_layers AS (
  SELECT 1 AS layer,'STKEYS0'::text AS patch,sb.key_x AS x,171 AS y
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_blue
  UNION ALL SELECT 1,'STKEYS1',sb.key_x,181
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_yellow
  UNION ALL SELECT 1,'STKEYS2',sb.key_x,191
  FROM player_ui_state CROSS JOIN status_bar sb WHERE key_red
),
digit_layers AS (
  -- Digits are right-aligned ending at right_x, one row of generate_series
  -- per character position. An integer's text is at most 11 characters, so
  -- the series runs to 11 and the WHERE keeps the real ones: the same rows,
  -- but a series bounded by length() is estimated at 1000 rows a call, which
  -- made the planner size the status bar's joins for a million pixels and
  -- spill them through 16 temp-file batches.
  SELECT 1 AS layer,
    'STTNUM' || substring(hd.value::text FROM gs.i FOR 1) AS patch,
    hd.right_x - (length(hd.value::text) - gs.i + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM health_digits hd CROSS JOIN status_bar sb
  CROSS JOIN generate_series(1, 11) AS gs(i)
  WHERE gs.i <= length(hd.value::text)
  UNION ALL
  SELECT 1, 'STTNUM' || substring(ad.value::text FROM gs.i FOR 1) AS patch,
    ad.right_x - (length(ad.value::text) - gs.i + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM armor_digits ad CROSS JOIN status_bar sb
  CROSS JOIN generate_series(1, 11) AS gs(i)
  WHERE gs.i <= length(ad.value::text)
  UNION ALL
  SELECT 1, 'STTNUM' || substring(am.value::text FROM gs.i FOR 1) AS patch,
    am.right_x - (length(am.value::text) - gs.i + 1) * sb.tall_digit_w AS x,
    sb.digit_y AS y
  FROM ammo_digits am CROSS JOIN status_bar sb
  CROSS JOIN generate_series(1, 11) AS gs(i)
  WHERE gs.i <= length(am.value::text)
  UNION ALL
  SELECT 1, 'STYSNUM' || substring(at.value::text FROM gs.i FOR 1) AS patch,
    at.right_x - (length(at.value::text) - gs.i + 1) * sb.short_digit_w AS x,
    at.y
  FROM ammo_type_values at CROSS JOIN status_bar sb
  CROSS JOIN generate_series(1, 11) AS gs(i)
  WHERE gs.i <= length(at.value::text)
  UNION ALL
  SELECT 1, 'STYSNUM' || substring(mx.value::text FROM gs.i FOR 1) AS patch,
    mx.right_x - (length(mx.value::text) - gs.i + 1) * sb.short_digit_w AS x,
    mx.y
  FROM ammo_max_values mx CROSS JOIN status_bar sb
  CROSS JOIN generate_series(1, 11) AS gs(i)
  WHERE gs.i <= length(mx.value::text)
),
ui_layers AS (
  SELECT layer, patch, x, y FROM digit_layers
  UNION ALL SELECT layer,patch,x,y FROM key_layers
  UNION ALL SELECT layer,patch,x,y FROM weapon_layers
  UNION ALL SELECT 1, face_patch, sb.face_x, sb.top_y
  FROM ui_face CROSS JOIN status_bar sb
),
ui_layer_patches AS MATERIALIZED (
  -- The ~28 patches the bar shows, placed: MATERIALIZED, or the planner
  -- reads their pixels first and looks each pixel's patch up again.
  SELECT l.layer,l.patch,l.x-p.left_offset AS dest_x,
         l.y-p.top_offset AS dest_y
  FROM ui_layers l
  JOIN ui_patches p ON p.name = l.patch
),
ui_pixels AS (
  SELECT ulp.layer,ulp.dest_x+px.dx AS x,ulp.dest_y+px.dy AS y,
         px.palette_index
  FROM ui_layer_patches ulp
  -- Each patch's own pixels by index: a few dozen probes instead of a hash
  -- join reading all 39,000 of the status bar art's. OFFSET 0 keeps the
  -- planner from turning it back into that join.
  CROSS JOIN LATERAL (SELECT p.dx, p.dy, p.palette_index FROM ui_hud_pixels p
                      WHERE p.name = ulp.patch OFFSET 0) px
),
ui_resolved AS (
  -- ARG_MAX(palette_index, layer) in CedarDB; layer and index packed into one
  -- MAX here. Only the pixels on the bar, numbered in its screen order: the
  -- grouping's sort is then the order the splice reads them in.
  SELECT (u.y - rs.screen_h) * rs.screen_w + u.x AS pix,
         (MAX(u.layer*256+u.palette_index)%256) AS palette_index
  FROM ui_pixels u CROSS JOIN render_settings rs
  WHERE u.x BETWEEN 0 AND rs.screen_w - 1
    AND u.y BETWEEN rs.screen_h AND rs.screen_h + 31
  GROUP BY 1
),
ui_overlay AS (
  -- The overlay's pixels, each in light level 0 of this frame's palette,
  -- read out of a string through a scalar subquery: joined, the palette
  -- was a nested loop per pixel.
  SELECT ur.pix,
         substring((SELECT pb.b FROM palette_level0 pb)
                   FROM ur.palette_index * octet_length('\x000000'::bytea) + 1
                   FOR octet_length('\x000000'::bytea)) AS rgb
  FROM ui_resolved ur
),
ui_bar_static AS MATERIALIZED (
  -- The bar's own art in this frame's palette, made at load time
  -- (ui_bar_bytes), and detoasted once here for the reason frame_walltex
  -- gives. No player, no palette, no bar.
  SELECT ub.rgb || ''::bytea AS b
  FROM active_palette ap
  JOIN ui_bar_bytes ub ON ub.pal = ap.pal
),
ui_colored AS (
  -- The static bar with the overlay spliced in: per overlay pixel, in screen
  -- order, the static run since the last one and then its own colour. About
  -- 2,000 pieces instead of a row, a join and a sort per pixel of the bar's
  -- 10,240.
  SELECT CASE WHEN o.n = 0 THEN st.b
              ELSE o.b || substring(st.b FROM (o.last_pix + 1) * pb.bpp + 1) END AS b
  FROM ui_bar_static st
  CROSS JOIN palette_level0 pb
  CROSS JOIN LATERAL (
    SELECT count(*) AS n, MAX(v.pix) AS last_pix,
           string_agg(substring(st.b FROM (v.prev + 1) * pb.bpp + 1
                                FOR (v.pix - v.prev - 1) * pb.bpp)
                      || COALESCE(v.rgb, substring(st.b FROM v.pix * pb.bpp + 1 FOR pb.bpp)),
                      ''::bytea ORDER BY v.pix) AS b
    FROM (SELECT o.pix, o.rgb, LAG(o.pix, 1, -1) OVER (ORDER BY o.pix) AS prev
          FROM ui_overlay o) v
  ) o
),
palette_level0 AS MATERIALIZED (
  -- Light level 0 alone (768 bytes), for the status bar's overlay. A join
  -- can copy its rows, and the whole 49 KB palette string with them: that
  -- was 370 ms over the bar's 10240 pixels.
  SELECT substring(b FROM 1 FOR 256 * bpp) AS b, bpp FROM palette_bytes
),

palette_bytes AS MATERIALIZED (
  -- This frame's COLORMAP x PLAYPAL as one string: entry (light, index) at
  -- offset (light*256 + index) * bpp. A substring per pixel replaces
  -- CedarDB's join of every pixel against the colormap. The string is made
  -- once per palette at load time (colormap_bytes): built here, it was a
  -- sort and an aggregate of 8,704 rows every frame. (No player, or a
  -- palette the WAD lacks: all black.) || '' detoasts it once, for the
  -- reason frame_walltex gives.
  SELECT CASE WHEN cb.pal IS NULL THEN
           decode(repeat(encode('\x000000'::bytea, 'hex'), 64 * 256), 'hex')
         ELSE cb.rgb || ''::bytea END AS b,
         octet_length('\x000000'::bytea) AS bpp
  FROM (SELECT) one
  LEFT JOIN active_palette ap ON TRUE
  LEFT JOIN colormap_bytes cb ON cb.pal = ap.pal
),
view_colored AS NOT MATERIALIZED (
  -- Resolve COLORMAP on the view's pixels, in resolved's (screen) order. The
  -- palette is read through scalar subqueries, evaluated once a frame: a join
  -- would cost a pass per pixel and lose the order. The entry's number,
  -- light * 256 + texel, is the key's low 14 bits as they are; a pixel's
  -- size in bytes is a constant (the indexed renderer's is 1).
  SELECT r.pix,
         substring((SELECT pb.b FROM palette_bytes pb)
                   FROM (r.winner_key & 16383)::int * octet_length('\x000000'::bytea) + 1
                   FOR octet_length('\x000000'::bytea)) AS rgb
  FROM resolved r
),
view_holes AS (
  -- Any view pixel no fragment reached. The pipeline aims to cover all
  -- screen_w*screen_h of them and normally does, but coverage depends on
  -- per-column clip arithmetic over a float camera pose (about one pose in
  -- fifty leaves a few pixels), and a pose that leaves even one pixel
  -- uncovered used to truncate the packed frame and fail the whole render.
  -- frame paints them black itself; this is the debug overlay's count of
  -- them (render_stats_tail.sql).
  SELECT g AS pix, '\x000000'::bytea AS rgb
  FROM render_settings rs
  CROSS JOIN LATERAL generate_series(0, rs.screen_w * rs.screen_h - 1) AS g
  WHERE NOT EXISTS (SELECT 1 FROM resolved r WHERE r.pix = g)
),
-- @stats-cut: doom_sql.prepare_render_stats() splices its own counting
-- projection in here, so the debug overlay's row counts are always measured
-- against this exact pipeline instead of a hand-kept copy of it.
frame AS (
  -- The 3D view owns rows 0..screen_h-1 and the status bar rows
  -- screen_h..199, so the frame is the view's pixels in order followed by
  -- the bar's. The view arrives in order from resolved; its count is taken
  -- in the same pass, and only a short view pays for the holes: every pixel
  -- number joined to the view, which runs the pixel stages again (resolved
  -- is not materialized), with black where nothing reached.
  SELECT CASE WHEN v.n = rs.screen_w * rs.screen_h THEN v.b
              ELSE (SELECT string_agg(COALESCE(vc.rgb, '\x000000'::bytea), ''::bytea
                                      ORDER BY g.pix)
                    FROM generate_series(0, rs.screen_w * rs.screen_h - 1) AS g(pix)
                    LEFT JOIN view_colored vc ON vc.pix = g.pix)
         END
         || COALESCE(u.b, ''::bytea) AS frame_rgb
  FROM (SELECT string_agg(rgb, ''::bytea ORDER BY pix) AS b, count(*) AS n
        FROM view_colored) v
  CROSS JOIN (SELECT (SELECT b FROM ui_colored) AS b) u
  CROSS JOIN render_settings rs
)
SELECT frame_rgb FROM frame;
