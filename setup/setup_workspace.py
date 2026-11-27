"""Set up SQLDoom on Lakebase in a workspace, step by step, idempotently.

Every step checks what is already there and only does what is missing, so a
failed run can be started again. Run it from a notebook in the workspace (in
the notebook's own Python: a subprocess cannot use the notebook's sign-in),
see setup_notebook.ipynb, or from a laptop signed in with `databricks auth login`.

    import sys; sys.path[:0] = ["<repo>/setup"]
    from setup_workspace import Setup
    s = Setup(project="sqldoom", app="sqldoom-ltap",
              wad="/Volumes/<catalog>/<schema>/wad/DOOM1.WAD")
              # soundfont="/Volumes/.../x.sf2": another soundfont for the music;
              # default: TimGM6mb.sf2 next to the WAD, else the repository's own
    s.run()                 # every step below, in order
    s.run(until="sql")      # only the database part

Steps (Setup.STEPS):
  project     Lakebase project (Postgres 19), default endpoint size 16 CU
  compute     the default branch's primary sized for the map load (8 CU)
  database    schema doom, extensions btree_gist and pg_prewarm, work_mem 64 MB
  owner       doom_owner.sql parts 1 and 3: role doom_owner owns the schema,
              schema lobby
  maps        as doom_owner: the tables, types and the game's SQL from sql/
              (sqldoom.db), then the game's definitions and the 9 shareware
              maps from DOOM1.WAD (sqldoom.wad), the frame views last; the
              music is rendered as it loads when the soundfont is there
  music       the tracks the maps use that have no audio yet, rendered with
              the General MIDI soundfont (sqldoom.wad.midi), on the default
              branch and on game-template if it exists. The soundfont ships
              with the repository (assets/soundfont/TimGM6mb.sf2, GPL-2);
              Setup(soundfont=...) or a TimGM6mb.sf2 next to DOOM1.WAD
              overrides it. Without fluidsynth, the step pip installs
              tinysoundfont (--no-deps), soundfile and numpy itself
              (setup_notebook.ipynb already does). If rendering still cannot
              run: says why and goes on, the game plays without music.
  sql         the game's SQL up to date (sqldoom.db.install; a no-op right
              after maps)
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

Not done here: uploading DOOM1.WAD to a volume (it cannot ship with the code;
the music's soundfont does, in assets/soundfont/), deploying the app (Setup.deploy(), or the app page: Deploy), giving players
Can use on the app.
"""
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent         # setup/
REPO = HERE.parent                             # the repository: the app's source
if str(REPO / "src") not in sys.path:
    sys.path.insert(0, str(REPO / "src"))

MAPS = ("E1M1", "E1M2", "E1M3", "E1M4", "E1M5", "E1M6", "E1M7", "E1M8", "E1M9")


def log(msg):
    print(f"[setup] {msg}", flush=True)


