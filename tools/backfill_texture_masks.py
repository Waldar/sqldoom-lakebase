"""Add what a database loaded before migration 0007 lacks, from the WAD.

    PYTHONPATH=src python tools/backfill_texture_masks.py \
        --endpoint projects/sqldoom/branches/game-template/endpoints/primary \
        --wad /Volumes/<catalog>/<schema>/<volume>/DOOM1.WAD

* walltex_meta.mask, the coverage of the see-through textures (the grates):
  without it the renderer draws them opaque, their holes black.
* the STFKILL0-4 face patches (ui_patches), which the loader did not load
  before: Doom's face shows them when hit head-on or holding fire.

Data, not code: the installer adds the column, not its content. Run it on
game-template (new games copy it) and on production (a future template is
made from it), after the installer has added migration 0007. It can run
again. The WAD loader itself (sqldoom.wad.loader) fills both.
"""
import argparse
import sys

import psycopg2
from psycopg2.extras import execute_values

from sqldoom.lakebase.connection import CREDS
from sqldoom.wad import loader
from sqldoom.wad.catalogs import materialize_ui_pixels

FACES = tuple(f"STFKILL{i}" for i in range(5))


def backfill(cur, wad_path, log=print):
    cur.execute("SELECT 1 FROM information_schema.columns WHERE table_schema = 'doom' "
                "AND table_name = 'walltex_meta' AND column_name = 'mask'")
    if cur.fetchone() is None:
        raise SystemExit("walltex_meta.mask is missing: install the database code first (migration 0007)")
    with open(wad_path, "rb") as fp:
        _, lumps = loader.parse_wad(fp)
        walltex, _ = loader.composite_wall_textures(fp, lumps)
        faces, face_pixels, missing = loader.decode_ui_patches(fp, lumps, FACES)
    cur.execute("SELECT name, width, height, palette_indices FROM walltex_meta")
    stored = {n: (w, h, bytes(p)) for n, w, h, p in cur.fetchall()}
    masked = 0
    for name, w, h, tex, mask in walltex:
        if stored.get(name) != (w, h, tex):
            # a texture this WAD does not hold as stored: not this WAD's, leave it
            continue
        cur.execute("UPDATE walltex_meta SET mask = %s WHERE name = %s AND mask IS DISTINCT FROM %s",
                    (psycopg2.Binary(mask) if mask else None, name, psycopg2.Binary(mask) if mask else None))
        masked += mask is not None
    log(f"walltex_meta: {masked} see-through textures masked, of {len(walltex)} in the WAD")
    cur.execute("SELECT name FROM ui_patches WHERE name = ANY(%s)", (list(FACES),))
    have = {r[0] for r in cur.fetchall()}
    rows = [r for r in faces if r[0] not in have]
    if rows:
        execute_values(cur, "INSERT INTO ui_patches (name, width, height, left_offset, top_offset, pixels, mask) VALUES %s",
                       rows)
        execute_values(cur, "INSERT INTO ui_patch_pixels (name, dx, dy, palette_index) VALUES %s",
                       [p for p in face_pixels if p[0] not in have], page_size=5000)
        materialize_ui_pixels(cur)
    log(f"ui_patches: {len(rows)} face patches added ({', '.join(r[0] for r in rows) or 'none missing'})"
        + (f"; not in the WAD: {', '.join(missing)}" if missing else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--endpoint", required=True, help="projects/<p>/branches/<b>/endpoints/<e>")
    ap.add_argument("--wad", required=True, help="path to DOOM1.WAD (or DOOM.WAD)")
    ap.add_argument("--role", default="doom_owner")
    args = ap.parse_args()
    conn = psycopg2.connect(CREDS.dsn(args.endpoint, application_name="backfill-masks", role=args.role))
    try:
        cur = conn.cursor()
        cur.execute("SET search_path = doom, public")
        backfill(cur, args.wad, log=lambda m: print(m, flush=True))
        conn.commit()
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
