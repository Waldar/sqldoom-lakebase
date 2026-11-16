# Deploying SQLDoom with an assistant (Genie Code)

This page is written for an AI assistant working in a Databricks workspace (Genie Code or similar) that was asked something like:

> Deploy the app described in https://github.com/Waldar/sqldoom-lakebase/blob/main/DEPLOY_WITH_GENIE.md

Follow the steps in order. Everything runs through `setup_workspace.py`, whose steps are idempotent: when a step fails, fix the cause and run it again, earlier work is kept. People can follow the same page; `docs/DEPLOYMENT.md` explains each step in more detail.

## 0. Ask the user once, before changing anything

Ask these together, with the defaults shown, and wait for the answers:

1. **Lakebase project id** (default `sqldoom`). It must not exist yet, or be a project made by this setup.
2. **App name** (default `sqldoom-ltap`; lowercase letters, digits and dashes).
3. **Where `DOOM1.WAD` is**: a Unity Catalog volume path such as `/Volumes/<catalog>/<schema>/<volume>/DOOM1.WAD`. The shareware WAD is not in the repository; if the user has none uploaded, ask them to upload it to a volume and give you the path.
4. **Confirmation of the changes**, listed in full so one answer covers them:
   * create the Lakebase project (Postgres 17, default endpoint size 24 CU; during the map load the main endpoint runs at 8 CU, then 1 CU);
   * create the Databricks App (Medium) with the project's database as its resource;
   * grant the app's service principal the Postgres role `doom_owner` and **Can manage** on the Lakebase project (the app creates and deletes one branch per game);
   * create the `game-template` branch after the app, or, if it already exists without the app's database login, add that login there (role, `doom_owner`, CONNECT and CREATE on the database);
   * edit `app.yaml` in the cloned folder and deploy the app from that folder.

If a tool refuses one of these changes (for example a permission grant), stop and tell the user which change and why. Retry it only after they confirm.

## 1. Get the code

Clone the public repository `https://github.com/Waldar/sqldoom-lakebase.git` as a Git folder under the user's home folder, for example `/Workspace/Users/<user>/sqldoom-lakebase`. The project is the clone's root (called `ROOT` below), not a nested subfolder. Public source does not require access to the original private monorepo; if the workspace's Git integration requires a linked GitHub credential, ask the user to configure one in Settings, Linked accounts.

## 2. Database part (about 1 minute)

Run this Python on serverless compute, in your own session (not as a subprocess: a subprocess cannot use the session's sign-in). Fill in the three values.

```python
import subprocess, sys
subprocess.run([sys.executable, "-m", "pip", "install", "-q", "databricks-sdk>=0.118.0", "psycopg2-binary>=2.9"], check=True)
ROOT = "/Workspace/Users/<user>/sqldoom-lakebase"
sys.path[:0] = [ROOT, ROOT + "/sqldoom"]
from setup_workspace import Setup
s = Setup(project="<project id>", app="<app name>", wad="<volume path of DOOM1.WAD>")
s.run(until="sql")
```

Expected: one `[setup] --- <step>` line per step (project, compute, database, maps, owner, sql), the loader's progress during `maps`, then `[frozen] differs: nothing` and `[setup] all done in ... s`. Normal lines that are not errors: `postgres_compat.sql before the load: relation "mp_players" does not exist (empty schema)` and `translator fixes skipped during the load ...: doom_cs_monster_step`.

## 3. App part

```python
s.run(start="app")
```

This creates the app with its Lakebase resource (or adds the resource to an existing app of that name), waits for the service principal's Postgres role, grants it `doom_owner` and Can manage on the project, **then** creates the `game-template` branch, points `app.yaml` at the project, and sizes the main endpoint down to 1 CU.

The order matters: Lakebase roles are per branch, and a branch copies its parent's roles only when it is created. `game-template` (and every game branch, copied from it) must be created after the app's role exists on the default branch, or the app cannot log in to it. If `game-template` already exists without the app's login (a setup run in the older order), the template step adds the login, its `doom_owner` membership and CONNECT and CREATE on the database, as on the default branch. That is a permission change: include it in the confirmation of step 0.

If your tools do not let code create an app, create it with your own app tool instead (name as agreed, Medium), then run `s.run(start="app")` again: the step finds the app and adds what is missing.

## 4. Deploy

Deploy from the cloned folder (no Git credential needed). A deployment only works when the app is running:

```python
s.deploy()   # starts the app first if it is stopped, then deploys ROOT
```

or with the CLI: `databricks apps get <app> --output JSON` first; if `compute_status.state` is `STOPPED`, `databricks apps start <app> --timeout 20m`; if it is `STARTING` or `STOPPING`, wait and check again; once it is running, `databricks apps deploy <app> --source-code-path <ROOT>`.

## 5. Check

```python
s.status()   # read only: one line per step, "ok" or "MISSING"; True when everything is in place
```

Then the app's logs (your app-log tool; the CLI's `apps logs` is not reliable from a notebook). Within a minute of the start, expect:

* `[games] template game-template: installing code frozen-...`, `[games] template compacted: ...`, `[games] template reset: 9 maps ...`, `[games] template game-template refreshed in ... s`
* no traceback.

Give the user the app URL (printed by `status()`), and tell them to give players **Can use** on the app. Playing: open the URL, type a name, **Single player**; the loading screen takes about 5-15 s.

## If something fails

| Message | What to do |
| --- | --- |
| `... DOOM1.WAD: no such file` | Ask the user for the right volume path, then `s.run(start="maps", until="sql")` |
| Starting a game: `template not available: ... password authentication failed for user '<app id>'` | `game-template` was made before the app and has no login for it: `s.run(steps=["template"])` (adds it, see step 3), then start a game again. An app deployed from this repository since 2026-11-16 retries the template on the next game; an older deployment must be redeployed (or restarted) first |
| `setup_doom_owner.sql part 1 left ...: rolled back` | Something in schema `doom` is owned by another role; show the user the counts |
| `after apply, still different from sql_frozen/` | Run `s.status()` and report the counts; do not edit `sql_frozen/` |
| `Postgres role <id> of the app's service principal did not appear` | The app's Lakebase resource is missing or still being created; check the app's resources, then `s.run(start="app")` |
| App deploy: `not in RUNNING state` | Do not retry the deploy: `apps get`, then start the app or wait, as in step 4 |
| In the app logs: `template refresh failed` or `frame views missing on this branch` | The app applies `sql_frozen/` to `game-template` at each start; report the log lines around it and `s.status()` to the user |

Tested end to end for the database part on a new Lakebase project (2026-11-13: 53 s, then played on a game branch). First run in another workspace (2026-11-16): deployed, but games failed because `game-template` was made before the app (fixed by the order above; the repair of an existing template has not run yet).
