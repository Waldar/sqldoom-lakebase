-- Baseline: the game's types and tables.
--
-- Applied once, on an empty schema doom (the setup creates the schema, owned by
-- doom_owner, and the extensions btree_gist and pg_prewarm). A database made
-- before migrations existed already has these tables: the installer records
-- this migration as applied without running it (src/sqldoom/db/install.py).
-- Later changes to tables go in new migrations (0002_..., 0003_...), never here.
--
-- Hot tables (written every tic) keep dead rows few with aggressive
-- autovacuum settings and, for the three updated in place most, a low
-- fillfactor so updates stay on the same page (HOT updates).

-- Enumerated types
CREATE TYPE doom.actor_state AS ENUM ('stand', 'see', 'missile', 'pain', 'die', 'xdeath', 'dead');
CREATE TYPE doom.ammo_kind AS ENUM ('bullets', 'shells', 'cells', 'rockets');
CREATE TYPE doom.boss_action AS ENUM ('none', 'exit_level', 'lower_666');
CREATE TYPE doom.bsp_child AS ENUM ('NODE', 'SSECTOR');
CREATE TYPE doom.damage_kind AS ENUM ('direct', 'splash', 'bfg_spray');
CREATE TYPE doom.door_target AS ENUM ('back', 'tag');
CREATE TYPE doom.effect_kind AS ENUM ('puff', 'blood', 'tfog', 'ifog', 'bfg_spray');
CREATE TYPE doom.height_target AS ENUM ('floor', 'floor8', 'highest', 'highest8', 'highest_ceiling', 'lowest', 'lowest_ceiling', 'lowest_ceiling_minus8', 'next_floor', 'plus24', 'plus32', 'plus512', 'shortest_texture');
CREATE TYPE doom.hit_kind AS ENUM ('wall', 'target');
CREATE TYPE doom.key_color AS ENUM ('red', 'blue', 'yellow');
CREATE TYPE doom.light_source AS ENUM ('max_neighbor', 'min_neighbor', 'strobe');
CREATE TYPE doom.match_state AS ENUM ('playing', 'intermission');
CREATE TYPE doom.movement_mode AS ENUM ('idle', 'turn', 'full');
CREATE TYPE doom.mover_kind AS ENUM ('door_open', 'door_close', 'door_raise', 'door_close_open', 'door_manual_raise', 'floor_raise', 'floor_lower', 'ceiling_raise', 'ceiling_lower', 'platform', 'platform_perpetual', 'crusher', 'donut_raise');
CREATE TYPE doom.pickup_kind AS ENUM ('health', 'armor', 'bullets', 'shells', 'cells', 'rockets', 'backpack', 'weapon', 'key_red', 'key_blue', 'key_yellow', 'invuln', 'invis', 'radsuit', 'powermap', 'lightamp');
CREATE TYPE doom.plane_kind AS ENUM ('floor', 'ceiling');
CREATE TYPE doom.projectile_kind AS ENUM ('rocket', 'plasma', 'bfg', 'imp_fireball', 'caco_fireball', 'baron_fireball');
CREATE TYPE doom.projectile_state AS ENUM ('fly', 'explode');
CREATE TYPE doom.screen_kind AS ENUM ('title', 'main', 'episode', 'skill', 'load', 'save', 'help1', 'help2', 'game', 'intermission', 'finale');
CREATE TYPE doom.sound_cue AS ENUM ('sight', 'active', 'pain', 'death', 'xdeath');
CREATE TYPE doom.special_mechanic AS ENUM ('door', 'floor', 'raise', 'platform', 'ceiling', 'crusher', 'stop', 'lights', 'stairs', 'teleport', 'donut');
CREATE TYPE doom.texture_part AS ENUM ('upper', 'middle', 'lower');
CREATE TYPE doom.trigger_kind AS ENUM ('use', 'cross', 'shoot');
CREATE TYPE doom.weapon_state AS ENUM ('up', 'down', 'ready', 'fire', 'flash');

-- Text is assigned to enum columns implicitly in the game's SQL (e.g.
-- SET mode = CASE .. THEN 'full' END): one assignment cast per enum type.
CREATE CAST (text AS doom.actor_state) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.ammo_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.boss_action) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.bsp_child) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.damage_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.door_target) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.effect_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.height_target) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.hit_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.key_color) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.light_source) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.match_state) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.movement_mode) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.mover_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.pickup_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.plane_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.projectile_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.projectile_state) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.screen_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.sound_cue) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.special_mechanic) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.texture_part) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.trigger_kind) WITH INOUT AS ASSIGNMENT;
CREATE CAST (text AS doom.weapon_state) WITH INOUT AS ASSIGNMENT;

-- Tables (foreign keys at the end)

