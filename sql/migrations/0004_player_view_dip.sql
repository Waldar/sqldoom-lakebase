-- The view's dip after a hard landing (2026-11-20). Doom keeps the eye
-- height per player (player->viewheight, VIEWHEIGHT 41 at rest) and its rate
-- of change (deltaviewheight): P_ZMovement sets the rate to momz/8 when the
-- player hits the floor faster than GRAVITY*8 (with sfx_oof), and
-- P_CalcHeight then adds it each tic, never below half the eye height, the
-- rate growing by FRACUNIT/4 a tic until the view is back up. Stored as
-- offsets from the eye height, 0 at rest: view_dip = viewheight - VIEWHEIGHT
-- (0 to -20.5) and view_dip_delta = deltaviewheight. Written by doom_cs_move
-- (view_z = base_z + bob + view_dip), reset when a player spawns.
ALTER TABLE doom.player_state ADD COLUMN IF NOT EXISTS view_dip real NOT NULL DEFAULT 0;
ALTER TABLE doom.player_state ADD COLUMN IF NOT EXISTS view_dip_delta real NOT NULL DEFAULT 0;
