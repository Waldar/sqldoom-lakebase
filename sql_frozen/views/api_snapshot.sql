CREATE OR REPLACE VIEW doom.api_snapshot AS
 WITH command AS (
         SELECT g.map_id,
            g.player_thing_id,
            g.command_serial,
            g.skill,
            g.skill_bit,
            g.move_fwd,
            g.move_strafe,
            g.running,
            g.turn_degrees,
            g.attack_held,
            g.weapon_switch_to,
            g.use_requested,
            g.movement_mode
           FROM (game_tic_commands g
             JOIN mp_players mp ON (((mp.map_id = g.map_id) AND (mp.player_thing_id = g.player_thing_id))))
          WHERE (mp.role_name = doom_caller())
        ), cross_exit AS (
         SELECT COALESCE(bool_or(d.is_exit), false) AS requested,
            COALESCE(bool_or(d.secret_exit), false) AS secret
           FROM (((line_special_events e
             JOIN command c_1 ON (((c_1.map_id = e.map_id) AND (c_1.player_thing_id = e.player_thing_id))))
             JOIN linedefs ld ON (((ld.map_id = e.map_id) AND (ld.id = e.line_id))))
             JOIN line_special_defs d ON ((d.special = ld.special)))
          WHERE (e.trigger_type = 'cross'::trigger_kind)
        ), sector_exit AS (
         SELECT COALESCE(bool_or((ps_1.health <= sd.exit_at_health)), false) AS requested
           FROM (((command c_1
             JOIN player_state ps_1 ON (((ps_1.map_id = c_1.map_id) AND (ps_1.player_thing_id = c_1.player_thing_id))))
             JOIN sectors s ON (((s.map_id = ps_1.map_id) AND (s.id = ps_1.sector_id))))
             LEFT JOIN sector_special_defs sd ON ((sd.special = s.special)))
        ), boss_exit AS (
         SELECT (COALESCE(max(
                CASE
                    WHEN (q.alive_bosses = 0) THEN 1
                    ELSE 0
                END), 0) = 1) AS requested
           FROM ( SELECT sum(
                        CASE
                            WHEN h.alive THEN 1
                            ELSE 0
                        END) AS alive_bosses
                   FROM ((((command c_1
                     JOIN boss_actions ba ON ((ba.action = 'exit_level'::boss_action)))
                     JOIN maps m ON (((m.name = ba.map_name) AND (m.map_id = c_1.map_id))))
                     JOIN things t ON (((t.map_id = m.map_id) AND (t.type = ba.boss_type))))
                     JOIN thing_health h ON (((h.map_id = t.map_id) AND (h.thing_id = t.id))))
                  GROUP BY ba.map_name) q
        )
 SELECT ps.position_x,
    ps.position_y,
    ps.view_angle,
    ps.view_z,
    ps.alive,
    COALESCE(ur.locked, false) AS use_locked,
        CASE
            WHEN COALESCE(ur.locked, false) THEN (usd.key_required)::text
            ELSE NULL::text
        END AS required_key,
    COALESCE((c.use_requested AND ur.eligible AND usd.is_exit), false) AS use_exit,
    COALESCE((c.use_requested AND ur.eligible AND usd.secret_exit), false) AS use_secret_exit,
    ce.requested AS cross_exit,
    ce.secret AS cross_secret_exit,
    se.requested AS sector_exit,
    be.requested AS boss_exit,
    ps.power_map,
    COALESCE(tt.stages, (0)::bigint) AS tic_stages,
    'game'::text AS screen,
    false AS demo_active
   FROM (((((((command c
     JOIN player_state ps ON (((ps.map_id = c.map_id) AND (ps.player_thing_id = c.player_thing_id))))
     LEFT JOIN line_use_results ur ON (((ur.map_id = c.map_id) AND (ur.player_thing_id = c.player_thing_id))))
     LEFT JOIN line_special_defs usd ON ((usd.special = ur.special)))
     LEFT JOIN tic_trace tt ON (((tt.map_id = c.map_id) AND (tt.player_thing_id = c.player_thing_id))))
     CROSS JOIN cross_exit ce)
     CROSS JOIN sector_exit se)
     CROSS JOIN boss_exit be);
GRANT SELECT ON TABLE doom.api_snapshot TO databricks_gateway;
GRANT SELECT ON TABLE doom.api_snapshot TO databricks_reader_16406;
GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE doom.api_snapshot TO databricks_superuser;
