-- The health the killing blow left a player with, below zero (2026-11-20).
-- player_state.health is the status bar's player->health, clamped at 0 as
-- P_DamageMobj does; Doom's body, mo->health, is not, and P_KillMobj gibs it
-- (S_PLAY_XDIE, A_XScream's sfx_slop) when it is below minus its spawn
-- health, 100. Set by every killing blow, NULL while alive (cleared when the
-- player respawns or leaves). Read by doom_cs_player_pose (the gib frames,
-- PLAYO-W, which could not show while health stopped at 0) and doom_cs_sound.
ALTER TABLE doom.player_state ADD COLUMN IF NOT EXISTS death_health integer;
