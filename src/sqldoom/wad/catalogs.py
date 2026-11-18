"""The game's definitions (sql/seed/) and what the loader derives from the WAD data."""

from functools import cache

from sqldoom.db import SQL_ROOT

SEED = SQL_ROOT / "seed"
# In this order; demo_data.sql is optional (see load_game_data).
SEED_FILES = ("game_data.sql", "menu_data.sql", "rules.sql")
# Every materialized view, in dependency order (ui_bar_bytes reads ui_static_pixels).
# In refresh order: ui_hud_runs reads ui_hud_pixels and colormap_rgb,
# sprite_rotations sprite_frames.
MATVIEWS = ("linedef_geom", "sector_adjacency", "node_path_steps", "ui_hud_pixels",
            "ui_static_pixels", "ui_bar_bytes", "colormap_bytes", "ui_hud_runs", "sprite_rotations")


@cache
def load_sql(filename):
    return (SEED / filename).read_text(encoding="utf-8")


def load_game_data(cur):
    """The game's definitions: things, weapons, line specials, menus, the
    constants (TICRATE ...) and each mode's default rules."""
    for filename in SEED_FILES:
        cur.execute(load_sql(filename))
    # Recorded demos are not in the tree: a demo is an input stream the world
    # is recomputed from, so it only replays while the simulation it was
    # recorded against is unchanged, and gameplay fixes retire it. Without
    # sql/seed/demo_data.sql the attract loop shows the title pages and
    # nothing else changes.
    if (SEED / "demo_data.sql").exists():
        cur.execute(load_sql("demo_data.sql"))


def stamp_line_specials(cur):
    """Copy the catalogue's hot-path flags onto every linedef."""
    cur.execute("""
        UPDATE linedefs ld
        SET cross_activated   = d.cross_activated,
            cross_once        = d.cross_once,
            monster_crossable = d.monster_crossable,
            scrolls           = d.scrolls
        FROM line_special_defs d
        WHERE d.special = ld.special
          AND (ld.cross_activated   <> d.cross_activated
            OR ld.cross_once        <> d.cross_once
            OR ld.monster_crossable <> d.monster_crossable
            OR ld.scrolls           <> d.scrolls)
    """)


def materialize_render_segs(cur, map_id):
    cur.execute("SELECT doom_materialize_render_segs(%s)", (map_id,))
    cur.fetchone()


def refresh_derived(cur):
    """Every materialized view, from the data now loaded."""
    for view in MATVIEWS:
        cur.execute(f"REFRESH MATERIALIZED VIEW {view}")


def derive_colormap_bytes(cur):
    """colormap_idx_lvl: per palette and light level, the 256 mapped palette
    indices as one small bytea (frames look a pixel's colour up in it). Small
    rows on purpose: one 8.7 KB string per palette is TOASTed and was read
    again for every pixel (+225 ms per frame)."""
    cur.execute("DELETE FROM colormap_idx_lvl")
    cur.execute("INSERT INTO colormap_idx_lvl (pal, level, bytes) "
                "SELECT pal, level, string_agg(set_byte('\\x00'::bytea, 0, mapped_index::int), ''::bytea "
                "ORDER BY palette_index) FROM colormap_rgb GROUP BY pal, level")


def create_frame_views(cur):
    """The per-player frame views of every loaded map (sql/frame_views)."""
    cur.execute("SELECT doom.create_frame_views()")
    return cur.fetchone()[0]


def materialize_ui_pixels(cur):
    cur.execute("REFRESH MATERIALIZED VIEW ui_hud_pixels")
    cur.execute("REFRESH MATERIALIZED VIEW ui_static_pixels")


def materialize_render_things(cur, map_id=None):
    if map_id is None:
        cur.execute("SELECT doom_materialize_all_render_things()")
    else:
        cur.execute("SELECT doom_materialize_render_things(%s)", (map_id,))
    cur.fetchone()
