"""Frozen SQL: the game's Postgres code as plain files in Git (sql_frozen/).

cedar2plpgsql.py translated upstream's CedarScript once; the referee then
stacked text rewrites on top at every template install (frame tail, lean
plan, occlusion, LBDoom renderer, slot gates, statement fixes ...). The result
only existed in the database. This module takes that result out of a branch
(dump) and puts it back into another one (apply), so the SQL that runs is the
SQL in Git, and an install only touches what changed.

  dump(conn, root)    writes root/ from a branch that holds the final code
                      (game-template): one file per function, view and
                      materialized view, the per-slot frame views as 5
                      templates, every index, and manifest.json (apply order
                      and the per-slot instances).
  apply(conn, root)   reads the branch's objects the way dump would write
                      them and creates or replaces those that differ from
                      the files (or are missing), in one transaction, as the
                      connection's role (doom_owner). No bookkeeping table:
                      the catalog itself is the state.
  version(root)       hash of the files: the template is refreshed when it
                      changes.

A fix is a plain edit of a .sql file. Postgres keeps views (and function
headers) in its own layout, so after the edit is applied, run dump on the
template once to write the file back in that layout (else every check finds
it different and applies it again).

What is NOT frozen: tables, types, sequences and their data (WAD assets,
lookup tables). They live on the branch and are copied with it; a change to
them is a migration, written by hand.

Per-slot frame views: api_frame_slot<S>_m<M>, api_frame_idx_slot<S>_m<M>,
api_frame_idx_slot<S>_m<M>_low, doom_hud_slot<S>_m<M>, doom_hudkey_slot<S>_m<M>
for 9 maps x 4 slots (180 views, ~100 KB each) differ only by the map, the
slot and the player-start Thing written in as literals. They are stored once
per kind with {map_id} {slot} {thing_id} placeholders; dump renders every
instance back and checks it is the stored text, byte for byte (an instance
that differs is stored as a plain view instead).

Command line (run from sqldoom-lakebase/, with Databricks credentials):
  python -m doomapp.frozen dump  <endpoint> [root]     default root sql_frozen
  python -m doomapp.frozen apply <endpoint> [root] [--force]
  python -m doomapp.frozen check <endpoint> [root]     objects that differ, nothing written
"""
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
ROOT = Path(os.getenv("DOOM_SQL_FROZEN_DIR") or HERE / "sql_frozen")   # env: tests only
SCHEMA = "doom"

# --- per-slot frame view templates --------------------------------------------
SLOT_KINDS = ("api_frame_slot{S}_m{M}", "api_frame_idx_slot{S}_m{M}", "api_frame_idx_slot{S}_m{M}_low",
              "doom_hud_slot{S}_m{M}", "doom_hudkey_slot{S}_m{M}")
_SLOT_RE = re.compile(r"^(api_frame_slot|api_frame_idx_slot|doom_hud_slot|doom_hudkey_slot)(\d+)_m(\d+)(_low)?$")
# The only places the literals appear (checked on every instance by dump).
_LITERALS = ((r"SELECT {M} AS map_id,", "SELECT {map_id} AS map_id,"),
             (r"{T} AS player_thing_id", "{thing_id} AS player_thing_id"),
             (r"(mp.map_id = {M})", "(mp.map_id = {map_id})"),
             (r"(mp.slot = {S})", "(mp.slot = {slot})"),
             (r"(c.map_id = {M})", "(c.map_id = {map_id})"),
             (r"(c.slot = {S})", "(c.slot = {slot})"))

# Objects that belong to extensions (btree_gist, pg_prewarm, pg_stat_statements
# live in the doom schema) are not ours.
_NOT_EXT = "NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = {o} AND e.deptype = 'e')"


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _slot_kind(name):
    m = _SLOT_RE.match(name)
    if not m:
        return None
    prefix, slot, map_id, low = m.groups()
    return f"{prefix}{{S}}_m{{M}}{low or ''}", int(slot), int(map_id)


def render_slot(template, name, map_id, slot, thing_id, grants=()):
    """One per-slot view's DDL: the kind's template filled in, then its own
    GRANTs (they are not the same on every instance)."""
    return (template.replace("{name}", name).replace("{map_id}", str(map_id))
            .replace("{slot}", str(slot)).replace("{thing_id}", str(thing_id))
            + "".join(g + "\n" for g in grants))


