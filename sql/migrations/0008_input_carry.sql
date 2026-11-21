-- 2026-11-21 (owner: no angry face). The page sends its keys on a 35 Hz
-- timer that is not the game's clock, so some tics find no new input row
-- (doom_mp_begin_player): they ran with nothing held, the fire key
-- included, which reset the face's 2 s fire count (and stopped the player
-- for that tic). Such a tic now keeps the previous tic's held keys, as
-- Doom builds each tic from the keys down; for at most 3 tics in a row, so
-- a lost page does not leave the player running and firing. This counts
-- them.
ALTER TABLE doom.game_tic_commands ADD COLUMN IF NOT EXISTS empty_tics smallint NOT NULL DEFAULT 0;
