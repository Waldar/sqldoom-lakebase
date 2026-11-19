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
import time
from concurrent.futures import ProcessPoolExecutor

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
    cur = conn.cursor()
    cur.execute("SET search_path = doom, public")
    cur.execute("""SELECT a.name, a.midi_data FROM music_assets a
                   WHERE a.name IN (SELECT music_name FROM map_music) %s ORDER BY a.name"""
                % ("" if args.all else "AND a.audio_data IS NULL"))
    todo = [(name, bytes(data)) for name, data in cur.fetchall()]
    if not todo:
        print("every track the maps use has audio already")
        return
    print(f"rendering {len(todo)} tracks with {midi.soundfont()} ...", flush=True)
    t0 = time.time()
    with ProcessPoolExecutor() as pool:
        audio = dict(zip([n for n, _ in todo], pool.map(midi.render, [m for _, m in todo])))
    done = [(n, a) for n, a in audio.items() if a]
    for name, data in done:
        cur.execute("UPDATE music_assets SET audio_data = %s, audio_format = %s WHERE name = %s",
                    (psycopg2.Binary(data), midi.AUDIO_FORMAT, name))
    conn.commit()
    failed = sorted(n for n, a in audio.items() if not a)
    print(f"rendered {len(done)} of {len(todo)} tracks in {time.time() - t0:.0f} s, "
          f"{sum(len(a) for _, a in done) // 1024} KB" + (f"; failed: {', '.join(failed)}" if failed else ""))
    conn.close()
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
