-- Monsters walk, wake and shoot as Doom's A_Chase, A_Look and P_CheckMissileRange (2026-11-24).
--
-- monster_chase_defs: mobjinfo's speed (the stride of one A_Chase call) and how many A_Chase
-- calls one of this engine's 'see' frames stands for. The see frames of thing_ai_frames pair
-- two of Doom's run states for most monsters (S_TROO_RUN1/2, 3 + 3 tics = one 6-tic frame),
-- so they step twice a frame; the cacodemon, the lost soul, the cyberdemon and the spider
-- mastermind run on one Doom state a frame (S_HEAD_RUN1 3 tics, S_SKULL_RUN1 6, S_CYBER_RUN1 3,
-- S_SPID_RUN1 3) and step once. Until now every monster strode MONSTER_STEP (8) twice a frame:
-- cacodemons and lost souls walked twice as fast as in Doom, demons and spectres 80% as fast.
CREATE TABLE IF NOT EXISTS doom.monster_chase_defs (
  thing_type integer PRIMARY KEY,
  speed real NOT NULL,
  calls_per_frame smallint NOT NULL
);
INSERT INTO doom.monster_chase_defs (thing_type, speed, calls_per_frame) VALUES
  (3004, 8, 2),    -- zombieman      S_POSS_RUN 4 tics
  (9, 8, 2),       -- shotgun guy    S_SPOS_RUN 3
  (3001, 8, 2),    -- imp            S_TROO_RUN 3
  (3002, 10, 2),   -- demon          S_SARG_RUN 2
  (58, 10, 2),     -- spectre        S_SARG_RUN 2
  (3006, 8, 1),    -- lost soul      S_SKULL_RUN 6
  (3005, 8, 1),    -- cacodemon      S_HEAD_RUN 3
  (3003, 8, 2),    -- baron of hell  S_BOSS_RUN 3
  (16, 16, 1),     -- cyberdemon     S_CYBER_RUN 3
  (7, 12, 1),      -- spider mastermind S_SPID_RUN 3
  (65, 8, 2), (66, 10, 2), (67, 8, 2), (68, 12, 2), (69, 8, 2), (71, 8, 1), (64, 15, 2), (84, 8, 2)
ON CONFLICT (thing_type) DO UPDATE SET speed = EXCLUDED.speed, calls_per_frame = EXCLUDED.calls_per_frame;

-- heard: P_NoiseAlert reached a monster placed with MTF_AMBUSH ("deaf"): A_Look then wakes it
-- as soon as it sees its target, in any direction (P_CheckSight without the 180-degree cone);
-- until now the noise woke deaf monsters like the others.
ALTER TABLE doom.monster_ai ADD COLUMN IF NOT EXISTS heard boolean NOT NULL DEFAULT false;
