-- Storage settings of the tables the game tic writes, as on the live
-- game-template (read 2026-11-13). sql_frozen/ holds no tables, and these were
-- set by hand on the live project during the tuning, so a new project gets
-- them from here (setup_workspace.py, step sql). Idempotent.
--
-- Autovacuum: vacuum after 1000 changed rows whatever the table size, no
-- cost delay, never auto-ANALYZE (the referee analyzes at map change; an
-- auto-ANALYZE mid-level changed tic plans). fillfactor leaves room on the
-- page for HOT updates of the rows rewritten every tic.
-- (vacuum_truncate = false on every table comes from postgres_compat.sql.)

DO $$
DECLARE
  t text;
  common constant text := 'autovacuum_enabled = true, autovacuum_vacuum_threshold = 1000, '
    'autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_insert_threshold = 1000, '
    'autovacuum_vacuum_insert_scale_factor = 0, autovacuum_vacuum_cost_delay = 0, '
    'autovacuum_analyze_threshold = 2147483647, autovacuum_analyze_scale_factor = 0';
BEGIN
  FOREACH t IN ARRAY ARRAY['hitscan_hits', 'line_special_events', 'mapped_lines', 'monster_attack_damage',
                           'monster_steps', 'picked_up_items', 'pickup_touches', 'player_weapons',
                           'render_things', 'sector_movers', 'sectors', 'sound_events', 'thing_health',
                           'things', 'tic_trace', 'world_effects'] LOOP
    EXECUTE format('ALTER TABLE %I SET (%s)', t, common);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['game_tic_commands', 'monster_ai', 'player_state'] LOOP
    EXECUTE format('ALTER TABLE %I SET (%s, fillfactor = 10)', t, common);
  END LOOP;
  EXECUTE format('ALTER TABLE %I SET (%s, fillfactor = 80)', 'render_segs', common);
END $$;