def _split_grants(ddl):
    """(DDL without its trailing GRANT lines, [GRANT lines])."""
    lines = ddl.split("\n")
    grants = []
    while lines and (lines[-1] == "" or lines[-1].startswith(("GRANT ", "REVOKE "))):
        line = lines.pop()
        if line:
            grants.insert(0, line)
    return "\n".join(lines) + "\n", grants


def _templatize(ddl, name, map_id, slot, thing_id):
    out = ddl.replace(f"{SCHEMA}.{name} ", f"{SCHEMA}.{{name}} ")
    for lit, ph in _LITERALS:
        out = out.replace(lit.format(M=map_id, S=slot, T=thing_id), ph)
    out = out.replace(f" ON TABLE {SCHEMA}.{name} TO ", f" ON TABLE {SCHEMA}.{{name}} TO ")
    return out


# --- catalog reads ---------------------------------------------------------------
def _grants(cur, kind, oid, ident, owner_col, acl_col, catalog):
    """GRANT statements for an object's ACL (owner left out, unknown roles
    skipped, one line per grantee whoever granted it). Functions with an ACL start with REVOKE ALL FROM PUBLIC, so a
    function that is not for PUBLIC stays that way on a fresh create."""
    cur.execute(f"""SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END,
                           string_agg(DISTINCT a.privilege_type, ', ' ORDER BY a.privilege_type)
                    FROM {catalog} o, aclexplode(o.{acl_col}) a
                    LEFT JOIN pg_roles r ON r.oid = a.grantee
                    WHERE o.oid = %s AND a.grantee <> o.{owner_col} AND (a.grantee = 0 OR r.oid IS NOT NULL)
                    GROUP BY 1 ORDER BY 1""", (oid,))
    rows = [(who, privs) for who, privs in cur.fetchall() if not _LOCAL_ROLE_RE.match(who)]
    cur.execute(f"SELECT {acl_col} IS NOT NULL FROM {catalog} WHERE oid = %s", (oid,))
    has_acl = cur.fetchone()[0]
    lines = []
    if kind == "function" and has_acl:
        lines.append(f"REVOKE ALL ON FUNCTION {ident} FROM PUBLIC;")
    word = "FUNCTION" if kind == "function" else "TABLE"
    lines += [f"GRANT {privs} ON {word} {ident} TO {who};" for who, privs in rows]
    return lines


def _functions(cur):
    cur.execute(f"""SELECT p.oid, p.proname, p.oid::regprocedure::text, p.prokind
                    FROM pg_proc p WHERE p.pronamespace = '{SCHEMA}'::regnamespace
                    AND p.prokind IN ('f', 'a') AND {_NOT_EXT.format(o='p.oid')}
                    ORDER BY p.proname, p.oid::regprocedure::text""")
    rows = cur.fetchall()
    seen, out = {}, []
    for oid, name, sig, kind in rows:
        if kind == "f":
            cur.execute("SELECT pg_get_functiondef(%s)", (oid,))
            ddl = cur.fetchone()[0].rstrip() + ";\n"
        else:
            cur.execute("""SELECT a.aggtransfn::regproc::text, format_type(a.aggtranstype, NULL),
                                  a.aggsortop::regoperator::text, a.aggcombinefn::regproc::text
                           FROM pg_aggregate a WHERE a.aggfnoid = %s""", (oid,))
            sfunc, stype, sortop, combine = cur.fetchone()
            sig_q = f"{SCHEMA}.{sig}" if not sig.startswith(SCHEMA + ".") else sig
            parts = [f"SFUNC = {sfunc}", f"STYPE = {stype}"]
            if combine and combine != "-":
                parts.append(f"COMBINEFUNC = {combine}")
            if sortop and sortop != "0":
                parts.append(f"SORTOP = {sortop.split('(')[0]}")
            ddl = (f"DROP AGGREGATE IF EXISTS {sig_q};\nCREATE AGGREGATE {sig_q} (\n    "
                   + ",\n    ".join(parts) + "\n);\n")
        ident = sig if sig.startswith(SCHEMA + ".") else f"{SCHEMA}.{sig}"
        ddl += "".join(g + "\n" for g in _grants(cur, "function", oid, ident, "proowner", "proacl", "pg_proc"))
        n = seen.get(name, 0)
        seen[name] = n + 1
        fname = name if n == 0 else f"{name}__{n + 1}"
        out.append({"kind": "aggregate" if kind == "a" else "function", "name": sig,
                    "ident": ident, "file": f"functions/{fname}.sql", "ddl": ddl})
    return out


