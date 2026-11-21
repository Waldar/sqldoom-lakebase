-- Single player's screens between levels (2026-11-21): Doom's intermission
-- (wi_stuff.c: the stats, then the episode map) and the end of an episode
-- (f_finale.c: the text, then the picture), run by the referee between two
-- maps (sqldoom/game/referee.py _solo_screens) and drawn by
-- doom.api_screen_frame.

-- player_t.didsecret: E1M9 was played (its exit leaves it set for the rest of
-- the episode), so the episode map keeps a splat on it. A new game starts
-- from game-template, where it is false.
ALTER TABLE doom.screen_state ADD COLUMN IF NOT EXISTS did_secret boolean NOT NULL DEFAULT false;

-- Items taken that came back since (item respawn in single player): the
-- respawn deletes the item's picked_up_items row, so the intermission's Items
-- count would lose it. One row per item, the times it was taken and came back.
CREATE TABLE IF NOT EXISTS doom.level_items_taken (
  map_id integer NOT NULL,
  thing_id integer NOT NULL,
  taken integer NOT NULL DEFAULT 0,
  CONSTRAINT level_items_taken_pkey PRIMARY KEY (map_id, thing_id)
)
WITH (vacuum_truncate=false);
