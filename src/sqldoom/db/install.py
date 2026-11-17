"""Installs and upgrades the game's database code from sql/.

sql/
  migrations/NNNN_*.sql  changes to tables and types, each applied once, in order
  functions/**/*.sql     functions and aggregates, one per file
  frame_views/*.sql      the frame-view templates and doom.create_frame_views()
  matviews/*.sql         materialized views
  views/*.sql            views
  indexes.sql            indexes on tables and materialized views

install(conn) does, in one transaction:
  1. the migrations not applied yet (doom.schema_migrations records them);
  2. when the code version (a hash of every other file under sql/) is not the
     one in doom.schema_version: drops the materialized views, creates every
     function, view and materialized view, then the frame views
     (doom.create_frame_views()) and the indexes, and records the version.

The code objects are applied in passes, so no file lists their order: one that
needs an object not created yet (a view that reads another view) waits for
the next pass. Run it as the owner of the schema (doom_owner).
"""
import hashlib
import time
from pathlib import Path

SQL_ROOT = Path(__file__).resolve().parents[3] / "sql"
SCHEMA = "doom"

# Postgres errors that mean "an object this one needs is not there yet"
_MISSING = {"42P01",   # undefined_table
            "42883",   # undefined_function
            "42704",   # undefined_object (a type)
            "42703"}   # undefined_column (a view on a view not replaced yet)
# Errors CREATE OR REPLACE gives when the new definition cannot replace the
# old one in place (other result type, other view columns): drop and create.
_INCOMPATIBLE = {"42P13", "42P16", "42809"}

_BOOTSTRAP = f"""
CREATE TABLE IF NOT EXISTS {SCHEMA}.schema_migrations (
  id         text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS {SCHEMA}.schema_version (
  id           integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  code_version text NOT NULL,
  installed_at timestamptz NOT NULL DEFAULT now());
"""


def log(msg):
    print(f"[db] {msg}", flush=True)


class Obj:
    """One file of code: a function, a view or a materialized view."""

    def __init__(self, path, kind):
        self.path, self.kind = path, kind
        self.name = path.stem
        self.sql = path.read_text(encoding="utf-8")

    def __repr__(self):
        return f"{self.kind} {self.path.relative_to(SQL_ROOT)}"


def _code_files(root):
    return sorted(p for p in root.rglob("*.sql") if "migrations" not in p.relative_to(root).parts)


def code_version(root=SQL_ROOT):
    """Hash of the code files (paths and contents): any edit changes it."""
    root = Path(root)
    h = hashlib.sha256()
    for p in _code_files(root):
        h.update(str(p.relative_to(root)).encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()[:16]


def _migrations(root):
    d = Path(root) / "migrations"
    return sorted(d.glob("*.sql")) if d.is_dir() else []


def _objects(root):
    root = Path(root)
    funcs = [Obj(p, "function") for p in sorted((root / "functions").rglob("*.sql"))]
    funcs += [Obj(p, "function") for p in sorted((root / "frame_views").glob("*.sql"))]
    mats = [Obj(p, "matview") for p in sorted((root / "matviews").glob("*.sql"))]
    views = [Obj(p, "view") for p in sorted((root / "views").glob("*.sql"))]
    return funcs, mats, views


def _applied(cur):
    cur.execute(f"SELECT id FROM {SCHEMA}.schema_migrations")
    return {r[0] for r in cur.fetchall()}


def _installed_version(cur):
    cur.execute(f"SELECT code_version FROM {SCHEMA}.schema_version")
    row = cur.fetchone()
    return row[0] if row else None


def status(conn, root=SQL_ROOT):
    """{'pending_migrations': [...], 'installed': v or None, 'code': v, 'up_to_date': bool}
    without writing anything (a branch never installed has no version tables)."""
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass(%s) IS NOT NULL, to_regclass(%s) IS NOT NULL",
                    (f"{SCHEMA}.schema_migrations", f"{SCHEMA}.schema_version"))
        has_mig, has_ver = cur.fetchone()
        applied = _applied(cur) if has_mig else set()
        installed = _installed_version(cur) if has_ver else None
    pending = [p.stem for p in _migrations(root) if p.stem not in applied]
    code = code_version(root)
    return {"pending_migrations": pending, "installed": installed, "code": code,
            "up_to_date": not pending and installed == code}