def _relations(cur, normalize=False):
    """Views and materialized views, dependencies first.

    normalize: Postgres' view text is not stable on its first round trip (it
    prints nested ANDs with parentheses it drops when the view is created
    again from that text; same plan). Each view is created again from its
    text inside a savepoint that is rolled back, and the text read then is
    kept: a dump is in the form a branch holds after apply. Needs the
    owner's role and an open transaction (collect does both)."""
    cur.execute(f"""SELECT c.oid, c.relname, c.relkind, pg_get_viewdef(c.oid),
                           array_to_string(c.reloptions, ', ')
                    FROM pg_class c WHERE c.relnamespace = '{SCHEMA}'::regnamespace
                    AND c.relkind IN ('v', 'm') AND {_NOT_EXT.format(o='c.oid')}""")
    rels = {r[0]: r for r in cur.fetchall()}
    if normalize:
        for oid, (_, name, kind, body, opts) in list(rels.items()):
            if kind != "v":
                continue
            cur.execute("SAVEPOINT frozen_norm")
            with_ = f" WITH ({opts})" if opts else ""
            cur.execute(f"CREATE OR REPLACE VIEW {SCHEMA}.{name}{with_} AS {body.rstrip().rstrip(';')}")
            cur.execute("SELECT pg_get_viewdef(%s)", (oid,))
            rels[oid] = (oid, name, kind, cur.fetchone()[0], opts)
            cur.execute("ROLLBACK TO SAVEPOINT frozen_norm")
    cur.execute("""SELECT DISTINCT r.ev_class, d.refobjid FROM pg_rewrite r
                   JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
                   WHERE d.refobjid <> r.ev_class""")
    deps = {}
    for v, ref in cur.fetchall():
        if v in rels and ref in rels:
            deps.setdefault(v, set()).add(ref)
    order, done = [], set()

    def visit(oid, path=()):
        if oid in done:
            return
        if oid in path:
            raise RuntimeError(f"view dependency cycle at {rels[oid][1]}")
        for ref in sorted(deps.get(oid, ()), key=lambda o: rels[o][1]):
            visit(ref, path + (oid,))
        done.add(oid)
        order.append(oid)

    for oid in sorted(rels, key=lambda o: rels[o][1]):
        visit(oid)
    out = []
    for oid in order:
        _, name, kind, body, opts = rels[oid]
        ident = f"{SCHEMA}.{name}"
        body = body.rstrip().rstrip(";")
        with_ = f" WITH ({opts})" if opts else ""
        if kind == "v":
            ddl = f"CREATE OR REPLACE VIEW {ident}{with_} AS\n{body};\n"
        else:
            ddl = f"CREATE MATERIALIZED VIEW {ident}{with_} AS\n{body}\nWITH DATA;\n"
        ddl += "".join(g + "\n" for g in _grants(cur, "rel", oid, ident, "relowner", "relacl", "pg_class"))
        out.append({"kind": "view" if kind == "v" else "matview", "name": name, "ident": ident, "ddl": ddl,
                    "deps": sorted(rels[o][1] for o in deps.get(oid, ()))})
    return out


def _indexes(cur):
    """Indexes that are not behind a constraint (those come with their table)."""
    cur.execute(f"""SELECT i.relname, pg_get_indexdef(x.indexrelid)
                    FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
                    WHERE i.relnamespace = '{SCHEMA}'::regnamespace AND {_NOT_EXT.format(o='x.indexrelid')}
                    AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = x.indexrelid)
                    ORDER BY i.relname""")
    out = []
    for name, ddl in cur.fetchall():
        ddl = re.sub(r"^CREATE (UNIQUE )?INDEX ", lambda m: f"CREATE {m.group(1) or ''}INDEX IF NOT EXISTS ", ddl)
        out.append({"kind": "index", "name": name, "ident": f"{SCHEMA}.{name}", "ddl": ddl + ";\n"})
    return out


