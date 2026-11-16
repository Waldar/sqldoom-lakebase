CREATE OR REPLACE FUNCTION doom.api_camera(p_alpha double precision)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  playing boolean;
  _r1 record;
BEGIN

playing := false;
FOR _r1 IN SELECT (m.state = 'playing') AS x FROM mp_match m
LOOP playing := _r1.x; END LOOP;
IF _cs.playing THEN
UPDATE mp_players mp SET pose_x = c.x, pose_y = c.y, pose_z = c.z, pose_angle = c.angle, last_seen = GREATEST(COALESCE(mp.last_seen, now()), now())
FROM (
-- The camera between two tics. p_alpha is how far the client's clock has run into
-- the tic that has not happened yet: 0 draws the pose one tic ago, 1 the
-- current one.
SELECT ps.previous_x + (ps.position_x - ps.previous_x) * k.a AS x,
       ps.previous_y + (ps.position_y - ps.previous_y) * k.a AS y,
       ps.previous_view_z + (ps.view_z - ps.previous_view_z) * k.a AS z,
       w.a0 + t.turn * k.a - 360.0 * FLOOR((w.a0 + t.turn * k.a) / 360.0) AS angle
FROM player_state ps
JOIN mp_players me ON me.map_id = ps.map_id AND me.player_thing_id = ps.player_thing_id AND me.role_name = doom_caller()
CROSS JOIN LATERAL (SELECT LEAST(1.0, GREATEST(0.0, api_camera.p_alpha::float8)) AS a) k
CROSS JOIN LATERAL (
  SELECT ps.previous_view_angle::float8 AS a0,
         ps.view_angle::float8 - ps.previous_view_angle::float8 + 180.0 AS d
) w
CROSS JOIN LATERAL (SELECT (w.d - 360.0 * FLOOR(w.d / 360.0)) - 180.0 AS turn) t
) c
WHERE mp.role_name = doom_caller();
END IF;
RETURN 1;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_camera(double precision) FROM PUBLIC;