CREATE TABLE doom.ammo_defs (
  ammo_type ammo_kind NOT NULL,
  cap integer NOT NULL,
  backpack_cap integer NOT NULL,
  backpack_gives integer NOT NULL,
  CONSTRAINT ammo_defs_pkey PRIMARY KEY (ammo_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.api_roles (
  role_name text NOT NULL,
  CONSTRAINT api_roles_pkey PRIMARY KEY (role_name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.api_spectator_roles (
  role_name text NOT NULL,
  CONSTRAINT api_spectator_roles_pkey PRIMARY KEY (role_name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.api_tic_stats (
  id integer NOT NULL,
  updated_at timestamp with time zone NOT NULL,
  tic_ms real NOT NULL,
  tic_p90_ms real NOT NULL,
  tic_max_ms real NOT NULL,
  tics integer NOT NULL,
  dropped integer NOT NULL,
  interval_seconds real NOT NULL,
  CONSTRAINT api_tic_stats_pkey PRIMARY KEY (id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.automap_view (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  center_x real DEFAULT 0 NOT NULL,
  center_y real DEFAULT 0 NOT NULL,
  zoom real DEFAULT 1.0 NOT NULL,
  follow boolean DEFAULT true NOT NULL,
  grid boolean DEFAULT false NOT NULL,
  cheat smallint DEFAULT 0 NOT NULL,
  CONSTRAINT automap_view_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.blockmaps (
  map_id integer NOT NULL,
  origin_x smallint NOT NULL,
  origin_y smallint NOT NULL,
  cols smallint NOT NULL,
  rows smallint NOT NULL,
  payload bytea NOT NULL,
  CONSTRAINT blockmaps_pkey PRIMARY KEY (map_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.boss_actions (
  map_name text NOT NULL,
  boss_type integer NOT NULL,
  action boss_action NOT NULL,
  CONSTRAINT boss_actions_pkey PRIMARY KEY (map_name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.chase_dir_defs (
  dir smallint NOT NULL,
  name text NOT NULL,
  dx double precision NOT NULL,
  dy double precision NOT NULL,
  angle real NOT NULL,
  opposite smallint NOT NULL,
  is_diagonal boolean NOT NULL,
  CONSTRAINT chase_dir_defs_pkey PRIMARY KEY (dir)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.colormap_idx_lvl (
  pal smallint NOT NULL,
  level integer NOT NULL,
  bytes bytea NOT NULL,
  CONSTRAINT colormap_idx_lvl_pkey PRIMARY KEY (pal, level)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.colormap_rgb (
  pal smallint DEFAULT 0 NOT NULL,
  level smallint NOT NULL,
  palette_index smallint NOT NULL,
  mapped_index smallint NOT NULL,
  r smallint NOT NULL,
  g smallint NOT NULL,
  b smallint NOT NULL,
  rgb bytea NOT NULL,
  CONSTRAINT colormap_rgb_pkey PRIMARY KEY (pal, level, palette_index)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.demo_tics (
  demo_id integer NOT NULL,
  tic integer NOT NULL,
  move_fwd real NOT NULL,
  move_strafe real NOT NULL,
  running boolean NOT NULL,
  turn_degrees real NOT NULL,
  attack_held boolean NOT NULL,
  weapon_switch_to integer,
  use_requested boolean NOT NULL,
  CONSTRAINT demo_tics_pkey PRIMARY KEY (demo_id, tic)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.demos (
  demo_id integer NOT NULL,
  name text NOT NULL,
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  skill integer NOT NULL,
  tic_count integer DEFAULT 0 NOT NULL,
  recorded_at timestamp without time zone DEFAULT now() NOT NULL,
  CONSTRAINT demos_pkey PRIMARY KEY (demo_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.doom_constants (
  name text NOT NULL,
  value double precision NOT NULL,
  source text NOT NULL,
  CONSTRAINT doom_constants_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.effect_sprite_defs (
  effect_type effect_kind NOT NULL,
  sprite character varying(4) NOT NULL,
  frame_sequence text NOT NULL,
  tics_per_frame smallint NOT NULL,
  fullbright boolean NOT NULL,
  CONSTRAINT effect_sprite_defs_pkey PRIMARY KEY (effect_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.finale_defs (
  episode integer NOT NULL,
  flat text NOT NULL,
  patch text NOT NULL,
  story_text text NOT NULL,
  CONSTRAINT finale_defs_pkey PRIMARY KEY (episode)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.flat_textures (
  name text NOT NULL,
  palette_indices bytea NOT NULL,
  CONSTRAINT flat_textures_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.game_tic_commands (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  command_serial bigint DEFAULT 0 NOT NULL,
  skill integer DEFAULT 2 NOT NULL,
  skill_bit integer DEFAULT 2 NOT NULL,
  move_fwd real DEFAULT 0 NOT NULL,
  move_strafe real DEFAULT 0 NOT NULL,
  running boolean DEFAULT false NOT NULL,
  turn_degrees real DEFAULT 0 NOT NULL,
  attack_held boolean DEFAULT false NOT NULL,
  weapon_switch_to integer,
  use_requested boolean DEFAULT false NOT NULL,
  movement_mode movement_mode DEFAULT 'idle'::movement_mode NOT NULL,
  CONSTRAINT game_tic_commands_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, fillfactor=10, vacuum_truncate=false);

CREATE TABLE doom.hitscan_hits (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  shot_serial bigint NOT NULL,
  pellet smallint NOT NULL,
  damage smallint NOT NULL,
  thing_id integer,
  sector_id integer,
  no_blood boolean NOT NULL,
  distance real NOT NULL,
  angle double precision NOT NULL,
  slope double precision NOT NULL,
  hit_kind hit_kind NOT NULL,
  px real NOT NULL,
  py real NOT NULL,
  shoot_z real NOT NULL,
  line_id integer,
  line_from_front boolean,
  CONSTRAINT hitscan_hits_pkey PRIMARY KEY (map_id, player_thing_id, shot_serial, pellet)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.hud_cache (
  map_id integer NOT NULL,
  slot integer NOT NULL,
  key text NOT NULL,
  bar bytea NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT hud_cache_pkey PRIMARY KEY (map_id, slot)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.item_respawns (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  respawn_tic bigint NOT NULL,
  CONSTRAINT item_respawns_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.level_pars (
  episode integer NOT NULL,
  level integer NOT NULL,
  par_secs integer NOT NULL,
  CONSTRAINT level_pars_pkey PRIMARY KEY (episode, level)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.level_secret_discoveries (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  sector_id integer NOT NULL,
  CONSTRAINT level_secret_discoveries_pkey PRIMARY KEY (map_id, player_thing_id, sector_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.level_stats (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  skill_bit integer NOT NULL,
  level_tics bigint DEFAULT 0 NOT NULL,
  par_tics bigint,
  kills integer DEFAULT 0 NOT NULL,
  total_kills integer DEFAULT 0 NOT NULL,
  items integer DEFAULT 0 NOT NULL,
  total_items integer DEFAULT 0 NOT NULL,
  secrets integer DEFAULT 0 NOT NULL,
  total_secrets integer DEFAULT 0 NOT NULL,
  completed boolean DEFAULT false NOT NULL,
  secret_exit boolean DEFAULT false NOT NULL,
  CONSTRAINT level_stats_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.line_activations (
  map_id integer NOT NULL,
  line_id integer NOT NULL,
  CONSTRAINT line_activations_pkey PRIMARY KEY (map_id, line_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.line_buttons (
  map_id integer NOT NULL,
  line_id integer NOT NULL,
  sidedef_id integer NOT NULL,
  texture_part texture_part NOT NULL,
  original_tex character varying(8) NOT NULL,
  active_tex character varying(8) NOT NULL,
  countdown integer NOT NULL,
  just_restored boolean DEFAULT false NOT NULL,
  CONSTRAINT line_buttons_pkey PRIMARY KEY (map_id, line_id, sidedef_id, texture_part)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.line_special_defs (
  special integer NOT NULL,
  name text NOT NULL,
  mechanic special_mechanic,
  cross_activated boolean DEFAULT false NOT NULL,
  cross_once boolean DEFAULT false NOT NULL,
  monster_crossable boolean DEFAULT false NOT NULL,
  use_activated boolean DEFAULT false NOT NULL,
  use_once boolean DEFAULT false NOT NULL,
  key_required key_color,
  is_exit boolean DEFAULT false NOT NULL,
  secret_exit boolean DEFAULT false NOT NULL,
  door_target door_target,
  height_target height_target,
  change_tex boolean DEFAULT false NOT NULL,
  flips_switch boolean DEFAULT false NOT NULL,
  shoot_activated boolean DEFAULT false NOT NULL,
  monster_usable boolean DEFAULT false NOT NULL,
  scrolls boolean DEFAULT false NOT NULL,
  target_light smallint,
  mover_type mover_kind,
  direction smallint,
  step_height smallint,
  crush boolean DEFAULT false NOT NULL,
  light_source light_source,
  stops_mover mover_kind,
  speed numeric(4,1),
  wait_tics integer,
  CONSTRAINT line_special_defs_pkey PRIMARY KEY (special)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.line_special_events (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  line_id integer NOT NULL,
  trigger_type trigger_kind NOT NULL,
  from_front boolean NOT NULL,
  CONSTRAINT line_special_events_pkey PRIMARY KEY (map_id, player_thing_id, line_id, trigger_type)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.line_use_results (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  line_id integer,
  special integer,
  locked boolean DEFAULT false NOT NULL,
  eligible boolean DEFAULT false NOT NULL,
  from_front boolean DEFAULT false NOT NULL,
  CONSTRAINT line_use_results_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.linedefs (
  id integer NOT NULL,
  map_id integer NOT NULL,
  v1_id integer NOT NULL,
  v2_id integer NOT NULL,
  flags integer NOT NULL,
  special integer NOT NULL,
  tag integer NOT NULL,
  right_sd_id integer NOT NULL,
  left_sd_id integer NOT NULL,
  cross_activated boolean DEFAULT false NOT NULL,
  cross_once boolean DEFAULT false NOT NULL,
  monster_crossable boolean DEFAULT false NOT NULL,
  scrolls boolean DEFAULT false NOT NULL,
  CONSTRAINT linedefs_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.map_music (
  map_id integer NOT NULL,
  music_name character varying(8) NOT NULL,
  CONSTRAINT map_music_pkey PRIMARY KEY (map_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mapped_lines (
  map_id integer NOT NULL,
  line_id integer NOT NULL,
  CONSTRAINT mapped_lines_pkey PRIMARY KEY (map_id, line_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.maps (
  map_id serial,
  wad_id integer,
  name text NOT NULL,
  sky_texture text,
  CONSTRAINT maps_pkey PRIMARY KEY (map_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.menu_decor (
  screen screen_kind NOT NULL,
  seq integer NOT NULL,
  patch text NOT NULL,
  x integer NOT NULL,
  y integer NOT NULL,
  CONSTRAINT menu_decor_pkey PRIMARY KEY (screen, seq)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.menu_items (
  screen screen_kind NOT NULL,
  idx integer NOT NULL,
  patch text,
  x integer NOT NULL,
  y integer NOT NULL,
  CONSTRAINT menu_items_pkey PRIMARY KEY (screen, idx)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.monster_ai (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  state actor_state DEFAULT 'stand'::actor_state NOT NULL,
  state_tics integer DEFAULT '-1'::integer NOT NULL,
  seq_index integer DEFAULT 0 NOT NULL,
  sector_id integer,
  attack_cooldown integer DEFAULT 0 NOT NULL,
  fired_this_tick boolean DEFAULT false NOT NULL,
  target_thing_id integer,
  charge_tics integer DEFAULT 0 NOT NULL,
  movedir smallint DEFAULT 0,
  movecount smallint DEFAULT 0 NOT NULL,
  CONSTRAINT monster_ai_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, fillfactor=10, vacuum_truncate=false);

CREATE TABLE doom.monster_attack_damage (
  map_id integer NOT NULL,
  attacker_id integer NOT NULL,
  victim_id integer,
  victim_player integer NOT NULL,
  dmg integer NOT NULL,
  mx double precision NOT NULL,
  my double precision NOT NULL
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.monster_deaths (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  death_tic bigint NOT NULL,
  CONSTRAINT monster_deaths_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.monster_projectiles (
  map_id integer NOT NULL,
  projectile_id bigint NOT NULL,
  owner_thing_id integer NOT NULL,
  projectile_type projectile_kind NOT NULL,
  x real NOT NULL,
  y real NOT NULL,
  z real NOT NULL,
  vx real NOT NULL,
  vy real NOT NULL,
  vz real NOT NULL,
  sector_id integer,
  state projectile_state DEFAULT 'fly'::projectile_state NOT NULL,
  age smallint DEFAULT 0 NOT NULL,
  damage smallint NOT NULL,
  impact_player boolean DEFAULT false NOT NULL,
  CONSTRAINT monster_projectiles_pkey PRIMARY KEY (map_id, projectile_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.monster_respawns (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  old_x real NOT NULL,
  old_y real NOT NULL,
  CONSTRAINT monster_respawns_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.monster_steps (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  old_x real NOT NULL,
  old_y real NOT NULL,
  new_x real NOT NULL,
  new_y real NOT NULL,
  face_angle real NOT NULL,
  movedir smallint,
  movecount smallint DEFAULT 0 NOT NULL,
  CONSTRAINT monster_steps_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.monster_teleports (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  dest_x real NOT NULL,
  dest_y real NOT NULL,
  dest_angle real NOT NULL,
  sector_id integer NOT NULL,
  CONSTRAINT monster_teleports_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_dm_things (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  solo_flags integer NOT NULL,
  dm_flags integer NOT NULL,
  CONSTRAINT mp_dm_things_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_holders (
  slot integer NOT NULL,
  role_name text NOT NULL,
  display_name text,
  claimed_at timestamp with time zone,
  CONSTRAINT mp_holders_pkey PRIMARY KEY (slot)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_inputs (
  seq bigserial,
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  move_fwd real DEFAULT 0 NOT NULL,
  move_strafe real DEFAULT 0 NOT NULL,
  running boolean DEFAULT false NOT NULL,
  turn_degrees real DEFAULT 0 NOT NULL,
  attack_held boolean DEFAULT false NOT NULL,
  weapon_switch_to integer,
  use_requested boolean DEFAULT false NOT NULL,
  CONSTRAINT mp_inputs_pkey PRIMARY KEY (seq)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_join_requests (
  map_id integer NOT NULL,
  slot integer NOT NULL,
  CONSTRAINT mp_join_requests_pkey PRIMARY KEY (map_id, slot)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_map_request (
  id boolean DEFAULT true NOT NULL,
  map_name text NOT NULL,
  requested_at timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT mp_map_request_pkey PRIMARY KEY (id),
  CONSTRAINT mp_map_request_id_check CHECK (id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_match (
  id integer DEFAULT 0 NOT NULL,
  map_id integer NOT NULL,
  skill integer DEFAULT 3 NOT NULL,
  state match_state DEFAULT 'playing'::match_state NOT NULL,
  timer_tics integer DEFAULT 21000 NOT NULL,
  altdeath boolean DEFAULT true NOT NULL,
  monsters boolean DEFAULT true NOT NULL,
  respawn_monsters boolean DEFAULT true NOT NULL,
  intermission_tics integer DEFAULT 350 NOT NULL,
  intermission_until timestamp with time zone,
  maps_played integer DEFAULT 0 NOT NULL,
  hold_seconds integer DEFAULT 0 NOT NULL,
  mode text DEFAULT 'solo'::text NOT NULL,
  pending text,
  weapons_stay boolean DEFAULT false NOT NULL,
  death_restart boolean DEFAULT false NOT NULL,
  CONSTRAINT mp_match_pkey PRIMARY KEY (id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_players (
  map_id integer NOT NULL,
  slot integer NOT NULL,
  player_thing_id integer NOT NULL,
  skill integer DEFAULT 3 NOT NULL,
  role_name text,
  pose_x real DEFAULT 0 NOT NULL,
  pose_y real DEFAULT 0 NOT NULL,
  pose_z real DEFAULT 41 NOT NULL,
  pose_angle real DEFAULT 0 NOT NULL,
  last_seen timestamp with time zone,
  display_name text,
  claimed_at timestamp with time zone,
  CONSTRAINT mp_players_pkey PRIMARY KEY (map_id, slot)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_referee (
  map_id integer NOT NULL,
  heartbeat timestamp with time zone NOT NULL,
  CONSTRAINT mp_referee_pkey PRIMARY KEY (map_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_rotation (
  position integer NOT NULL,
  map_name text NOT NULL,
  CONSTRAINT mp_rotation_pkey PRIMARY KEY ("position")
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_rules (
  mode text NOT NULL,
  monsters boolean NOT NULL,
  skill integer NOT NULL,
  monster_respawn boolean NOT NULL,
  monster_respawn_s integer NOT NULL,
  item_respawn boolean NOT NULL,
  item_respawn_s integer NOT NULL,
  weapons_stay boolean NOT NULL,
  death_restart boolean NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_by text,
  CONSTRAINT mp_rules_pkey PRIMARY KEY (mode),
  CONSTRAINT mp_rules_item_respawn_s_check CHECK (((item_respawn_s >= 1) AND (item_respawn_s <= 600))),
  CONSTRAINT mp_rules_mode_check CHECK ((mode = ANY (ARRAY['solo'::text, 'deathmatch'::text]))),
  CONSTRAINT mp_rules_monster_respawn_s_check CHECK (((monster_respawn_s >= 1) AND (monster_respawn_s <= 600))),
  CONSTRAINT mp_rules_skill_check CHECK (((skill >= 0) AND (skill <= 4)))
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.mp_waiting (
  role_name text NOT NULL,
  since timestamp with time zone NOT NULL,
  last_seen timestamp with time zone NOT NULL,
  CONSTRAINT mp_waiting_pkey PRIMARY KEY (role_name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.music_assets (
  name character varying(8) NOT NULL,
  mus_data bytea NOT NULL,
  midi_data bytea NOT NULL,
  audio_data bytea,
  audio_format text,
  CONSTRAINT music_assets_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.node_children (
  map_id integer NOT NULL,
  node_id integer NOT NULL,
  side character(1) NOT NULL,
  child_kind bsp_child NOT NULL,
  child_node_id integer,
  child_ssector_id integer,
  bbox_top smallint,
  bbox_bottom smallint,
  bbox_left smallint,
  bbox_right smallint,
  CONSTRAINT node_children_pkey PRIMARY KEY (map_id, node_id, side)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.nodes (
  id integer NOT NULL,
  map_id integer NOT NULL,
  x smallint,
  y smallint,
  dx smallint,
  dy smallint,
  CONSTRAINT nodes_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.picked_up_items (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  CONSTRAINT picked_up_items_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.pickup_defs (
  thing_type integer NOT NULL,
  kind pickup_kind NOT NULL,
  amount integer NOT NULL,
  cap integer NOT NULL,
  is_set_min boolean DEFAULT false NOT NULL,
  weapon_id integer,
  armor_class smallint,
  counts_item boolean DEFAULT false NOT NULL,
  dropped_amount integer,
  only_when_below_cap boolean DEFAULT false NOT NULL,
  CONSTRAINT pickup_defs_pkey PRIMARY KEY (thing_type, kind)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.pickup_grants (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  weapon_id integer NOT NULL,
  CONSTRAINT pickup_grants_pkey PRIMARY KEY (map_id, player_thing_id, weapon_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.pickup_messages (
  thing_type integer NOT NULL,
  message text NOT NULL,
  CONSTRAINT pickup_messages_pkey PRIMARY KEY (thing_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.pickup_touches (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  thing_id integer NOT NULL,
  kind pickup_kind NOT NULL,
  amount integer NOT NULL,
  cap integer NOT NULL,
  is_set_min boolean NOT NULL,
  weapon_id integer,
  armor_class smallint,
  CONSTRAINT pickup_touches_pkey PRIMARY KEY (map_id, player_thing_id, thing_id, kind)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.player_state (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  health integer DEFAULT 100 NOT NULL,
  alive boolean DEFAULT true NOT NULL,
  level_tics bigint DEFAULT 0 NOT NULL,
  previous_x real DEFAULT 0 NOT NULL,
  previous_y real DEFAULT 0 NOT NULL,
  position_x real DEFAULT 0 NOT NULL,
  position_y real DEFAULT 0 NOT NULL,
  base_z real DEFAULT 41 NOT NULL,
  view_z real DEFAULT 41 NOT NULL,
  view_angle real DEFAULT 0 NOT NULL,
  momentum_x real DEFAULT 0 NOT NULL,
  momentum_y real DEFAULT 0 NOT NULL,
  bob_strength real DEFAULT 0 NOT NULL,
  previous_view_z real DEFAULT 41 NOT NULL,
  previous_view_angle real DEFAULT 0 NOT NULL,
  sector_id integer,
  pain_face_tics integer DEFAULT 0 NOT NULL,
  armor integer DEFAULT 0 NOT NULL,
  armor_class smallint DEFAULT 0 NOT NULL,
  backpack boolean DEFAULT false NOT NULL,
  ammo_bullets integer DEFAULT 0 NOT NULL,
  ammo_shells integer DEFAULT 0 NOT NULL,
  ammo_rockets integer DEFAULT 0 NOT NULL,
  ammo_cells integer DEFAULT 0 NOT NULL,
  key_blue boolean DEFAULT false NOT NULL,
  key_yellow boolean DEFAULT false NOT NULL,
  key_red boolean DEFAULT false NOT NULL,
  radsuit_tics integer DEFAULT 0 NOT NULL,
  invis_tics integer DEFAULT 0 NOT NULL,
  momentum_z real DEFAULT 0 NOT NULL,
  damage_count integer DEFAULT 0 NOT NULL,
  bonus_count integer DEFAULT 0 NOT NULL,
  light_amp_tics integer DEFAULT 0 NOT NULL,
  power_map boolean DEFAULT false NOT NULL,
  god_mode boolean DEFAULT false NOT NULL,
  noclip boolean DEFAULT false NOT NULL,
  invuln_tics integer DEFAULT 0 NOT NULL,
  berserk boolean DEFAULT false NOT NULL,
  message text,
  message_tics integer DEFAULT 0 NOT NULL,
  frags integer DEFAULT 0 NOT NULL,
  death_tics integer DEFAULT 0 NOT NULL,
  killer_id integer,
  sprite_frame character(1) DEFAULT 'A'::bpchar NOT NULL,
  CONSTRAINT player_state_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, fillfactor=10, vacuum_truncate=false);

CREATE TABLE doom.player_weapon_owned (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  weapon_id integer NOT NULL,
  CONSTRAINT player_weapon_owned_pkey PRIMARY KEY (map_id, player_thing_id, weapon_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.player_weapons (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  current_weapon integer DEFAULT 2 NOT NULL,
  pending_weapon integer,
  state weapon_state DEFAULT 'up'::weapon_state NOT NULL,
  seq_index integer DEFAULT 0 NOT NULL,
  tics smallint DEFAULT 1 NOT NULL,
  flash_seq_index integer,
  flash_tics smallint DEFAULT 0 NOT NULL,
  sx real DEFAULT 1 NOT NULL,
  sy real DEFAULT 128 NOT NULL,
  shot_serial bigint DEFAULT 0 NOT NULL,
  fired_this_tick boolean DEFAULT false NOT NULL,
  CONSTRAINT player_weapons_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.projectile_damage (
  map_id integer NOT NULL,
  projectile_id bigint NOT NULL,
  damage_kind damage_kind NOT NULL,
  hit_index integer NOT NULL,
  thing_id integer NOT NULL,
  damage integer NOT NULL,
  CONSTRAINT projectile_damage_pkey PRIMARY KEY (map_id, projectile_id, damage_kind, hit_index)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.projectile_defs (
  projectile_type projectile_kind NOT NULL,
  name text NOT NULL,
  radius real NOT NULL,
  speed real,
  dmg_dice_mult integer,
  dmg_random_id smallint,
  explode_tics smallint NOT NULL,
  fly_timeout smallint NOT NULL,
  blast_radius real,
  spray_at_tic smallint,
  spray_rays smallint,
  spray_arc_degrees real,
  spray_range real,
  spray_dice smallint,
  spray_random_base smallint,
  fly_sprite character varying(4),
  impact_sprite character varying(4),
  dmg_dice_count smallint DEFAULT 8 NOT NULL,
  CONSTRAINT projectile_defs_pkey PRIMARY KEY (projectile_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.projectile_impacts (
  map_id integer NOT NULL,
  projectile_id bigint NOT NULL,
  projectile_type projectile_kind NOT NULL,
  owner_thing_id integer NOT NULL,
  x real NOT NULL,
  y real NOT NULL,
  z real NOT NULL,
  target_player boolean DEFAULT false NOT NULL,
  target_thing_id integer,
  target_player_thing_id integer,
  CONSTRAINT projectile_impacts_pkey PRIMARY KEY (map_id, projectile_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.reject_lumps (
  map_id integer NOT NULL,
  data bytea,
  CONSTRAINT reject_lumps_pkey PRIMARY KEY (map_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.render_segs (
  map_id integer NOT NULL,
  seg_id integer NOT NULL,
  ssector_id integer,
  direction smallint,
  linedef_id integer,
  x1 smallint,
  y1 smallint,
  x2 smallint,
  y2 smallint,
  seg_u1 double precision,
  seg_u2 double precision,
  fsec integer,
  bsec integer,
  x_offset smallint,
  y_offset smallint,
  upper_tex character varying(8),
  mid_tex character varying(8),
  lower_tex character varying(8),
  flags integer,
  f_floor smallint,
  f_ceil smallint,
  f_ceil_tex character varying(8),
  f_light smallint,
  b_floor smallint,
  b_ceil smallint,
  b_ceil_tex character varying(8),
  b_light smallint,
  light_bias smallint,
  CONSTRAINT render_segs_pkey PRIMARY KEY (map_id, seg_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, fillfactor=80, vacuum_truncate=false);

CREATE TABLE doom.render_things (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  sector_id integer NOT NULL,
  spawn_sector_id integer,
  sprite character varying(4) NOT NULL,
  frame character(1) NOT NULL,
  fullbright boolean NOT NULL,
  spawn_ceiling boolean NOT NULL,
  thing_height smallint NOT NULL,
  CONSTRAINT render_things_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.save_level_secret_discoveries (
  slot integer,
  map_id integer,
  player_thing_id integer,
  sector_id integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_level_stats (
  slot integer,
  map_id integer,
  player_thing_id integer,
  skill_bit integer,
  level_tics bigint,
  par_tics bigint,
  kills integer,
  total_kills integer,
  items integer,
  total_items integer,
  secrets integer,
  total_secrets integer,
  completed boolean,
  secret_exit boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_line_activations (
  slot integer,
  map_id integer,
  line_id integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_line_buttons (
  slot integer,
  map_id integer,
  line_id integer,
  sidedef_id integer,
  texture_part texture_part,
  original_tex character varying(8),
  active_tex character varying(8),
  countdown integer,
  just_restored boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_monster_ai (
  slot integer,
  map_id integer,
  thing_id integer,
  state actor_state,
  state_tics integer,
  seq_index integer,
  sector_id integer,
  attack_cooldown integer,
  fired_this_tick boolean,
  target_thing_id integer,
  charge_tics integer,
  movedir smallint,
  movecount smallint
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_monster_projectiles (
  slot integer,
  map_id integer,
  projectile_id bigint,
  owner_thing_id integer,
  projectile_type projectile_kind,
  x real,
  y real,
  z real,
  vx real,
  vy real,
  vz real,
  sector_id integer,
  state projectile_state,
  age smallint,
  damage smallint,
  impact_player boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_picked_up_items (
  slot integer,
  map_id integer,
  thing_id integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_player_state (
  slot integer,
  map_id integer,
  player_thing_id integer,
  health integer,
  alive boolean,
  level_tics bigint,
  previous_x real,
  previous_y real,
  position_x real,
  position_y real,
  base_z real,
  view_z real,
  view_angle real,
  momentum_x real,
  momentum_y real,
  bob_strength real,
  previous_view_z real,
  previous_view_angle real,
  sector_id integer,
  pain_face_tics integer,
  armor integer,
  armor_class smallint,
  backpack boolean,
  ammo_bullets integer,
  ammo_shells integer,
  ammo_rockets integer,
  ammo_cells integer,
  key_blue boolean,
  key_yellow boolean,
  key_red boolean,
  radsuit_tics integer,
  invis_tics integer,
  momentum_z real,
  damage_count integer,
  bonus_count integer,
  light_amp_tics integer,
  power_map boolean,
  god_mode boolean,
  noclip boolean,
  invuln_tics integer,
  berserk boolean,
  message text,
  message_tics integer,
  frags integer,
  death_tics integer,
  killer_id integer,
  sprite_frame character(1)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_player_weapon_owned (
  slot integer,
  map_id integer,
  player_thing_id integer,
  weapon_id integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_player_weapons (
  slot integer,
  map_id integer,
  player_thing_id integer,
  current_weapon integer,
  pending_weapon integer,
  state weapon_state,
  seq_index integer,
  tics smallint,
  flash_seq_index integer,
  flash_tics smallint,
  sx real,
  sy real,
  shot_serial bigint,
  fired_this_tick boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_sector_movers (
  slot integer,
  map_id integer,
  sector_id integer,
  source_line_id integer,
  mover_type mover_kind,
  plane plane_kind,
  direction smallint,
  bottom_height smallint,
  top_height smallint,
  speed numeric(4,1),
  move_carry numeric(4,1),
  wait_tics integer,
  countdown integer,
  next_ceiling smallint,
  next_floor smallint,
  target_floor_tex character varying(8),
  moved_this_tick boolean,
  crush boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_sectors (
  slot integer,
  id integer,
  map_id integer,
  floor_height smallint,
  ceil_height smallint,
  spawn_floor_height smallint,
  spawn_ceil_height smallint,
  spawn_floor_tex character varying(8),
  spawn_light_level smallint,
  floor_tex character varying(8),
  ceil_tex character varying(8),
  light_level smallint,
  special integer,
  tag integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_sidedefs (
  slot integer,
  id integer,
  map_id integer,
  x_offset smallint,
  y_offset smallint,
  upper_tex character varying(8),
  lower_tex character varying(8),
  mid_tex character varying(8),
  sector_id integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_slots (
  slot integer NOT NULL,
  saved_at timestamp without time zone NOT NULL,
  name text NOT NULL,
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  map_name text,
  skill integer NOT NULL,
  CONSTRAINT save_slots_pkey PRIMARY KEY (slot)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_thing_health (
  slot integer,
  map_id integer,
  thing_id integer,
  health integer,
  max_health integer,
  alive boolean
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_things (
  slot integer,
  id integer,
  map_id integer,
  x real,
  y real,
  z real,
  angle real,
  spawn_x smallint,
  spawn_y smallint,
  spawn_angle smallint,
  mom_x real,
  mom_y real,
  type integer,
  flags integer
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.save_world_effects (
  slot integer,
  map_id integer,
  effect_id bigint,
  effect_type effect_kind,
  x real,
  y real,
  z real,
  sector_id integer,
  age smallint
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.screen_state (
  id integer NOT NULL,
  screen screen_kind NOT NULL,
  cursor_index integer DEFAULT 0 NOT NULL,
  episode integer DEFAULT 1 NOT NULL,
  skill integer DEFAULT 2 NOT NULL,
  tics integer DEFAULT 0 NOT NULL,
  inter_episode integer,
  inter_level integer,
  inter_next integer,
  kills_pct integer,
  items_pct integer,
  secrets_pct integer,
  time_secs integer,
  par_secs integer,
  sp_state integer DEFAULT 0 NOT NULL,
  cnt_pause integer DEFAULT 0 NOT NULL,
  accelerate boolean DEFAULT false NOT NULL,
  tgt_kills integer,
  tgt_items integer,
  tgt_secrets integer,
  tgt_time integer,
  tgt_par integer,
  next_map_id integer,
  secret_exit boolean DEFAULT false NOT NULL,
  finale_episode integer,
  finale_count integer DEFAULT 0 NOT NULL,
  finale_stage integer DEFAULT 0 NOT NULL,
  demo_recording integer,
  demo_playing integer,
  demo_tic integer DEFAULT 0 NOT NULL,
  attract_step integer DEFAULT '-1'::integer NOT NULL,
  attract_pagetic real DEFAULT 0 NOT NULL,
  cheat_buffer text DEFAULT ''::text NOT NULL,
  CONSTRAINT screen_state_pkey PRIMARY KEY (id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sector_light_fx (
  map_id integer NOT NULL,
  sector_id integer NOT NULL,
  special smallint NOT NULL,
  base_light smallint NOT NULL,
  dark_light smallint NOT NULL,
  CONSTRAINT sector_light_fx_pkey PRIMARY KEY (map_id, sector_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sector_movers (
  map_id integer NOT NULL,
  sector_id integer NOT NULL,
  source_line_id integer,
  mover_type mover_kind NOT NULL,
  plane plane_kind DEFAULT 'ceiling'::plane_kind NOT NULL,
  direction smallint NOT NULL,
  bottom_height smallint,
  top_height smallint NOT NULL,
  speed numeric(4,1) NOT NULL,
  move_carry numeric(4,1) DEFAULT 0 NOT NULL,
  wait_tics integer NOT NULL,
  countdown integer DEFAULT 0 NOT NULL,
  next_ceiling smallint,
  next_floor smallint,
  target_floor_tex character varying(8),
  moved_this_tick boolean DEFAULT false NOT NULL,
  crush boolean DEFAULT false NOT NULL,
  CONSTRAINT sector_movers_pkey PRIMARY KEY (map_id, sector_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.sector_sound_origins (
  map_id integer NOT NULL,
  sector_id integer NOT NULL,
  x real NOT NULL,
  y real NOT NULL,
  CONSTRAINT sector_sound_origins_pkey PRIMARY KEY (map_id, sector_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sector_special_defs (
  special integer NOT NULL,
  name text NOT NULL,
  is_secret boolean DEFAULT false NOT NULL,
  damage_per_hit integer,
  ends_level_at_low_health boolean DEFAULT false NOT NULL,
  exit_at_health integer,
  CONSTRAINT sector_special_defs_pkey PRIMARY KEY (special)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sectors (
  id integer NOT NULL,
  map_id integer NOT NULL,
  floor_height smallint NOT NULL,
  ceil_height smallint NOT NULL,
  spawn_floor_height smallint NOT NULL,
  spawn_ceil_height smallint NOT NULL,
  spawn_floor_tex character varying(8) NOT NULL,
  spawn_light_level smallint NOT NULL,
  floor_tex character varying(8) NOT NULL,
  ceil_tex character varying(8) NOT NULL,
  light_level smallint NOT NULL,
  special integer NOT NULL,
  tag integer NOT NULL,
  CONSTRAINT sectors_pkey PRIMARY KEY (map_id, id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.segs (
  id integer NOT NULL,
  map_id integer NOT NULL,
  v1_id integer NOT NULL,
  v2_id integer NOT NULL,
  angle smallint NOT NULL,
  linedef_id integer NOT NULL,
  direction smallint NOT NULL,
  offs smallint NOT NULL,
  CONSTRAINT segs_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sidedefs (
  id integer NOT NULL,
  map_id integer NOT NULL,
  x_offset smallint NOT NULL,
  y_offset smallint NOT NULL,
  upper_tex character varying(8) NOT NULL,
  lower_tex character varying(8) NOT NULL,
  mid_tex character varying(8) NOT NULL,
  sector_id integer NOT NULL,
  CONSTRAINT sidedefs_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sound_assets (
  name character varying(8) NOT NULL,
  wav_data bytea NOT NULL,
  CONSTRAINT sound_assets_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sound_events (
  event_id bigserial,
  map_id integer NOT NULL,
  event_key text NOT NULL,
  level_tic bigint NOT NULL,
  sound_name character varying(8) NOT NULL,
  source_thing_id integer,
  source_x real,
  source_y real,
  CONSTRAINT sound_events_pkey PRIMARY KEY (event_id),
  CONSTRAINT sound_events_map_id_event_key_key UNIQUE (map_id, event_key)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.sprite_frames (
  sprite character varying(4) NOT NULL,
  frame character(1) NOT NULL,
  rotation smallint NOT NULL,
  lump_name character varying(8) NOT NULL,
  flipped boolean NOT NULL,
  width smallint NOT NULL,
  height smallint NOT NULL,
  left_offset smallint NOT NULL,
  top_offset smallint NOT NULL,
  CONSTRAINT sprite_frames_pkey PRIMARY KEY (sprite, frame, rotation)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.sprite_lumps (
  lump_name character varying(8) NOT NULL,
  pixels bytea NOT NULL,
  mask bytea NOT NULL,
  CONSTRAINT sprite_lumps_pkey PRIMARY KEY (lump_name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.ssectors (
  id integer NOT NULL,
  map_id integer NOT NULL,
  seg_count smallint NOT NULL,
  first_seg_id smallint NOT NULL,
  CONSTRAINT ssectors_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_ai_frames (
  thing_type integer NOT NULL,
  state actor_state NOT NULL,
  seq_index integer NOT NULL,
  frame character(1) NOT NULL,
  tics integer NOT NULL,
  fullbright boolean DEFAULT false NOT NULL,
  is_attack_frame boolean DEFAULT false NOT NULL,
  CONSTRAINT thing_ai_frames_pkey PRIMARY KEY (thing_type, state, seq_index)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_blocking_defs (
  thing_type integer NOT NULL,
  radius real NOT NULL,
  CONSTRAINT thing_blocking_defs_pkey PRIMARY KEY (thing_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_combat_defs (
  thing_type integer NOT NULL,
  spawn_health integer NOT NULL,
  radius real NOT NULL,
  death_sprite character varying(4) NOT NULL,
  death_frame character(1) NOT NULL,
  death_fullbright boolean NOT NULL,
  no_blood boolean DEFAULT false NOT NULL,
  pain_chance smallint DEFAULT 0 NOT NULL,
  attack_range real DEFAULT 2048 NOT NULL,
  xdeath_frame character(1),
  mass integer DEFAULT 100 NOT NULL,
  counts_kill boolean DEFAULT false NOT NULL,
  name text,
  height smallint DEFAULT 56 NOT NULL,
  floats boolean DEFAULT false NOT NULL,
  skull_fly boolean DEFAULT false NOT NULL,
  missile_type projectile_kind,
  missile_speed real,
  missile_dice smallint,
  hitscan_pellets smallint,
  melee_mult smallint,
  melee_sides smallint,
  fast_on_nightmare boolean DEFAULT false NOT NULL,
  attack_sound character varying(8),
  explodes boolean DEFAULT false NOT NULL,
  drops_thing_type integer,
  blast_radius real,
  hitscan_mult smallint,
  hitscan_sides smallint,
  charge_mult smallint,
  charge_sides smallint,
  fuzzy boolean DEFAULT false NOT NULL,
  CONSTRAINT thing_combat_defs_pkey PRIMARY KEY (thing_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_health (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  health integer NOT NULL,
  max_health integer NOT NULL,
  alive boolean NOT NULL,
  CONSTRAINT thing_health_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.thing_role_defs (
  thing_type integer NOT NULL,
  name text NOT NULL,
  is_player_start boolean DEFAULT false NOT NULL,
  player_number smallint,
  is_deathmatch_start boolean DEFAULT false NOT NULL,
  is_teleport_dest boolean DEFAULT false NOT NULL,
  CONSTRAINT thing_role_defs_pkey PRIMARY KEY (thing_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_sound_defs (
  thing_type integer NOT NULL,
  cue sound_cue NOT NULL,
  variant integer NOT NULL,
  sound_name character varying(8) NOT NULL,
  CONSTRAINT thing_sound_defs_pkey PRIMARY KEY (thing_type, cue, variant)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.thing_sprite_defs (
  thing_type integer NOT NULL,
  sprite character varying(4) NOT NULL,
  frame character(1) NOT NULL,
  fullbright boolean NOT NULL,
  spawn_ceiling boolean NOT NULL,
  thing_height smallint NOT NULL,
  CONSTRAINT thing_sprite_defs_pkey PRIMARY KEY (thing_type)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.things (
  id integer NOT NULL,
  map_id integer NOT NULL,
  x real NOT NULL,
  y real NOT NULL,
  z real DEFAULT 41 NOT NULL,
  angle real NOT NULL,
  spawn_x smallint NOT NULL,
  spawn_y smallint NOT NULL,
  spawn_angle smallint NOT NULL,
  mom_x real DEFAULT 0 NOT NULL,
  mom_y real DEFAULT 0 NOT NULL,
  type integer NOT NULL,
  flags integer NOT NULL,
  CONSTRAINT things_pkey PRIMARY KEY (map_id, id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.tic_trace (
  map_id integer NOT NULL,
  player_thing_id integer NOT NULL,
  stages bigint NOT NULL,
  CONSTRAINT tic_trace_pkey PRIMARY KEY (map_id, player_thing_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

CREATE TABLE doom.ui_patch_pixels (
  name character varying(8) NOT NULL,
  dx smallint NOT NULL,
  dy smallint NOT NULL,
  palette_index smallint NOT NULL,
  CONSTRAINT ui_patch_pixels_pkey PRIMARY KEY (name, dx, dy)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.ui_patches (
  name character varying(8) NOT NULL,
  width smallint NOT NULL,
  height smallint NOT NULL,
  left_offset smallint NOT NULL,
  top_offset smallint NOT NULL,
  pixels bytea NOT NULL,
  mask bytea NOT NULL,
  CONSTRAINT ui_patches_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.vertexes (
  id integer NOT NULL,
  map_id integer NOT NULL,
  x smallint NOT NULL,
  y smallint NOT NULL,
  CONSTRAINT vertexes_pkey PRIMARY KEY (map_id, id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.wads (
  wad_id serial,
  wad_type text,
  wad_path text NOT NULL,
  CONSTRAINT wads_pkey PRIMARY KEY (wad_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.walltex_meta (
  name text NOT NULL,
  width integer NOT NULL,
  height integer NOT NULL,
  palette_indices bytea NOT NULL,
  CONSTRAINT walltex_meta_pkey PRIMARY KEY (name)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.weapon_defs (
  weapon_id integer NOT NULL,
  name text NOT NULL,
  slot integer NOT NULL,
  ammo_type ammo_kind,
  ammo_per_shot integer DEFAULT 0 NOT NULL,
  sprite character varying(4) NOT NULL,
  flash_sprite character varying(4),
  pellet_count integer NOT NULL,
  max_range real NOT NULL,
  dmg_dice_count integer NOT NULL,
  dmg_dice_mult integer NOT NULL,
  projectile_type projectile_kind,
  idle_loop_sound character varying(8),
  CONSTRAINT weapon_defs_pkey PRIMARY KEY (weapon_id)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.weapon_frames (
  weapon_id integer NOT NULL,
  state weapon_state NOT NULL,
  seq_index integer NOT NULL,
  frame character(1) NOT NULL,
  tics integer NOT NULL,
  fullbright boolean DEFAULT false NOT NULL,
  is_attack_frame boolean DEFAULT false NOT NULL,
  refire_check boolean DEFAULT false NOT NULL,
  CONSTRAINT weapon_frames_pkey PRIMARY KEY (weapon_id, state, seq_index)
)
WITH (vacuum_truncate=false);

CREATE TABLE doom.world_effects (
  map_id integer NOT NULL,
  effect_id bigint NOT NULL,
  effect_type effect_kind NOT NULL,
  x real NOT NULL,
  y real NOT NULL,
  z real NOT NULL,
  sector_id integer,
  age smallint DEFAULT 0 NOT NULL,
  CONSTRAINT world_effects_pkey PRIMARY KEY (map_id, effect_id)
)
WITH (autovacuum_enabled=true, autovacuum_vacuum_threshold=1000, autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_insert_threshold=1000, autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_cost_delay=0, autovacuum_analyze_threshold=2147483647, autovacuum_analyze_scale_factor=0, vacuum_truncate=false);

-- Foreign keys
ALTER TABLE doom.blockmaps ADD CONSTRAINT blockmaps_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.linedefs ADD CONSTRAINT linedefs_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.linedefs ADD CONSTRAINT linedefs_map_id_v1_id_fkey FOREIGN KEY (map_id, v1_id) REFERENCES vertexes(map_id, id);
ALTER TABLE doom.linedefs ADD CONSTRAINT linedefs_map_id_v2_id_fkey FOREIGN KEY (map_id, v2_id) REFERENCES vertexes(map_id, id);
ALTER TABLE doom.maps ADD CONSTRAINT maps_wad_id_fkey FOREIGN KEY (wad_id) REFERENCES wads(wad_id);
ALTER TABLE doom.nodes ADD CONSTRAINT nodes_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.pickup_defs ADD CONSTRAINT pickup_defs_thing_type_fkey FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs(thing_type);
ALTER TABLE doom.reject_lumps ADD CONSTRAINT reject_lumps_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.sectors ADD CONSTRAINT sectors_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.segs ADD CONSTRAINT segs_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.segs ADD CONSTRAINT segs_map_id_linedef_id_fkey FOREIGN KEY (map_id, linedef_id) REFERENCES linedefs(map_id, id);
ALTER TABLE doom.segs ADD CONSTRAINT segs_map_id_v1_id_fkey FOREIGN KEY (map_id, v1_id) REFERENCES vertexes(map_id, id);
ALTER TABLE doom.segs ADD CONSTRAINT segs_map_id_v2_id_fkey FOREIGN KEY (map_id, v2_id) REFERENCES vertexes(map_id, id);
ALTER TABLE doom.sidedefs ADD CONSTRAINT sidedefs_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.sidedefs ADD CONSTRAINT sidedefs_map_id_sector_id_fkey FOREIGN KEY (map_id, sector_id) REFERENCES sectors(map_id, id);
ALTER TABLE doom.ssectors ADD CONSTRAINT ssectors_map_id_first_seg_id_fkey FOREIGN KEY (map_id, first_seg_id) REFERENCES segs(map_id, id);
ALTER TABLE doom.ssectors ADD CONSTRAINT ssectors_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.thing_ai_frames ADD CONSTRAINT thing_ai_frames_thing_type_fkey FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs(thing_type);
ALTER TABLE doom.thing_combat_defs ADD CONSTRAINT thing_combat_defs_drops_thing_type_fkey FOREIGN KEY (drops_thing_type) REFERENCES thing_sprite_defs(thing_type);
ALTER TABLE doom.thing_combat_defs ADD CONSTRAINT thing_combat_defs_missile_type_fkey FOREIGN KEY (missile_type) REFERENCES projectile_defs(projectile_type);
ALTER TABLE doom.thing_combat_defs ADD CONSTRAINT thing_combat_defs_thing_type_fkey FOREIGN KEY (thing_type) REFERENCES thing_sprite_defs(thing_type);
ALTER TABLE doom.things ADD CONSTRAINT things_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.vertexes ADD CONSTRAINT vertexes_map_id_fkey FOREIGN KEY (map_id) REFERENCES maps(map_id);
ALTER TABLE doom.weapon_defs ADD CONSTRAINT weapon_defs_projectile_type_fkey FOREIGN KEY (projectile_type) REFERENCES projectile_defs(projectile_type);
ALTER TABLE doom.weapon_frames ADD CONSTRAINT weapon_frames_weapon_id_fkey FOREIGN KEY (weapon_id) REFERENCES weapon_defs(weapon_id);