# --- dump ---------------------------------------------------------------------------
def collect(conn, quiet=False, normalize=False):
    """Everything dump writes, as {path: text} plus the manifest dict (each
    object with the sha256 of its DDL, not written to manifest.json).
    normalize: see _relations (dump uses it; nothing is changed on the branch)."""
    old_autocommit = conn.autocommit
    if normalize:
        conn.autocommit = False
    try:
        with conn.cursor() as cur:
            cur.execute(f"SET LOCAL search_path = {SCHEMA}" if not conn.autocommit else f"SET search_path = {SCHEMA}")
            funcs = _functions(cur)
            rels = _relations(cur, normalize=normalize)
            idx = _indexes(cur)
            cur.execute("SELECT version()")
            pg = cur.fetchone()[0]
    finally:
        if normalize:
            conn.rollback()
            conn.autocommit = old_autocommit
    files, objects, slot_views, kinds = {}, [], [], {}
    # Each kind's template is taken from its instance with the highest map and
    # slot: literals like 1 or 0 would also match unrelated numbers.
    source = {}
    for r in rels:
        sk = _slot_kind(r["name"]) if r["kind"] == "view" else None
        m = re.search(r"\n\s+(\d+) AS player_thing_id", r["ddl"]) if sk else None
        if sk and m and (sk[2], sk[1]) > source.get(sk[0], (None, (-1, -1)))[1]:
            source[sk[0]] = (r, (sk[2], sk[1]), int(m.group(1)))
    for kind, (r, (map_id, slot), thing) in source.items():
        kinds[kind] = _templatize(_split_grants(r["ddl"])[0], r["name"], map_id, slot, thing)
    for f in funcs:
        files[f["file"]] = f["ddl"]
        objects.append({"kind": f["kind"], "name": f["name"], "ident": f["ident"], "file": f["file"],
                        "sha": _sha(f["ddl"])})
    plain = []
    for r in rels:
        sk = _slot_kind(r["name"]) if r["kind"] == "view" else None
        if sk is None:
            plain.append(r)
            continue
        kind, slot, map_id = sk
        m = re.search(r"\n\s+(\d+) AS player_thing_id", r["ddl"])
        if not m:
            plain.append(r)
            continue
        thing = int(m.group(1))
        tpl = kinds[kind]
        grants = _split_grants(r["ddl"])[1]
        if render_slot(tpl, r["name"], map_id, slot, thing, grants) != r["ddl"]:
            if not quiet:
                print(f"[frozen] {r['name']}: differs from its kind's template, stored as a plain view", flush=True)
            plain.append(r)
            continue
        slot_views.append({"name": r["name"], "kind": kind, "map_id": map_id, "slot": slot, "thing_id": thing,
                           "ident": f"{SCHEMA}.{r['name']}", "deps": r["deps"], "grants": grants})
    for r in plain:
        sub = "views" if r["kind"] == "view" else "matviews"
        path = f"{sub}/{r['name']}.sql"
        files[path] = r["ddl"]
        objects.append({"kind": r["kind"], "name": r["name"], "ident": r["ident"], "file": path,
                        "sha": _sha(r["ddl"]), "deps": r["deps"]})
    for kind, tpl in kinds.items():
        files[f"slot_views/{kind.replace('{S}', 'S').replace('{M}', 'M')}.sql"] = tpl
    for sv in slot_views:
        path = f"slot_views/{sv['kind'].replace('{S}', 'S').replace('{M}', 'M')}.sql"
        text = render_slot(kinds[sv["kind"]], sv["name"], sv["map_id"], sv["slot"], sv["thing_id"], sv["grants"])
        objects.append({"kind": "slot_view", "name": sv["name"], "ident": sv["ident"], "file": path,
                        "map_id": sv["map_id"], "slot": sv["slot"], "thing_id": sv["thing_id"],
                        "grants": sv["grants"], "sha": _sha(text), "deps": sv["deps"]})
    files["indexes.sql"] = "".join(i["ddl"] for i in idx)
    for i in idx:
        objects.append({"kind": "index", "name": i["name"], "ident": i["ident"], "file": "indexes.sql",
                        "sha": _sha(i["ddl"])})
    objects = _ordered(objects)
    manifest = {"schema": SCHEMA, "source": pg.split(" on ")[0],
                "counts": {k: sum(1 for o in objects if o["kind"] == k)
                           for k in ("function", "aggregate", "view", "matview", "slot_view", "index")},
                "objects": objects}
    return files, manifest


