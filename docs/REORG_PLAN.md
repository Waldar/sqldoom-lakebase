# Reorganization plan

Branch: `reorg`

Goal: turn this repository into an autonomous SQLDoom-on-Lakebase project.
Outside `README.md` and `tools/cedar2plpgsql.py`, CedarDB should disappear from the code layout and runtime. The current live app and `main` stay unchanged until this branch is validated.

## Constraints agreed with the user

* Package name: `sqldoom`
* Keep benchmark tools, but move them under `tools/`
* Delete dormant shared-match code and read-replica rendering code
* Keep GPL notice in `LICENSE` and README credits

## Target tree

```text
README.md
LICENSE
pyproject.toml
app.py
app.yaml
src/sqldoom/
  server/
  game/
  lakebase/
  db/
  wad/
sql/
  schema/
  game/
  render/
  api/
  multiplayer/
  migrations/
setup/
tools/
web/
docs/
tests/
```

## Phases

### Phase 1: database source of truth

Replace `sql_frozen/` with plain Postgres source files and a versioned installer.

Deliverables:
* `sql/` hierarchy with explicit install order
* installer/upgrade code under `src/sqldoom/db/`
* version table + migrations
* SQL function/template that builds per-map/per-slot frame views

Acceptance:
* installing on a scratch branch produces the same catalog shape as the current live `game-template`
* key static tables match the current live template
* a frame rendered from the rebuilt schema matches the current app

### Phase 2: runtime package and web client

Absorb the app runtime under `src/sqldoom/`.

Deliverables:
* app imports from `src/sqldoom/...`
* upstream browser assets copied under `web/` with patches applied in-file
* no runtime dependency on `sqldoom/` or `sql_frozen/`
* no `doomapp/appjs_patch.py`

Acceptance:
* imports and lint pass
* local app startup succeeds
* a scratch game can start, change map, and render

### Phase 3: setup and operations

Move setup assets under `setup/` and make them use the new installer.

Deliverables:
* setup script + notebook under `setup/`
* runbook updated for the new tree
* app config points to the packaged runtime

Acceptance:
* fresh-workspace instructions are coherent
* `Setup.status()` still checks every critical step

### Phase 4: cleanup and docs

Delete the old mixed layout once the new path works.

Delete:
* `sqldoom/` runtime copy
* `sql_frozen/`
* dormant shared-match and replica code
* dead renderer/transpiler leftovers no longer needed

Acceptance:
* repository tree matches the target structure
* README and docs describe the autonomous project accurately

## Validation reference

The current live `game-template` and the running app are the behavioral reference:
* catalog snapshot
* stable data tables
* frame output for a known map/state
* playable single-player flow
