-- Each sprite frame as it is drawn from each direction: for a wanted
-- rotation 1..8 (0 for effects, which have none) the frame's own rotation
-- if it has that one, else its rotation 0: the lookup the frame views made
-- per thing, as one probe of an index. From LBDoom's sql/schema.sql
-- (2026-11-17).
CREATE MATERIALIZED VIEW doom.sprite_rotations AS
SELECT k.sprite, k.frame, r.r::smallint AS wanted_rotation,
       sf.lump_name, sf.flipped, sf.width, sf.height, sf.left_offset, sf.top_offset
FROM (SELECT DISTINCT sprite, frame FROM sprite_frames) k
CROSS JOIN generate_series(0, 8) AS r(r)
CROSS JOIN LATERAL (
  SELECT f.* FROM sprite_frames f
  WHERE f.sprite = k.sprite AND f.frame = k.frame AND f.rotation IN (0, r.r)
  ORDER BY CASE WHEN f.rotation = r.r THEN 0 ELSE 1 END
  LIMIT 1
) sf
WITH DATA;
