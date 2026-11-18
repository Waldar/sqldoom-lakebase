-- Template of the frame view api_frame_idx_slot<slot>_m<map> (one per map and
-- player slot). doom.create_frame_views() fills in {name}, {map_id}, {slot}
-- and {thing_id} (the slot's player start, things.id) and creates the views.
CREATE OR REPLACE FUNCTION doom.frame_view_template_api_frame_idx()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $template$SELECT $view$CREATE OR REPLACE VIEW doom.{name} AS
 WITH RECURSIVE render_context AS NOT MATERIALIZED (
         SELECT {map_id} AS map_id,
            {thing_id} AS player_thing_id,
            ( SELECT mm.skill
                   FROM mp_match mm
                 LIMIT 1) AS skill,
                CASE
                    WHEN (( SELECT mm.skill
                       FROM mp_match mm
                     LIMIT 1) <= 1) THEN 1
                    WHEN (( SELECT mm.skill
                       FROM mp_match mm
                     LIMIT 1) = 2) THEN 2
                    ELSE 4
                END AS skill_bit
        ), pos AS NOT MATERIALIZED (
         SELECT (mp.pose_x)::double precision AS x,
            (mp.pose_y)::double precision AS y,
            (mp.pose_z)::double precision AS z,
            (mp.pose_angle)::double precision AS angle
           FROM mp_players mp
          WHERE ((mp.map_id = {map_id}) AND (mp.slot = {slot}) AND (mp.role_name = doom_caller()))
        ), frame_clock AS (
         SELECT COALESCE(max(ps.level_tics), (0)::bigint) AS t
           FROM (player_state ps
             CROSS JOIN render_context rc)
          WHERE ((ps.map_id = rc.map_id) AND (ps.player_thing_id = rc.player_thing_id))
        ), animated_light AS (
         SELECT k.sector_id,
            (LEAST(((255)::smallint)::bigint, GREATEST(((0)::smallint)::bigint,
                CASE k.special
                    WHEN 2 THEN (
                    CASE
                        WHEN (((k.t + k.phase) % (20)::bigint) < 5) THEN k.base_light
                        ELSE k.dark_light
                    END)::bigint
                    WHEN 13 THEN (
                    CASE
                        WHEN ((k.t % (20)::bigint) < 5) THEN k.base_light
                        ELSE k.dark_light
                    END)::bigint
                    WHEN 3 THEN (
                    CASE
                        WHEN (((k.t + k.phase) % (40)::bigint) < 5) THEN k.base_light
                        ELSE k.dark_light
                    END)::bigint
                    WHEN 12 THEN (
                    CASE
                        WHEN ((k.t % (40)::bigint) < 5) THEN k.base_light
                        ELSE k.dark_light
                    END)::bigint
                    WHEN 1 THEN (
                    CASE
                        WHEN ((((k.sector_id * '2654435761'::bigint) + (k.t / 4)) % (8)::bigint) < 2) THEN k.dark_light
                        ELSE k.base_light
                    END)::bigint
                    WHEN 17 THEN (GREATEST((k.dark_light)::integer, (k.base_light - (((((((((k.t / 3) % (1000)::bigint) * ((k.t / 3) % (1000)::bigint)) * 1103515245) + (k.sector_id * 40503)) % (1009)::bigint) % (4)::bigint) * GREATEST(1, ((k.base_light - k.dark_light) / 4))))::integer)))::bigint
                    WHEN 8 THEN (k.dark_light + (8 *
                    CASE
                        WHEN (((k.t + k.phase) % ((2 * k.glow_steps))::bigint) < k.glow_steps) THEN ((k.t + k.phase) % ((2 * k.glow_steps))::bigint)
                        ELSE ((2 * k.glow_steps) - ((k.t + k.phase) % ((2 * k.glow_steps))::bigint))
                    END))
                    ELSE (k.base_light)::bigint
                END)))::smallint AS light_level
           FROM ( SELECT f.sector_id,
                    f.base_light,
                    f.dark_light,
                    f.special,
                    ((f.sector_id * 7919) % 64) AS phase,
                    GREATEST(1, ((f.base_light - f.dark_light) / 8)) AS glow_steps,
                    fc.t
                   FROM ((sector_light_fx f
                     CROSS JOIN render_context rc)
                     CROSS JOIN frame_clock fc)
                  WHERE (f.map_id = rc.map_id)) k
        ), sectors_lit AS (
         SELECT s.map_id,
            s.id,
            s.floor_height,
            s.ceil_height,
            s.spawn_floor_height,
            s.spawn_ceil_height,
            s.spawn_floor_tex,
            s.spawn_light_level,
            s.floor_tex,
            s.ceil_tex,
            COALESCE(a.light_level, s.light_level) AS light_level,
            s.special,
            s.tag
           FROM ((sectors s
             CROSS JOIN render_context rc)
             LEFT JOIN animated_light a ON ((a.sector_id = s.id)))
          WHERE (s.map_id = rc.map_id)
        ), scrolling_segs AS (
         SELECT ld.id AS linedef_id
           FROM (linedefs ld
             CROSS JOIN render_context rc)
          WHERE ((ld.map_id = rc.map_id) AND ld.scrolls)
        ), render_settings AS NOT MATERIALIZED (
         SELECT b.screen_w,
            b.screen_h,
            b.fov_rad,
            (((b.screen_w)::numeric / 2.0))::double precision AS cx,
            (((b.screen_h)::numeric / 2.0))::double precision AS cy,
            ((((b.screen_w)::numeric / 2.0))::double precision / tan((b.fov_rad / (2.0)::double precision))) AS focal,
            tan((b.fov_rad / (2.0)::double precision)) AS tan_half_fov,
            (0.001)::double precision AS near,
            ((16.0)::double precision * ((((b.screen_w)::numeric / 2.0))::double precision / tan((b.fov_rad / (2.0)::double precision)))) AS max_plane_depth,
            (202.5)::double precision AS rotation_offset,
            (45.0)::double precision AS rotation_span,
            32 AS light_index_invuln,
            23 AS light_psprite_bias,
            (256.0)::double precision AS sky_columns,
            (90.0)::double precision AS sky_degrees,
            128 AS sky_rows,
            100 AS sky_horizon_y,
            64 AS flat_size
           FROM ( SELECT 320 AS screen_w,
                    168 AS screen_h,
                    radians((90.0)::double precision) AS fov_rad) b
        ), frame_flats AS MATERIALIZED (
         SELECT f.name,
            (f.palette_indices || '\x'::bytea) AS palette_indices
           FROM flat_textures f
          WHERE (f.name IN ( SELECT s.floor_tex
                   FROM sectors_lit s
                UNION
                 SELECT s.ceil_tex
                   FROM sectors_lit s))
        ), cam AS NOT MATERIALIZED (
         SELECT pos.x AS px,
            pos.y AS py,
            pos.z AS pz,
            ( SELECT radians(p.angle) AS radians
                   FROM pos p) AS view_rad,
            ( SELECT cos(radians(p.angle)) AS cos
                   FROM pos p) AS cos_v,
            ( SELECT sin(radians(p.angle)) AS sin
                   FROM pos p) AS sin_v,
            ( SELECT cos((- radians(p.angle))) AS cos
                   FROM pos p) AS cos_nv,
            ( SELECT sin((- radians(p.angle))) AS sin
                   FROM pos p) AS sin_nv
           FROM pos
        ), weapon_runtime AS (
         SELECT rc.map_id,
            rc.player_thing_id,
            COALESCE(w.sx, (1)::real) AS sx,
            COALESCE(w.sy, (32)::real) AS sy,
                CASE
                    WHEN (COALESCE(ps2.light_amp_tics, 0) > 0) THEN 16
                    ELSE (COALESCE(w.flash_seq_index, '-1'::integer) + 1)
                END AS extra_light,
            (COALESCE(ps2.invuln_tics, 0) > 0) AS invuln,
            wd.sprite,
            wd.flash_sprite,
                CASE
                    WHEN (COALESCE(w.state, 'ready'::weapon_state) = ANY (ARRAY['up'::weapon_state, 'down'::weapon_state])) THEN rf.frame
                    ELSE mf.frame
                END AS frame,
                CASE
                    WHEN (COALESCE(w.state, 'ready'::weapon_state) = ANY (ARRAY['up'::weapon_state, 'down'::weapon_state])) THEN rf.fullbright
                    ELSE mf.fullbright
                END AS fullbright,
            ff.frame AS flash_frame,
            ff.fullbright AS flash_fullbright
           FROM ((((((render_context rc
             LEFT JOIN player_weapons w ON (((w.map_id = rc.map_id) AND (w.player_thing_id = rc.player_thing_id))))
             LEFT JOIN player_state ps2 ON (((ps2.map_id = rc.map_id) AND (ps2.player_thing_id = rc.player_thing_id))))
             JOIN weapon_defs wd ON ((wd.weapon_id = COALESCE(w.current_weapon, 2))))
             LEFT JOIN weapon_frames rf ON (((rf.weapon_id = wd.weapon_id) AND (rf.state = 'ready'::weapon_state) AND (rf.seq_index = 0))))
             LEFT JOIN weapon_frames mf ON (((mf.weapon_id = wd.weapon_id) AND (mf.state = COALESCE(w.state, 'ready'::weapon_state)) AND (mf.seq_index = COALESCE(w.seq_index, 0)))))
             LEFT JOIN weapon_frames ff ON (((ff.weapon_id = wd.weapon_id) AND (ff.state = 'flash'::weapon_state) AND (ff.seq_index = w.flash_seq_index))))
        ), visible_children AS MATERIALIZED (
         SELECT nc.map_id,
            nc.node_id,
            nc.side,
            ((nc.side)::text =
                CASE
                    WHEN (((((p.x - (n.x)::double precision))::bigint * (n.dy)::bigint) - (((p.y - (n.y)::double precision))::bigint * (n.dx)::bigint)) > 0) THEN 'R'::text
                    ELSE 'L'::text
                END) AS is_front,
            (((c.px >= (nc.bbox_left)::double precision) AND (c.px <= (nc.bbox_right)::double precision) AND ((c.py >= (nc.bbox_bottom)::double precision) AND (c.py <= (nc.bbox_top)::double precision))) OR ((((((c.sin_nv - (rs.tan_half_fov * c.cos_nv)) * (
                CASE
                    WHEN ((c.sin_nv - (rs.tan_half_fov * c.cos_nv)) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + ((c.cos_nv + (rs.tan_half_fov * c.sin_nv)) * (
                CASE
                    WHEN ((c.cos_nv + (rs.tan_half_fov * c.sin_nv)) >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + ((((- c.px) * c.sin_nv) - (c.py * c.cos_nv)) + (rs.tan_half_fov * ((c.px * c.cos_nv) - (c.py * c.sin_nv))))) <= (0.5)::double precision) AND ((((((- c.sin_nv) - (rs.tan_half_fov * c.cos_nv)) * (
                CASE
                    WHEN (((- c.sin_nv) - (rs.tan_half_fov * c.cos_nv)) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + (((- c.cos_nv) + (rs.tan_half_fov * c.sin_nv)) * (
                CASE
                    WHEN (((- c.cos_nv) + (rs.tan_half_fov * c.sin_nv)) >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + (((c.px * c.sin_nv) + (c.py * c.cos_nv)) + (rs.tan_half_fov * ((c.px * c.cos_nv) - (c.py * c.sin_nv))))) <= (0.5)::double precision) AND (((((- c.cos_nv) * (
                CASE
                    WHEN ((- c.cos_nv) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + (c.sin_nv * (
                CASE
                    WHEN (c.sin_nv >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + ((rs.near + (c.px * c.cos_nv)) - (c.py * c.sin_nv))) <= (0.5)::double precision))) AS keep
           FROM (((((node_children nc
             JOIN nodes n ON (((n.map_id = nc.map_id) AND (n.id = nc.node_id))))
             CROSS JOIN pos p)
             CROSS JOIN cam c)
             CROSS JOIN render_settings rs)
             CROSS JOIN render_context rctx)
          WHERE (nc.map_id = rctx.map_id)
        ), bsp_order AS (
         SELECT s.ssector_id,
            row_number() OVER (ORDER BY s.sort_key) AS bsp_seq
           FROM ( SELECT st.ssector_id,
                    sum(
                        CASE
                            WHEN vc.is_front THEN (0)::bigint
                            ELSE ((1)::bigint << (40 - st.depth))
                        END) AS sort_key,
                    bool_and(vc.keep) AS visible
                   FROM ((node_path_steps st
                     CROSS JOIN render_context rc)
                     JOIN visible_children vc ON (((vc.node_id = st.node_id) AND (vc.side = st.side))))
                  WHERE (st.map_id = rc.map_id)
                  GROUP BY st.ssector_id) s
          WHERE s.visible
        ), player_sector AS (
         SELECT sec.map_id,
            sec.id,
            sec.floor_height,
            sec.ceil_height,
            sec.spawn_floor_height,
            sec.spawn_ceil_height,
            sec.spawn_floor_tex,
            sec.spawn_light_level,
            sec.floor_tex,
            sec.ceil_tex,
            sec.light_level,
            sec.special,
            sec.tag
           FROM (((bsp_order bo
             JOIN render_context rc ON (true))
             JOIN render_segs sg ON (((sg.map_id = rc.map_id) AND (sg.ssector_id = bo.ssector_id))))
             JOIN sectors_lit sec ON (((sec.map_id = rc.map_id) AND (sec.id = sg.fsec))))
          WHERE (bo.bsp_seq = 1)
          ORDER BY sg.seg_id
         LIMIT 1
        ), segs_with_verts AS (
         SELECT s.seg_id,
            s.direction,
            s.linedef_id,
            s.map_id,
            s.x1,
            s.y1,
            s.x2,
            s.y2,
            s.seg_u1,
            s.seg_u2,
            bo.bsp_seq
           FROM (((render_segs s
             JOIN bsp_order bo ON ((bo.ssector_id = s.ssector_id)))
             CROSS JOIN pos)
             CROSS JOIN render_context rc)
          WHERE ((s.map_id = rc.map_id) AND (((((s.x2 - s.x1))::bigint * ((pos.y - (s.y1)::double precision))::bigint) - (((s.y2 - s.y1))::bigint * ((pos.x - (s.x1)::double precision))::bigint)) < 0))
        ), viewspace AS (
         SELECT s.seg_id,
            s.direction,
            s.linedef_id,
            s.map_id,
            s.seg_u1,
            s.seg_u2,
            s.bsp_seq,
            ((((s.x1)::double precision - c.px) * c.cos_nv) - (((s.y1)::double precision - c.py) * c.sin_nv)) AS x1,
            (- ((((s.x1)::double precision - c.px) * c.sin_nv) + (((s.y1)::double precision - c.py) * c.cos_nv))) AS y1,
            ((((s.x2)::double precision - c.px) * c.cos_nv) - (((s.y2)::double precision - c.py) * c.sin_nv)) AS x2,
            (- ((((s.x2)::double precision - c.px) * c.sin_nv) + (((s.y2)::double precision - c.py) * c.cos_nv))) AS y2
           FROM (segs_with_verts s
             CROSS JOIN cam c)
        ), visible AS (
         SELECT viewspace.seg_id,
            viewspace.direction,
            viewspace.linedef_id,
            viewspace.map_id,
            viewspace.seg_u1,
            viewspace.seg_u2,
            viewspace.bsp_seq,
            viewspace.x1,
            viewspace.y1,
            viewspace.x2,
            viewspace.y2
           FROM viewspace
          WHERE ((viewspace.x1 > (0)::double precision) OR (viewspace.x2 > (0)::double precision))
        ), clipped AS (
         SELECT visible.seg_id,
            visible.direction,
            visible.linedef_id,
            visible.map_id,
            visible.seg_u1,
            visible.seg_u2,
            visible.bsp_seq,
                CASE
                    WHEN (visible.x1 < render_settings.near) THEN render_settings.near
                    ELSE visible.x1
                END AS cx1,
                CASE
                    WHEN (visible.x1 < render_settings.near) THEN (visible.y1 + (((render_settings.near - visible.x1) * (visible.y2 - visible.y1)) / (visible.x2 - visible.x1)))
                    ELSE visible.y1
                END AS cy1,
                CASE
                    WHEN (visible.x2 < render_settings.near) THEN render_settings.near
                    ELSE visible.x2
                END AS cx2,
                CASE
                    WHEN (visible.x2 < render_settings.near) THEN (visible.y2 + (((render_settings.near - visible.x2) * (visible.y1 - visible.y2)) / (visible.x1 - visible.x2)))
                    ELSE visible.y2
                END AS cy2
           FROM visible,
            render_settings
        ), projected AS (
         SELECT clipped.seg_id,
            clipped.direction,
            clipped.linedef_id,
            clipped.map_id,
            clipped.cx1,
            clipped.cy1,
            clipped.cx2,
            clipped.cy2,
            (render_settings.cx + (render_settings.focal * (clipped.cy1 / clipped.cx1))) AS screen_x1,
            (render_settings.cx + (render_settings.focal * (clipped.cy2 / clipped.cx2))) AS screen_x2,
            ((1.0)::double precision / clipped.cx1) AS invx1,
            ((1.0)::double precision / clipped.cx2) AS invx2,
            clipped.seg_u1,
            clipped.seg_u2,
            clipped.bsp_seq
           FROM clipped,
            render_settings
        ), on_screen AS (
         SELECT p.seg_id,
            p.direction,
            p.linedef_id,
            p.map_id,
            p.cx1,
            p.cy1,
            p.cx2,
            p.cy2,
            p.screen_x1,
            p.screen_x2,
            p.invx1,
            p.invx2,
            p.seg_u1,
            p.seg_u2,
            p.bsp_seq
           FROM (projected p
             CROSS JOIN render_settings rs)
          WHERE ((GREATEST(p.screen_x1, p.screen_x2) >= (0)::double precision) AND (LEAST(p.screen_x1, p.screen_x2) < (rs.screen_w)::double precision))
        ), heights AS (
         SELECT p.seg_id,
            p.direction,
            p.linedef_id,
            p.map_id,
            p.cx1,
            p.cy1,
            p.cx2,
            p.cy2,
            p.screen_x1,
            p.screen_x2,
            p.invx1,
            p.invx2,
            p.seg_u1,
            p.seg_u2,
            p.bsp_seq,
            s.fsec,
            s.bsec,
            (s.x_offset +
                CASE
                    WHEN (sc.linedef_id IS NULL) THEN (0)::bigint
                    ELSE fc.t
                END) AS x_offset,
            s.y_offset,
            s.upper_tex,
            s.mid_tex,
            s.lower_tex,
            s.flags,
            s.f_floor,
            s.f_ceil,
            s.f_ceil_tex,
            COALESCE(alf.light_level, s.f_light) AS f_light,
            s.b_floor,
            s.b_ceil,
            s.b_ceil_tex,
            COALESCE(alb.light_level, s.b_light) AS b_light,
            s.light_bias
           FROM (((((on_screen p
             JOIN render_segs s ON (((s.map_id = p.map_id) AND (s.seg_id = p.seg_id))))
             CROSS JOIN frame_clock fc)
             LEFT JOIN animated_light alf ON ((alf.sector_id = s.fsec)))
             LEFT JOIN animated_light alb ON ((alb.sector_id = s.bsec)))
             LEFT JOIN scrolling_segs sc ON ((sc.linedef_id = s.linedef_id)))
        ), occluders AS (
         SELECT h.seg_id,
            h.screen_x1,
            h.screen_x2,
            h.bsp_seq
           FROM heights h
          WHERE ((h.bsec IS NULL) OR (h.b_ceil <= h.b_floor))
        ), occlusion_cols AS (
         SELECT generate_series(GREATEST(0, (floor(LEAST(o.screen_x1, o.screen_x2)))::integer), LEAST((rs.screen_w - 1), (ceil(GREATEST(o.screen_x1, o.screen_x2)))::integer)) AS col_x,
            o.bsp_seq
           FROM (occluders o
             CROSS JOIN render_settings rs)
          WHERE (o.screen_x1 <> o.screen_x2)
        ), min_occlusion AS (
         SELECT occlusion_cols.col_x,
            min(occlusion_cols.bsp_seq) AS min_bsp_seq
           FROM occlusion_cols
          GROUP BY occlusion_cols.col_x
        ), occlusion_arr AS MATERIALIZED (
         -- min_occlusion as an array by column (index x + 1), the largest
         -- bigint where nothing occludes: one subscript per column.
         SELECT array_agg(COALESCE(mo.min_bsp_seq, '9223372036854775807'::bigint) ORDER BY g.x) AS a
           FROM ((render_settings rs
             CROSS JOIN LATERAL generate_series(0, (rs.screen_w - 1)) g(x))
             LEFT JOIN min_occlusion mo ON ((mo.col_x = g.x)))
        ), heights_shown AS (
         -- The segs not wholly behind a nearer occluder: those with a column
         -- that columns keeps (same rule, over a range at least as wide as
         -- the seg's columns). The others make no parts, columns or panels,
         -- and their textures are not loaded (LBDoom R4, 2026-11-17).
         SELECT h.*
           FROM ((heights h
             CROSS JOIN occlusion_arr oa)
             CROSS JOIN render_settings rs)
          WHERE (NOT (h.bsp_seq > ALL (oa.a[(GREATEST(0, (floor(LEAST(h.screen_x1, h.screen_x2)))::integer) + 1):(LEAST((rs.screen_w - 1), (ceil(GREATEST(h.screen_x1, h.screen_x2)))::integer) + 1)])))
        ), frame_walltex AS MATERIALIZED (
         SELECT m.name,
            m.width,
            m.height,
            (m.palette_indices || '\x'::bytea) AS palette_indices
           FROM walltex_meta m
          WHERE (m.name IN ( SELECT t.tex
                   FROM (heights_shown h
                     CROSS JOIN LATERAL ( VALUES (h.upper_tex), (h.mid_tex), (h.lower_tex)) t(tex))
                UNION
                 SELECT ma.sky_texture
                   FROM (maps ma
                     JOIN render_context rc ON ((rc.map_id = ma.map_id)))))
        ), wall_parts AS (
         SELECT heights.seg_id,
            'solid'::text AS part,
            heights.mid_tex AS tex,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.f_floor AS z_bot,
            heights.f_ceil AS z_top,
                CASE
                    WHEN ((heights.flags & 16) <> 0) THEN heights.f_floor
                    ELSE heights.f_ceil
                END AS v_anchor_base,
            ((heights.flags & 16) <> 0) AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NULL) AND (heights.f_ceil > heights.f_floor))
        UNION ALL
         SELECT heights.seg_id,
            'upper'::text AS text,
            heights.upper_tex,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.b_ceil AS z_bot,
            heights.f_ceil AS z_top,
                CASE
                    WHEN ((heights.flags & 8) <> 0) THEN heights.f_ceil
                    ELSE heights.b_ceil
                END AS v_anchor_base,
            ((heights.flags & 8) = 0) AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.b_ceil < heights.f_ceil) AND (((heights.f_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text) OR ((heights.b_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text)))
        UNION ALL
         SELECT heights.seg_id,
            'upper_open'::text AS text,
            NULL::text AS text,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.f_ceil AS z_bot,
            heights.b_ceil AS z_top,
            heights.b_ceil AS v_anchor_base,
            false AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.b_ceil > heights.f_ceil) AND (((heights.f_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text) OR ((heights.b_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text)))
        UNION ALL
         SELECT heights.seg_id,
            'upper_flush'::text AS text,
            NULL::text AS text,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.f_ceil AS z_bot,
            heights.b_ceil AS z_top,
            heights.b_ceil AS v_anchor_base,
            false AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.b_ceil = heights.f_ceil) AND (((heights.f_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text) OR ((heights.b_ceil_tex)::text IS DISTINCT FROM 'F_SKY1'::text)))
        UNION ALL
         SELECT heights.seg_id,
            'lower'::text AS text,
            heights.lower_tex,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.f_floor AS z_bot,
            heights.b_floor AS z_top,
                CASE
                    WHEN ((heights.flags & 16) <> 0) THEN heights.f_ceil
                    ELSE heights.b_floor
                END AS v_anchor_base,
            false AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.b_floor > heights.f_floor))
        UNION ALL
         SELECT heights.seg_id,
            'lower_down'::text AS text,
            NULL::text AS text,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.b_floor AS z_bot,
            heights.f_floor AS z_top,
            heights.f_floor AS v_anchor_base,
            false AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.b_floor <= heights.f_floor))
        UNION ALL
         SELECT heights.seg_id,
            'midmask'::text AS text,
            heights.mid_tex,
            heights.x_offset,
            heights.y_offset,
            heights.flags,
            heights.f_floor AS z_bot,
            heights.f_ceil AS z_top,
                CASE
                    WHEN ((heights.flags & 16) <> 0) THEN GREATEST(heights.f_floor, heights.b_floor)
                    ELSE LEAST(heights.f_ceil, heights.b_ceil)
                END AS v_anchor_base,
            ((heights.flags & 16) <> 0) AS v_anchor_add_tex_h,
            heights.f_light,
            heights.fsec,
            heights.invx1,
            heights.invx2,
            heights.screen_x1,
            heights.screen_x2,
            heights.cx1,
            heights.cx2,
            heights.cy1,
            heights.cy2,
            heights.seg_u1,
            heights.seg_u2,
            heights.bsp_seq,
            heights.light_bias
           FROM heights_shown heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.mid_tex IS NOT NULL) AND ((heights.mid_tex)::text <> '-'::text) AND (heights.f_ceil > heights.f_floor))
        ), wall_parts_tex AS (
         SELECT wp.seg_id,
            wp.part,
            wp.tex,
            wp.x_offset,
            wp.y_offset,
            wp.flags,
            wp.z_bot,
            wp.z_top,
            wp.v_anchor_base,
            wp.v_anchor_add_tex_h,
            wp.f_light,
            wp.fsec,
            wp.invx1,
            wp.invx2,
            wp.screen_x1,
            wp.screen_x2,
            wp.cx1,
            wp.cx2,
            wp.cy1,
            wp.cy2,
            wp.seg_u1,
            wp.seg_u2,
            wp.bsp_seq,
            wp.light_bias,
            COALESCE(m.width, 64) AS tex_w,
            COALESCE(m.height, 64) AS tex_h,
            m.width AS tex_width
           FROM (wall_parts wp
             LEFT JOIN walltex_meta m ON ((m.name = (wp.tex)::text)))
        ), columns AS (
         SELECT w.seg_id,
            w.part,
            w.tex,
            w.x_offset,
            w.y_offset,
            w.flags,
            w.z_bot,
            w.z_top,
            w.v_anchor_base,
            w.v_anchor_add_tex_h,
            w.f_light,
            w.fsec,
            w.invx1,
            w.invx2,
            w.screen_x1,
            w.screen_x2,
            w.cx1,
            w.cx2,
            w.cy1,
            w.cy2,
            w.seg_u1,
            w.seg_u2,
            w.bsp_seq,
            w.light_bias,
            w.tex_w,
            w.tex_h,
            w.tex_width,
            w.x,
            ((w.x_offset)::double precision + w.seg_u1) AS u1,
            ((w.x_offset)::double precision + w.seg_u2) AS u2,
            w.x AS col_x,
            w.x AS screen_x_clamped,
            LEAST((1.0)::double precision, GREATEST((0.0)::double precision, (((w.x)::double precision - w.screen_x1) / NULLIF((w.screen_x2 - w.screen_x1), (0.000001)::double precision)))) AS t
           FROM (( SELECT w_1.seg_id,
                    w_1.part,
                    w_1.tex,
                    w_1.x_offset,
                    w_1.y_offset,
                    w_1.flags,
                    w_1.z_bot,
                    w_1.z_top,
                    w_1.v_anchor_base,
                    w_1.v_anchor_add_tex_h,
                    w_1.f_light,
                    w_1.fsec,
                    w_1.invx1,
                    w_1.invx2,
                    w_1.screen_x1,
                    w_1.screen_x2,
                    w_1.cx1,
                    w_1.cx2,
                    w_1.cy1,
                    w_1.cy2,
                    w_1.seg_u1,
                    w_1.seg_u2,
                    w_1.bsp_seq,
                    w_1.light_bias,
                    w_1.tex_w,
                    w_1.tex_h,
                    w_1.tex_width,
                    generate_series(b.x_lo, b.x_hi) AS x
                   FROM ((wall_parts_tex w_1
                     CROSS JOIN render_settings rs)
                     CROSS JOIN LATERAL ( SELECT (NOT ((GREATEST(w_1.screen_x1, w_1.screen_x2) < (0)::double precision) OR (LEAST(w_1.screen_x1, w_1.screen_x2) >= (rs.screen_w)::double precision))) AS on_screen,
                            GREATEST(0, (floor(LEAST(w_1.screen_x1, w_1.screen_x2)))::integer) AS x_lo,
                            LEAST((rs.screen_w - 1), (ceil(GREATEST(w_1.screen_x1, w_1.screen_x2)))::integer) AS x_hi) b)
                  WHERE (b.on_screen AND (w_1.screen_x1 <> w_1.screen_x2))) w
             LEFT JOIN min_occlusion mo ON ((mo.col_x = w.x)))
          WHERE (w.bsp_seq <= COALESCE(mo.min_bsp_seq, w.bsp_seq))
         OFFSET 0
        ), per_column AS (
         SELECT c.seg_id,
            c.part,
            c.tex,
            c.x_offset,
            c.y_offset,
            c.flags,
            c.z_bot,
            c.z_top,
            c.v_anchor_base,
            c.v_anchor_add_tex_h,
            c.f_light,
            c.fsec,
            c.invx1,
            c.invx2,
            c.screen_x1,
            c.screen_x2,
            c.cx1,
            c.cx2,
            c.cy1,
            c.cy2,
            c.seg_u1,
            c.seg_u2,
            c.bsp_seq,
            c.light_bias,
            c.tex_w,
            c.tex_h,
            c.tex_width,
            c.x,
            c.u1,
            c.u2,
            c.col_x,
            c.screen_x_clamped,
            c.t,
            iv.invx,
            iv.u_over_x,
            ((1.0)::double precision / iv.invx) AS depth_x,
            (iv.u_over_x / NULLIF(iv.invx, (0.000001)::double precision)) AS u_col,
            (rs.focal * iv.invx) AS scale
           FROM ((columns c
             CROSS JOIN render_settings rs)
             CROSS JOIN LATERAL ( SELECT (c.invx1 + (c.t * (c.invx2 - c.invx1))) AS invx,
                    ((c.u1 * c.invx1) + (c.t * ((c.u2 * c.invx2) - (c.u1 * c.invx1)))) AS u_over_x) iv)
        ), vertical AS (
         SELECT p.seg_id,
            p.part,
            p.tex,
            p.y_offset,
            p.f_light,
            p.tex_w,
            p.tex_h,
            p.tex_width,
            p.bsp_seq,
            p.light_bias,
            p.col_x,
            p.screen_x_clamped,
            p.depth_x,
            p.u_col,
            p.scale,
            c.pz AS view_z,
            rs.cy AS screen_cy,
            (rs.cy - (p.scale * ((p.z_top)::double precision - c.pz))) AS y_top_f,
            (rs.cy - (p.scale * ((p.z_bot)::double precision - c.pz))) AS y_bot_f,
            (p.v_anchor_base +
                CASE
                    WHEN p.v_anchor_add_tex_h THEN p.tex_h
                    ELSE 0
                END) AS v_anchor_z
           FROM ((per_column p
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
        ), clamped_spans AS (
         SELECT t.seg_id,
            t.part,
            t.tex,
            t.y_offset,
            t.f_light,
            t.tex_w,
            t.tex_h,
            t.tex_width,
            t.bsp_seq,
            t.light_bias,
            t.col_x,
            t.screen_x_clamped,
            t.depth_x,
            t.u_col,
            t.scale,
            t.view_z,
            t.screen_cy,
            t.y_top_f,
            t.y_bot_f,
            t.v_anchor_z,
            t.y_start,
            t.y_end,
            (((t.v_anchor_z)::double precision - (t.view_z + ((t.screen_cy - (t.y_start)::double precision) / NULLIF(t.scale, (0.000000001)::double precision)))) + (t.y_offset)::double precision) AS v0,
            ((1.0)::double precision / NULLIF(t.scale, (0.000000001)::double precision)) AS v_step
           FROM ( SELECT v.seg_id,
                    v.part,
                    v.tex,
                    v.y_offset,
                    v.f_light,
                    v.tex_w,
                    v.tex_h,
                    v.tex_width,
                    v.bsp_seq,
                    v.light_bias,
                    v.col_x,
                    v.screen_x_clamped,
                    v.depth_x,
                    v.u_col,
                    v.scale,
                    v.view_z,
                    v.screen_cy,
                    v.y_top_f,
                    v.y_bot_f,
                    v.v_anchor_z,
                    (ceil(LEAST(((rs.screen_h)::double precision - (1.0)::double precision), GREATEST((0.0)::double precision, LEAST(v.y_top_f, v.y_bot_f)))))::integer AS y_start,
                    (floor(LEAST(((rs.screen_h)::double precision - (1.0)::double precision), GREATEST((0.0)::double precision, GREATEST(v.y_top_f, v.y_bot_f)))))::integer AS y_end
                   FROM (vertical v
                     CROSS JOIN render_settings rs)
                  WHERE ((LEAST(v.y_top_f, v.y_bot_f) < (rs.screen_h)::double precision) AND (GREATEST(v.y_top_f, v.y_bot_f) >= (0)::double precision))) t
          WHERE (t.y_end >= t.y_start)
        ), clamped_spans_lit AS (
         SELECT c.seg_id,
            c.part,
            c.tex,
            c.y_offset,
            c.f_light,
            c.tex_w,
            c.tex_h,
            c.tex_width,
            c.bsp_seq,
            c.light_bias,
            c.col_x,
            c.screen_x_clamped,
            c.depth_x,
            c.u_col,
            c.scale,
            c.view_z,
            c.screen_cy,
            c.y_top_f,
            c.y_bot_f,
            c.v_anchor_z,
            c.y_start,
            c.y_end,
            c.v0,
            c.v_step,
            cu.u_i,
            wt.palette_indices AS tex_pi,
            ((wt.palette_indices IS NOT NULL) AND (cu.u_i >= 0) AND (cu.u_i < c.tex_width) AND (octet_length(wt.palette_indices) >= (c.tex_width * c.tex_h))) AS texel_safe,
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    ELSE doom_light_index((c.f_light)::double precision, (c.light_bias + wr.extra_light), doom_light_scale(c.depth_x))
                END AS light_index,
            (((c.seg_id)::bigint * 8) +
                CASE c.part
                    WHEN 'solid'::text THEN 0
                    WHEN 'upper'::text THEN 1
                    WHEN 'lower'::text THEN 2
                    WHEN 'lower_down'::text THEN 3
                    ELSE 7
                END) AS stable_id
           FROM ((((clamped_spans c
             CROSS JOIN LATERAL ( SELECT (floor((c.u_col - ((c.tex_w)::double precision * floor((c.u_col / (c.tex_w)::double precision))))))::integer AS u_i) cu)
             LEFT JOIN frame_walltex wt ON ((wt.name = (c.tex)::text)))
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
        ), wall_spans AS (
         SELECT c.seg_id,
            c.part,
            c.tex,
            c.y_offset,
            c.f_light,
            c.tex_w,
            c.tex_h,
            c.tex_width,
            c.bsp_seq,
            c.light_bias,
            c.col_x,
            c.screen_x_clamped,
            c.depth_x,
            c.u_col,
            c.scale,
            c.view_z,
            c.screen_cy,
            c.y_top_f,
            c.y_bot_f,
            c.v_anchor_z,
            c.y_start,
            c.y_end,
            c.v0,
            c.v_step,
            c.u_i,
            c.tex_pi,
            c.texel_safe,
            c.light_index,
            c.stable_id,
            (((((((GREATEST((0.0)::double precision, LEAST(c.depth_x, (131071.0)::double precision)) * (4096)::double precision))::bigint << 34) | (((2)::bigint - (2)::bigint) << 32)) | (LEAST((0)::bigint, (3)::bigint) << 30)) | (LEAST((65535)::bigint, GREATEST((0)::bigint, (c.stable_id + 32768))) << 14)) | ((c.light_index)::bigint << 8)) AS key_hi
           FROM clamped_spans_lit c
          WHERE ((c.tex IS NOT NULL) AND ((c.tex)::text <> '-'::text))
         OFFSET 0
        ), fragments AS (
         SELECT ((f.y * rs.screen_w) + f.screen_x_clamped) AS pix,
            (f.key_hi | (
                CASE
                    WHEN f.texel_safe THEN get_byte(f.tex_pi, ((vv.v_i * f.tex_width) + f.u_i))
                    WHEN ((f.tex_pi IS NULL) OR (((vv.v_i * f.tex_width) + f.u_i) < 0) OR (((vv.v_i * f.tex_width) + f.u_i) >= octet_length(f.tex_pi))) THEN 0
                    ELSE get_byte(f.tex_pi, ((vv.v_i * f.tex_width) + f.u_i))
                END)::bigint) AS winner_key
           FROM ((( SELECT w.screen_x_clamped,
                    w.key_hi,
                    w.texel_safe,
                    w.tex_pi,
                    w.tex_width,
                    w.tex_h,
                    w.u_i,
                    w.v0,
                    w.v_step,
                    w.y_start,
                    generate_series(w.y_start, w.y_end) AS y
                   FROM wall_spans w) f
             CROSS JOIN render_settings rs)
             CROSS JOIN LATERAL ( SELECT ((((floor((f.v0 + (((f.y - f.y_start))::double precision * f.v_step))))::integer % f.tex_h) + f.tex_h) % f.tex_h) AS v_i) vv)
        ), panel_cols AS (
         SELECT v.col_x,
            v.seg_id,
            v.bsp_seq,
            v.part,
            v.depth_x,
            v.y_top_f,
            v.y_bot_f,
                CASE
                    WHEN (v.part = 'lower_down'::text) THEN v.y_top_f
                    ELSE v.y_bot_f
                END AS f_floor_y_f,
                CASE
                    WHEN (v.part = 'upper_open'::text) THEN v.y_bot_f
                    ELSE v.y_top_f
                END AS f_ceil_y_f,
            h.fsec,
            h.f_light,
            h.f_floor,
            h.f_ceil,
            ((h.f_ceil_tex)::text = 'F_SKY1'::text) AS f_ceil_is_sky
           FROM ((vertical v
             JOIN heights_shown h ON ((h.seg_id = v.seg_id)))
             CROSS JOIN render_settings rs)
          WHERE ((v.part = ANY (ARRAY['upper_open'::text, 'upper_flush'::text, 'lower_down'::text])) OR ((LEAST(v.y_top_f, v.y_bot_f) < (rs.screen_h)::double precision) AND (GREATEST(v.y_top_f, v.y_bot_f) >= (0)::double precision)))
        ), panel_seq AS (
         SELECT p.col_x,
            p.seg_id,
            p.bsp_seq,
            p.part,
            p.depth_x,
            p.y_top_f,
            p.y_bot_f,
            p.f_floor_y_f,
            p.f_ceil_y_f,
            p.fsec,
            p.f_light,
            p.f_floor,
            p.f_ceil,
            p.f_ceil_is_sky,
            row_number() OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id) AS seq
           FROM panel_cols p
        ), panel_clips AS (
         SELECT p.col_x,
            p.seg_id,
            p.bsp_seq,
            p.part,
            p.depth_x,
            p.y_top_f,
            p.y_bot_f,
            p.f_floor_y_f,
            p.f_ceil_y_f,
            p.fsec,
            p.f_light,
            p.f_floor,
            p.f_ceil,
            p.f_ceil_is_sky,
            p.seq,
            p.cc_before,
            p.fc_before,
            p.ceil_k,
            p.ceil_zl,
            p.floor_k,
            p.floor_zl,
                CASE
                    WHEN ((p.ceil_k IS NULL) OR (((p.ceil_k >> 32) & (1)::bigint) = 1)) THEN NULL::integer
                    ELSE (((p.ceil_k & '4294967295'::bigint) - '2147483648'::bigint))::integer
                END AS carried_ceil_sec,
                CASE
                    WHEN ((p.ceil_zl IS NULL) OR (((p.ceil_zl >> 18) & (262143)::bigint) >= 131072)) THEN NULL::smallint
                    ELSE ((((p.ceil_zl >> 18) & (262143)::bigint) - 32768))::smallint
                END AS carried_ceil_z,
                CASE
                    WHEN ((p.ceil_zl IS NULL) OR ((p.ceil_zl & (262143)::bigint) >= 131072)) THEN NULL::smallint
                    ELSE (((p.ceil_zl & (262143)::bigint) - 32768))::smallint
                END AS carried_ceil_light,
            COALESCE((((p.ceil_zl >> 36) & (1)::bigint) = 1), false) AS carried_ceil_is_sky,
                CASE
                    WHEN ((p.floor_k IS NULL) OR (((p.floor_k >> 32) & (1)::bigint) = 1)) THEN NULL::integer
                    ELSE (((p.floor_k & '4294967295'::bigint) - '2147483648'::bigint))::integer
                END AS carried_floor_sec,
                CASE
                    WHEN ((p.floor_zl IS NULL) OR (((p.floor_zl >> 18) & (262143)::bigint) >= 131072)) THEN NULL::smallint
                    ELSE ((((p.floor_zl >> 18) & (262143)::bigint) - 32768))::smallint
                END AS carried_floor_z,
                CASE
                    WHEN ((p.floor_zl IS NULL) OR ((p.floor_zl & (262143)::bigint) >= 131072)) THEN NULL::smallint
                    ELSE (((p.floor_zl & (262143)::bigint) - 32768))::smallint
                END AS carried_floor_light
           FROM ( SELECT p_1.col_x,
                    p_1.seg_id,
                    p_1.bsp_seq,
                    p_1.part,
                    p_1.depth_x,
                    p_1.y_top_f,
                    p_1.y_bot_f,
                    p_1.f_floor_y_f,
                    p_1.f_ceil_y_f,
                    p_1.fsec,
                    p_1.f_light,
                    p_1.f_floor,
                    p_1.f_ceil,
                    p_1.f_ceil_is_sky,
                    p_1.seq,
                    COALESCE(max(
                        CASE
                            WHEN (p_1.part = ANY (ARRAY['solid'::text, 'upper'::text])) THEN ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision, p_1.y_bot_f))))::integer + 1)
                            WHEN (p_1.part = 'upper_flush'::text) THEN GREATEST(0, ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, p_1.y_bot_f)))::integer + 1))
                            ELSE NULL::integer
                        END) OVER w_before, 0) AS cc_before,
                    COALESCE(min(
                        CASE
                            WHEN (p_1.part = ANY (ARRAY['solid'::text, 'lower'::text, 'lower_down'::text])) THEN LEAST((rs.screen_h - 1), ((ceil(GREATEST((0.0)::double precision, p_1.y_top_f)))::integer - 1))
                            ELSE NULL::integer
                        END) OVER w_before, (rs.screen_h - 1)) AS fc_before,
                    max(
                        CASE
                            WHEN ((p_1.f_ceil)::double precision > c.pz) THEN ((p_1.seq << 33) |
                            CASE
                                WHEN (p_1.fsec IS NULL) THEN '4294967296'::bigint
                                ELSE ((p_1.fsec)::bigint + '2147483648'::bigint)
                            END)
                            ELSE NULL::bigint
                        END) OVER w_before AS ceil_k,
                    max(
                        CASE
                            WHEN ((p_1.f_ceil)::double precision > c.pz) THEN ((((p_1.seq << 37) | (
                            CASE
                                WHEN p_1.f_ceil_is_sky THEN (1)::bigint
                                ELSE (0)::bigint
                            END << 36)) | (
                            CASE
                                WHEN (p_1.f_ceil IS NULL) THEN (131072)::bigint
                                ELSE ((p_1.f_ceil)::bigint + 32768)
                            END << 18)) |
                            CASE
                                WHEN (p_1.f_light IS NULL) THEN (131072)::bigint
                                ELSE ((p_1.f_light)::bigint + 32768)
                            END)
                            ELSE NULL::bigint
                        END) OVER w_before AS ceil_zl,
                    max(
                        CASE
                            WHEN ((p_1.f_floor)::double precision < c.pz) THEN ((p_1.seq << 33) |
                            CASE
                                WHEN (p_1.fsec IS NULL) THEN '4294967296'::bigint
                                ELSE ((p_1.fsec)::bigint + '2147483648'::bigint)
                            END)
                            ELSE NULL::bigint
                        END) OVER w_before AS floor_k,
                    max(
                        CASE
                            WHEN ((p_1.f_floor)::double precision < c.pz) THEN (((p_1.seq << 36) | (
                            CASE
                                WHEN (p_1.f_floor IS NULL) THEN (131072)::bigint
                                ELSE ((p_1.f_floor)::bigint + 32768)
                            END << 18)) |
                            CASE
                                WHEN (p_1.f_light IS NULL) THEN (131072)::bigint
                                ELSE ((p_1.f_light)::bigint + 32768)
                            END)
                            ELSE NULL::bigint
                        END) OVER w_before AS floor_zl
                   FROM ((panel_seq p_1
                     CROSS JOIN render_settings rs)
                     CROSS JOIN cam c)
                  WINDOW w_before AS (PARTITION BY p_1.col_x ORDER BY p_1.depth_x, p_1.bsp_seq, p_1.part, p_1.seg_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) p
        ), nearest_floor_panel AS (
         SELECT panel_cols.col_x,
            min(panel_cols.depth_x) AS depth_x
           FROM panel_cols
          WHERE (panel_cols.part = ANY (ARRAY['solid'::text, 'lower'::text, 'lower_down'::text]))
          GROUP BY panel_cols.col_x
        ), nearest_ceiling_panel AS (
         SELECT panel_cols.col_x,
            min(panel_cols.depth_x) AS depth_x
           FROM panel_cols
          WHERE (panel_cols.part = ANY (ARRAY['solid'::text, 'upper'::text, 'upper_open'::text, 'upper_flush'::text]))
          GROUP BY panel_cols.col_x
        ), plane_spans_raw AS (
         SELECT k.col_x,
                CASE
                    WHEN (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky) THEN k.fsec
                    ELSE k.carried_ceil_sec
                END AS sector_id,
                CASE
                    WHEN (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky) THEN k.f_ceil
                    ELSE k.carried_ceil_z
                END AS plane_z,
                CASE
                    WHEN (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky) THEN k.f_light
                    ELSE k.carried_ceil_light
                END AS sector_light,
                CASE
                    WHEN (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky) THEN k.f_ceil_is_sky
                    ELSE k.carried_ceil_is_sky
                END AS is_sky,
            'ceil'::text AS plane,
            1 AS source_priority,
            GREATEST(0, k.cc_before) AS y0,
            b.y1
           FROM (((panel_clips k
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN LATERAL ( SELECT ((ceil(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision,
                        CASE
                            WHEN (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky) THEN k.f_ceil_y_f
                            ELSE LEAST(k.f_ceil_y_f, (rs.cy - ((rs.focal * ((k.carried_ceil_z)::double precision - c.pz)) / rs.max_plane_depth)))
                        END))))::integer - 1) AS y1) b)
          WHERE ((k.part = ANY (ARRAY['solid'::text, 'upper'::text, 'upper_open'::text, 'upper_flush'::text, 'midmask'::text])) AND (b.y1 >= k.cc_before) AND (((k.f_ceil)::double precision > c.pz) OR k.f_ceil_is_sky OR k.carried_ceil_is_sky OR (k.cc_before > 0)))
        UNION ALL
         SELECT k.col_x,
                CASE
                    WHEN ((k.f_floor)::double precision < c.pz) THEN k.fsec
                    ELSE k.carried_floor_sec
                END AS sector_id,
                CASE
                    WHEN ((k.f_floor)::double precision < c.pz) THEN k.f_floor
                    ELSE k.carried_floor_z
                END AS plane_z,
                CASE
                    WHEN ((k.f_floor)::double precision < c.pz) THEN k.f_light
                    ELSE k.carried_floor_light
                END AS sector_light,
            false AS is_sky,
            'floor'::text AS plane,
            1 AS source_priority,
            b.y0,
            LEAST((rs.screen_h - 1), k.fc_before) AS y1
           FROM (((panel_clips k
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN LATERAL ( SELECT ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision,
                        CASE
                            WHEN ((k.f_floor)::double precision < c.pz) THEN k.f_floor_y_f
                            ELSE GREATEST(k.f_floor_y_f, (rs.cy - ((rs.focal * ((k.carried_floor_z)::double precision - c.pz)) / rs.max_plane_depth)))
                        END))))::integer + 1) AS y0) b)
          WHERE ((k.part = ANY (ARRAY['solid'::text, 'midmask'::text, 'lower'::text, 'lower_down'::text])) AND (b.y0 <= k.fc_before) AND (((k.f_floor)::double precision < c.pz) OR (k.fc_before < (rs.screen_h - 1))))
        UNION ALL
         SELECT x.x AS col_x,
            ps.id AS sector_id,
            ps.floor_height AS plane_z,
            ps.light_level AS sector_light,
            false AS is_sky,
            'floor'::text AS plane,
            0 AS source_priority,
                CASE
                    WHEN (np.depth_x IS NULL) THEN ((floor(rs.cy))::integer + 1)
                    ELSE ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision, (rs.cy - ((rs.focal * ((ps.floor_height)::double precision - c.pz)) / np.depth_x))))))::integer + 1)
                END AS y0,
            (rs.screen_h - 1) AS y1
           FROM ((((render_settings rs
             CROSS JOIN cam c)
             CROSS JOIN player_sector ps)
             CROSS JOIN LATERAL generate_series(0, (rs.screen_w - 1)) x(x))
             LEFT JOIN nearest_floor_panel np ON ((np.col_x = x.x)))
        UNION ALL
         SELECT x.x AS col_x,
            ps.id AS sector_id,
            ps.ceil_height AS plane_z,
            ps.light_level AS sector_light,
            ((ps.ceil_tex)::text = 'F_SKY1'::text) AS is_sky,
            'ceil'::text AS plane,
            0 AS source_priority,
            0 AS y0,
                CASE
                    WHEN (np.depth_x IS NULL) THEN ((ceil(rs.cy))::integer - 1)
                    ELSE ((ceil(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision, (rs.cy - ((rs.focal * ((ps.ceil_height)::double precision - c.pz)) / np.depth_x))))))::integer - 1)
                END AS y1
           FROM ((((render_settings rs
             CROSS JOIN cam c)
             CROSS JOIN player_sector ps)
             CROSS JOIN LATERAL generate_series(0, (rs.screen_w - 1)) x(x))
             LEFT JOIN nearest_ceiling_panel np ON ((np.col_x = x.x)))
        ), plane_spans AS (
         SELECT ps.col_x,
            ps.sector_id,
            ps.plane_z,
            ps.sector_light,
            ps.is_sky,
            ps.plane,
            ps.source_priority,
            ps.y0,
            ps.y1
           FROM (plane_spans_raw ps
             CROSS JOIN cam c)
          WHERE (((ps.plane = 'floor'::text) AND ((ps.plane_z)::double precision < c.pz)) OR ((ps.plane = 'ceil'::text) AND (((ps.plane_z)::double precision > c.pz) OR ps.is_sky)))
        ), plane_spans_deduped AS (
         SELECT plane_spans.col_x,
            plane_spans.sector_id,
            plane_spans.plane_z,
            plane_spans.plane,
            plane_spans.is_sky,
            plane_spans.y0,
            plane_spans.y1,
            min(plane_spans.sector_light) AS sector_light,
            min(plane_spans.source_priority) AS source_priority
           FROM plane_spans
          WHERE (plane_spans.y1 >= plane_spans.y0)
          GROUP BY plane_spans.col_x, plane_spans.sector_id, plane_spans.plane_z, plane_spans.plane, plane_spans.is_sky, plane_spans.y0, plane_spans.y1
        ), plane_span_tex AS (
         SELECT ps.col_x,
            ps.sector_id,
            ps.plane_z,
            ps.plane,
            ps.y0,
            ps.y1,
            ps.sector_light,
            ps.source_priority,
            ps.is_sky AS span_is_sky,
            t.tex_name,
            ((t.tex_name)::text = 'F_SKY1'::text) AS is_sky,
            ft.palette_indices AS flat_pi,
            wt.palette_indices AS sky_pi,
            wt.width AS sky_w,
            (octet_length(ft.palette_indices) >= (rs.flat_size * rs.flat_size)) AS flat_whole,
            ((wt.width >= (rs.sky_columns)::integer) AND (octet_length(wt.palette_indices) >= (wt.width * rs.sky_rows))) AS sky_whole,
            t.tan_alpha,
            ((((floor((degrees((c.view_rad - atan(t.tan_alpha))) * (rs.sky_columns / rs.sky_degrees))))::integer % (rs.sky_columns)::integer) + (rs.sky_columns)::integer) % (rs.sky_columns)::integer) AS sky_u
           FROM ((((((((plane_spans_deduped ps
             CROSS JOIN render_context rc)
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             JOIN sectors_lit s ON (((s.id = ps.sector_id) AND (s.map_id = rc.map_id))))
             CROSS JOIN LATERAL ( SELECT
                        CASE
                            WHEN (ps.plane = 'floor'::text) THEN s.floor_tex
                            ELSE s.ceil_tex
                        END AS tex_name,
                    (((ps.col_x)::double precision - rs.cx) / rs.focal) AS tan_alpha) t)
             LEFT JOIN frame_flats ft ON ((((t.tex_name)::text <> 'F_SKY1'::text) AND (ft.name = (t.tex_name)::text))))
             CROSS JOIN ( SELECT m.sky_texture AS name
                   FROM (maps m
                     JOIN render_context rc2 ON ((rc2.map_id = m.map_id)))) sk)
             LEFT JOIN frame_walltex wt ON ((((t.tex_name)::text = 'F_SKY1'::text) AND (wt.name = sk.name))))
        ), plane_span_keyed AS (
         SELECT ps.col_x,
            ps.sector_id,
            ps.plane_z,
            ps.plane,
            ps.y0,
            ps.y1,
            ps.sector_light,
            ps.source_priority,
            ps.span_is_sky,
            ps.tex_name,
            ps.is_sky,
            ps.flat_pi,
            ps.sky_pi,
            ps.sky_w,
            ps.flat_whole,
            ps.sky_whole,
            ps.tan_alpha,
            ps.sky_u,
            (rs.focal * ((ps.plane_z)::double precision - c.pz)) AS depth_num,
            (((((2)::bigint - (0)::bigint) << 32) | (LEAST((ps.source_priority)::bigint, (3)::bigint) << 30)) | (LEAST((65535)::bigint, GREATEST((0)::bigint, ((((ps.sector_id)::bigint * 2) +
                CASE
                    WHEN (ps.plane = 'floor'::text) THEN 0
                    ELSE 1
                END) + 32768))) << 14)) AS key_hi,
            (
                CASE
                    WHEN ps.is_sky THEN 16
                    WHEN wr.invuln THEN 17
                    ELSE (15 - LEAST(15, GREATEST(0, ((floor(((ps.sector_light)::double precision / (16.0)::double precision)))::integer + wr.extra_light))))
                END * 128) AS light_row
           FROM (((plane_span_tex ps
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN weapon_runtime wr)
         OFFSET 0
        ), plane_rays AS (
         SELECT r.col_x,
            r.y,
            r.span_is_sky,
            r.is_sky,
            r.key_hi,
            r.light_row,
            r.flat_pi,
            r.flat_whole,
            r.sky_pi,
            r.sky_w,
            r.sky_whole,
            r.sky_u,
            r.tan_alpha,
                CASE
                    WHEN r.span_is_sky THEN ('10000000'::numeric)::double precision
                    ELSE (r.depth_num / NULLIF((rs.cy - (r.y)::double precision), (0.0)::double precision))
                END AS depth_x
           FROM (( SELECT ps.col_x,
                    ps.span_is_sky,
                    ps.is_sky,
                    ps.key_hi,
                    ps.light_row,
                    ps.flat_pi,
                    ps.flat_whole,
                    ps.sky_pi,
                    ps.sky_w,
                    ps.sky_whole,
                    ps.sky_u,
                    ps.tan_alpha,
                    ps.depth_num,
                    generate_series(ps.y0, ps.y1) AS y
                   FROM plane_span_keyed ps) r
             CROSS JOIN render_settings rs)
         OFFSET 0
        ), plane_fragments AS (
         SELECT ((r.y * rs.screen_w) + r.col_x) AS pix,
            ((((((LEAST(r.depth_x, (131071.0)::double precision) * (4096)::double precision))::bigint << 34) | r.key_hi) | ((get_byte(doom_zlight_lut(), (r.light_row + LEAST(127, (floor((r.depth_x / (16.0)::double precision)))::integer))))::bigint << 8)) | (
                CASE
                    WHEN ((NOT r.is_sky) AND r.flat_whole) THEN get_byte(r.flat_pi, ((uv.v_i * rs.flat_size) + uv.u_i))
                    WHEN (r.is_sky AND r.sky_whole) THEN get_byte(r.sky_pi, ((uv.v_i * r.sky_w) + uv.u_i))
                    WHEN ((NOT r.is_sky) AND (r.flat_pi IS NOT NULL) AND (((uv.v_i * rs.flat_size) + uv.u_i) >= 0) AND (((uv.v_i * rs.flat_size) + uv.u_i) < octet_length(r.flat_pi))) THEN get_byte(r.flat_pi, ((uv.v_i * rs.flat_size) + uv.u_i))
                    WHEN (r.is_sky AND (r.sky_pi IS NOT NULL)) THEN
                    CASE
                        WHEN ((((uv.v_i * r.sky_w) + uv.u_i) >= 0) AND (((uv.v_i * r.sky_w) + uv.u_i) < octet_length(r.sky_pi))) THEN get_byte(r.sky_pi, ((uv.v_i * r.sky_w) + uv.u_i))
                        ELSE 0
                    END
                    ELSE 0
                END)::bigint) AS winner_key
           FROM (((plane_rays r
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN LATERAL ( SELECT
                        CASE
                            WHEN r.is_sky THEN r.sky_u
                            ELSE ((floor(((c.px + (r.depth_x * c.cos_v)) + ((r.tan_alpha * r.depth_x) * c.sin_v))))::integer & (rs.flat_size - 1))
                        END AS u_i,
                        CASE
                            WHEN r.is_sky THEN ((r.y - rs.sky_horizon_y) & (rs.sky_rows - 1))
                            ELSE ((floor(((c.py + (r.depth_x * c.sin_v)) - ((r.tan_alpha * r.depth_x) * c.cos_v))))::integer & (rs.flat_size - 1))
                        END AS v_i) uv)
          WHERE (r.span_is_sky OR (r.depth_x > rs.near))
        ), thing_view AS (
         SELECT (t.id)::bigint AS thing_id,
            t.x,
            t.y,
            t.angle,
                CASE
                    WHEN (COALESCE(d.explodes, false) AND (ai.state = 'die'::actor_state)) THEN d.death_sprite
                    WHEN ((h.alive = false) AND ((ai.state IS NULL) OR (ai.state = 'dead'::actor_state))) THEN d.death_sprite
                    ELSE rt.sprite
                END AS sprite,
                CASE
                    WHEN ((h.alive = false) AND ((ai.state IS NULL) OR (ai.state = 'dead'::actor_state))) THEN
                    CASE
                        WHEN ((h.health < (- h.max_health)) AND (d.xdeath_frame IS NOT NULL)) THEN d.xdeath_frame
                        ELSE d.death_frame
                    END
                    WHEN (f.frame IS NOT NULL) THEN f.frame
                    ELSE rt.frame
                END AS frame,
                CASE
                    WHEN ((h.alive = false) AND ((ai.state IS NULL) OR (ai.state = 'dead'::actor_state))) THEN d.death_fullbright
                    WHEN (f.frame IS NOT NULL) THEN f.fullbright
                    ELSE rt.fullbright
                END AS fullbright,
                CASE
                    WHEN rt.spawn_ceiling THEN ((s.ceil_height - rt.thing_height))::real
                    WHEN (d.floats AND COALESCE(h.alive, true)) THEN t.z
                    ELSE (s.floor_height)::real
                END AS base_z,
            s.floor_height,
            s.ceil_height,
            s.light_level AS sector_light,
            (((t.x - c.px) * cos(c.view_rad)) + ((t.y - c.py) * sin(c.view_rad))) AS depth,
            (((t.x - c.px) * sin(c.view_rad)) - ((t.y - c.py) * cos(c.view_rad))) AS side,
            ((((((floor((((degrees(atan2((t.y - c.py), (t.x - c.px))) - t.angle) + rs.rotation_offset) / rs.rotation_span)))::integer % 8) + 8) % 8) + 1))::smallint AS wanted_rotation,
            COALESCE(d.fuzzy, false) AS fuzz
           FROM ((((((((((render_things rt
             CROSS JOIN render_context rc)
             CROSS JOIN render_settings rs)
             JOIN things t ON (((t.map_id = rt.map_id) AND (t.id = rt.thing_id))))
             LEFT JOIN thing_health h ON (((h.map_id = rt.map_id) AND (h.thing_id = rt.thing_id))))
             LEFT JOIN thing_combat_defs d ON ((d.thing_type = t.type)))
             LEFT JOIN monster_ai ai ON (((ai.map_id = rt.map_id) AND (ai.thing_id = rt.thing_id))))
             LEFT JOIN thing_ai_frames f ON (((f.thing_type = t.type) AND (f.state = ai.state) AND (f.seq_index = ai.seq_index))))
             LEFT JOIN picked_up_items pu ON (((pu.map_id = rt.map_id) AND (pu.thing_id = rt.thing_id))))
             JOIN sectors_lit s ON (((s.map_id = rt.map_id) AND (s.id = COALESCE(ai.sector_id, rt.sector_id)))))
             CROSS JOIN cam c)
          WHERE ((rt.map_id = rc.map_id) AND ((t.flags & rc.skill_bit) <> 0) AND ((t.flags & 16) = 0) AND (pu.thing_id IS NULL) AND (NOT (COALESCE(d.explodes, false) AND (ai.state = 'dead'::actor_state))))
        UNION ALL
         SELECT (- e.effect_id) AS thing_id,
            e.x,
            e.y,
            (0)::smallint AS int2,
            ed.sprite,
            SUBSTRING(ed.frame_sequence FROM (LEAST((length(ed.frame_sequence) - 1), ((e.age / ed.tics_per_frame))::integer) + 1) FOR 1) AS "substring",
            ed.fullbright,
            e.z,
            s.floor_height,
            s.ceil_height,
            COALESCE(s.light_level, ps.light_level) AS "coalesce",
            (((e.x - c.px) * cos(c.view_rad)) + ((e.y - c.py) * sin(c.view_rad))),
            (((e.x - c.px) * sin(c.view_rad)) - ((e.y - c.py) * cos(c.view_rad))),
            (0)::smallint AS int2,
            false
           FROM (((((world_effects e
             CROSS JOIN render_context rc)
             CROSS JOIN cam c)
             CROSS JOIN player_sector ps)
             JOIN effect_sprite_defs ed ON ((ed.effect_type = e.effect_type)))
             LEFT JOIN sectors_lit s ON (((s.map_id = e.map_id) AND (s.id = e.sector_id))))
          WHERE (e.map_id = rc.map_id)
        UNION ALL
         SELECT (ot.id)::bigint AS id,
            ot.x,
            ot.y,
            ot.angle,
            'PLAY'::character varying(4) AS "varchar",
            op.sprite_frame,
            false,
            (s.floor_height)::real AS floor_height,
            s.floor_height,
            s.ceil_height,
            s.light_level,
            (((ot.x - c.px) * cos(c.view_rad)) + ((ot.y - c.py) * sin(c.view_rad))),
            (((ot.x - c.px) * sin(c.view_rad)) - ((ot.y - c.py) * cos(c.view_rad))),
            ((((((floor((((degrees(atan2((ot.y - c.py), (ot.x - c.px))) - ot.angle) + rs.rotation_offset) / rs.rotation_span)))::integer % 8) + 8) % 8) + 1))::smallint AS int2,
            (op.invis_tics > 0)
           FROM (((((player_state op
             CROSS JOIN render_context rc)
             CROSS JOIN render_settings rs)
             JOIN things ot ON (((ot.map_id = op.map_id) AND (ot.id = op.player_thing_id))))
             JOIN sectors_lit s ON (((s.map_id = op.map_id) AND (s.id = op.sector_id))))
             CROSS JOIN cam c)
          WHERE ((op.map_id = rc.map_id) AND (op.player_thing_id <> rc.player_thing_id) AND (op.alive OR (EXISTS ( SELECT 1
                   FROM mp_players mx
                  WHERE ((mx.map_id = op.map_id) AND (mx.player_thing_id = op.player_thing_id) AND (mx.role_name IS NOT NULL))))))
        UNION ALL
         SELECT (- ('1000000000000'::bigint + mp.projectile_id)) AS thing_id,
            mp.x,
            mp.y,
            (degrees(atan2((mp.vy)::double precision, (mp.vx)::double precision)))::smallint AS degrees,
                CASE
                    WHEN (mp.state = 'fly'::projectile_state) THEN pd.fly_sprite
                    ELSE pd.impact_sprite
                END AS impact_sprite,
                CASE
                    WHEN (mp.projectile_type = 'rocket'::projectile_kind) THEN
                    CASE
                        WHEN (mp.state = 'fly'::projectile_state) THEN 'A'::text
                        WHEN (mp.age < 8) THEN 'B'::text
                        WHEN (mp.age < 14) THEN 'C'::text
                        ELSE 'D'::text
                    END
                    WHEN (mp.projectile_type = 'plasma'::projectile_kind) THEN
                    CASE
                        WHEN (mp.state = 'fly'::projectile_state) THEN
                        CASE
                            WHEN (((mp.age)::integer % 12) < 6) THEN 'A'::text
                            ELSE 'B'::text
                        END
                        WHEN (mp.age < 4) THEN 'A'::text
                        WHEN (mp.age < 8) THEN 'B'::text
                        WHEN (mp.age < 12) THEN 'C'::text
                        WHEN (mp.age < 16) THEN 'D'::text
                        ELSE 'E'::text
                    END
                    WHEN (mp.projectile_type = 'bfg'::projectile_kind) THEN
                    CASE
                        WHEN (mp.state = 'fly'::projectile_state) THEN
                        CASE
                            WHEN (((mp.age)::integer % 8) < 4) THEN 'A'::text
                            ELSE 'B'::text
                        END
                        WHEN (mp.age < 8) THEN 'A'::text
                        WHEN (mp.age < 16) THEN 'B'::text
                        WHEN (mp.age < 24) THEN 'C'::text
                        WHEN (mp.age < 32) THEN 'D'::text
                        WHEN (mp.age < 40) THEN 'E'::text
                        ELSE 'F'::text
                    END
                    ELSE
                    CASE
                        WHEN (mp.state = 'fly'::projectile_state) THEN
                        CASE
                            WHEN (((mp.age)::integer % 8) < 4) THEN 'A'::text
                            ELSE 'B'::text
                        END
                        WHEN (mp.age < 5) THEN 'C'::text
                        WHEN (mp.age < 10) THEN 'D'::text
                        ELSE 'E'::text
                    END
                END AS "case",
            true,
            mp.z,
            COALESCE(s.floor_height, ps.floor_height) AS "coalesce",
            COALESCE(s.ceil_height, ps.ceil_height) AS "coalesce",
            COALESCE(s.light_level, ps.light_level) AS "coalesce",
            (((mp.x - c.px) * cos(c.view_rad)) + ((mp.y - c.py) * sin(c.view_rad))),
            (((mp.x - c.px) * sin(c.view_rad)) - ((mp.y - c.py) * cos(c.view_rad))),
                CASE
                    WHEN (mp.state = 'fly'::projectile_state) THEN ((((((floor((((degrees(atan2((mp.y - c.py), (mp.x - c.px))) - degrees(atan2((mp.vy)::double precision, (mp.vx)::double precision))) + rs.rotation_offset) / rs.rotation_span)))::integer % 8) + 8) % 8) + 1))::smallint
                    ELSE (0)::smallint
                END AS "case",
            false
           FROM ((((((monster_projectiles mp
             CROSS JOIN render_context rc)
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN player_sector ps)
             JOIN projectile_defs pd ON ((pd.projectile_type = mp.projectile_type)))
             LEFT JOIN sectors_lit s ON (((s.map_id = mp.map_id) AND (s.id = mp.sector_id))))
          WHERE (mp.map_id = rc.map_id)
        ), thing_projected AS MATERIALIZED (
         SELECT tv.thing_id,
            tv.x,
            tv.y,
            tv.angle,
            tv.sprite,
            tv.frame,
            tv.fullbright,
            tv.base_z,
            tv.floor_height,
            tv.ceil_height,
            tv.sector_light,
            tv.depth,
            tv.side,
            tv.wanted_rotation,
            tv.fuzz,
            sf.lump_name,
            sf.flipped,
            sf.width,
            sf.height,
            sf.left_offset,
            sf.top_offset,
            (rs.focal / tv.depth) AS scale,
            (rs.cx + ((rs.focal * tv.side) / tv.depth)) AS origin_x
           FROM ((thing_view tv
             CROSS JOIN render_settings rs)
             CROSS JOIN LATERAL ( SELECT f.sprite,
                    f.frame,
                    f.rotation,
                    f.lump_name,
                    f.flipped,
                    f.width,
                    f.height,
                    f.left_offset,
                    f.top_offset
                   FROM sprite_frames f
                  WHERE (((f.sprite)::text = (tv.sprite)::text) AND (f.frame = tv.frame) AND (f.rotation = ANY (ARRAY[0, (tv.wanted_rotation)::integer])))
                  ORDER BY
                        CASE
                            WHEN (f.rotation = tv.wanted_rotation) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) sf)
          WHERE ((tv.depth >= (4.0)::double precision) AND (abs(tv.side) <= (tv.depth * (2.0)::double precision)))
        ), thing_bounds AS (
         SELECT tp.thing_id,
            tp.x,
            tp.y,
            tp.angle,
            tp.sprite,
            tp.frame,
            tp.fullbright,
            tp.base_z,
            tp.floor_height,
            tp.ceil_height,
            tp.sector_light,
            tp.depth,
            tp.side,
            tp.wanted_rotation,
            tp.fuzz,
            tp.lump_name,
            tp.flipped,
            tp.width,
            tp.height,
            tp.left_offset,
            tp.top_offset,
            tp.scale,
            tp.origin_x,
            (tp.origin_x - (tp.scale * (tp.left_offset)::double precision)) AS x_left_f,
            (tp.origin_x + (tp.scale * ((tp.width - tp.left_offset))::double precision)) AS x_right_f,
            (rs.cy - (tp.scale * ((tp.base_z + (tp.top_offset)::double precision) - c.pz))) AS y_top_f,
            (rs.cy - (tp.scale * (((tp.base_z + (tp.top_offset)::double precision) - (tp.height)::double precision) - c.pz))) AS y_bottom_f
           FROM ((thing_projected tp
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
        ), thing_bounds_lit AS (
         SELECT tb.thing_id,
            tb.x,
            tb.y,
            tb.angle,
            tb.sprite,
            tb.frame,
            tb.fullbright,
            tb.base_z,
            tb.floor_height,
            tb.ceil_height,
            tb.sector_light,
            tb.depth,
            tb.side,
            tb.wanted_rotation,
            tb.fuzz,
            tb.lump_name,
            tb.flipped,
            tb.width,
            tb.height,
            tb.left_offset,
            tb.top_offset,
            tb.scale,
            tb.origin_x,
            tb.x_left_f,
            tb.x_right_f,
            tb.y_top_f,
            tb.y_bottom_f,
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    WHEN tb.fullbright THEN 0
                    ELSE doom_light_index((tb.sector_light)::double precision, wr.extra_light, doom_light_scale(tb.depth))
                END AS base_light
           FROM ((thing_bounds tb
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
        ), thing_spans AS (
         SELECT tb.thing_id,
            tb.x,
            tb.y,
            tb.angle,
            tb.sprite,
            tb.frame,
            tb.fullbright,
            tb.base_z,
            tb.floor_height,
            tb.ceil_height,
            tb.sector_light,
            tb.depth,
            tb.side,
            tb.wanted_rotation,
            tb.fuzz,
            tb.lump_name,
            tb.flipped,
            tb.width,
            tb.height,
            tb.left_offset,
            tb.top_offset,
            tb.scale,
            tb.origin_x,
            tb.x_left_f,
            tb.x_right_f,
            tb.y_top_f,
            tb.y_bottom_f,
            tb.base_light,
            mpl.slot AS mp_slot,
            (sl.pixels || '\x'::bytea) AS pixels,
            (sl.mask || '\x'::bytea) AS mask,
            GREATEST(0, (floor(tb.x_left_f))::integer) AS x_lo,
            LEAST((rs.screen_w - 1), ((ceil(tb.x_right_f))::integer - 1)) AS x_hi,
            GREATEST(0, (floor(tb.y_top_f))::integer) AS y_lo,
            LEAST((rs.screen_h - 1), ((ceil(tb.y_bottom_f))::integer - 1)) AS y_hi
           FROM ((((thing_bounds_lit tb
             JOIN sprite_lumps sl ON (((sl.lump_name)::text = (tb.lump_name)::text)))
             CROSS JOIN render_settings rs)
             CROSS JOIN render_context rc)
             LEFT JOIN mp_players mpl ON (((mpl.map_id = rc.map_id) AND (mpl.player_thing_id = tb.thing_id))))
          WHERE ((tb.x_right_f > (0)::double precision) AND (tb.x_left_f < (rs.screen_w)::double precision) AND (tb.y_bottom_f > (0)::double precision) AND (tb.y_top_f < (rs.screen_h)::double precision))
         OFFSET 0
        ), thing_columns AS (
         SELECT c.thing_id,
            c.screen_x,
            c.depth,
            c.fuzz,
            c.base_light,
            c.mp_slot,
            c.pixels,
            c.mask,
            c.width,
            c.height,
            c.y_top_f,
            c.scale,
            c.y_lo,
            c.y_hi,
                CASE
                    WHEN c.flipped THEN ((c.width - 1) - uu.raw_u)
                    ELSE uu.raw_u
                END AS col_off
           FROM (( SELECT t.thing_id,
                    t.depth,
                    t.fuzz,
                    t.base_light,
                    t.mp_slot,
                    t.pixels,
                    t.mask,
                    t.width,
                    t.height,
                    t.y_top_f,
                    t.scale,
                    t.y_lo,
                    t.y_hi,
                    t.flipped,
                    t.x_left_f,
                    generate_series(t.x_lo, t.x_hi) AS screen_x
                   FROM thing_spans t) c
             CROSS JOIN LATERAL ( SELECT LEAST((c.width - 1), GREATEST(0, (floor((((c.screen_x)::double precision - c.x_left_f) / c.scale)))::integer)) AS raw_u) uu)
         OFFSET 0
        ), thing_texels AS (
         SELECT p.thing_id,
            p.screen_x,
            p.screen_y,
            p.depth,
            p.fuzz,
            p.base_light,
            p.mp_slot,
            p.pixels,
            p.mask,
            ((LEAST((p.height - 1), GREATEST(0, (floor((((p.screen_y)::double precision - p.y_top_f) / p.scale)))::integer)) * p.width) + p.col_off) AS off
           FROM ( SELECT c.thing_id,
                    c.screen_x,
                    c.depth,
                    c.fuzz,
                    c.base_light,
                    c.mp_slot,
                    c.pixels,
                    c.mask,
                    c.width,
                    c.height,
                    c.y_top_f,
                    c.scale,
                    c.col_off,
                    generate_series(c.y_lo, c.y_hi) AS screen_y
                   FROM thing_columns c) p
         OFFSET 0
        ), thing_pixels AS (
         SELECT t.thing_id,
            t.screen_x AS x,
            t.screen_y AS y,
            t.depth,
            t.fuzz,
            t.base_light,
                CASE
                    WHEN ((t.mp_slot > 1) AND ((px.raw >= 112) AND (px.raw <= 127))) THEN ((px.raw - 112) +
                    CASE t.mp_slot
                        WHEN 2 THEN 96
                        WHEN 3 THEN 64
                        ELSE 32
                    END)
                    ELSE px.raw
                END AS palette_index
           FROM (thing_texels t
             CROSS JOIN LATERAL ( SELECT get_byte(t.pixels, t.off) AS raw) px)
          WHERE (get_byte(t.mask, t.off) <> 0)
        ), sprite_fragments AS (
         SELECT ((sp.y * rs.screen_w) + sp.x) AS pix,
            ((((((((GREATEST((0.0)::double precision, LEAST(sp.depth, (131071.0)::double precision)) * (4096)::double precision))::bigint << 34) | (((2)::bigint - (1)::bigint) << 32)) | (LEAST((0)::bigint, (3)::bigint) << 30)) | (LEAST((65535)::bigint, GREATEST((0)::bigint, (sp.thing_id + 32768))) << 14)) | ((
                CASE
                    WHEN sp.fuzz THEN (26 + ((((sp.x * 7) + (sp.y * 13)) + (sp.depth)::integer) % 5))
                    ELSE sp.base_light
                END)::bigint << 8)) | (sp.palette_index)::bigint) AS winner_key
           FROM (thing_pixels sp
             CROSS JOIN render_settings rs)
        ), psprite_layers AS (
         SELECT 1 AS layer,
            wr.sprite,
            wr.frame,
            (wr.sx)::double precision AS sx,
            (wr.sy)::double precision AS sy,
            COALESCE(wr.fullbright, false) AS fullbright
           FROM weapon_runtime wr
        UNION ALL
         SELECT 2,
            wr.flash_sprite,
            wr.flash_frame AS frame,
            wr.sx,
            wr.sy,
            COALESCE(wr.flash_fullbright, true) AS "coalesce"
           FROM weapon_runtime wr
          WHERE ((wr.flash_sprite IS NOT NULL) AND (wr.flash_frame IS NOT NULL))
        ), psprite_patches AS MATERIALIZED (
         SELECT p.layer,
            p.sprite,
            p.frame,
            p.sx,
            p.sy,
            p.fullbright,
            sf.width,
            sf.height,
            sf.left_offset,
            sf.top_offset,
            (sl.pixels || '\x'::bytea) AS pixels,
            (sl.mask || '\x'::bytea) AS mask,
            (p.sx - (sf.left_offset)::double precision) AS x_left_f,
            ((((p.sy - (sf.top_offset)::double precision) + rs.cy) - (100.0)::double precision) - (0.5)::double precision) AS y_top_f
           FROM (((psprite_layers p
             CROSS JOIN render_settings rs)
             JOIN sprite_frames sf ON ((((sf.sprite)::text = (p.sprite)::text) AND (sf.frame = p.frame) AND (sf.rotation = 0))))
             JOIN sprite_lumps sl ON (((sl.lump_name)::text = (sf.lump_name)::text)))
        ), psprite_pixels AS (
         SELECT q.layer,
            q.x,
            q.y,
            q.fullbright,
            get_byte(q.pixels, (((q.y - q.y0) * q.width) + (q.x - q.x0))) AS palette_index
           FROM ( SELECT c.layer,
                    c.fullbright,
                    c.pixels,
                    c.mask,
                    c.width,
                    c.height,
                    c.x0,
                    c.y0,
                    c.x,
                    generate_series(GREATEST(0, c.y0), LEAST((rs.screen_h - 1), ((c.y0 + c.height) - 1))) AS y
                   FROM (( SELECT p.layer,
                            p.fullbright,
                            p.pixels,
                            p.mask,
                            p.width,
                            p.height,
                            (floor(p.x_left_f))::integer AS x0,
                            (floor(p.y_top_f))::integer AS y0,
                            generate_series(GREATEST(0, (floor(p.x_left_f))::integer), LEAST((rs_1.screen_w - 1), (((floor(p.x_left_f))::integer + p.width) - 1))) AS x
                           FROM (psprite_patches p
                             CROSS JOIN render_settings rs_1)) c
                     CROSS JOIN render_settings rs)) q
          WHERE (get_byte(q.mask, (((q.y - q.y0) * q.width) + (q.x - q.x0))) <> 0)
        ), psprite_lit AS (
         SELECT p.layer,
            p.x,
            p.y,
            p.palette_index,
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    WHEN p.fullbright THEN 0
                    ELSE doom_light_index((ps.light_level)::double precision, wr.extra_light, rs.light_psprite_bias)
                END AS light_index
           FROM (((psprite_pixels p
             CROSS JOIN player_sector ps)
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
        ), psprite_resolved AS (
         SELECT DISTINCT psprite_lit.x,
            psprite_lit.y
           FROM psprite_lit
        ), player_ui_state AS (
         SELECT ps.health,
            ps.alive,
            ps.pain_face_tics,
            ps.armor,
            ps.ammo_bullets,
            ps.ammo_shells,
            ps.ammo_rockets,
            ps.ammo_cells,
            ps.key_blue,
            ps.key_yellow,
            ps.key_red,
            ps.damage_count,
            ps.bonus_count,
            ps.radsuit_tics,
            ps.message,
            ps.message_tics,
            ps.backpack,
            wd.ammo_type AS current_ammo_type
           FROM (((player_state ps
             CROSS JOIN render_context rc)
             LEFT JOIN player_weapons w ON (((w.map_id = ps.map_id) AND (w.player_thing_id = ps.player_thing_id))))
             LEFT JOIN weapon_defs wd ON ((wd.weapon_id = COALESCE(w.current_weapon, 2))))
          WHERE ((ps.map_id = rc.map_id) AND (ps.player_thing_id = rc.player_thing_id))
        ), message_glyphs AS (
         SELECT gs.i AS pos,
            SUBSTRING(upper(pu.message) FROM gs.i FOR 1) AS ch
           FROM (player_ui_state pu
             CROSS JOIN LATERAL generate_series(1, length(pu.message)) gs(i))
          WHERE ((pu.message IS NOT NULL) AND (pu.message_tics > 0))
        ), message_placed AS (
         SELECT g.pos,
            g.ch,
                CASE
                    WHEN (g.ch = ' '::text) THEN NULL::text
                    ELSE ('STCFN'::text || lpad((ascii(g.ch))::text, 3, '0'::text))
                END AS patch,
            sum(
                CASE
                    WHEN (g.ch = ' '::text) THEN 4
                    ELSE COALESCE((( SELECT p.width
                       FROM ui_patches p
                      WHERE ((p.name)::text = ('STCFN'::text || lpad((ascii(g.ch))::text, 3, '0'::text)))))::integer, 4)
                END) OVER (ORDER BY g.pos ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS pen
           FROM message_glyphs g
        ), message_pixels AS (
         SELECT ((COALESCE(mp.pen, (0)::bigint))::integer + px.dx) AS x,
            (1 + px.dy) AS y,
            px.palette_index
           FROM (message_placed mp
             JOIN ui_hud_pixels px ON (((px.name)::text = mp.patch)))
          WHERE (mp.patch IS NOT NULL)
        ), ranked_fragments AS (
         SELECT fragments.pix,
            fragments.winner_key
           FROM fragments
        UNION ALL
         SELECT sprite_fragments.pix,
            sprite_fragments.winner_key
           FROM sprite_fragments
        UNION ALL
         SELECT plane_fragments.pix,
            plane_fragments.winner_key
           FROM plane_fragments
        UNION ALL
         SELECT ((p.y * rs.screen_w) + p.x),
            ((((- ((p.layer)::bigint + 1)) << 32) | ((p.light_index)::bigint << 8)) | (p.palette_index)::bigint)
           FROM (psprite_lit p
             CROSS JOIN render_settings rs)
        UNION ALL
         SELECT ((m.y * rs.screen_w) + m.x),
            ((('-8'::integer)::bigint << 32) | (m.palette_index)::bigint)
           FROM (message_pixels m
             CROSS JOIN render_settings rs)
          WHERE ((m.x >= 0) AND (m.x <= (rs.screen_w - 1)) AND ((m.y >= 0) AND (m.y <= (rs.screen_h - 1))))
        ), resolved AS NOT MATERIALIZED (
         SELECT DISTINCT ON (ranked_fragments.pix) ranked_fragments.pix,
            ranked_fragments.winner_key
           FROM ranked_fragments
          ORDER BY ranked_fragments.pix, ranked_fragments.winner_key
        ), active_palette AS (
         SELECT (
                CASE
                    WHEN (pu.damage_count > 0) THEN (LEAST(7, ((pu.damage_count + 7) / 8)) + 1)
                    WHEN (pu.bonus_count > 0) THEN (LEAST(3, ((pu.bonus_count + 7) / 8)) + 9)
                    WHEN ((pu.radsuit_tics > 128) OR ((pu.radsuit_tics & 8) <> 0)) THEN 13
                    ELSE 0
                END)::smallint AS pal
           FROM player_ui_state pu
        ), weapon_ownership AS (
         SELECT slot.weapon_id,
            (EXISTS ( SELECT 1
                   FROM (player_weapon_owned o
                     CROSS JOIN render_context rc)
                  WHERE ((o.map_id = rc.map_id) AND (o.player_thing_id = rc.player_thing_id) AND (o.weapon_id = slot.weapon_id)))) AS owned
           FROM generate_series(2, 7) slot(weapon_id)
        ), weapon_layers AS (
         SELECT 2 AS layer,
            (
                CASE
                    WHEN weapon_ownership.owned THEN 'STYSNUM'::text
                    ELSE 'STGNUM'::text
                END || (weapon_ownership.weapon_id)::text) AS patch,
            (111 + (((weapon_ownership.weapon_id - 2) % 3) * 12)) AS x,
            (172 + (((weapon_ownership.weapon_id - 2) / 3) * 10)) AS y
           FROM weapon_ownership
        ), ui_face AS (
         SELECT
                CASE
                    WHEN (NOT pu.alive) THEN 'STFDEAD0'::text
                    WHEN (pu.pain_face_tics > 0) THEN ('STFOUCH'::text || (LEAST(4, GREATEST(0, ((100 - GREATEST(0, LEAST(100, pu.health))) / 20))))::text)
                    ELSE (('STFST'::text || (LEAST(4, GREATEST(0, ((100 - GREATEST(0, LEAST(100, pu.health))) / 20))))::text) || '0'::text)
                END AS face_patch
           FROM player_ui_state pu
        ), status_bar AS NOT MATERIALIZED (
         SELECT rs.screen_h AS top_y,
            (rs.screen_h + 4) AS digit_y,
            90 AS health_right_x,
            221 AS armor_right_x,
            44 AS ammo_right_x,
            288 AS ammo_box_right_x,
            314 AS max_ammo_right_x,
            239 AS key_x,
            143 AS face_x,
            14 AS tall_digit_w,
            4 AS short_digit_w
           FROM render_settings rs
        ), health_digits AS (
         SELECT pu.health AS value,
            sb.health_right_x AS right_x
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        ), armor_digits AS (
         SELECT pu.armor AS value,
            sb.armor_right_x AS right_x
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        ), ammo_digits AS (
         SELECT
                CASE pu.current_ammo_type
                    WHEN 'bullets'::ammo_kind THEN pu.ammo_bullets
                    WHEN 'shells'::ammo_kind THEN pu.ammo_shells
                    WHEN 'rockets'::ammo_kind THEN pu.ammo_rockets
                    WHEN 'cells'::ammo_kind THEN pu.ammo_cells
                    ELSE NULL::integer
                END AS value,
            sb.ammo_right_x AS right_x
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
          WHERE (pu.current_ammo_type IS NOT NULL)
        ), ammo_type_values AS (
         SELECT pu.ammo_bullets AS value,
            sb.ammo_box_right_x AS right_x,
            173 AS y
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        UNION ALL
         SELECT pu.ammo_shells,
            sb.ammo_box_right_x,
            179
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        UNION ALL
         SELECT pu.ammo_rockets,
            sb.ammo_box_right_x,
            185
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        UNION ALL
         SELECT pu.ammo_cells,
            sb.ammo_box_right_x,
            191
           FROM (player_ui_state pu
             CROSS JOIN status_bar sb)
        ), ammo_max_values AS (
         SELECT
                CASE
                    WHEN pu.backpack THEN ad.backpack_cap
                    ELSE ad.cap
                END AS value,
            sb.max_ammo_right_x AS right_x,
                CASE ad.ammo_type
                    WHEN 'bullets'::ammo_kind THEN 173
                    WHEN 'shells'::ammo_kind THEN 179
                    WHEN 'rockets'::ammo_kind THEN 185
                    ELSE 191
                END AS y
           FROM ((player_ui_state pu
             CROSS JOIN status_bar sb)
             CROSS JOIN ammo_defs ad)
        ), key_layers AS (
         SELECT 1 AS layer,
            'STKEYS0'::text AS patch,
            sb.key_x AS x,
            171 AS y
           FROM (player_ui_state
             CROSS JOIN status_bar sb)
          WHERE player_ui_state.key_blue
        UNION ALL
         SELECT 1,
            'STKEYS1'::text AS text,
            sb.key_x,
            181
           FROM (player_ui_state
             CROSS JOIN status_bar sb)
          WHERE player_ui_state.key_yellow
        UNION ALL
         SELECT 1,
            'STKEYS2'::text AS text,
            sb.key_x,
            191
           FROM (player_ui_state
             CROSS JOIN status_bar sb)
          WHERE player_ui_state.key_red
        ), digit_layers AS (
         SELECT 1 AS layer,
            ('STTNUM'::text || SUBSTRING((hd.value)::text FROM gs.i FOR 1)) AS patch,
            (hd.right_x - (((length((hd.value)::text) - gs.i) + 1) * sb.tall_digit_w)) AS x,
            sb.digit_y AS y
           FROM ((health_digits hd
             CROSS JOIN status_bar sb)
             CROSS JOIN generate_series(1, 11) gs(i))
          WHERE (gs.i <= length((hd.value)::text))
        UNION ALL
         SELECT 1,
            ('STTNUM'::text || SUBSTRING((ad.value)::text FROM gs.i FOR 1)) AS patch,
            (ad.right_x - (((length((ad.value)::text) - gs.i) + 1) * sb.tall_digit_w)) AS x,
            sb.digit_y AS y
           FROM ((armor_digits ad
             CROSS JOIN status_bar sb)
             CROSS JOIN generate_series(1, 11) gs(i))
          WHERE (gs.i <= length((ad.value)::text))
        UNION ALL
         SELECT 1,
            ('STTNUM'::text || SUBSTRING((am.value)::text FROM gs.i FOR 1)) AS patch,
            (am.right_x - (((length((am.value)::text) - gs.i) + 1) * sb.tall_digit_w)) AS x,
            sb.digit_y AS y
           FROM ((ammo_digits am
             CROSS JOIN status_bar sb)
             CROSS JOIN generate_series(1, 11) gs(i))
          WHERE (gs.i <= length((am.value)::text))
        UNION ALL
         SELECT 1,
            ('STYSNUM'::text || SUBSTRING((at.value)::text FROM gs.i FOR 1)) AS patch,
            (at.right_x - (((length((at.value)::text) - gs.i) + 1) * sb.short_digit_w)) AS x,
            at.y
           FROM ((ammo_type_values at
             CROSS JOIN status_bar sb)
             CROSS JOIN generate_series(1, 11) gs(i))
          WHERE (gs.i <= length((at.value)::text))
        UNION ALL
         SELECT 1,
            ('STYSNUM'::text || SUBSTRING((mx.value)::text FROM gs.i FOR 1)) AS patch,
            (mx.right_x - (((length((mx.value)::text) - gs.i) + 1) * sb.short_digit_w)) AS x,
            mx.y
           FROM ((ammo_max_values mx
             CROSS JOIN status_bar sb)
             CROSS JOIN generate_series(1, 11) gs(i))
          WHERE (gs.i <= length((mx.value)::text))
        ), ui_layers AS (
         SELECT digit_layers.layer,
            digit_layers.patch,
            digit_layers.x,
            digit_layers.y
           FROM digit_layers
        UNION ALL
         SELECT key_layers.layer,
            key_layers.patch,
            key_layers.x,
            key_layers.y
           FROM key_layers
        UNION ALL
         SELECT weapon_layers.layer,
            weapon_layers.patch,
            weapon_layers.x,
            weapon_layers.y
           FROM weapon_layers
        UNION ALL
         SELECT 1,
            ui_face.face_patch,
            sb.face_x,
            sb.top_y
           FROM (ui_face
             CROSS JOIN status_bar sb)
        ), ui_layer_patches AS MATERIALIZED (
         SELECT l.layer,
            l.patch,
            (l.x - p.left_offset) AS dest_x,
            (l.y - p.top_offset) AS dest_y
           FROM (ui_layers l
             JOIN ui_patches p ON (((p.name)::text = l.patch)))
        ), ui_pixels AS (
         SELECT ulp.layer,
            (ulp.dest_x + px.dx) AS x,
            (ulp.dest_y + px.dy) AS y,
            px.palette_index
           FROM (ui_layer_patches ulp
             CROSS JOIN LATERAL ( SELECT p.dx,
                    p.dy,
                    p.palette_index
                   FROM ui_hud_pixels p
                  WHERE ((p.name)::text = ulp.patch)
                 OFFSET 0) px)
        ), ui_resolved AS (
         SELECT (((u.y - rs.screen_h) * rs.screen_w) + u.x) AS pix,
            (max(((u.layer * 256) + u.palette_index)) % 256) AS palette_index
           FROM (ui_pixels u
             CROSS JOIN render_settings rs)
          WHERE ((u.x >= 0) AND (u.x <= (rs.screen_w - 1)) AND ((u.y >= rs.screen_h) AND (u.y <= (rs.screen_h + 31))))
          GROUP BY (((u.y - rs.screen_h) * rs.screen_w) + u.x)
        ), ui_bar_static AS MATERIALIZED (
         SELECT (ub.idx || '\x'::bytea) AS b
           FROM (active_palette ap
             JOIN ui_bar_bytes ub ON ((ub.pal = ap.pal)))
        ), palette_bytes AS MATERIALIZED (
         SELECT
                CASE
                    WHEN (cb.pal IS NULL) THEN decode(repeat(encode('\x00'::bytea, 'hex'::text), (64 * 256)), 'hex'::text)
                    ELSE (cb.idx || '\x'::bytea)
                END AS b,
            octet_length('\x00'::bytea) AS bpp
           FROM ((( SELECT) one
             LEFT JOIN active_palette ap ON (true))
             LEFT JOIN colormap_bytes cb ON ((cb.pal = ap.pal)))
        ), palette_level0 AS MATERIALIZED (
         SELECT SUBSTRING(palette_bytes.b FROM 1 FOR (256 * palette_bytes.bpp)) AS b,
            palette_bytes.bpp
           FROM palette_bytes
        ), ui_overlay AS (
         SELECT ur.pix,
            SUBSTRING(( SELECT pb.b
                   FROM palette_level0 pb) FROM ((ur.palette_index * octet_length('\x00'::bytea)) + 1) FOR octet_length('\x00'::bytea)) AS rgb
           FROM ui_resolved ur
        ), ui_colored AS (
         SELECT
                CASE
                    WHEN (o.n = 0) THEN st.b
                    ELSE (o.b || SUBSTRING(st.b FROM (((o.last_pix + 1) * pb.bpp) + 1)))
                END AS b
           FROM ((ui_bar_static st
             CROSS JOIN palette_level0 pb)
             CROSS JOIN LATERAL ( SELECT count(*) AS n,
                    max(v.pix) AS last_pix,
                    string_agg((SUBSTRING(st.b FROM (((v.prev + 1) * pb.bpp) + 1) FOR (((v.pix - v.prev) - 1) * pb.bpp)) || COALESCE(v.rgb, SUBSTRING(st.b FROM ((v.pix * pb.bpp) + 1) FOR pb.bpp))), '\x'::bytea ORDER BY v.pix) AS b
                   FROM ( SELECT o_1.pix,
                            o_1.rgb,
                            lag(o_1.pix, 1, '-1'::integer) OVER (ORDER BY o_1.pix) AS prev
                           FROM ui_overlay o_1) v) o)
        ), view_colored AS NOT MATERIALIZED (
         SELECT r.pix,
            SUBSTRING(( SELECT pb.b
                   FROM palette_bytes pb) FROM ((((r.winner_key & (16383)::bigint))::integer * octet_length('\x00'::bytea)) + 1) FOR octet_length('\x00'::bytea)) AS rgb
           FROM resolved r
        ), view_holes AS (
         SELECT g.g AS pix,
            '\x00'::bytea AS rgb
           FROM (render_settings rs
             CROSS JOIN LATERAL generate_series(0, ((rs.screen_w * rs.screen_h) - 1)) g(g))
          WHERE (NOT (EXISTS ( SELECT 1
                   FROM resolved r
                  WHERE (r.pix = g.g))))
        ), frame AS (
         SELECT (
                CASE
                    WHEN (v.n = (rs.screen_w * rs.screen_h)) THEN v.b
                    ELSE ( SELECT string_agg(COALESCE(vc.rgb, '\x00'::bytea), '\x'::bytea ORDER BY g.pix) AS string_agg
                       FROM (generate_series(0, ((rs.screen_w * rs.screen_h) - 1)) g(pix)
                         LEFT JOIN view_colored vc ON ((vc.pix = g.pix))))
                END || COALESCE(u.b, '\x'::bytea)) AS frame_rgb
           FROM ((( SELECT string_agg(view_colored.rgb, '\x'::bytea ORDER BY view_colored.pix) AS b,
                    count(*) AS n
                   FROM view_colored) v
             CROSS JOIN ( SELECT ( SELECT ui_colored.b
                           FROM ui_colored) AS b) u)
             CROSS JOIN render_settings rs)
        )
 SELECT
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pos)) THEN (( SELECT set_byte('\x00'::bytea, 0, (ap.pal)::integer) AS set_byte
               FROM active_palette ap) || frame_rgb)
            ELSE NULL::bytea
        END AS frame_rgb
   FROM frame;
$view$::text$template$;
