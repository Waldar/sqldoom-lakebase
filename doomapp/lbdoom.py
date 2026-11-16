"""The frame renderer of Ilia Chibaev's LBDoom, as our indexed frame views.

LBDoom (github.com/ilia-chibaev_data/LBDoom, GPL-2.0 like upstream SQLDoom)
rewrote upstream's renderer for Postgres's executor (narrow rows, set-returning
functions in select lists, the plane light from a lookup table, the colormap
and status bar as strings made at load time, ...). Its `sql/renderer.sql` is
one statement with 7 parameters: map, player thing, skill and the camera pose.
Vendored as `lbdoom/renderer.sql` and `lbdoom/43_render_light.sql`, unchanged.

view_sql() turns it into our per-slot view api_frame_idx_slot<n>_m<map>: map
and player thing folded in, the skill read from mp_match (a level restart
changes it, no view rebuild), the pose read from the caller's seat in
mp_players (what api_camera writes), and the indexed output (palette byte +
one COLORMAP-mapped index per pixel, doom_sql.indexed_renderer in LBDoom).
A caller without the seat gets one NULL row, like our views.

Measured 2026-11-12 on a 24 CU branch, 7 E1M1 poses fed to both: frames
byte-identical to our views on 7/7, median 141-148 ms against 173-175 ms.
The low-detail views stay ours (derived from our indexed view before this
replaces it). DOOM_RENDERER=upstream keeps our views.
"""
import os
import re
from pathlib import Path

DIR = Path(os.getenv("DOOM_LBDOOM_DIR") or Path(__file__).resolve().parent.parent / "lbdoom")
ENABLED = os.getenv("DOOM_RENDERER", "lbdoom") == "lbdoom"
MARKER = "doom_zlight_lut()"          # in every view made here, in none of ours

_POSE = "SELECT $4::float8 AS x, $5::float8 AS y, $6::float8 AS z, $7::float8 AS angle"
# The other players drawn: a free slot's player is dead (doom_server opens 4
# slots), so every free start showed a corpse, e.g. 3 in single player. Only
# seated players, or alive ones, are drawn. Same text in upstream's renderer
# (our low-detail views, doomapp/referee.py frame_view_body).
OTHERS = "WHERE op.map_id = rc.map_id AND op.player_thing_id <> rc.player_thing_id"
OTHERS_SEATED = (OTHERS + " AND (op.alive OR EXISTS (SELECT 1 FROM mp_players mx WHERE mx.map_id = op.map_id"
                 " AND mx.player_thing_id = op.player_thing_id AND mx.role_name IS NOT NULL))")
_SKILL = "(SELECT mm.skill FROM mp_match mm LIMIT 1)"
_TAIL = "SELECT frame_rgb FROM frame"
# LBDoom doom_sql.indexed_renderer: palette indices instead of RGB
_INDEXED = (("ELSE cb.rgb || ''::bytea END AS b", "ELSE cb.idx || ''::bytea END AS b"),
            ("SELECT ub.rgb || ''::bytea AS b", "SELECT ub.idx || ''::bytea AS b"),
            ("'\\x000000'::bytea", "'\\x00'::bytea"))
_INDEXED_TAIL = ("SELECT CASE WHEN EXISTS (SELECT 1 FROM pos) THEN "
                 "(SELECT set_byte('\\x00'::bytea, 0, ap.pal::int) FROM active_palette ap) || frame_rgb "
                 "END AS frame_rgb FROM frame")

