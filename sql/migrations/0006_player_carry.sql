-- What a single-player player takes to the next level (2026-11-20), as Doom's
-- G_PlayerFinishLevel: health, armor and its class, the backpack, ammo, the
-- weapons owned and the one in hand, and the cheats (god mode, no clipping);
-- not the keys, not the power-ups. doom_mp_rotate fills it when a
-- single-player level ends by its exit (no map asked for, nothing pending: a
-- map picked from the page, a death restart, a rules change or a mode switch
-- all start fresh, as Doom's pistol start); doom_mp_spawn_if_requested
-- applies it after the player's spawn on the next map and deletes it. One row
-- per seat (the map changes, the seat follows the player).
CREATE TABLE IF NOT EXISTS doom.mp_carry (
  slot integer PRIMARY KEY,
  health integer NOT NULL,
  armor integer NOT NULL,
  armor_class smallint NOT NULL,
  backpack boolean NOT NULL,
  ammo_bullets integer NOT NULL,
  ammo_shells integer NOT NULL,
  ammo_rockets integer NOT NULL,
  ammo_cells integer NOT NULL,
  weapons integer[] NOT NULL,
  current_weapon integer NOT NULL,
  god_mode boolean NOT NULL,
  noclip boolean NOT NULL
);
