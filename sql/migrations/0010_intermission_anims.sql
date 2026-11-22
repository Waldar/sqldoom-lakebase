-- The episode map's moving parts during the intermission (2026-11-21), as
-- wi_stuff.c's WI_initAnimatedBack / WI_updateAnimatedBack: each animation
-- starts at a random tic in its first period after the screen began
-- (M_Random() % period) and steps every period. anim_base: the screen step
-- (screen_state.tics) the animations were last started at (the stats, then
-- the episode map: Doom starts them again there); anim_rnd: each
-- animation's random start, 0 .. period - 1.
ALTER TABLE doom.screen_state ADD COLUMN IF NOT EXISTS anim_base integer NOT NULL DEFAULT 0;
ALTER TABLE doom.screen_state ADD COLUMN IF NOT EXISTS anim_rnd integer[] NOT NULL DEFAULT '{}';
