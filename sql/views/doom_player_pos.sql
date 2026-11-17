CREATE OR REPLACE VIEW doom.doom_player_pos AS
 SELECT map_id,
    id AS player_thing_id,
    (x)::double precision AS px,
    (y)::double precision AS py
   FROM things t;
