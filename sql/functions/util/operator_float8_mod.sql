-- double precision % double precision (float8_mod: sign of the dividend, like
-- integer %). Postgres has no CREATE OR REPLACE OPERATOR: created once.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_operator
                 WHERE oprname = '%' AND oprnamespace = 'doom'::regnamespace
                   AND oprleft = 'double precision'::regtype AND oprright = 'double precision'::regtype) THEN
    CREATE OPERATOR doom.% (LEFTARG = double precision, RIGHTARG = double precision,
                            FUNCTION = doom.float8_mod);
  END IF;
END
$$;
