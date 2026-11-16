-- Shared owner role for the doom schema (SQLDoom Databricks App, sqldoom-ltap).
-- Run in the Lakebase SQL editor on projects/sqldoom, branch production,
-- database databricks_postgres, as the user who loaded the maps.
--
-- PART 1 -- now. One transaction: creates doom_owner, makes it the owner of
-- the doom schema and everything in it, and keeps you a member (full access).
-- The final SELECT must show 0 | 0 | 0 | doom_owner; if not, ROLLBACK instead.

BEGIN;

CREATE ROLE doom_owner NOLOGIN;
GRANT doom_owner TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;
ALTER SCHEMA doom OWNER TO doom_owner;

DO $$
DECLARE r record;
BEGIN
  -- tables, views, materialized views, standalone sequences
  -- (sequences owned by a column follow their table). Objects of extensions
  -- created in doom (btree_gist, pg_prewarm, pg_stat_statements) keep their
  -- owner: only the extension's owner can change them.
  FOR r IN SELECT c.oid::regclass AS obj, c.relkind
           FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'doom' AND c.relkind IN ('r','p','v','m','S','f')
             AND NOT (c.relkind = 'S' AND EXISTS (
                 SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype IN ('a','i')))
             AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = c.oid AND e.deptype = 'e')
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO doom_owner',
      CASE r.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
                     WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END,
      r.obj);
  END LOOP;
  -- functions, procedures, aggregates (postgres_compat.sql aggregates included)
  FOR r IN SELECT p.oid::regprocedure AS obj, p.prokind
           FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'doom'
             AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = p.oid AND e.deptype = 'e')
  LOOP
    EXECUTE format('ALTER %s %s OWNER TO doom_owner',
      CASE r.prokind WHEN 'a' THEN 'AGGREGATE' WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
      r.obj);
  END LOOP;
  -- enums, domains, standalone composite types (array types follow)
  FOR r IN SELECT t.oid::regtype AS obj
           FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
           WHERE n.nspname = 'doom' AND t.typelem = 0 AND t.typtype IN ('e','d','c','r','m')
             AND (t.typrelid = 0 OR (SELECT relkind FROM pg_class WHERE oid = t.typrelid) = 'c')
             AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = t.oid AND e.deptype = 'e')
  LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO doom_owner', r.obj);
  END LOOP;
END $$;

-- Check: relations, functions, types not owned by doom_owner (all 0, extension
-- objects aside), schema owner.
SELECT
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'doom' AND pg_get_userbyid(c.relowner) <> 'doom_owner'
      AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = c.oid AND e.deptype = 'e')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d JOIN pg_depend e ON e.objid = d.refobjid AND e.deptype = 'e'
                      WHERE d.objid = c.oid AND d.deptype IN ('a', 'i'))) AS relations_left,
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'doom' AND pg_get_userbyid(p.proowner) <> 'doom_owner'
      AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = p.oid AND e.deptype = 'e')) AS functions_left,
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'doom' AND pg_get_userbyid(t.typowner) <> 'doom_owner'
      AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = t.oid AND e.deptype = 'e')
      AND NOT EXISTS (SELECT 1 FROM pg_type a JOIN pg_depend e ON e.objid = a.oid AND e.deptype = 'e'
                      WHERE a.typarray = t.oid)) AS types_left,
  (SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'doom') AS schema_owner;

COMMIT;   -- or ROLLBACK; if any *_left is not 0


-- PART 2 -- after the app exists and Lakebase is added as its resource.
-- Adding the resource creates the app service principal's Postgres role; its
-- name is the SP's client (application) ID, shown on the app's Authorization tab.
-- Replace <app-sp-client-id> with that UUID, keeping the double quotes.

-- GRANT doom_owner TO "<app-sp-client-id>" WITH INHERIT TRUE, SET TRUE;


-- PART 3 -- branch per game (doomapp/games.py). The lobby (one row per game)
-- lives on production in its own schema; the app creates its tables, but
-- doom_owner has no CREATE on the database, so the schema comes from here.

CREATE SCHEMA IF NOT EXISTS lobby AUTHORIZATION doom_owner;
