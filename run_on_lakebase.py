#!/usr/bin/env python3
"""Run an unmodified SQLDoom script against Lakebase.

    python3 run_on_lakebase.py <repo_dir> <script.py> [args...]

Any argument equal to {DSN} is replaced by a libpq DSN for the Lakebase endpoint
(fresh OAuth token, sslmode=require, search_path=doom). psycopg2.connect is wrapped
so every cursor transpiles `LANGUAGE cedarscript` DDL to PL/pgSQL on the fly and
drops CedarDB-only SET statements.

Env: LAKEBASE_ENDPOINT (default projects/sqldoom/branches/production/endpoints/primary)
     LAKEBASE_DB (databricks_postgres), LAKEBASE_SCHEMA (doom)
     LAKEBASE_TIC_WARMUP (1) -- set 0 to skip the per-connection plan warm-up
"""
import os
import runpy
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import psycopg2  # noqa: E402
import psycopg2.extensions  # noqa: E402

import cedar2plpgsql as c2p  # noqa: E402


def lakebase_dsn():
    if os.getenv("LAKEBASE_DSN"):
        return os.environ["LAKEBASE_DSN"]
    from databricks.sdk import WorkspaceClient
    w = WorkspaceClient()
    ep = os.getenv("LAKEBASE_ENDPOINT", "projects/sqldoom/branches/production/endpoints/primary")
    host = w.postgres.get_endpoint(name=ep).status.hosts.host
    token = w.postgres.generate_database_credential(endpoint=ep).token
    user = w.current_user.me().user_name
    schema = os.getenv("LAKEBASE_SCHEMA", "doom")
    db = os.getenv("LAKEBASE_DB", "databricks_postgres")
    return psycopg2.extensions.make_dsn(
        host=host, port=5432, dbname=db, user=user, password=token,
        sslmode="require",
        # synchronous_commit=off: tics commit without waiting for the WAL to be
        # durable on the safekeepers (~4 ms/tic). A crash can lose at most the
        # last few hundred ms of game state; data is never corrupted.
        options=f"-c search_path={schema} -c synchronous_commit=off")


def install_shim(repo):
    t = c2p.Transpiler()
    for p in Path(repo).rglob("*"):
        if p.suffix in (".sql", ".py") and p.is_file():
            t.learn(p.read_text(encoding="utf-8", errors="replace"))

    class ShimConnection(psycopg2.extensions.connection):
        def cursor(self, *a, **k):
            return c2p.ShimCursor(super().cursor(*a, **k), t)

    real_connect = psycopg2.connect

    def connect(*a, **k):
        k.setdefault("connection_factory", ShimConnection)
        return real_connect(*a, **k)

    psycopg2.connect = connect
    return t


def apply_compat(dsn):
    """Install postgres_compat.sql (CedarDB built-ins missing in Postgres)."""
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute((HERE / "postgres_compat.sql").read_text(encoding="utf-8"))
    conn.close()


WARMUP_COMMANDS = (
    # (skill, fwd, strafe, run, turn, attack, weapon_switch, use)
    [(2, 1.0, 0.0, True, 3.0, True, 0, False)] * 40      # run + turn + fire
    + [(2, 0.0, 1.0, False, -3.0, True, 0, False)] * 10  # strafe + fire
    + [(2, 0.0, 0.0, False, 0.0, False, 2, False),       # weapon switches
       (2, 0.0, 0.0, False, 0.0, False, 3, False),
       (2, 1.0, 0.0, False, 0.0, False, 0, True)]        # use
    + [(2, 0.0, 0.0, False, 0.0, False, 0, False)] * 17  # idle
)


def install_tic_warmup():
    """Warm the per-connection plan cache before the first real tic.

    Postgres has no shared plan cache: each connection plans every tic
    statement on first use (~60 tics at 30-60 ms on a cold connection). Before
    a connection's first real tic, run WARMUP_COMMANDS inside a transaction and
    roll it back. Game state is untouched; the cached plans (and the PREPAREd
    statements, which are not transactional) survive the rollback.
    Disable with LAKEBASE_TIC_WARMUP=0.
    """
    if os.getenv("LAKEBASE_TIC_WARMUP", "1") == "0":
        return
    import doom_sql
    if getattr(doom_sql.execute_game_tic, "_lakebase_warmup", False):
        return  # already installed in this process
    real_tic, warmed = doom_sql.execute_game_tic, set()

    def execute_game_tic(cur, map_id, player_id, command):
        conn = cur.connection
        if id(conn) not in warmed and conn.autocommit:
            warmed.add(id(conn))
            t0 = time.perf_counter()
            cur.execute("BEGIN")
            try:
                for c in WARMUP_COMMANDS:
                    real_tic(cur, map_id, player_id, c)
                    doom_sql.finish_game_tic(cur, map_id, player_id)
            finally:
                cur.execute("ROLLBACK")
            print(f"[lakebase] tic plan cache warmed: {len(WARMUP_COMMANDS)} tics "
                  f"in {time.perf_counter() - t0:.2f}s (rolled back)", file=sys.stderr)
        return real_tic(cur, map_id, player_id, command)

    execute_game_tic._lakebase_warmup = True
    doom_sql.execute_game_tic = execute_game_tic


def main():
    repo, script, *args = sys.argv[1:]
    repo = str(Path(repo).resolve())
    dsn = lakebase_dsn()
    os.environ["DB_DSN"] = dsn
    apply_compat(dsn)
    install_shim(repo)
    sys.path.insert(0, repo)
    install_tic_warmup()
    script_path = str(Path(repo, script))
    sys.path.insert(0, str(Path(script_path).parent))
    os.chdir(repo)
    sys.argv = [script_path] + [dsn if a == "{DSN}" else a for a in args]
    runpy.run_path(script_path, run_name="__main__")


if __name__ == "__main__":
    main()
