CREATE OR REPLACE VIEW doom.doom_player_shadow AS
 SELECT map_id,
    player_thing_id,
    (invis_tics > 0) AS shadowed,
    level_tics
   FROM player_state ps;
