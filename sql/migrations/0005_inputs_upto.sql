-- The newest input a tic has taken, for the page's input-to-picture probe
-- (2026-11-20, as LBDoom's ?lag=1). Every api_input returns its mp_inputs.seq;
-- doom_run_mp_tic takes every row up to the newest one there (upto) and
-- deletes them in the same transaction, and stores upto here, on the rows it
-- has just written for this tic. A frame read after that tic committed has
-- every input up to there; frames.py stamps each frame with it (the oldest
-- of the player's inputs still waiting, minus one, if that is lower: one
-- committed during the tic), and the page times each input to the first
-- frame drawn with a stamp at or past it.
ALTER TABLE doom.game_tic_commands ADD COLUMN IF NOT EXISTS inputs_upto bigint NOT NULL DEFAULT 0;