# LBDoom sql/schema.sql: COLORMAP x PLAYPAL and the static status bar, one
# string per palette, made once (the renderer reads them every frame).
_SUPPORT = (
    """CREATE MATERIALIZED VIEW IF NOT EXISTS ui_bar_bytes AS
    SELECT cm.pal,
           string_agg(cm.rgb, ''::bytea ORDER BY s.y, s.x) AS rgb,
           string_agg(set_byte('\\x00'::bytea, 0, s.palette_index::int), ''::bytea ORDER BY s.y, s.x) AS idx
    FROM ui_static_pixels s
    JOIN colormap_rgb cm ON cm.level = 0 AND cm.palette_index = s.palette_index
    GROUP BY cm.pal WITH NO DATA""",
    """CREATE MATERIALIZED VIEW IF NOT EXISTS colormap_bytes AS
    SELECT pal,
           CASE WHEN count(*) = (MAX(level) + 1) * 256 THEN
             string_agg(rgb, ''::bytea ORDER BY level, palette_index)
             || decode(repeat(encode('\\x000000'::bytea, 'hex'), (63 - MAX(level)) * 256), 'hex')
           END AS rgb,
           CASE WHEN count(*) = (MAX(level) + 1) * 256 THEN
             string_agg(set_byte('\\x00'::bytea, 0, mapped_index::int), ''::bytea ORDER BY level, palette_index)
             || decode(repeat(encode('\\x00'::bytea, 'hex'), (63 - MAX(level)) * 256), 'hex')
           END AS idx
    FROM colormap_rgb GROUP BY pal WITH NO DATA""",
    "CREATE INDEX IF NOT EXISTS idx_linedef_geom_map ON linedef_geom (map_id, linedef_id)",
    "CREATE INDEX IF NOT EXISTS idx_node_path_steps_map ON node_path_steps (map_id)",
    "CREATE INDEX IF NOT EXISTS idx_ui_hud_pixels_name ON ui_hud_pixels (name)",
)


def available():
    return ENABLED and (DIR / "renderer.sql").is_file() and (DIR / "43_render_light.sql").is_file()


def install_support(raw):
    """doom_zlight_lut (LBDoom's only new function; doom_light_index/scale
    are the same as ours, doom_light_zdepth gives the same values), the two
    strings and three indexes. Idempotent."""
    light = (DIR / "43_render_light.sql").read_text(encoding="utf-8")
    m = re.search(r"CREATE OR REPLACE FUNCTION doom_zlight_lut\(\).*?\$\$;", light, re.S)
    if not m:
        raise ValueError("43_render_light.sql: doom_zlight_lut not found")
    raw.execute(m.group(0))
    for sql in _SUPPORT:
        raw.execute(sql)
    for mv in ("ui_bar_bytes", "colormap_bytes"):
        raw.execute("SELECT ispopulated FROM pg_matviews WHERE schemaname = current_schema() AND matviewname = %s", (mv,))
        row = raw.fetchone()
        if row and not row[0]:
            raw.execute(f"REFRESH MATERIALIZED VIEW {mv}")
            raw.execute(f"ANALYZE {mv}")


def view_sql(map_id, slot, player_thing_id):
    """The SELECT of api_frame_idx_slot<slot>_m<map_id>, from renderer.sql."""
    body = (DIR / "renderer.sql").read_text(encoding="utf-8").strip().rstrip(";")
    for src, dst in _INDEXED:
        if src not in body:
            raise ValueError(f"renderer.sql lost the colour anchor {src[:40]!r}")
        body = body.replace(src, dst)
    for anchor in (_TAIL, _POSE, OTHERS):
        if body.count(anchor) != 1:
            raise ValueError(f"renderer.sql changed: {anchor[:40]!r}")
    m, s, t = int(map_id), int(slot), int(player_thing_id)
    body = body.replace(_TAIL, _INDEXED_TAIL).replace(OTHERS, OTHERS_SEATED)
    body = body.replace(_POSE, "SELECT mp.pose_x::float8 AS x, mp.pose_y::float8 AS y, mp.pose_z::float8 AS z, "
                               f"mp.pose_angle::float8 AS angle FROM mp_players mp WHERE mp.map_id = {m} "
                               f"AND mp.slot = {s} AND mp.role_name = doom_caller()")
    body = body.replace("$1::int", str(m)).replace("$2::int", str(t)).replace("$3::int", _SKILL)
    left = re.findall(r"\$\d", re.sub(r"\$\$.*?\$\$", "", body, flags=re.S))
    if left:
        raise ValueError(f"renderer.sql: parameters left {sorted(set(left))}")
    return body
