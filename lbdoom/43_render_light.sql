
CREATE OR REPLACE FUNCTION doom_light_index(
  p_sector_light double precision, p_extra integer, p_attenuation integer)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT GREATEST(0, LEAST(31,
  (15 - LEAST(15, GREATEST(0, FLOOR(p_sector_light / 16.0)::int + p_extra))) * 4
  - p_attenuation))
$$;

-- scalelight, for walls and sprites: attenuation by 1/depth.
CREATE OR REPLACE FUNCTION doom_light_scale(p_depth double precision)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
SELECT FLOOR(LEAST(47.0, GREATEST(0.0, 2560.0 / NULLIF(p_depth, 0.0))) / 2.0)::int
$$;

-- zlight, for planes, which vanilla indexes by a distance step instead.
CREATE OR REPLACE FUNCTION doom_light_zdepth(p_depth double precision)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
-- 80.0 as float8: a numeric literal would make this per-pixel division decimal.
SELECT FLOOR(80.0::float8 / (LEAST(127, FLOOR(p_depth / 16.0)::int) + 1))::int
$$;

-- A plane pixel's light for every pair of what is constant along its span
-- and its distance step d = LEAST(127, FLOOR(depth / 16)): byte r * 128 + d.
-- Rows 0..15 are a sector's light step k, light 15 - clamp(floor(l/16) + e)
-- (doom_light_index's per-span part), each giving
-- GREATEST(0, LEAST(31, k * 4 - doom_light_zdepth(depth))); row 16 is the
-- sky's (unlit, 0), row 17 invulnerability's (32). Immutable and without
-- arguments, so the planner evaluates it once, into a constant of the plan:
-- a byte per pixel instead of the zlight arithmetic.
CREATE OR REPLACE FUNCTION doom_zlight_lut()
RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
SELECT string_agg(set_byte('\x00'::bytea, 0,
         CASE WHEN r.k = 16 THEN 0
              WHEN r.k = 17 THEN 32
              -- d * 16.0 is a depth whose step is d exactly
              ELSE GREATEST(0, LEAST(31, r.k * 4 - doom_light_zdepth(d.d * 16.0)))
         END), ''::bytea ORDER BY r.k, d.d)
FROM generate_series(0, 17) r(k) CROSS JOIN generate_series(0, 127) d(d)
$$;
