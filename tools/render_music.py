"""Render the music tracks that have no audio yet, on one branch.

    pip install --no-deps tinysoundfont && pip install soundfile numpy
    # (--no-deps: its pyaudio dependency, for live playback only, needs
    #  PortAudio to build; the x86 Linux wheel of tinysoundfont itself is prebuilt)
    PYTHONPATH=src DOOM_SOUNDFONT=/Volumes/<catalog>/<schema>/<volume>/TimGM6mb.sf2 \
        python tools/render_music.py --endpoint projects/sqldoom/branches/game-template/endpoints/primary

The WAD loader renders the tracks itself when it can (sqldoom.wad.midi);
this is for a branch loaded without a renderer (music_assets.audio_data
NULL, the page then plays no music). Only the tracks the maps use
(map_music), only those without audio: it can run again. Data, not code:
the installer never touches music_assets, so render on game-template (new
games copy it) and on production (a future template is made from it).
"""
import argparse
import sys

import psycopg2

from sqldoom.lakebase.connection import CREDS
from sqldoom.wad import midi


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--endpoint", required=True, help="projects/<p>/branches/<b>/endpoints/<e>")
    ap.add_argument("--role", default="doom_owner")
    ap.add_argument("--all", action="store_true", help="render every track the maps use, even those with audio")
    args = ap.parse_args()
    why = midi.unavailable_reason()
    if why:
        sys.exit(f"cannot render: {why}")
    conn = psycopg2.connect(CREDS.dsn(args.endpoint, application_name="render-music", role=args.role))
    try:
        cur = conn.cursor()
        cur.execute("SET search_path = doom, public")
        _, failed = midi.render_missing(cur, every=args.all, log=lambda m: print(m, flush=True))
        conn.commit()
    finally:
        conn.close()
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