def _ordered(objects):
    """Apply order: functions, aggregates, then views and materialized views
    with every dependency first, the per-slot views, the indexes."""
    rank = {"function": 0, "aggregate": 1, "view": 2, "matview": 2, "slot_view": 3, "index": 4}
    rels = {o["name"]: o for o in objects if rank[o["kind"]] in (2, 3)}
    out, done = [], set()

    def visit(o):
        if o["name"] in done:
            return
        done.add(o["name"])
        for d in o.get("deps", ()):
            if d in rels:
                visit(rels[d])
        out.append(o)

    for o in sorted(objects, key=lambda o: (rank[o["kind"]], o["name"])):
        if rank[o["kind"]] in (2, 3):
            visit(o)
        else:
            out.append(o)
    return sorted(out, key=lambda o: 0 if rank[o["kind"]] < 2 else (2 if rank[o["kind"]] < 4 else 4))


def dump(conn, root=ROOT):
    """Write root/ (replacing its .sql files and manifest.json) from conn's branch."""
    root = Path(root)
    files, manifest = collect(conn, normalize=True)
    for old in list(root.rglob("*.sql")) if root.exists() else []:
        if str(old.relative_to(root)) not in files:
            old.unlink()
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
    # apply order and the per-slot instances; no sha (apply compares with the
    # branch's catalog), so an edited .sql file needs no manifest change
    out = dict(manifest, objects=[{k: v for k, v in o.items() if k != "sha"} for o in manifest["objects"]])
    (root / "manifest.json").write_text(json.dumps(out, indent=1) + "\n", encoding="utf-8")
    return manifest


# --- apply ---------------------------------------------------------------------------
def load(root=ROOT):
    root = Path(root)
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    cache = {}

    def text_of(o):
        if o["file"] not in cache:
            cache[o["file"]] = (root / o["file"]).read_text(encoding="utf-8")
        t = cache[o["file"]]
        if o["kind"] == "slot_view":
            return render_slot(t, o["name"], o["map_id"], o["slot"], o["thing_id"], o.get("grants", ()))
        if o["kind"] == "index":
            for line in t.splitlines(keepends=True):
                if re.match(rf"CREATE (UNIQUE )?INDEX IF NOT EXISTS {re.escape(o['name'])} ", line):
                    return line
            raise KeyError(f"index {o['name']} not in {o['file']}")
        return t
    return manifest, text_of


def available(root=ROOT):
    return (Path(root) / "manifest.json").is_file()


def enabled(root=ROOT):
    """Kept for callers: the frozen SQL is the only way since 2026-11-13."""
    return available(root)


