CREATE OR REPLACE VIEW doom.doom_weapon_decision AS
 WITH input AS (
         SELECT g.map_id,
            g.player_thing_id,
            g.attack_held,
            COALESCE(g.weapon_switch_to, pg.weapon_id) AS switch_to,
            ps.bob_strength AS bob,
            (ps.level_tics)::integer AS level_tic
           FROM ((game_tic_commands g
             JOIN player_state ps ON (((ps.map_id = g.map_id) AND (ps.player_thing_id = g.player_thing_id))))
             LEFT JOIN ( SELECT pickup_grants.map_id,
                    pickup_grants.player_thing_id,
                    min(pickup_grants.weapon_id) AS weapon_id
                   FROM pickup_grants
                  GROUP BY pickup_grants.map_id, pickup_grants.player_thing_id) pg ON (((pg.map_id = g.map_id) AND (pg.player_thing_id = g.player_thing_id))))
        ), current AS (
         SELECT pw.map_id,
            pw.player_thing_id,
            pw.current_weapon,
            pw.pending_weapon,
            pw.state,
            pw.seq_index,
            pw.tics,
            pw.flash_seq_index,
            pw.flash_tics,
            pw.sx,
            pw.sy,
            pw.shot_serial,
            pw.fired_this_tick,
            wd.ammo_type,
            wd.ammo_per_shot,
            i.attack_held,
            i.switch_to,
            i.bob,
            i.level_tic
           FROM ((input i
             JOIN player_weapons pw ON (((pw.map_id = i.map_id) AND (pw.player_thing_id = i.player_thing_id))))
             JOIN weapon_defs wd ON ((wd.weapon_id = pw.current_weapon)))
        ), ammo AS (
         SELECT c.map_id,
            c.player_thing_id,
            c.current_weapon,
            c.pending_weapon,
            c.state,
            c.seq_index,
            c.tics,
            c.flash_seq_index,
            c.flash_tics,
            c.sx,
            c.sy,
            c.shot_serial,
            c.fired_this_tick,
            c.ammo_type,
            c.ammo_per_shot,
            c.attack_held,
            c.switch_to,
            c.bob,
            c.level_tic,
            (
                CASE c.ammo_type
                    WHEN 'bullets'::ammo_kind THEN ps.ammo_bullets
                    WHEN 'shells'::ammo_kind THEN ps.ammo_shells
                    WHEN 'rockets'::ammo_kind THEN ps.ammo_rockets
                    WHEN 'cells'::ammo_kind THEN ps.ammo_cells
                    ELSE 999999
                END >= c.ammo_per_shot) AS has_ammo
           FROM (current c
             JOIN player_state ps ON (((ps.map_id = c.map_id) AND (ps.player_thing_id = c.player_thing_id))))
        ), switch AS (
         SELECT a.map_id,
            a.player_thing_id,
            a.current_weapon,
            a.pending_weapon,
            a.state,
            a.seq_index,
            a.tics,
            a.flash_seq_index,
            a.flash_tics,
            a.sx,
            a.sy,
            a.shot_serial,
            a.fired_this_tick,
            a.ammo_type,
            a.ammo_per_shot,
            a.attack_held,
            a.switch_to,
            a.bob,
            a.level_tic,
            a.has_ammo,
            ((a.switch_to IS NOT NULL) AND (a.switch_to <> a.current_weapon) AND (own.weapon_id IS NOT NULL)) AS switch_requested
           FROM (ammo a
             LEFT JOIN player_weapon_owned own ON (((own.map_id = a.map_id) AND (own.player_thing_id = a.player_thing_id) AND (own.weapon_id = a.switch_to))))
        ), frames AS (
         SELECT s.map_id,
            s.player_thing_id,
            s.current_weapon,
            s.pending_weapon,
            s.state,
            s.seq_index,
            s.tics,
            s.flash_seq_index,
            s.flash_tics,
            s.sx,
            s.sy,
            s.shot_serial,
            s.fired_this_tick,
            s.ammo_type,
            s.ammo_per_shot,
            s.attack_held,
            s.switch_to,
            s.bob,
            s.level_tic,
            s.has_ammo,
            s.switch_requested,
            ready0.tics AS ready_tics,
            fire0.tics AS fire0_tics,
            fire0.is_attack_frame AS fire0_attack,
            nextf.seq_index AS next_seq,
            nextf.tics AS next_tics,
            nextf.is_attack_frame AS next_attack,
            nextf.refire_check AS next_refire,
            flash0.tics AS flash0_tics,
            flashnext.seq_index AS flashnext_seq,
            flashnext.tics AS flashnext_tics
           FROM (((((switch s
             LEFT JOIN weapon_frames ready0 ON (((ready0.weapon_id = s.current_weapon) AND (ready0.state = 'ready'::weapon_state) AND (ready0.seq_index = 0))))
             LEFT JOIN weapon_frames fire0 ON (((fire0.weapon_id = s.current_weapon) AND (fire0.state = 'fire'::weapon_state) AND (fire0.seq_index = 0))))
             LEFT JOIN weapon_frames nextf ON (((nextf.weapon_id = s.current_weapon) AND (nextf.state = 'fire'::weapon_state) AND (nextf.seq_index = (s.seq_index + 1)))))
             LEFT JOIN weapon_frames flash0 ON (((flash0.weapon_id = s.current_weapon) AND (flash0.state = 'flash'::weapon_state) AND (flash0.seq_index = 0))))
             LEFT JOIN weapon_frames flashnext ON (((flashnext.weapon_id = s.current_weapon) AND (flashnext.state = 'flash'::weapon_state) AND (flashnext.seq_index = (s.flash_seq_index + 1)))))
        ), flags AS (
         SELECT f.map_id,
            f.player_thing_id,
            f.current_weapon,
            f.pending_weapon,
            f.state,
            f.seq_index,
            f.tics,
            f.flash_seq_index,
            f.flash_tics,
            f.sx,
            f.sy,
            f.shot_serial,
            f.fired_this_tick,
            f.ammo_type,
            f.ammo_per_shot,
            f.attack_held,
            f.switch_to,
            f.bob,
            f.level_tic,
            f.has_ammo,
            f.switch_requested,
            f.ready_tics,
            f.fire0_tics,
            f.fire0_attack,
            f.next_seq,
            f.next_tics,
            f.next_attack,
            f.next_refire,
            f.flash0_tics,
            f.flashnext_seq,
            f.flashnext_tics,
            ((f.state = 'fire'::weapon_state) AND (f.tics <= 1)) AS advancing,
            ((f.state = 'fire'::weapon_state) AND (f.tics <= 1) AND (f.next_seq IS NULL)) AS falls_off,
            ((f.state = 'fire'::weapon_state) AND (f.tics <= 1) AND (f.next_seq IS NOT NULL) AND f.next_refire AND f.attack_held AND f.has_ammo) AS refires,
            ((f.state = 'ready'::weapon_state) AND f.attack_held AND f.has_ammo AND (NOT f.switch_requested)) AS starts_fire,
            ((f.state = 'down'::weapon_state) AND ((f.sy + (6.0)::double precision) >= (128.0)::double precision)) AS down_done,
            ((f.state = 'up'::weapon_state) AND ((f.sy - (6.0)::double precision) <= (32.0)::double precision)) AS up_done,
            ((f.flash_seq_index IS NOT NULL) AND (f.flash_tics <= 1)) AS flash_advancing
           FROM frames f
        ), decision AS (
         SELECT fl.map_id,
            fl.player_thing_id,
            fl.current_weapon,
            fl.pending_weapon,
            fl.state,
            fl.seq_index,
            fl.tics,
            fl.flash_seq_index,
            fl.flash_tics,
            fl.sx,
            fl.sy,
            fl.shot_serial,
            fl.fired_this_tick,
            fl.ammo_type,
            fl.ammo_per_shot,
            fl.attack_held,
            fl.switch_to,
            fl.bob,
            fl.level_tic,
            fl.has_ammo,
            fl.switch_requested,
            fl.ready_tics,
            fl.fire0_tics,
            fl.fire0_attack,
            fl.next_seq,
            fl.next_tics,
            fl.next_attack,
            fl.next_refire,
            fl.flash0_tics,
            fl.flashnext_seq,
            fl.flashnext_tics,
            fl.advancing,
            fl.falls_off,
            fl.refires,
            fl.starts_fire,
            fl.down_done,
            fl.up_done,
            fl.flash_advancing,
                CASE
                    WHEN fl.switch_requested THEN 'down'::weapon_state
                    WHEN (fl.state = 'down'::weapon_state) THEN
                    CASE
                        WHEN fl.down_done THEN 'up'::weapon_state
                        ELSE 'down'::weapon_state
                    END
                    WHEN (fl.state = 'up'::weapon_state) THEN
                    CASE
                        WHEN fl.up_done THEN 'ready'::weapon_state
                        ELSE 'up'::weapon_state
                    END
                    WHEN (fl.state = 'ready'::weapon_state) THEN
                    CASE
                        WHEN fl.starts_fire THEN 'fire'::weapon_state
                        ELSE 'ready'::weapon_state
                    END
                    WHEN ((fl.state = 'fire'::weapon_state) AND fl.advancing AND fl.falls_off) THEN 'ready'::weapon_state
                    ELSE fl.state
                END AS n_state,
                CASE
                    WHEN fl.switch_requested THEN fl.seq_index
                    WHEN ((fl.state = 'up'::weapon_state) AND fl.up_done) THEN 0
                    WHEN (fl.state = 'ready'::weapon_state) THEN 0
                    WHEN ((fl.state = 'fire'::weapon_state) AND fl.advancing) THEN
                    CASE
                        WHEN (fl.falls_off OR fl.refires) THEN 0
                        ELSE fl.next_seq
                    END
                    ELSE fl.seq_index
                END AS n_seq,
                CASE
                    WHEN fl.switch_requested THEN (fl.tics)::integer
                    WHEN (fl.state = 'up'::weapon_state) THEN
                    CASE
                        WHEN fl.up_done THEN fl.ready_tics
                        ELSE (fl.tics)::integer
                    END
                    WHEN (fl.state = 'ready'::weapon_state) THEN
                    CASE
                        WHEN fl.starts_fire THEN fl.fire0_tics
                        ELSE (fl.tics)::integer
                    END
                    WHEN ((fl.state = 'fire'::weapon_state) AND fl.advancing) THEN
                    CASE
                        WHEN fl.falls_off THEN fl.ready_tics
                        WHEN fl.refires THEN fl.fire0_tics
                        ELSE fl.next_tics
                    END
                    WHEN (fl.state = 'fire'::weapon_state) THEN (fl.tics - 1)
                    ELSE (fl.tics)::integer
                END AS n_tics,
            (((fl.state = 'ready'::weapon_state) AND fl.starts_fire AND (fl.fire0_attack IS TRUE)) OR ((fl.state = 'fire'::weapon_state) AND fl.advancing AND (NOT fl.falls_off) AND (NOT fl.refires) AND (fl.next_attack IS TRUE)) OR ((fl.state = 'fire'::weapon_state) AND fl.advancing AND fl.refires AND (fl.fire0_attack IS TRUE))) AS fires_now,
                CASE
                    WHEN ((fl.state = 'down'::weapon_state) AND fl.down_done AND (NOT fl.switch_requested)) THEN fl.pending_weapon
                    ELSE fl.current_weapon
                END AS n_current_weapon,
                CASE
                    WHEN fl.switch_requested THEN fl.switch_to
                    WHEN ((fl.state = 'down'::weapon_state) AND fl.down_done) THEN NULL::integer
                    ELSE fl.pending_weapon
                END AS n_pending_weapon
           FROM flags fl
        ), decision2 AS (
         SELECT d.map_id,
            d.player_thing_id,
            d.current_weapon,
            d.pending_weapon,
            d.state,
            d.seq_index,
            d.tics,
            d.flash_seq_index,
            d.flash_tics,
            d.sx,
            d.sy,
            d.shot_serial,
            d.fired_this_tick,
            d.ammo_type,
            d.ammo_per_shot,
            d.attack_held,
            d.switch_to,
            d.bob,
            d.level_tic,
            d.has_ammo,
            d.switch_requested,
            d.ready_tics,
            d.fire0_tics,
            d.fire0_attack,
            d.next_seq,
            d.next_tics,
            d.next_attack,
            d.next_refire,
            d.flash0_tics,
            d.flashnext_seq,
            d.flashnext_tics,
            d.advancing,
            d.falls_off,
            d.refires,
            d.starts_fire,
            d.down_done,
            d.up_done,
            d.flash_advancing,
            d.n_state,
            d.n_seq,
            d.n_tics,
            d.fires_now,
            d.n_current_weapon,
            d.n_pending_weapon,
                CASE
                    WHEN (d.n_state = 'ready'::weapon_state) THEN ((1.0)::double precision + (d.bob * cos(((((2.0)::double precision * pi()) * ((d.level_tic % 64))::double precision) / (64.0)::double precision))))
                    ELSE (d.sx)::double precision
                END AS n_sx,
                CASE
                    WHEN (d.n_state = 'ready'::weapon_state) THEN ((32.0)::double precision + (d.bob * sin(((((2.0)::double precision * pi()) * ((d.level_tic % 32))::double precision) / (64.0)::double precision))))
                    WHEN (d.n_state = 'down'::weapon_state) THEN LEAST((128.0)::double precision, (d.sy + (6.0)::double precision))
                    WHEN (d.n_state = 'up'::weapon_state) THEN GREATEST((32.0)::double precision, (d.sy - (6.0)::double precision))
                    ELSE (d.sy)::double precision
                END AS n_sy,
                CASE
                    WHEN d.fires_now THEN
                    CASE
                        WHEN (d.flash0_tics IS NOT NULL) THEN 0
                        ELSE NULL::integer
                    END
                    WHEN (d.flash_seq_index IS NULL) THEN NULL::integer
                    WHEN (NOT d.flash_advancing) THEN d.flash_seq_index
                    ELSE d.flashnext_seq
                END AS n_flash_seq,
                CASE
                    WHEN d.fires_now THEN COALESCE(d.flash0_tics, 0)
                    WHEN (d.flash_seq_index IS NULL) THEN 0
                    WHEN (NOT d.flash_advancing) THEN (d.flash_tics - 1)
                    ELSE COALESCE(d.flashnext_tics, 0)
                END AS n_flash_tics
           FROM decision d
        )
 SELECT map_id,
    player_thing_id,
    n_state,
    n_seq,
    n_tics,
    n_current_weapon,
    n_pending_weapon,
    n_flash_seq,
    n_flash_tics,
    n_sx,
    n_sy,
    fires_now
   FROM decision2;
