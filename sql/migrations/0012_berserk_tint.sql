-- Berserk's red tint (2026-11-27). Doom's powers[pw_strength] is not a flag:
-- P_GivePower sets it to 1 and P_PlayerThink adds 1 every tic, and
-- ST_doPaletteStuff tints the screen red by 12 - (powers[pw_strength] >> 6),
-- fading out over the first 768 tics (~22 s). berserk_tics is that counter
-- (0 without berserk; doom_cs_clock counts it up while berserk is on).
ALTER TABLE doom.player_state ADD COLUMN IF NOT EXISTS berserk_tics integer NOT NULL DEFAULT 0;