def version(root=ROOT):
    """Hash of every file under root/ (manifest included): any edit changes it."""
    root = Path(root)
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        if p.is_file() and p.suffix in (".sql", ".json"):
            h.update(str(p.relative_to(root)).encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()[:16]


def _exists(cur, o):
    if o["kind"] in ("function", "aggregate"):
        cur.execute("SELECT to_regprocedure(%s) IS NOT NULL", (o["ident"],))
    else:
        cur.execute("SELECT to_regclass(%s) IS NOT NULL", (o["ident"],))
    return cur.fetchone()[0]


def _run(cur, o, ddl):
    """One object's DDL in a savepoint. CREATE OR REPLACE refuses a changed
    result type (function) or changed columns (view): drop it, create again;
    an object that others depend on then fails with Postgres' own message."""
    cur.execute("SAVEPOINT frozen_obj")
    try:
        if o["kind"] == "matview":
            # the views reading it go too; they are applied again after it
            # (apply() recreates every missing object)
            cur.execute(f"DROP MATERIALIZED VIEW IF EXISTS {o['ident']} CASCADE")
        cur.execute(ddl)
        cur.execute("RELEASE SAVEPOINT frozen_obj")
        return
    except Exception as exc:
        cur.execute("ROLLBACK TO SAVEPOINT frozen_obj")
        code = getattr(exc, "pgcode", None)
        # 42P13 invalid_function_definition (return type), 42P16 invalid_table_definition (view columns)
        if o["kind"] not in ("function", "view", "slot_view") or code not in ("42P13", "42P16", "42809"):
            raise RuntimeError(f"{o['kind']} {o['name']}: {exc}") from exc
    word = "FUNCTION" if o["kind"] == "function" else "VIEW"
    try:
        cur.execute(f"DROP {word} {o['ident']}")
        cur.execute(ddl)
        cur.execute("RELEASE SAVEPOINT frozen_obj")
    except Exception as exc:
        cur.execute("ROLLBACK TO SAVEPOINT frozen_obj")
        raise RuntimeError(f"{o['kind']} {o['name']} (drop + create): {exc}") from exc


def live_shas(conn):
    """{kind:name: sha} of the branch's objects, in the form dump writes them."""
    files, manifest = collect(conn, quiet=True)
    return {f"{o['kind']}:{o['name']}": o["sha"] for o in manifest["objects"]}


_GRANT_TO_RE = re.compile(r"^GRANT .* TO (\S+);$")
# Lakebase's per-database reader and writer roles get their grants from the
# database's default privileges, and their number differs from one project to
# the next (databricks_reader_16406 here, databricks_reader_16407 on a new
# project, 2026-11-13): never dumped, never compared, never granted by apply.
_LOCAL_ROLE_RE = re.compile(r"^databricks_(reader|writer)_\d+$")


def _known_grants(ddl, roles):
    """Drop the GRANT lines to Lakebase's numbered reader/writer roles and to
    roles this database does not have (a dump from another workspace), so
    the comparison with the branch's catalog stays exact."""
    lines = ddl.split("\n")
    kept = [ln for ln in lines
            if not ((m := _GRANT_TO_RE.match(ln)) and (m.group(1) not in roles or _LOCAL_ROLE_RE.match(m.group(1))))]
    return ddl if len(kept) == len(lines) else "\n".join(kept)


def apply(conn, root=ROOT, force=False, dry_run=False, log=print):
    """Bring conn's branch to root/. The branch's own catalog is the state: its
    objects are read in dump's form, and every object whose text differs from
    the file (or that is missing) is created or replaced, dependencies first.
    One transaction (all or nothing). Returns {kind: count applied}.

    A file edited by hand is applied as written; Postgres stores views (and
    function headers) in its own layout, so such an object differs again on
    the next check until `dump` writes it back in that layout."""
    manifest, text_of = load(root)
    t0 = time.time()
    old_autocommit = conn.autocommit
    conn.autocommit = False
    done, names = {}, []
    try:
        live = {} if force else live_shas(conn)
        with conn.cursor() as cur:
            cur.execute("SELECT quote_ident(rolname) FROM pg_roles")
            roles = {r[0] for r in cur.fetchall()} | {"PUBLIC"}
        with conn.cursor() as cur:
            cur.execute(f"SET LOCAL search_path = {SCHEMA}")
            cur.execute("SET LOCAL check_function_bodies = off")
            cur.execute("SET LOCAL lock_timeout = '20s'")
            for o in manifest["objects"]:
                key = f"{o['kind']}:{o['name']}"
                ddl = _known_grants(text_of(o), roles)
                # an object dropped above (CASCADE from a materialized view) is missing
                if live.get(key) == _sha(ddl) and (not names or _exists(cur, o)):
                    continue
                names.append(key)
                done[o["kind"]] = done.get(o["kind"], 0) + 1
                if not dry_run:
                    _run(cur, o, ddl)
        if dry_run:
            conn.rollback()
        else:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.autocommit = old_autocommit
    what = ", ".join(f"{n} {k}s" for k, n in sorted(done.items())) or "nothing"
    log(f"[frozen] {'differs' if dry_run else 'applied'}: {what} "
        f"(version {version(root)}) in {time.time() - t0:.1f} s")
    if dry_run:
        return {"counts": done, "names": names}
    return done


# --- command line ------------------------------------------------------------------
def _connect(endpoint):
    import psycopg2
    from doomapp.lakebase import CREDS
    conn = psycopg2.connect(CREDS.dsn(endpoint, application_name="sqldoom-frozen",
                                      role=os.getenv("DOOM_DB_ROLE", "doom_owner") or None))
    conn.autocommit = True
    return conn


def main(argv):
    if len(argv) < 2 or argv[0] not in ("dump", "apply", "check"):
        print(__doc__)
        return 2
    cmd, endpoint = argv[0], argv[1]
    rest = [a for a in argv[2:] if not a.startswith("--")]
    root = Path(rest[0]) if rest else ROOT
    conn = _connect(endpoint)
    try:
        if cmd == "dump":
            m = dump(conn, root)
            print(f"[frozen] dumped version {version(root)} to {root}: {m['counts']}")
        elif cmd == "apply":
            apply(conn, root, force="--force" in argv)
        else:
            r = apply(conn, root, dry_run=True)
            for n in r["names"]:
                print("  " + n)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
