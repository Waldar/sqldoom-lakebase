CREATE OR REPLACE VIEW doom.api_things_spawn AS
 SELECT id,
    map_id,
    spawn_x,
    spawn_y,
    spawn_angle,
    type,
    flags
   FROM things;
