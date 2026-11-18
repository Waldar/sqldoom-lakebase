"""The game loop's SQL: the statements the referee prepares once and runs.

The game itself is in the database (sql/functions); the loop only opens the
match, runs doom_run_mp_tic at the tic rate, frees idle seats and reads the
score. The tic rate comes from the database too (doom_constants.TICRATE).
"""

TIC_SECONDS = None          # 1 / TICRATE, set by load_constants()

_STATEMENTS = (
    ("doom_mp_start", ("int", "int"), "SELECT doom_mp_start($1,$2)"),
    ("doom_mp_tic", ("int", "int", "int", "int", "int", "int"),
     "SELECT doom_run_mp_tic($1,$2,$3,$4,$5,$6)"),
    ("doom_mp_players", ("int",),
     "SELECT slot, player_thing_id FROM mp_players WHERE map_id=$1 ORDER BY slot"),
    ("doom_mp_reap", ("int", "int"), "SELECT doom_mp_reap($1,$2)"),
    ("doom_mp_score", ("int",),
     "SELECT mp.slot, ps.frags, ps.health, ps.alive, mp.role_name FROM mp_players mp "
     "JOIN player_state ps ON ps.map_id=mp.map_id AND ps.player_thing_id=mp.player_thing_id "
     "WHERE mp.map_id=$1 ORDER BY mp.slot"),
)


def load_constants(cur):
    """The tic rate, from the database."""
    global TIC_SECONDS
    cur.execute("SELECT value FROM doom_constants WHERE name = 'TICRATE'")
    row = cur.fetchone()
    if row is None:
        raise RuntimeError("doom_constants has no TICRATE")
    TIC_SECONDS = 1.0 / float(row[0])


def prepare(cur):
    for name, types, statement in _STATEMENTS:
        cur.execute(f"PREPARE {name}({','.join(types)}) AS {statement}")


def _execute(cur, name, params):
    cur.execute(f"EXECUTE {name}({','.join(['%s'] * len(params))})", params)


def mp_players(cur, map_id):
    """{slot: player_thing_id} of the map's seats."""
    _execute(cur, "doom_mp_players", (map_id,))
    return {int(slot): int(thing) for slot, thing in cur.fetchall()}


def mp_start(cur, map_id, skill):
    """Open the match on map_id (four free seats); returns mp_players()."""
    _execute(cur, "doom_mp_start", (map_id, skill))
    cur.fetchone()
    return mp_players(cur, map_id)


def mp_tic(cur, map_id, skill, players):
    """One tic. players: {slot: player_thing_id}, slot 1 required. True when
    this tic ended the level (an exit line, the timer)."""
    _execute(cur, "doom_mp_tic", (map_id, skill, players[1], players.get(2), players.get(3), players.get(4)))
    row = cur.fetchone()
    return bool(row and row[0])


def mp_score(cur, map_id):
    """[(slot, frags, health, alive, role_name)] of the map's seats."""
    _execute(cur, "doom_mp_score", (map_id,))
    return cur.fetchall()


def mp_reap(cur, map_id, idle_seconds):
    """Free every seat whose holder has been silent for idle_seconds; returns how many."""
    _execute(cur, "doom_mp_reap", (map_id, idle_seconds))
    return int(cur.fetchone()[0])