class Setup:
    STEPS = ("project", "compute", "database", "owner", "maps", "music", "sql", "app", "template", "config", "shrink")

    def __init__(self, project="sqldoom", app="sqldoom-ltap", wad=None, maps=MAPS, soundfont=None,
                 db="databricks_postgres", schema="doom", role="doom_owner", template="game-template",
                 default_cu=16.0, load_cu=8.0, lobby_cu=1.0, pg_version=19, app_yaml=REPO / "app.yaml"):
        from databricks.sdk import WorkspaceClient
        self.w = WorkspaceClient()
        self.project_id = project
        self.project = f"projects/{project}"
        self.app_name, self.wad, self.maps = app, wad, tuple(maps)
        # the music's General MIDI soundfont: given, or TimGM6mb.sf2 next to the WAD;
        # neither: sqldoom.wad.midi uses the repository's own (assets/soundfont/)
        if not soundfont and wad and (Path(wad).parent / "TimGM6mb.sf2").is_file():
            soundfont = str(Path(wad).parent / "TimGM6mb.sf2")
        self.soundfont = soundfont
        if soundfont:
            import os
            os.environ["DOOM_SOUNDFONT"] = soundfont   # sqldoom.wad.midi reads it
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
        from sqldoom.lakebase.connection import CREDS
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
        # btree_gist: the (map_id, box) GiST index on linedef_geom (sql/indexes.sql);
        # pg_prewarm: a new game's branch loads its tables into the cache
        self.sql(f"CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA {self.schema}")
        self.sql(f"CREATE EXTENSION IF NOT EXISTS pg_prewarm SCHEMA {self.schema}")
        try:
            self.sql(f"ALTER DATABASE {self.db} SET work_mem = '64MB'")
        except Exception as exc:     # needs the database owner; the game runs without it, slower
            log(f"work_mem not set ({str(exc).splitlines()[0]}): ask the database owner to run "
                f"ALTER DATABASE {self.db} SET work_mem = '64MB'")
        log(f"schema {self.schema}, btree_gist and pg_prewarm ready")

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
        have = self.loaded_maps()
        if have:
            # The loader fills an empty world (one WAD record, the definitions once).
            raise RuntimeError(f"{self.schema} holds some maps already ({', '.join(sorted(have))}), not "
                               f"{', '.join(missing)}: start again from an empty schema {self.schema}")
        from sqldoom import db, wad
        t0 = time.time()
        conn = self.connect(role=self.role)
        try:
            db.install(conn)
            log(f"loading {', '.join(self.maps)} from {self.wad}")
            wad.load(conn, self.wad, self.maps)
        finally:
            conn.close()
        log(f"maps loaded in {time.time() - t0:.0f} s: {sorted(self.loaded_maps())}")

    def _music_endpoints(self):
        """The default branch's endpoint, and game-template's if it exists."""
        out = [(self.endpoint, self.branch.rsplit("/", 1)[-1])]
        try:
            eps = list(self.w.postgres.list_endpoints(parent=f"{self.project}/branches/{self.template}"))
            if eps:
                out.append((eps[0].name, self.template))
        except Exception:
            pass
        return out

    def step_music(self):
        from sqldoom.wad import midi
        midi.ensure_packages(log)
        why = midi.unavailable_reason()
        if why:
            log(f"music not rendered: {why}. The game plays without music; fix that and run "
                f"s.run(['music']) (the soundfont is the repository's assets/soundfont/TimGM6mb.sf2 "
                f"unless Setup(soundfont=...) names another)")
            return
        log(f"music: soundfont {midi.soundfont()}")
        for endpoint, where in self._music_endpoints():
            conn = self.connect(role=self.role, endpoint=endpoint)
            conn.autocommit = False
            try:
                with conn.cursor() as cur:
                    cur.execute(f"SET search_path = {self.schema}, public")
                    _, failed = midi.render_missing(cur, log=lambda m, w=where: log(f"{w}: {m}"))
                conn.commit()
            finally:
                conn.close()
            if failed:
                log(f"{where}: {len(failed)} tracks could not be rendered ({', '.join(failed)}): run step music again")

    def step_owner(self):
        text = (HERE / "doom_owner.sql").read_text(encoding="utf-8")
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
                    raise RuntimeError(f"doom_owner.sql part 1 left {left} (want 0, 0, 0, doom_owner): rolled back")
            conn.commit()
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(part3)
        finally:
            conn.close()
        log("role doom_owner owns schema doom and everything in it; schema lobby ready")

    def step_sql(self):
        from sqldoom import db
        conn = self.connect(role=self.role)
        try:
            st = db.install(conn)
        finally:
            conn.close()
        if not st["up_to_date"]:
            raise RuntimeError(f"after install, the game's SQL is still not up to date: {st}")

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
                resources = [r for r in (app.resources or []) if r.name != "database"] + [resource]
                # Only the resources change (update_mask): the older update
                # call rejects a request carrying the compute size, and one
                # without it may reset fields (2026-11-20, the move to Postgres 19).
                if hasattr(self.w.apps, "create_update"):
                    self.w.apps.create_update(self.app_name, "resources", app=A.App(
                        name=self.app_name, resources=resources)).result()
                else:
                    self.w.apps.update(name=self.app_name, app=A.App(name=self.app_name, resources=resources))
                app = self.w.apps.get(name=self.app_name)
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
        self.set_thumbnail()

    def set_thumbnail(self, path=REPO / "assets" / "app_thumbnail.png"):
        """The app's picture on the Apps page, from the repository
        (assets/app_thumbnail.png): PATCH /api/2.0/apps/<name>/thumbnail, run by
        the app step and by deploy(). A deploy from the app page or from Git
        does not run it: then s.set_thumbnail() once."""
        import base64
        path = Path(path)
        if not path.is_file():
            log(f"no {path.name}: the app keeps its thumbnail")
            return
        try:
            self.w.api_client.do("PATCH", f"/api/2.0/apps/{self.app_name}/thumbnail", body={
                "app_thumbnail": {"thumbnail": base64.b64encode(path.read_bytes()).decode()}})
            log(f"app thumbnail set from {path.name}")
        except Exception as exc:          # a picture is not worth failing the setup for
            log(f"app thumbnail not set: {exc}")

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

        def music():
            parts, ok = [], True
            for endpoint, where in self._music_endpoints():
                conn = self.connect(role=self.role, endpoint=endpoint)
                try:
                    with conn.cursor() as cur:
                        cur.execute(f"SELECT count(*), count(a.audio_data) FROM {self.schema}.music_assets a "
                                    f"WHERE a.name IN (SELECT music_name FROM {self.schema}.map_music)")
                        n, audio = cur.fetchone()
                finally:
                    conn.close()
                ok = ok and n > 0 and audio == n
                parts.append(f"{where} {audio} of {n} tracks with audio")
            return ok, ", ".join(parts) + ("" if ok else " (step music)")

        def owner():
            r = self.sql("SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = %s", (self.schema,), fetch=True)
            lobby = self.sql("SELECT 1 FROM pg_namespace WHERE nspname = 'lobby'", fetch=True)
            return bool(r and r[0][0] == self.role and lobby), f"schema owner {r[0][0] if r else None}, lobby {'yes' if lobby else 'no'}"

        def sql():
            # Games are copied from the template, so that is the branch that
            # counts (the default branch only gets the SQL before the template
            # exists; afterwards the app refreshes the template itself).
            from sqldoom import db
            try:
                eps = list(self.w.postgres.list_endpoints(parent=f"{self.project}/branches/{self.template}"))
                ep, where = eps[0].name, self.template
            except Exception:
                ep, where = self.endpoint, self.branch.rsplit("/", 1)[-1]
            conn = self.connect(role=self.role, endpoint=ep)
            try:
                st = db.status(conn)
                with conn.cursor() as cur:
                    cur.execute("SELECT count(*) FROM pg_class WHERE relnamespace = %s::regnamespace "
                                "AND relkind = 'v' AND relname ~ '^api_frame_idx_slot'", (self.schema,))
                    frames = cur.fetchone()[0]
            finally:
                conn.close()
            # Before the app's first start the template may still hold an older
            # version: the app installs the current one then (games wait for it).
            return frames > 0, (f"{where}: code {st['installed'] or 'none'} "
                                f"({'current' if st['up_to_date'] else 'the app installs ' + st['code'] + ' at its start'}), "
                                f"{frames} frame views")

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

        results = [check(n, f) for n, f in (("project", project), ("maps", maps), ("music", music), ("owner", owner), ("sql", sql),
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
        """Deploy the app from a workspace folder (default: this repository). A
        deployment only works on a running app: started first if stopped."""
        from databricks.sdk.service import apps as A
        path = source_code_path or str(REPO)
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
        self.set_thumbnail()
        return d
