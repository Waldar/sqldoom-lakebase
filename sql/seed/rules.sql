-- The default rules of each mode. Player 1 changes them from the page
-- (POST /api/match/rules); monsters and skill need a level restart.
INSERT INTO doom.mp_rules (mode, monsters, skill, monster_respawn, monster_respawn_s, item_respawn, item_respawn_s,
                           weapons_stay, death_restart)
VALUES ('solo',       true,  2, false, 12, false, 30, false, true),
       ('deathmatch', false, 2, false, 12, true,  30, true,  false)
ON CONFLICT (mode) DO NOTHING;