def _proc_of(cur, name):
    cur.execute("SELECT p.oid::regprocedure::text FROM pg_proc p WHERE p.pronamespace = %s::regnamespace "
                "AND p.proname = %s", (SCHEMA, name))
    return [r[0] for r in cur.fetchall()]


def _try(cur, o):
    """Apply one object in a savepoint: 'ok', 'missing' (retry in the next
    pass, with the error), or raise."""
    cur.execute("SAVEPOINT obj")
    try:
        cur.execute(o.sql)
        cur.execute("RELEASE SAVEPOINT obj")
        return "ok", None
    except Exception as exc:
        cur.execute("ROLLBACK TO SAVEPOINT obj")
        code = getattr(exc, "pgcode", None)
        if code in _MISSING:
            return "missing", exc
        if code not in _INCOMPATIBLE or o.kind == "matview":
            raise RuntimeError(f"{o}: {exc}") from exc
    # cannot be replaced in place: drop it (and what depends on it), create it
    if o.kind == "function":
        procs = _proc_of(cur, o.name)
        if len(procs) != 1:
            raise RuntimeError(f"{o}: cannot replace in place and {len(procs)} functions are named {o.name}")
        cur.execute(f"DROP FUNCTION {procs[0]} CASCADE")
    else:
        cur.execute(f"DROP VIEW {SCHEMA}.{o.name} CASCADE")
    cur.execute(o.sql)
    return "dropped", None


def _apply_code(cur, root):
    funcs, mats, views = _objects(root)
    for m in mats:   # their views go with them; every view is created again below
        cur.execute(f"DROP MATERIALIZED VIEW IF EXISTS {SCHEMA}.{m.name} CASCADE")
    pending, done = funcs + mats + views, []
    passes = 0
    while pending:
        passes += 1
        waiting, errors = [], []
        for o in pending:
            result, exc = _try(cur, o)
            if result == "missing":
                waiting.append(o)
                errors.append(f"{o}: {str(exc).splitlines()[0]}")
            elif result == "dropped":
                # a CASCADE may have taken views created earlier: do them again
                waiting += [d for d in done if d.kind != "function"]
                done = [d for d in done if d.kind == "function"] + [o]
            else:
                done.append(o)
        if len(waiting) == len(pending):
            raise RuntimeError("objects that need something no file creates:\n  " + "\n  ".join(errors))
        pending = waiting
    cur.execute(f"SELECT {SCHEMA}.create_frame_views()")
    frames = cur.fetchone()[0]
    idx = Path(root) / "indexes.sql"
    if idx.is_file():
        cur.execute(idx.read_text(encoding="utf-8"))
    return len(funcs), len(mats) + len(views), frames, passes


def install(conn, root=SQL_ROOT, force=False):
    """Bring conn's branch up to date with root/. Returns status() after."""
    root = Path(root)
    t0 = time.time()
    old_autocommit = conn.autocommit
    conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute("SET LOCAL check_function_bodies = off")
            cur.execute(f"SET LOCAL search_path = {SCHEMA}, public")
            cur.execute(_BOOTSTRAP)
            applied = _applied(cur)
            for m in _migrations(root):
                if m.stem in applied:
                    continue
                log(f"migration {m.stem}")
                cur.execute(m.read_text(encoding="utf-8"))
                cur.execute(f"INSERT INTO {SCHEMA}.schema_migrations (id) VALUES (%s)", (m.stem,))
            code = code_version(root)
            if force or _installed_version(cur) != code:
                n_fn, n_views, n_frames, passes = _apply_code(cur, root)
                cur.execute(f"INSERT INTO {SCHEMA}.schema_version (id, code_version) VALUES (1, %s) "
                            "ON CONFLICT (id) DO UPDATE SET code_version = EXCLUDED.code_version, "
                            "installed_at = now()", (code,))
                log(f"code {code}: {n_fn} functions, {n_views} views and materialized views, "
                    f"{n_frames} frame views ({passes} passes)")
            else:
                log(f"code {code} already installed")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.autocommit = old_autocommit
    log(f"done in {time.time() - t0:.1f} s")
    return status(conn, root)
