"""Match rules, set from the page by Player 1.

Player 1 is the player seated longest (earliest mp_players.claimed_at among the
held slots); the role passes on when that player leaves. Each mode has its own
rule set (mp_rules, see postgres_compat.sql):

  monsters, skill                    need a level restart: saving one of them
                                     sets mp_match.pending = 'rules' and the
                                     referee reopens the map (3 s, VACUUM FULL)
  monster_respawn(_s), item_respawn(_s),
  weapons_stay, death_restart        live: doom_mp_rules_live() at once

Fixed by mode, not settable: keys (in the level / everyone holds all),
multiplayer-only items (off / on), and death_restart is solo only.

The caller is identified like the relay does (sqldoom.server.relay.player_identity):
the proxy's X-Forwarded-Email plus the browser tab's token.
"""
import os
from contextlib import closing

import psycopg2

FIELDS = {
    "monsters": bool, "skill": int, "monster_respawn": bool, "monster_respawn_s": int,
    "item_respawn": bool, "item_respawn_s": int, "weapons_stay": bool, "death_restart": bool,
}
RESTART_FIELDS = ("monsters", "skill")
SKILLS = ("I'm too young to die", "Hey, not too rough", "Hurt me plenty", "Ultra-Violence", "Nightmare!")


class RulesError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def _connect(creds, endpoint):
    c = psycopg2.connect(creds.dsn(endpoint, application_name="sqldoom-rules",
                                   role=os.getenv("DOOM_DB_ROLE") or None))
    c.autocommit = True
    return closing(c)


def _host(cur):
    cur.execute("SELECT mp.role_name, mp.slot, COALESCE(NULLIF(mp.display_name, ''), split_part(mp.role_name, '#', 1)) "
                "FROM mp_players mp JOIN mp_match m ON m.map_id = mp.map_id "
                "WHERE mp.role_name IS NOT NULL ORDER BY mp.claimed_at NULLS LAST, mp.slot LIMIT 1")
    return cur.fetchone()


def _read(cur):
    cur.execute("SELECT mode, " + ", ".join(FIELDS) + " FROM mp_rules")
    return {r[0]: dict(zip(FIELDS, r[1:])) for r in cur.fetchall()}


def get_rules(creds, endpoint, identity):
    with _connect(creds, endpoint) as c, c.cursor() as cur:
        cur.execute("SELECT mode, state::text, pending FROM mp_match LIMIT 1")
        mode, state, pending = cur.fetchone()
        cur.execute("SELECT EXTRACT(EPOCH FROM (intermission_until - now()))::int FROM mp_match LIMIT 1")
        left = cur.fetchone()[0]
        host = _host(cur)
        cur.execute("SELECT count(*) FROM mp_players mp JOIN mp_match m ON m.map_id = mp.map_id WHERE mp.role_name IS NOT NULL")
        seated = int(cur.fetchone()[0])
        return {
            "mode": mode, "state": state, "pending": pending, "seconds_left": left, "seated": seated,
            "host": {"slot": host[1], "name": host[2]} if host else None,
            "you_are_host": bool(host and identity and host[0] == identity),
            "rules": _read(cur), "skills": SKILLS,
        }


def switch_mode(creds, endpoint, identity, want):
    """Player 1 alone picks the rule set: 'deathmatch' (wander with the
    multiplayer rules) or 'solo'. The level restarts in 3 s. With two or more
    players the mode follows the count, so only the way to multiplayer is open."""
    if want not in ("solo", "deathmatch"):
        raise RulesError(400, f"unknown mode {want!r}")
    with _connect(creds, endpoint) as c, c.cursor() as cur:
        host = _host(cur)
        if not host or not identity or host[0] != identity:
            raise RulesError(403, "only Player 1 (the player seated longest) can switch the rules"
                             + (f": {host[2]}" if host else "; nobody is playing"))
        cur.execute("SELECT count(*) FROM mp_players mp JOIN mp_match m ON m.map_id = mp.map_id WHERE mp.role_name IS NOT NULL")
        seated = int(cur.fetchone()[0])
        cur.execute("SELECT mode, state::text, pending FROM mp_match LIMIT 1")
        mode, state, pending = cur.fetchone()
        if mode == want:
            return {"ok": True, "switch": False}
        if want == "solo" and seated >= 2:
            raise RulesError(409, "with two or more players the multiplayer rules stay on")
        if state != "playing" or pending is not None:
            raise RulesError(409, "the level is already ending, try again in a few seconds")
        # the referee sees it within a second: 3 s countdown, same map
        cur.execute("UPDATE mp_match SET pending = %s WHERE pending IS NULL AND state = 'playing'",
                    ("stay" if want == "deathmatch" else "solo",))
        print(f"[rules] {identity} switched to the {want} rules", flush=True)
        return {"ok": True, "switch": cur.rowcount > 0}


def save_rules(creds, endpoint, identity, mode, values):
    if mode not in ("solo", "deathmatch"):
        raise RulesError(400, f"unknown mode {mode!r}")
    new = {}
    for k, v in values.items():
        if k not in FIELDS:
            raise RulesError(400, f"unknown rule {k!r}")
        new[k] = bool(v) if FIELDS[k] is bool else int(v)
    if "skill" in new and not 0 <= new["skill"] <= 4:
        raise RulesError(400, "skill is 0 to 4")
    for k in ("monster_respawn_s", "item_respawn_s"):
        if k in new and not 1 <= new[k] <= 600:
            raise RulesError(400, f"{k} is 1 to 600 seconds")
    if mode == "deathmatch":
        new.pop("death_restart", None)           # a deathmatch always respawns
    with _connect(creds, endpoint) as c, c.cursor() as cur:
        host = _host(cur)
        if not host or not identity or host[0] != identity:
            raise RulesError(403, "only Player 1 (the player seated longest) can change the rules"
                             + (f": {host[2]}" if host else "; nobody is playing"))
        old = _read(cur)[mode]
        changed = {k: v for k, v in new.items() if old.get(k) != v}
        if not changed:
            return {"ok": True, "changed": [], "restart": False}
        cur.execute("UPDATE mp_rules SET " + ", ".join(f"{k} = %s" for k in changed)
                    + ", updated_at = now(), updated_by = %s WHERE mode = %s",
                    (*changed.values(), identity, mode))
        cur.execute("SELECT mode, state::text, pending FROM mp_match LIMIT 1")
        cur_mode, state, pending = cur.fetchone()
        restart = False
        if mode == cur_mode:
            cur.execute("SELECT doom_mp_rules_live()")
            if any(k in changed for k in RESTART_FIELDS) and state == "playing":
                # the referee sees it within a second and reopens the map
                cur.execute("UPDATE mp_match SET pending = 'rules' WHERE pending IS NULL AND state = 'playing'")
                restart = cur.rowcount > 0
        print(f"[rules] {identity} changed the {mode} rules: {changed}"
              + (" (level restarts)" if restart else ""), flush=True)
        return {"ok": True, "changed": list(changed), "restart": restart}
