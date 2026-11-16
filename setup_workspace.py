"""Set up SQLDoom on Lakebase in a workspace, step by step, idempotently.

Every step checks what is already there and only does what is missing, so a
failed run can be started again. Run it from a notebook in the workspace (in
the notebook's own Python: a subprocess cannot use the notebook's sign-in),
see setup_notebook.py, or from a laptop signed in with `databricks auth login`.

    from setup_workspace import Setup
    s = Setup(project="sqldoom", app="sqldoom-ltap",
              wad="/Volumes/<catalog>/<schema>/wad/DOOM1.WAD")
    s.run()                 # every step below, in order
    s.run(until="sql")      # only the database part

Steps (Setup.STEPS):
  project     Lakebase project (Postgres 17), default endpoint size 24 CU
  compute     the default branch's primary sized for the map load (8 CU)
  database    schema doom, extension pg_prewarm, work_mem 64 MB
  maps        the 9 shareware maps (upstream wad_loader.py through the
              CedarScript translator, run_on_lakebase.py): tables, data,
              upstream functions
  owner       setup_doom_owner.sql parts 1 and 3: role doom_owner owns the
              schema, schema lobby
  sql         table_settings.sql, then sql_frozen/ applied (doomapp/frozen.py)
              and checked
  app         the Databricks App with its Lakebase resource; its service
              principal is granted doom_owner and Can manage on the project
  template    branch game-template from the default branch, no expiry. After
              the app: Lakebase roles are per branch and a branch copies the
              roles of its parent when it is created, so the app's role must
              exist before the template is made (a template made first has no
              login for the app: "password authentication failed for user
              '<app id>'", found 2026-11-16 in another workspace). An existing
              template without the app's role gets it (role, doom_owner,
              CONNECT and CREATE, as on the default branch).
  config      app.yaml points at this project
  shrink      the default branch's primary back to 1 CU (lobby only)

Not done here: uploading DOOM1.WAD to a volume (it cannot ship with the code),
deploying the app (Setup.deploy(), or the app page: Deploy), giving players
Can use on the app.
"""
import os
import re
import runpy
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE / "sqldoom"
for _p in (str(HERE), str(REPO)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

MAPS = ("E1M1", "E1M2", "E1M3", "E1M4", "E1M5", "E1M6", "E1M7", "E1M8", "E1M9")


def log(msg):
    print(f"[setup] {msg}", flush=True)


class Setup:
    STEPS = ("project", "compute", "database", "maps", "owner", "sql", "app", "template", "config", "shrink")

    def __init__(self, project="sqldoom", app="sqldoom-ltap", wad=None, maps=MAPS,
                 db="databricks_postgres", schema="doom", role="doom_owner", template="game-template",
                 default_cu=24.0, load_cu=8.0, lobby_cu=1.0, pg_version=17, app_yaml=HERE / "app.yaml"):
        from databricks.sdk import WorkspaceClient
        self.w = WorkspaceClient()
        self.project_id = project
        self.project = f"projects/{project}"
        self.app_name, self.wad, self.maps = app, wad, tuple(maps)
        self.db, self.schema, self.role, self.template = db, schema, role, template
        self.default_cu, self.load_cu, self.lobby_cu = float(default_cu), float(load_cu), float(lobby_cu)
        self.pg_version = pg_version
        self.app_yaml = Path(app_yaml)
        self._branch = None
        self._endpoint = None

    # ------------------------------------------------------------ helpers
    @property
    def branch(self):
        """The project's default branch (production on a new project)."""
        if self._branch is None:
            self._branch = self.w.postgres.get_project(name=self.project).status.default_branch
        return self._branch

    @property
    def endpoint(self):
        """The default branch's read-write endpoint."""
        if self._endpoint is None:
            eps = list(self.w.postgres.list_endpoints(parent=self.branch))
            rw = [e for e in eps if "READ_WRITE" in str(e.status.endpoint_type)] or eps
            if not rw:
                raise RuntimeError(f"{self.branch} has no endpoint")
            self._endpoint = rw[0].name
        return self._endpoint

    def connect(self, role=None, endpoint=None):
        import psycopg2
        from doomapp.lakebase import CREDS
        conn = psycopg2.connect(CREDS.dsn(endpoint or self.endpoint, application_name="sqldoom-setup", role=role))
        conn.autocommit = True
        return conn

    def sql(self, statement, args=(), fetch=False, role=None):
        conn = self.connect(role=role)
        try:
            with conn.cursor() as cur:
                cur.execute(statement, args)
                return cur.fetchall() if fetch else None
        finally:
            conn.close()

    def _size(self, endpoint, cu):
        from databricks.sdk.service import postgres as P
        from databricks.sdk.service.postgres import FieldMask
        ep = self.w.postgres.get_endpoint(name=endpoint)
        if (ep.status.autoscaling_limit_min_cu, ep.status.autoscaling_limit_max_cu) == (cu, cu):
            log(f"{endpoint}: already {cu:g} CU")
            return
        self.w.postgres.update_endpoint(name=endpoint, endpoint=P.Endpoint(name=endpoint, spec=P.EndpointSpec(
            endpoint_type=ep.status.endpoint_type, autoscaling_limit_min_cu=cu, autoscaling_limit_max_cu=cu)),
            update_mask=FieldMask(field_mask=["spec.autoscaling_limit_min_cu", "spec.autoscaling_limit_max_cu"])).wait()
        log(f"{endpoint}: sized to {cu:g} CU")

    # ------------------------------------------------------------ steps
    def step_project(self):
        from databricks.sdk.service import postgres as P
        from databricks.sdk.service.postgres import FieldMask
        settings = P.ProjectDefaultEndpointSettings(autoscaling_limit_min_cu=self.default_cu,
                                                    autoscaling_limit_max_cu=self.default_cu)
        try:
            pr = self.w.postgres.get_project(name=self.project)
        except Exception:
            pr = None
        if pr is None:
            log(f"creating Lakebase project {self.project} (Postgres {self.pg_version})")
            self.w.postgres.create_project(project_id=self.project_id, project=P.Project(spec=P.ProjectSpec(
                display_name="SQLDoom", pg_version=self.pg_version, default_endpoint_settings=settings))).wait()
            return
        d = pr.status.default_endpoint_settings
        if d and (d.autoscaling_limit_min_cu, d.autoscaling_limit_max_cu) == (self.default_cu, self.default_cu):
            log(f"{self.project} exists, default endpoint size {self.default_cu:g} CU")
            return
        self.w.postgres.update_project(name=self.project, project=P.Project(name=self.project, spec=P.ProjectSpec(
            default_endpoint_settings=settings)), update_mask=FieldMask(field_mask=["spec.default_endpoint_settings"])).wait()
        log(f"{self.project}: default endpoint size set to {self.default_cu:g} CU")

    def step_compute(self):
        self._size(self.endpoint, self.load_cu)

    def step_database(self):
        self.sql(f"CREATE SCHEMA IF NOT EXISTS {self.schema}")
        self.sql(f"CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA {self.schema}")
        try:
            self.sql(f"ALTER DATABASE {self.db} SET work_mem = '64MB'")
        except Exception as exc:     # needs the database owner; the game runs without it, slower
            log(f"work_mem not set ({str(exc).splitlines()[0]}): ask the database owner to run "
                f"ALTER DATABASE {self.db} SET work_mem = '64MB'")
        log(f"schema {self.schema} and pg_prewarm ready")

    def loaded_maps(self):
        rows = self.sql("SELECT to_regclass(%s) IS NOT NULL", (f"{self.schema}.maps",), fetch=True)
        if not rows[0][0]:
            return set()
        return {r[0] for r in self.sql(f"SELECT name FROM {self.schema}.maps", fetch=True)}

    def step_maps(self):
        missing = [m for m in self.maps if m not in self.loaded_maps()]
        if not missing:
            log(f"maps already loaded: {', '.join(self.maps)}")
            return
        if not self.wad:
            raise RuntimeError("Setup(wad=...) is needed: the path of DOOM1.WAD, e.g. in a Unity Catalog volume")
        if not Path(self.wad).is_file():
            raise RuntimeError(f"{self.wad}: no such file (upload DOOM1.WAD there first)")
        # In this process, as run_on_lakebase.py does from the command line:
        # compat SQL, then upstream's loader with the CedarScript translator.
        import psycopg2
        import run_on_lakebase as rol
        import cedar2plpgsql as c2p
        # The translator's targeted fixes expect one function per statement; the
        # loader sends whole runtime files, where an anchor can match several
        # functions ("expected 1 match, found 3", tested 2026-11-13). The
        # functions it installs are all replaced by sql_frozen/ in step sql,
        # so here an ambiguous fix is skipped instead of stopping the load.
        strict_fixes = c2p.apply_targeted_fixes
        skipped = []

        def lenient_fixes(sql):
            for fn, old, new, _why in c2p.TARGETED_FIXES:
                if re.search(rf"FUNCTION\s+{fn}\s*\(", sql, re.I) and sql.count(old) > 1:
                    skipped.append(fn)
                    sql = sql   # left as translated; replaced by sql_frozen/
            try:
                return strict_fixes(sql)
            except c2p.TranspileError:
                return sql

        env_before = {k: os.environ.get(k) for k in ("LAKEBASE_ENDPOINT", "LAKEBASE_DB", "LAKEBASE_SCHEMA", "DB_DSN")}
        connect_before, argv_before, cwd_before = psycopg2.connect, sys.argv, os.getcwd()
        os.environ.update(LAKEBASE_ENDPOINT=self.endpoint, LAKEBASE_DB=self.db, LAKEBASE_SCHEMA=self.schema)
        t0 = time.time()
        try:
            dsn = rol.lakebase_dsn()
            os.environ["DB_DSN"] = dsn
            # postgres_compat.sql now also adds to upstream's tables (mp_players
            # ...), so on an empty schema it can only run after the loader
            # (tested 2026-11-13 on a new project); on a reload it runs first,
            # as run_on_lakebase.py does.
            compat_first = True
            try:
                rol.apply_compat(dsn)
            except Exception as exc:
                compat_first = False
                log(f"postgres_compat.sql before the load: {str(exc).splitlines()[0]} (empty schema)")
            rol.install_shim(str(REPO))
            c2p.apply_targeted_fixes = lenient_fixes
            os.chdir(REPO)
            if not compat_first:
                # Upstream's tables first, then the compat SQL: the translated
                # runtime calls its doom_caller() (tested 2026-11-13 on a new
                # project: "function doom_caller() does not exist").
                import wad_loader
                conn = psycopg2.connect(dsn)
                try:
                    conn.autocommit = True
                    with conn.cursor() as cur:
                        wad_loader.apply_schema(cur, wad_loader.DEFAULT_SCHEMA)
                finally:
                    conn.close()
                rol.apply_compat(dsn)
                log("upstream schema, then postgres_compat.sql applied")
            loader = str(REPO / "wad_loader.py")
            sys.argv = [loader, self.wad, *self.maps, "--dsn", dsn]
            log(f"loading {', '.join(self.maps)} from {self.wad} (the slow step)")
            try:
                runpy.run_path(loader, run_name="__main__")
            except SystemExit as exc:
                if exc.code not in (0, None):
                    raise RuntimeError(f"wad_loader.py exited with {exc.code}") from exc
            # Again after the load in any case: its derived tables come from the
            # WAD data (colormap_idx_lvl from colormap_rgb: empty when the
            # compat SQL ran first on a new project, tested 2026-11-13) and its
            # table settings cover tables the loader created.
            psycopg2.connect = connect_before
            rol.apply_compat(dsn)
            log("postgres_compat.sql applied again after the load")
        finally:
            psycopg2.connect, sys.argv = connect_before, argv_before   # the translator stays out of the next steps
            c2p.apply_targeted_fixes = strict_fixes
            os.chdir(cwd_before)
            if skipped:
                log(f"translator fixes skipped during the load (functions replaced by sql_frozen/ next): "
                    f"{', '.join(sorted(set(skipped)))}")
            for k, v in env_before.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        log(f"maps loaded in {time.time() - t0:.0f} s: {sorted(self.loaded_maps())}")

    def step_owner(self):
        text = (HERE / "setup_doom_owner.sql").read_text(encoding="utf-8")
        part1 = text.split("-- PART 2")[0]
        part3 = text.split("-- PART 3")[1]
        # Part 1 again on a later run: the role exists, the ownership loop is idempotent.
        part1 = part1.replace("CREATE ROLE doom_owner NOLOGIN;",
                              "DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'doom_owner') THEN "
                              "CREATE ROLE doom_owner NOLOGIN; END IF; END $$;")
        part1 = part1.replace("COMMIT;   -- or ROLLBACK; if any *_left is not 0", "")
        conn = self.connect()
        try:
            conn.autocommit = False
            with conn.cursor() as cur:
                cur.execute(part1.replace("BEGIN;", "", 1))
                left = cur.fetchone()
                if tuple(left) != (0, 0, 0, "doom_owner"):
                    conn.rollback()
                    raise RuntimeError(f"setup_doom_owner.sql part 1 left {left} (want 0, 0, 0, doom_owner): rolled back")
            conn.commit()
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(part3)
        finally:
            conn.close()
        log("role doom_owner owns schema doom and everything in it; schema lobby ready")

    def step_sql(self):
        from doomapp import frozen
        conn = self.connect(role=self.role)
        try:
            with conn.cursor() as cur:
                cur.execute(f"SET search_path = {self.schema}")
                cur.execute((HERE / "table_settings.sql").read_text(encoding="utf-8"))
            log("table settings applied (table_settings.sql)")
            frozen.apply(conn, log=log)
            left = frozen.apply(conn, dry_run=True, log=log)["counts"]
        finally:
            conn.close()
        if left:
            raise RuntimeError(f"after apply, still different from sql_frozen/: {left}")

    def _app_role(self, branch):
        """The Lakebase role of the app's service principal on a branch, or None."""
        sp = self.w.apps.get(name=self.app_name).service_principal_client_id
        for r in self.w.postgres.list_roles(parent=branch):
            if r.status and r.status.postgres_role == sp:
                return sp, r
        return sp, None

    def step_template(self):
        from databricks.sdk.service import postgres as P
        name = f"{self.project}/branches/{self.template}"
        try:
            self.w.postgres.get_branch(name=name)
            exists = True
        except Exception:
            exists = False
        if not exists:
            self.w.postgres.create_branch(parent=self.project, branch_id=self.template, branch=P.Branch(
                spec=P.BranchSpec(source_branch=self.branch, no_expiry=True))).wait()
            log(f"{name} created from {self.branch}, no expiry")
        # The app logs in to the template (refresh) and to every game branch
        # (copies of it): its role must be there.
        try:
            sp, role = self._app_role(name)
        except Exception as exc:
            log(f"app {self.app_name} not found ({str(exc).splitlines()[0]}): run step app, then this step again")
            return
        if role is not None:
            log(f"{name}: {'' if exists else 'new, '}has the app's login ({sp})")
            return
        _, src = self._app_role(self.branch)
        if src is None:
            raise RuntimeError(f"the app's role {sp} is not on {self.branch} either: run step app first")
        log(f"{name} has no login for the app ({sp}, made before the app): adding it")
        self.w.postgres.create_role(parent=name, role_id=src.status.role_id, role=P.Role(spec=P.RoleRoleSpec(
            identity_type=src.status.identity_type, auth_method=src.status.auth_method, postgres_role=sp))).wait()
        ep = list(self.w.postgres.list_endpoints(parent=name))[0].name
        conn = self.connect(endpoint=ep)
        try:
            with conn.cursor() as cur:
                for _ in range(30):
                    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (sp,))
                    if cur.fetchone():
                        break
                    time.sleep(2)
                cur.execute(f'GRANT {self.role} TO "{sp}" WITH INHERIT TRUE, SET TRUE')
                cur.execute(f'GRANT CONNECT, CREATE ON DATABASE {self.db} TO "{sp}"')
        finally:
            conn.close()
        log(f"{name}: app login {sp} added, member of {self.role}, CONNECT and CREATE on {self.db}. "
            "If the app is running, restart it (or deploy) so it retries the template")

    def step_app(self):
        from databricks.sdk.service import apps as A
        from databricks.sdk.service.iam import AccessControlRequest, PermissionLevel
        dbs = list(self.w.postgres.list_databases(parent=self.branch))
        db = next((d.name for d in dbs if (d.status and d.status.postgres_database == self.db)
                   or d.name.endswith("/" + self.db.replace("_", "-"))), None)
        if db is None:
            raise RuntimeError(f"database {self.db} not found on {self.branch}: {[d.name for d in dbs]}")
        resource = A.AppResource(name="database", postgres=A.AppResourcePostgres(
            branch=self.branch, database=db, permission=A.AppResourcePostgresPostgresPermission.CAN_CONNECT_AND_CREATE))
        try:
            app = self.w.apps.get(name=self.app_name)
            log(f"app {self.app_name} exists")
            # An app made elsewhere (the Apps page, an assistant's app tool) may
            # lack the Lakebase resource: add it, keeping its other resources.
            if not any(r.postgres and r.postgres.branch == self.branch for r in (app.resources or [])):
                log(f"adding the Lakebase database of {self.branch} to {self.app_name}'s resources")
                app = self.w.apps.update(name=self.app_name, app=A.App(
                    name=self.app_name, resources=[r for r in (app.resources or []) if r.name != "database"] + [resource]))
        except Exception as exc:
            if "does not exist" not in str(exc).lower() and "not found" not in str(exc).lower():
                raise
            log(f"creating app {self.app_name} (Medium) with the Lakebase database as resource")
            app = self.w.apps.create(app=A.App(
                name=self.app_name, description="SQLDoom on Lakebase", compute_size=A.ComputeSize.MEDIUM,
                resources=[resource])).result()
        sp = app.service_principal_client_id
        # the resource creates the service principal's Postgres role; wait for it
        for _ in range(60):
            if self.sql("SELECT 1 FROM pg_roles WHERE rolname = %s", (sp,), fetch=True):
                break
            time.sleep(5)
        else:
            raise RuntimeError(f"Postgres role {sp} of the app's service principal did not appear")
        self.sql(f'GRANT {self.role} TO "{sp}" WITH INHERIT TRUE, SET TRUE')
        self.w.permissions.update("database-projects", self.project_id, access_control_list=[
            AccessControlRequest(service_principal_name=sp, permission_level=PermissionLevel.CAN_MANAGE)])
        log(f"service principal {sp}: member of {self.role}, Can manage on {self.project}")

    def step_config(self):
        """app.yaml: the lobby endpoint, and the project when it is not projects/sqldoom."""
        text = self.app_yaml.read_text(encoding="utf-8")
        new = re.sub(r'(- name: LAKEBASE_ENDPOINT\n\s+value: )"[^"]*"', rf'\1"{self.endpoint}"', text)
        new = re.sub(r'(- name: LAKEBASE_DB\n\s+value: )"[^"]*"', rf'\1"{self.db}"', new)
        for key, value in (("LAKEBASE_PROJECT", self.project), ("DOOM_TEMPLATE_BRANCH", self.template)):
            if f"- name: {key}\n" in new:
                new = re.sub(rf'(- name: {key}\n\s+value: )"[^"]*"', rf'\1"{value}"', new)
            else:
                new = new.replace("  - name: LAKEBASE_DB\n", f'  - name: {key}\n    value: "{value}"\n  - name: LAKEBASE_DB\n', 1)
        if new == text:
            log(f"{self.app_yaml.name} already points at {self.endpoint}")
            return
        self.app_yaml.write_text(new, encoding="utf-8")
        log(f"{self.app_yaml.name} updated for {self.project} (commit it if the app deploys from Git)")

    def step_shrink(self):
        self._size(self.endpoint, self.lobby_cu)

    # ------------------------------------------------------------ status
    def status(self):
        """What is in place, read only: one line per step, ok / missing. For a
        person or an assistant checking a setup before or after run()."""
        def check(name, fn):
            try:
                ok, detail = fn()
            except Exception as exc:
                ok, detail = False, str(exc).splitlines()[0][:160]
            log(f"{'ok     ' if ok else 'MISSING'} {name}: {detail}")
            return ok

        def project():
            d = self.w.postgres.get_project(name=self.project).status.default_endpoint_settings
            return True, f"{self.project}, default endpoint {d.autoscaling_limit_max_cu:g} CU"

        def maps():
            got = self.loaded_maps()
            return set(self.maps) <= got, f"{len(got)} maps loaded"

        def owner():
            r = self.sql("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = %s", (self.schema,), fetch=True)
            lobby = self.sql("SELECT 1 FROM pg_namespace WHERE nspname = 'lobby'", fetch=True)
            return bool(r and r[0][0] == self.role and lobby), f"schema owner {r[0][0] if r else None}, lobby {'yes' if lobby else 'no'}"

        def sql():
            # Games are copied from the template, so that is the branch that
            # counts (the default branch only gets the SQL before the template
            # exists; afterwards the app refreshes the template itself).
            from doomapp import frozen
            try:
                eps = list(self.w.postgres.list_endpoints(parent=f"{self.project}/branches/{self.template}"))
                ep, where = eps[0].name, self.template
            except Exception:
                ep, where = self.endpoint, self.branch.rsplit("/", 1)[-1]
            conn = self.connect(role=self.role, endpoint=ep)
            try:
                left = frozen.apply(conn, dry_run=True, log=lambda m: None)["counts"]
            finally:
                conn.close()
            return not left, f"{where} differs from sql_frozen/: {left or 'nothing'}"

        def template():
            name = f"{self.project}/branches/{self.template}"
            self.w.postgres.get_branch(name=name)
            try:
                sp, role = self._app_role(name)
            except Exception:
                return True, f"{self.template} exists (no app yet to check its login)"
            return role is not None, f"{self.template} exists, app login {sp}: {'yes' if role else 'NO (run step template)'}"

        def app():
            a = self.w.apps.get(name=self.app_name)
            res = any(r.postgres and r.postgres.branch == self.branch for r in (a.resources or []))
            sp = a.service_principal_client_id
            member = self.sql("SELECT pg_has_role(%s, %s, 'MEMBER')", (sp, self.role), fetch=True)[0][0] if res else False
            acl = self.w.permissions.get("database-projects", self.project_id).access_control_list
            manage = any(x.service_principal_name == sp and any(p.permission_level.value == "CAN_MANAGE" for p in x.all_permissions)
                         for x in acl)
            state = a.compute_status.state.value if a.compute_status and a.compute_status.state else "?"
            return res and member and manage, (f"{self.app_name} ({state}): Lakebase resource {'yes' if res else 'no'}, "
                                              f"{self.role} {'yes' if member else 'no'}, Can manage {'yes' if manage else 'no'}, {a.url}")

        results = [check(n, f) for n, f in (("project", project), ("maps", maps), ("owner", owner), ("sql", sql),
                                            ("app", app), ("template", template))]
        return all(results)

    # ------------------------------------------------------------ run
    def run(self, steps=None, until=None, start=None):
        names = list(steps or self.STEPS)
        if start:
            names = names[names.index(start):]
        if until:
            names = names[:names.index(until) + 1]
        t0 = time.time()
        for name in names:
            t1 = time.time()
            log(f"--- {name}")
            getattr(self, f"step_{name}")()
            log(f"{name}: done in {time.time() - t1:.0f} s")
        log(f"all done in {time.time() - t0:.0f} s: {', '.join(names)}")

    def deploy(self, source_code_path=None):
        """Deploy the app from a workspace folder (default: this folder). A
        deployment only works on a running app: started first if stopped."""
        from databricks.sdk.service import apps as A
        path = source_code_path or str(HERE)
        if not path.startswith("/Workspace"):
            raise RuntimeError(f"{path}: deploy needs the folder's workspace path (/Workspace/...)")
        app = self.w.apps.get(name=self.app_name)
        state = str(app.compute_status.state) if app.compute_status else ""
        if "STOPPED" in state:
            log(f"starting {self.app_name}")
            self.w.apps.start(name=self.app_name).result()
        elif "STARTING" in state or "STOPPING" in state:
            raise RuntimeError(f"{self.app_name} is {state}: run deploy() again in a minute")
        log(f"deploying {path}")
        d = self.w.apps.deploy(app_name=self.app_name, app_deployment=A.AppDeployment(source_code_path=path)).result()
        log(f"deployment {d.deployment_id}: {d.status.state} {d.status.message}")
        return d
