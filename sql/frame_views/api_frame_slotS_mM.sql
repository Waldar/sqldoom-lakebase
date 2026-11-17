-- Template of the frame view api_frame_slot<slot>_m<map> (one per map and
-- player slot). doom.create_frame_views() fills in {name}, {map_id}, {slot}
-- and {thing_id} (the slot's player start, things.id) and creates the views.
CREATE OR REPLACE FUNCTION doom.frame_view_template_api_frame()
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $template$SELECT $view$CREATE OR REPLACE VIEW doom.{name} AS
 WITH RECURSIVE render_context AS (
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
        ), pos AS (
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
        ), render_settings AS (
         SELECT 320 AS screen_w,
            168 AS screen_h,
            radians((90.0)::double precision) AS fov_rad,
            (((320)::numeric / 2.0))::double precision AS cx,
            (((168)::numeric / 2.0))::double precision AS cy,
            ((((320)::numeric / 2.0))::double precision / tan((radians((90.0)::double precision) / (2.0)::double precision))) AS focal,
            tan((radians((90.0)::double precision) / (2.0)::double precision)) AS tan_half_fov,
            (0.001)::double precision AS near,
            ((16.0)::double precision * ((((320)::numeric / 2.0))::double precision / tan((radians((90.0)::double precision) / (2.0)::double precision)))) AS max_plane_depth,
            (202.5)::double precision AS rotation_offset,
            (45.0)::double precision AS rotation_span,
            32 AS light_index_invuln,
            23 AS light_psprite_bias,
            (256.0)::double precision AS sky_columns,
            (90.0)::double precision AS sky_degrees,
            128 AS sky_rows,
            100 AS sky_horizon_y,
            64 AS flat_size,
            (((320)::numeric / 2.0))::double precision AS cx_f,
            (((168)::numeric / 2.0))::double precision AS cy_f,
            (0.001)::double precision AS near_f,
            ((256.0 / 90.0))::double precision AS sky_ratio_f,
            256 AS sky_columns_i
        ), cam AS (
         SELECT pos.x AS px,
            pos.y AS py,
            pos.z AS pz,
            radians(pos.angle) AS view_rad
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
            (((c.px >= (nc.bbox_left)::double precision) AND (c.px <= (nc.bbox_right)::double precision) AND ((c.py >= (nc.bbox_bottom)::double precision) AND (c.py <= (nc.bbox_top)::double precision))) OR ((((((sin((- c.view_rad)) - (rs.tan_half_fov * cos((- c.view_rad)))) * (
                CASE
                    WHEN ((sin((- c.view_rad)) - (rs.tan_half_fov * cos((- c.view_rad)))) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + ((cos((- c.view_rad)) + (rs.tan_half_fov * sin((- c.view_rad)))) * (
                CASE
                    WHEN ((cos((- c.view_rad)) + (rs.tan_half_fov * sin((- c.view_rad)))) >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + ((((- c.px) * sin((- c.view_rad))) - (c.py * cos((- c.view_rad)))) + (rs.tan_half_fov * ((c.px * cos((- c.view_rad))) - (c.py * sin((- c.view_rad))))))) <= (0.5)::double precision) AND ((((((- sin((- c.view_rad))) - (rs.tan_half_fov * cos((- c.view_rad)))) * (
                CASE
                    WHEN (((- sin((- c.view_rad))) - (rs.tan_half_fov * cos((- c.view_rad)))) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + (((- cos((- c.view_rad))) + (rs.tan_half_fov * sin((- c.view_rad)))) * (
                CASE
                    WHEN (((- cos((- c.view_rad))) + (rs.tan_half_fov * sin((- c.view_rad)))) >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + (((c.px * sin((- c.view_rad))) + (c.py * cos((- c.view_rad)))) + (rs.tan_half_fov * ((c.px * cos((- c.view_rad))) - (c.py * sin((- c.view_rad))))))) <= (0.5)::double precision) AND (((((- cos((- c.view_rad))) * (
                CASE
                    WHEN ((- cos((- c.view_rad))) >= (0)::double precision) THEN nc.bbox_left
                    ELSE nc.bbox_right
                END)::double precision) + (sin((- c.view_rad)) * (
                CASE
                    WHEN (sin((- c.view_rad)) >= (0)::double precision) THEN nc.bbox_bottom
                    ELSE nc.bbox_top
                END)::double precision)) + ((rs.near + (c.px * cos((- c.view_rad)))) - (c.py * sin((- c.view_rad))))) <= (0.5)::double precision))) AS keep
           FROM (((node_children nc
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
                            WHEN ((st.side)::text = fs.front_side) THEN (0)::bigint
                            ELSE ((1)::bigint << (40 - st.depth))
                        END) AS sort_key,
                    bool_and(vc.keep) AS visible
                   FROM (((((node_path_steps st
                     CROSS JOIN render_context rc)
                     JOIN nodes n ON (((n.map_id = st.map_id) AND (n.id = st.node_id))))
                     CROSS JOIN pos p)
                     CROSS JOIN LATERAL ( SELECT
                                CASE
                                    WHEN (((((p.x - (n.x)::double precision))::bigint * (n.dy)::bigint) - (((p.y - (n.y)::double precision))::bigint * (n.dx)::bigint)) > 0) THEN 'R'::text
                                    ELSE 'L'::text
                                END AS front_side) fs)
                     JOIN visible_children vc ON (((vc.map_id = st.map_id) AND (vc.node_id = st.node_id) AND (vc.side = st.side))))
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
           FROM (( SELECT sg_1.map_id,
                    sg_1.fsec
                   FROM ((bsp_order bo
                     JOIN render_context rc ON (true))
                     JOIN render_segs sg_1 ON (((sg_1.map_id = rc.map_id) AND (sg_1.ssector_id = bo.ssector_id))))
                  WHERE (bo.bsp_seq = 1)
                  ORDER BY sg_1.seg_id
                 LIMIT 1) sg
             JOIN sectors_lit sec ON (((sec.map_id = sg.map_id) AND (sec.id = sg.fsec))))
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
            s.seg_u2
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
            ((((s.x1)::double precision - c.px) * cos((- c.view_rad))) - (((s.y1)::double precision - c.py) * sin((- c.view_rad)))) AS x1,
            (- ((((s.x1)::double precision - c.px) * sin((- c.view_rad))) + (((s.y1)::double precision - c.py) * cos((- c.view_rad))))) AS y1,
            ((((s.x2)::double precision - c.px) * cos((- c.view_rad))) - (((s.y2)::double precision - c.py) * sin((- c.view_rad)))) AS x2,
            (- ((((s.x2)::double precision - c.px) * sin((- c.view_rad))) + (((s.y2)::double precision - c.py) * cos((- c.view_rad))))) AS y2
           FROM (segs_with_verts s
             CROSS JOIN cam c)
        ), visible AS (
         SELECT viewspace.seg_id,
            viewspace.direction,
            viewspace.linedef_id,
            viewspace.map_id,
            viewspace.seg_u1,
            viewspace.seg_u2,
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
            clipped.seg_u2
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
            p.seg_u2
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
            COALESCE(alb.light_level, s.b_light) AS b_light
           FROM (((((on_screen p
             JOIN render_segs s ON (((s.map_id = p.map_id) AND (s.seg_id = p.seg_id))))
             CROSS JOIN frame_clock fc)
             LEFT JOIN animated_light alf ON ((alf.sector_id = s.fsec)))
             LEFT JOIN animated_light alb ON ((alb.sector_id = s.bsec)))
             LEFT JOIN scrolling_segs sc ON ((sc.linedef_id = s.linedef_id)))
        ), seg_light_bias AS (
         SELECT (s.seg_id + 0) AS seg_id,
            s.light_bias
           FROM (render_segs s
             CROSS JOIN render_context rc)
          WHERE (s.map_id = rc.map_id)
        ), seg_bsp AS (
         SELECT (s.seg_id + 0) AS seg_id,
            bo.bsp_seq
           FROM ((render_segs s
             JOIN bsp_order bo ON ((bo.ssector_id = s.ssector_id)))
             CROSS JOIN render_context rc)
          WHERE (s.map_id = rc.map_id)
        ), occluders AS (
         SELECT h.seg_id,
            h.screen_x1,
            h.screen_x2,
            sb.bsp_seq
           FROM (heights h
             JOIN seg_bsp sb ON ((sb.seg_id = h.seg_id)))
          WHERE ((h.bsec IS NULL) OR (h.b_ceil <= h.b_floor))
        ), occlusion_cols AS (
         SELECT x.x AS col_x,
            o.bsp_seq
           FROM ((occluders o
             CROSS JOIN render_settings rs)
             CROSS JOIN LATERAL generate_series(GREATEST(0, (floor(LEAST(o.screen_x1, o.screen_x2)))::integer), LEAST((rs.screen_w - 1), (ceil(GREATEST(o.screen_x1, o.screen_x2)))::integer)) x(x))
          WHERE (o.screen_x1 <> o.screen_x2)
        ), min_occlusion AS (
         SELECT occlusion_cols.col_x,
            min(occlusion_cols.bsp_seq) AS min_bsp_seq
           FROM occlusion_cols
          GROUP BY occlusion_cols.col_x
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
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
            heights.seg_u2
           FROM heights
          WHERE ((heights.bsec IS NOT NULL) AND (heights.mid_tex IS NOT NULL) AND ((heights.mid_tex)::text <> '-'::text) AND (heights.f_ceil > heights.f_floor))
        ), frame_walltex AS MATERIALIZED (
         SELECT wt.name,
            wt.width,
            wt.height,
            (wt.palette_indices || '\x'::bytea) AS palette_indices
           FROM walltex_meta wt
          WHERE (wt.name IN ( SELECT wp0.tex
                   FROM wall_parts wp0))
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
            COALESCE(m.width, 64) AS tex_w,
            COALESCE(m.height, 64) AS tex_h,
            m.width AS tex_width,
            m.palette_indices AS tex_pi
           FROM (wall_parts wp
             LEFT JOIN frame_walltex m ON ((m.name = (wp.tex)::text)))
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
            w.tex_w,
            w.tex_h,
            w.tex_width,
            w.tex_pi,
            sb.bsp_seq,
            ((w.x_offset)::double precision + w.seg_u1) AS u1,
            ((w.x_offset)::double precision + w.seg_u2) AS u2,
            x.x AS col_x,
            x.x AS screen_x_clamped,
            LEAST((1.0)::double precision, GREATEST((0.0)::double precision, (((x.x)::double precision - w.screen_x1) / NULLIF((w.screen_x2 - w.screen_x1), (0.000001)::double precision)))) AS t
           FROM (((((wall_parts_tex w
             CROSS JOIN render_settings rs)
             JOIN seg_bsp sb ON ((sb.seg_id = w.seg_id)))
             CROSS JOIN LATERAL ( SELECT (NOT ((GREATEST(w.screen_x1, w.screen_x2) < (0)::double precision) OR (LEAST(w.screen_x1, w.screen_x2) >= (rs.screen_w)::double precision))) AS on_screen,
                    GREATEST(0, (floor(LEAST(w.screen_x1, w.screen_x2)))::integer) AS x_lo,
                    LEAST((rs.screen_w - 1), (ceil(GREATEST(w.screen_x1, w.screen_x2)))::integer) AS x_hi) b)
             CROSS JOIN LATERAL generate_series(b.x_lo, b.x_hi) x(x))
             LEFT JOIN min_occlusion mo ON ((mo.col_x = x.x)))
          WHERE (b.on_screen AND (w.screen_x1 <> w.screen_x2) AND (sb.bsp_seq <= COALESCE(mo.min_bsp_seq, sb.bsp_seq)))
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
            c.tex_w,
            c.tex_h,
            c.tex_width,
            c.tex_pi,
            c.bsp_seq,
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
            p.x_offset,
            p.y_offset,
            p.flags,
            p.z_bot,
            p.z_top,
            p.v_anchor_base,
            p.v_anchor_add_tex_h,
            p.f_light,
            p.fsec,
            p.invx1,
            p.invx2,
            p.screen_x1,
            p.screen_x2,
            p.cx1,
            p.cx2,
            p.cy1,
            p.cy2,
            p.seg_u1,
            p.seg_u2,
            p.tex_w,
            p.tex_h,
            p.tex_width,
            p.tex_pi,
            p.bsp_seq,
            p.u1,
            p.u2,
            p.col_x,
            p.screen_x_clamped,
            p.t,
            p.invx,
            p.u_over_x,
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
            t.x_offset,
            t.y_offset,
            t.flags,
            t.z_bot,
            t.z_top,
            t.v_anchor_base,
            t.v_anchor_add_tex_h,
            t.f_light,
            t.fsec,
            t.invx1,
            t.invx2,
            t.screen_x1,
            t.screen_x2,
            t.cx1,
            t.cx2,
            t.cy1,
            t.cy2,
            t.seg_u1,
            t.seg_u2,
            t.tex_w,
            t.tex_h,
            t.tex_width,
            t.tex_pi,
            t.bsp_seq,
            t.u1,
            t.u2,
            t.col_x,
            t.screen_x_clamped,
            t.t,
            t.invx,
            t.u_over_x,
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
                    v.x_offset,
                    v.y_offset,
                    v.flags,
                    v.z_bot,
                    v.z_top,
                    v.v_anchor_base,
                    v.v_anchor_add_tex_h,
                    v.f_light,
                    v.fsec,
                    v.invx1,
                    v.invx2,
                    v.screen_x1,
                    v.screen_x2,
                    v.cx1,
                    v.cx2,
                    v.cy1,
                    v.cy2,
                    v.seg_u1,
                    v.seg_u2,
                    v.tex_w,
                    v.tex_h,
                    v.tex_width,
                    v.tex_pi,
                    v.bsp_seq,
                    v.u1,
                    v.u2,
                    v.col_x,
                    v.screen_x_clamped,
                    v.t,
                    v.invx,
                    v.u_over_x,
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
            c.tex_w,
            c.tex_h,
            c.tex_width,
            c.tex_pi,
            c.bsp_seq,
            c.u1,
            c.u2,
            c.col_x,
            c.screen_x_clamped,
            c.t,
            c.invx,
            c.u_over_x,
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
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    ELSE doom_light_index((c.f_light)::double precision, (b.light_bias + wr.extra_light), doom_light_scale(c.depth_x))
                END AS light_index,
            (((c.seg_id)::bigint * 8) +
                CASE c.part
                    WHEN 'solid'::text THEN 0
                    WHEN 'upper'::text THEN 1
                    WHEN 'lower'::text THEN 2
                    WHEN 'lower_down'::text THEN 3
                    ELSE 7
                END) AS stable_id
           FROM (((clamped_spans c
             JOIN seg_light_bias b ON ((b.seg_id = c.seg_id)))
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
        ), fragments AS (
         SELECT c.seg_id,
            c.part,
            c.tex,
            c.tex_width,
            c.tex_pi,
            c.light_index,
            c.stable_id,
            c.screen_x_clamped AS x,
            y.y,
            c.depth_x AS depth,
            c.u_i0 AS u_i,
            ((((floor((c.v0 + (((y.y - c.y_start))::double precision * c.v_step))))::integer % c.tex_h) + c.tex_h) % c.tex_h) AS v_i,
            c.f_light AS sector_light,
            c.fsec AS sector_id
           FROM (( SELECT s.seg_id,
                    s.part,
                    s.tex,
                    s.x_offset,
                    s.y_offset,
                    s.flags,
                    s.z_bot,
                    s.z_top,
                    s.v_anchor_base,
                    s.v_anchor_add_tex_h,
                    s.f_light,
                    s.fsec,
                    s.invx1,
                    s.invx2,
                    s.screen_x1,
                    s.screen_x2,
                    s.cx1,
                    s.cx2,
                    s.cy1,
                    s.cy2,
                    s.seg_u1,
                    s.seg_u2,
                    s.tex_w,
                    s.tex_h,
                    s.tex_width,
                    s.tex_pi,
                    s.bsp_seq,
                    s.u1,
                    s.u2,
                    s.col_x,
                    s.screen_x_clamped,
                    s.t,
                    s.invx,
                    s.u_over_x,
                    s.depth_x,
                    s.u_col,
                    s.scale,
                    s.view_z,
                    s.screen_cy,
                    s.y_top_f,
                    s.y_bot_f,
                    s.v_anchor_z,
                    s.y_start,
                    s.y_end,
                    s.v0,
                    s.v_step,
                    s.light_index,
                    s.stable_id,
                    (floor((s.u_col - ((s.tex_w)::double precision * floor((s.u_col / (s.tex_w)::double precision))))))::integer AS u_i0
                   FROM clamped_spans_lit s
                  WHERE ((s.tex IS NOT NULL) AND ((s.tex)::text <> '-'::text))
                 OFFSET 0) c
             CROSS JOIN LATERAL generate_series(c.y_start, c.y_end) y(y))
        ), wall_tex AS (
         SELECT f.x,
            f.y,
            f.depth,
            f.light_index,
            f.stable_id,
                CASE
                    WHEN ((f.tex_pi IS NULL) OR (((f.v_i * f.tex_width) + f.u_i) < 0) OR (((f.v_i * f.tex_width) + f.u_i) >= octet_length(f.tex_pi))) THEN 0
                    ELSE get_byte(f.tex_pi, ((f.v_i * f.tex_width) + f.u_i))
                END AS palette_index
           FROM fragments f
        ), colored AS (
         SELECT w.x,
            w.y,
            w.depth,
            w.light_index,
            w.palette_index,
            w.stable_id
           FROM wall_tex w
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
             JOIN heights h ON ((h.seg_id = v.seg_id)))
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
        ), panel_carry AS (
         SELECT q.col_x,
            q.seg_id,
            q.bsp_seq,
            q.part,
            q.depth_x,
            q.y_top_f,
            q.y_bot_f,
            q.f_floor_y_f,
            q.f_ceil_y_f,
            q.fsec,
            q.f_light,
            q.f_floor,
            q.f_ceil,
            q.f_ceil_is_sky,
            q.seq,
            max(
                CASE
                    WHEN ((q.f_ceil)::double precision > c.pz) THEN (((((q.seq << 48) | ((q.fsec)::bigint << 32)) | ((((q.f_ceil)::integer + 32768))::bigint << 16)) | ((q.f_light)::bigint << 1)) | ((q.f_ceil_is_sky)::integer)::bigint)
                    ELSE NULL::bigint
                END) OVER w AS pc_pack,
            max(
                CASE
                    WHEN ((q.f_floor)::double precision < c.pz) THEN ((((q.seq << 48) | ((q.fsec)::bigint << 32)) | ((((q.f_floor)::integer + 32768))::bigint << 16)) | (q.f_light)::bigint)
                    ELSE NULL::bigint
                END) OVER w AS pf_pack
           FROM (panel_seq q
             CROSS JOIN cam c)
          WINDOW w AS (PARTITION BY q.col_x ORDER BY q.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
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
            p.pc_pack,
            p.pf_pack,
            COALESCE(max(
                CASE
                    WHEN (p.part = ANY (ARRAY['solid'::text, 'upper'::text])) THEN ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, GREATEST((0.0)::double precision, p.y_bot_f))))::integer + 1)
                    WHEN (p.part = 'upper_flush'::text) THEN GREATEST(0, ((floor(LEAST((((rs.screen_h)::numeric - 1.0))::double precision, p.y_bot_f)))::integer + 1))
                    ELSE NULL::integer
                END) OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS cc_before,
            COALESCE(min(
                CASE
                    WHEN (p.part = ANY (ARRAY['solid'::text, 'lower'::text, 'lower_down'::text])) THEN LEAST((rs.screen_h - 1), ((ceil(GREATEST((0.0)::double precision, p.y_top_f)))::integer - 1))
                    ELSE NULL::integer
                END) OVER (PARTITION BY p.col_x ORDER BY p.depth_x, p.bsp_seq, p.part, p.seg_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), (rs.screen_h - 1)) AS fc_before,
            pc.fsec AS carried_ceil_sec,
            pc.f_ceil AS carried_ceil_z,
            pc.f_light AS carried_ceil_light,
            COALESCE(pc.is_sky, false) AS carried_ceil_is_sky,
            pf.fsec AS carried_floor_sec,
            pf.f_floor AS carried_floor_z,
            pf.f_light AS carried_floor_light
           FROM ((((panel_carry p
             CROSS JOIN render_settings rs)
             CROSS JOIN cam c)
             CROSS JOIN LATERAL ( SELECT (((p.pc_pack >> 32) & (65535)::bigint))::integer AS fsec,
                    ((((p.pc_pack >> 16) & (65535)::bigint) - 32768))::smallint AS f_ceil,
                    (((p.pc_pack >> 1) & (32767)::bigint))::smallint AS f_light,
                    ((p.pc_pack & (1)::bigint) = 1) AS is_sky) pc)
             CROSS JOIN LATERAL ( SELECT (((p.pf_pack >> 32) & (65535)::bigint))::integer AS fsec,
                    ((((p.pf_pack >> 16) & (65535)::bigint) - 32768))::smallint AS f_floor,
                    ((p.pf_pack & (65535)::bigint))::smallint AS f_light) pf)
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
        ), frame_flats AS MATERIALIZED (
         SELECT row_number() OVER () AS fid,
            flat_textures.name,
            (flat_textures.palette_indices || '\x'::bytea) AS palette_indices
           FROM flat_textures
        ), plane_spans_textured AS (
         SELECT psd.col_x,
            psd.sector_id,
            psd.plane_z,
            psd.plane,
            psd.is_sky,
            psd.y0,
            psd.y1,
            psd.sector_light,
            psd.source_priority,
            ft.fid AS flat_fid
           FROM (((plane_spans_deduped psd
             CROSS JOIN render_context rc)
             JOIN sectors_lit s ON (((s.id = psd.sector_id) AND (s.map_id = rc.map_id))))
             LEFT JOIN frame_flats ft ON (((NOT psd.is_sky) AND (ft.name = (
                CASE
                    WHEN (psd.plane = 'floor'::text) THEN s.floor_tex
                    ELSE s.ceil_tex
                END)::text))))
        ), plane_pixels AS (
         SELECT ps.col_x AS x,
            y.y,
            ps.sector_id,
            ps.plane_z,
            ps.sector_light,
            ps.plane,
            ps.is_sky,
            ps.source_priority,
            ps.flat_fid,
            ps.k_num,
            ps.tan_alpha
           FROM (( SELECT s.col_x,
                    s.sector_id,
                    s.plane_z,
                    s.plane,
                    s.is_sky,
                    s.y0,
                    s.y1,
                    s.sector_light,
                    s.source_priority,
                    s.flat_fid,
                    (rs.focal * ((s.plane_z)::double precision - c.pz)) AS k_num,
                    (((s.col_x)::double precision - rs.cx_f) / rs.focal) AS tan_alpha
                   FROM ((plane_spans_textured s
                     CROSS JOIN cam c)
                     CROSS JOIN render_settings rs)
                 OFFSET 0) ps
             CROSS JOIN LATERAL generate_series(ps.y0, ps.y1) y(y))
        ), plane_rays AS (
         SELECT pp.x,
            pp.y,
            pp.sector_id,
            pp.sector_light,
            pp.plane,
            pp.source_priority,
            pp.flat_fid,
            pp.is_sky,
                CASE
                    WHEN pp.is_sky THEN ('10000000'::numeric)::double precision
                    ELSE pp.d
                END AS depth_x,
            pp.tan_alpha
           FROM (( SELECT q.x,
                    q.y,
                    q.sector_id,
                    q.plane_z,
                    q.sector_light,
                    q.plane,
                    q.is_sky,
                    q.source_priority,
                    q.flat_fid,
                    q.k_num,
                    q.tan_alpha,
                    (q.k_num / NULLIF((rs0.cy_f - (q.y)::double precision), (0.0)::double precision)) AS d
                   FROM (plane_pixels q
                     CROSS JOIN render_settings rs0)
                 OFFSET 0) pp
             CROSS JOIN render_settings rs)
          WHERE (pp.is_sky OR (pp.d > rs.near_f))
        ), plane_world AS (
         SELECT pr.x,
            pr.y,
            pr.sector_id,
            pr.sector_light,
            pr.plane,
            pr.source_priority,
            pr.flat_fid,
            pr.is_sky,
            pr.depth_x AS depth,
            ((c.px + (pr.depth_x * c.cos_v)) + ((pr.tan_alpha * pr.depth_x) * c.sin_v)) AS wx,
            ((c.py + (pr.depth_x * c.sin_v)) - ((pr.tan_alpha * pr.depth_x) * c.cos_v)) AS wy,
                CASE
                    WHEN pr.is_sky THEN degrees((c.view_rad - atan(pr.tan_alpha)))
                    ELSE NULL::double precision
                END AS ray_deg
           FROM (plane_rays pr
             CROSS JOIN ( SELECT cc.px,
                    cc.py,
                    cc.pz,
                    cc.view_rad,
                    cos(cc.view_rad) AS cos_v,
                    sin(cc.view_rad) AS sin_v
                   FROM cam cc) c)
        ), plane_uv AS (
         SELECT plane_world.x,
            plane_world.y,
            plane_world.sector_id,
            plane_world.sector_light,
            plane_world.plane,
            plane_world.source_priority,
            plane_world.depth,
            plane_world.flat_fid,
            plane_world.is_sky,
                CASE
                    WHEN plane_world.is_sky THEN ((((floor((plane_world.ray_deg * rs.sky_ratio_f)))::integer % rs.sky_columns_i) + rs.sky_columns_i) % rs.sky_columns_i)
                    ELSE ((floor(plane_world.wx))::integer & 63)
                END AS u_i,
                CASE
                    WHEN plane_world.is_sky THEN ((((plane_world.y - rs.sky_horizon_y) % rs.sky_rows) + rs.sky_rows) % rs.sky_rows)
                    ELSE ((floor(plane_world.wy))::integer & 63)
                END AS v_i
           FROM (plane_world
             CROSS JOIN render_settings rs)
        ), plane_tex AS (
         SELECT pw.x,
            pw.y,
            pw.sector_id,
            pw.sector_light,
            pw.plane,
            pw.source_priority,
            pw.flat_fid,
            pw.is_sky,
            pw.depth,
            pw.wx,
            pw.wy,
            pw.ray_deg,
                CASE
                    WHEN (pw.plane = 'floor'::text) THEN s.floor_tex
                    ELSE s.ceil_tex
                END AS tex_name
           FROM ((plane_world pw
             CROSS JOIN render_context rc)
             JOIN sectors_lit s ON (((s.id = pw.sector_id) AND (s.map_id = rc.map_id))))
        ), frame_sky AS MATERIALIZED (
         SELECT wt.name,
            wt.width,
            (wt.palette_indices || '\x'::bytea) AS palette_indices
           FROM ((walltex_meta wt
             JOIN maps m ON ((m.sky_texture = wt.name)))
             JOIN render_context rc ON ((rc.map_id = m.map_id)))
        ), plane_color AS (
         SELECT p.x,
            p.y,
            p.depth,
            p.sector_id,
            p.plane,
            p.sector_light,
            p.is_sky,
            p.source_priority,
                CASE
                    WHEN ((NOT p.is_sky) AND (ft.palette_indices IS NOT NULL) AND (((p.v_i * rs.flat_size) + p.u_i) >= 0) AND (((p.v_i * rs.flat_size) + p.u_i) < octet_length(ft.palette_indices))) THEN get_byte(ft.palette_indices, ((p.v_i * rs.flat_size) + p.u_i))
                    WHEN (p.is_sky AND (sky.palette_indices IS NOT NULL)) THEN
                    CASE
                        WHEN ((((p.v_i * sky.width) + p.u_i) >= 0) AND (((p.v_i * sky.width) + p.u_i) < octet_length(sky.palette_indices))) THEN get_byte(sky.palette_indices, ((p.v_i * sky.width) + p.u_i))
                        ELSE 0
                    END
                    ELSE 0
                END AS palette_index
           FROM (((plane_uv p
             CROSS JOIN render_settings rs)
             LEFT JOIN frame_flats ft ON ((ft.fid = p.flat_fid)))
             CROSS JOIN frame_sky sky)
        ), plane_lit AS (
         SELECT plane_color.x,
            plane_color.y,
            plane_color.depth,
            plane_color.sector_id,
            plane_color.plane,
            plane_color.source_priority,
            plane_color.is_sky,
            plane_color.palette_index,
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    ELSE doom_light_index((plane_color.sector_light)::double precision, wr.extra_light, (floor(((80.0)::double precision / ((LEAST(127, (floor((plane_color.depth / (16.0)::double precision)))::integer) + 1))::double precision)))::integer)
                END AS light_index
           FROM ((plane_color
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
        ), plane_fragments AS (
         SELECT p.x,
            p.y,
            p.depth,
            p.source_priority,
                CASE
                    WHEN p.is_sky THEN 0
                    ELSE p.light_index
                END AS light_index,
            p.palette_index,
            (((p.sector_id)::bigint * 2) +
                CASE
                    WHEN (p.plane = 'floor'::text) THEN 0
                    ELSE 1
                END) AS stable_id
           FROM plane_lit p
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
            (sl.pixels || '\x'::bytea) AS pixels,
            (sl.mask || '\x'::bytea) AS mask,
            (rs.focal / tv.depth) AS scale,
            (rs.cx + ((rs.focal * tv.side) / tv.depth)) AS origin_x
           FROM (((thing_view tv
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
             JOIN sprite_lumps sl ON (((sl.lump_name)::text = (sf.lump_name)::text)))
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
            tp.pixels,
            tp.mask,
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
            tb.pixels,
            tb.mask,
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
        ), thing_pixels AS (
         SELECT tb.thing_id,
            screen_x.screen_x AS x,
            screen_y.screen_y AS y,
            tb.depth,
            tb.sector_light,
            tb.fullbright,
            tb.fuzz,
            tb.base_light,
                CASE
                    WHEN ((mpl.slot > 1) AND ((px.raw >= 112) AND (px.raw <= 127))) THEN ((px.raw - 112) +
                    CASE mpl.slot
                        WHEN 2 THEN 96
                        WHEN 3 THEN 64
                        ELSE 32
                    END)
                    ELSE px.raw
                END AS palette_index
           FROM (((((((thing_bounds_lit tb
             CROSS JOIN render_settings rs)
             CROSS JOIN render_context rc)
             LEFT JOIN mp_players mpl ON (((mpl.map_id = rc.map_id) AND (mpl.player_thing_id = tb.thing_id))))
             CROSS JOIN LATERAL generate_series(GREATEST(0, (floor(tb.x_left_f))::integer), LEAST((rs.screen_w - 1), ((ceil(tb.x_right_f))::integer - 1))) screen_x(screen_x))
             CROSS JOIN LATERAL generate_series(GREATEST(0, (floor(tb.y_top_f))::integer), LEAST((rs.screen_h - 1), ((ceil(tb.y_bottom_f))::integer - 1))) screen_y(screen_y))
             CROSS JOIN LATERAL ( SELECT LEAST((tb.width - 1), GREATEST(0, (floor((((screen_x.screen_x)::double precision - tb.x_left_f) / tb.scale)))::integer)) AS raw_u,
                    LEAST((tb.height - 1), GREATEST(0, (floor((((screen_y.screen_y)::double precision - tb.y_top_f) / tb.scale)))::integer)) AS v_i) uv)
             CROSS JOIN LATERAL ( SELECT get_byte(tb.pixels, ((uv.v_i * tb.width) +
                        CASE
                            WHEN tb.flipped THEN ((tb.width - 1) - uv.raw_u)
                            ELSE uv.raw_u
                        END)) AS raw) px)
          WHERE ((tb.x_right_f > (0)::double precision) AND (tb.x_left_f < (rs.screen_w)::double precision) AND (tb.y_bottom_f > (0)::double precision) AND (tb.y_top_f < (rs.screen_h)::double precision) AND (get_byte(tb.mask, ((uv.v_i * tb.width) +
                CASE
                    WHEN tb.flipped THEN ((tb.width - 1) - uv.raw_u)
                    ELSE uv.raw_u
                END)) <> 0))
        ), sprite_fragments AS (
         SELECT sp.x,
            sp.y,
            sp.depth,
            sp.thing_id AS stable_id,
            sp.palette_index,
                CASE
                    WHEN sp.fuzz THEN (26 + ((((sp.x * 7) + (sp.y * 13)) + (sp.depth)::integer) % 5))
                    ELSE sp.base_light
                END AS light_index
           FROM thing_pixels sp
        ), fragment_union AS (
         SELECT colored.x,
            colored.y,
            colored.depth,
            colored.light_index,
            colored.palette_index,
            (2)::bigint AS surface_priority,
            (0)::bigint AS source_priority,
            colored.stable_id
           FROM colored
        UNION ALL
         SELECT sprite_fragments.x,
            sprite_fragments.y,
            sprite_fragments.depth,
            sprite_fragments.light_index,
            sprite_fragments.palette_index,
            (1)::bigint AS int8,
            (0)::bigint AS int8,
            sprite_fragments.stable_id
           FROM sprite_fragments
        UNION ALL
         SELECT plane_fragments.x,
            plane_fragments.y,
            plane_fragments.depth,
            plane_fragments.light_index,
            plane_fragments.palette_index,
            (0)::bigint AS int8,
            (plane_fragments.source_priority)::bigint AS source_priority,
            plane_fragments.stable_id
           FROM plane_fragments
        ), ranked_fragments AS (
         SELECT ((u.y * rs.screen_w) + u.x) AS pix,
            ((((((((GREATEST((0.0)::double precision, LEAST(u.depth, (131071.0)::double precision)) * (4096)::double precision))::bigint << 34) | (((2)::bigint - u.surface_priority) << 32)) | (LEAST(u.source_priority, (3)::bigint) << 30)) | (LEAST((65535)::bigint, GREATEST((0)::bigint, (u.stable_id + 32768))) << 14)) | ((u.light_index)::bigint << 8)) | (u.palette_index)::bigint) AS winner_key
           FROM (fragment_union u
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
            x.x,
            y.y,
            q.fullbright,
            get_byte(q.pixels, (((y.y - (floor(q.y_top_f))::integer) * q.width) + (x.x - (floor(q.x_left_f))::integer))) AS palette_index
           FROM (((psprite_patches q
             CROSS JOIN render_settings rs)
             CROSS JOIN LATERAL generate_series(GREATEST(0, (floor(q.x_left_f))::integer), LEAST((rs.screen_w - 1), (((floor(q.x_left_f))::integer + q.width) - 1))) x(x))
             CROSS JOIN LATERAL generate_series(GREATEST(0, (floor(q.y_top_f))::integer), LEAST((rs.screen_h - 1), (((floor(q.y_top_f))::integer + q.height) - 1))) y(y))
          WHERE (get_byte(q.mask, (((y.y - (floor(q.y_top_f))::integer) * q.width) + (x.x - (floor(q.x_left_f))::integer))) <> 0)
        ), psprite_resolved AS (
         SELECT p.x,
            p.y,
            p.palette_index,
                CASE
                    WHEN wr.invuln THEN rs.light_index_invuln
                    WHEN p.fullbright THEN 0
                    ELSE doom_light_index((ps.light_level)::double precision, wr.extra_light, rs.light_psprite_bias)
                END AS light_index
           FROM (((( SELECT pp.layer,
                    pp.x,
                    pp.y,
                    pp.fullbright,
                    pp.palette_index,
                    row_number() OVER (PARTITION BY pp.x, pp.y ORDER BY pp.layer DESC) AS rn
                   FROM psprite_pixels pp) p
             CROSS JOIN player_sector ps)
             CROSS JOIN weapon_runtime wr)
             CROSS JOIN render_settings rs)
          WHERE (p.rn = 1)
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
        ), active_palette AS (
         SELECT (
                CASE
                    WHEN (pu.damage_count > 0) THEN (LEAST(7, ((pu.damage_count + 7) / 8)) + 1)
                    WHEN (pu.bonus_count > 0) THEN (LEAST(3, ((pu.bonus_count + 7) / 8)) + 9)
                    WHEN ((pu.radsuit_tics > 128) OR ((pu.radsuit_tics & 8) <> 0)) THEN 13
                    ELSE 0
                END)::smallint AS pal
           FROM player_ui_state pu
        ), palette_map AS (
         SELECT cm.level,
            cm.palette_index,
            cm.rgb
           FROM (colormap_rgb cm
             CROSS JOIN active_palette ap)
          WHERE (cm.pal = ap.pal)
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
        ), status_bar AS (
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
             CROSS JOIN LATERAL generate_series(1, length((hd.value)::text)) gs(i))
        UNION ALL
         SELECT 1,
            ('STTNUM'::text || SUBSTRING((ad.value)::text FROM gs.i FOR 1)) AS patch,
            (ad.right_x - (((length((ad.value)::text) - gs.i) + 1) * sb.tall_digit_w)) AS x,
            sb.digit_y AS y
           FROM ((armor_digits ad
             CROSS JOIN status_bar sb)
             CROSS JOIN LATERAL generate_series(1, length((ad.value)::text)) gs(i))
        UNION ALL
         SELECT 1,
            ('STTNUM'::text || SUBSTRING((am.value)::text FROM gs.i FOR 1)) AS patch,
            (am.right_x - (((length((am.value)::text) - gs.i) + 1) * sb.tall_digit_w)) AS x,
            sb.digit_y AS y
           FROM ((ammo_digits am
             CROSS JOIN status_bar sb)
             CROSS JOIN LATERAL generate_series(1, length((am.value)::text)) gs(i))
        UNION ALL
         SELECT 1,
            ('STYSNUM'::text || SUBSTRING((at.value)::text FROM gs.i FOR 1)) AS patch,
            (at.right_x - (((length((at.value)::text) - gs.i) + 1) * sb.short_digit_w)) AS x,
            at.y
           FROM ((ammo_type_values at
             CROSS JOIN status_bar sb)
             CROSS JOIN LATERAL generate_series(1, length((at.value)::text)) gs(i))
        UNION ALL
         SELECT 1,
            ('STYSNUM'::text || SUBSTRING((mx.value)::text FROM gs.i FOR 1)) AS patch,
            (mx.right_x - (((length((mx.value)::text) - gs.i) + 1) * sb.short_digit_w)) AS x,
            mx.y
           FROM ((ammo_max_values mx
             CROSS JOIN status_bar sb)
             CROSS JOIN LATERAL generate_series(1, length((mx.value)::text)) gs(i))
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
        ), ui_layer_patches AS (
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
             JOIN ui_hud_pixels px ON (((px.name)::text = ulp.patch)))
        ), ui_resolved AS (
         SELECT u.x,
            u.y,
            ((max((((u.layer)::bigint << 32) | ((u.palette_index)::bigint & '4294967295'::bigint))) & '4294967295'::bigint))::integer AS palette_index
           FROM ( SELECT ui_pixels.layer,
                    ui_pixels.x,
                    ui_pixels.y,
                    ui_pixels.palette_index
                   FROM ui_pixels
                  ORDER BY ui_pixels.x, ui_pixels.y) u
          GROUP BY u.x, u.y
        ), ui_colored AS (
         SELECT s.x,
            s.y,
            COALESCE(ovcm.rgb,
                CASE
                    WHEN (ap.pal = 0) THEN s.rgb
                    ELSE barcm.rgb
                END, s.rgb) AS rgb
           FROM ((((ui_static_pixels s
             CROSS JOIN active_palette ap)
             LEFT JOIN ui_resolved ur ON (((ur.x = s.x) AND (ur.y = s.y))))
             LEFT JOIN palette_map ovcm ON (((ovcm.level = 0) AND (ovcm.palette_index = ur.palette_index))))
             LEFT JOIN palette_map barcm ON (((ap.pal <> 0) AND (barcm.level = 0) AND (barcm.palette_index = s.palette_index))))
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
        ), resolved AS (
         SELECT (w.pix % rs.screen_w) AS x,
            (w.pix / rs.screen_w) AS y,
            (((w.winner_key >> 8) & (63)::bigint))::integer AS light_index,
            ((w.winner_key & (255)::bigint))::integer AS palette_index
           FROM (( SELECT rf.pix,
                    min(rf.winner_key) AS winner_key
                   FROM ( SELECT ranked_fragments.pix,
                            ranked_fragments.winner_key
                           FROM ranked_fragments
                        UNION ALL
                         SELECT ((p.y * rs0.screen_w) + p.x),
                            (((- ((1)::bigint << 62)) | ((p.light_index)::bigint << 8)) | (p.palette_index)::bigint)
                           FROM (psprite_resolved p
                             CROSS JOIN render_settings rs0)
                        UNION ALL
                         SELECT ((m.y * 320) + m.x),
                            (((1)::bigint << 63) | (m.palette_index)::bigint)
                           FROM message_pixels m
                          WHERE ((m.x >= 0) AND (m.x <= 319) AND ((m.y >= 0) AND (m.y <= 167)))
                  ORDER BY 1) rf
                  GROUP BY rf.pix) w
             CROSS JOIN render_settings rs)
        ), final_pixels AS (
         SELECT r.x,
            r.y,
            r.light_index,
            r.palette_index
           FROM resolved r
        ), view_holes AS (
         SELECT sx.x,
            sy.y,
            '\x000000'::bytea AS rgb
           FROM ((render_settings rs
             CROSS JOIN LATERAL generate_series(0,
                CASE
                    WHEN (( SELECT count(*) AS count
                       FROM final_pixels f0
                      WHERE ((f0.x >= 0) AND (f0.x <= (rs.screen_w - 1)) AND ((f0.y >= 0) AND (f0.y <= (rs.screen_h - 1))))) < (rs.screen_w * rs.screen_h)) THEN (rs.screen_w - 1)
                    ELSE '-1'::integer
                END) sx(x))
             CROSS JOIN LATERAL generate_series(0, (rs.screen_h - 1)) sy(y))
          WHERE (NOT (EXISTS ( SELECT 1
                   FROM final_pixels f
                  WHERE ((f.x = sx.x) AND (f.y = sy.y)))))
        ), view_colored AS (
         SELECT r.x,
            r.y,
            COALESCE(cm.rgb, '\x000000'::bytea) AS rgb
           FROM (final_pixels r
             LEFT JOIN palette_map cm ON (((cm.level = r.light_index) AND (cm.palette_index = r.palette_index))))
        ), framebuffer AS (
         SELECT v.x,
            v.y,
            ((v.y * 4096) + v.x) AS pix,
            v.rgb
           FROM view_colored v
        UNION ALL
         SELECT h.x,
            h.y,
            ((h.y * 4096) + h.x) AS pix,
            h.rgb
           FROM view_holes h
        UNION ALL
         SELECT ui_colored.x,
            ui_colored.y,
            ((ui_colored.y * 4096) + ui_colored.x) AS pix,
            ui_colored.rgb
           FROM ui_colored
        )
 SELECT string_agg(rgb, '\x'::bytea ORDER BY pix) AS frame_rgb
   FROM framebuffer
  WHERE (EXISTS ( SELECT 1
           FROM mp_players mp
          WHERE ((mp.map_id = {map_id}) AND (mp.slot = {slot}) AND (mp.role_name = doom_caller()))));
$view$::text$template$;
