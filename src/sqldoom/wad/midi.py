"""Render Doom's MIDI music to compressed audio (Ogg Vorbis).

Two ways, the first that is installed wins (as LBDoom's midi_render.py,
2026-11-17):

* fluidsynth and ffmpeg, from the system's packages;
* the tinysoundfont and soundfile packages from pip (prebuilt for x86 Linux,
  so on this workspace's serverless compute: pip install --no-deps
  tinysoundfont && pip install soundfile numpy; without --no-deps pip tries
  to build its pyaudio dependency, for live playback only, which needs
  PortAudio).

Either needs a General MIDI soundfont: DOOM_SOUNDFONT names one (for
example a .sf2 in a Unity Catalog volume next to DOOM1.WAD), or one of the
system paths below. tools/render_music.py renders a branch's tracks.
"""
import ctypes
import io
import os
import shutil
import subprocess
import tempfile

# Ubuntu/Debian ship these with fluidsynth's runtime; the first that exists
# wins. TimGM6mb is the smaller of the two and quite close to the FM-ish
# character of the original.
SOUNDFONTS = (
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/soundfonts/FluidR3_GM.sf2",
)

SAMPLE_RATE = 22050.0
GAIN = 0.6
# Vorbis quality 1 at 22 kHz mono is about 110 kbit/s: a Doom track lands
# around 200-300 KB, so the whole soundtrack is under 10 MB.
VORBIS_QUALITY = "1"
AUDIO_FORMAT = "ogg"

FLUID_PLAYER_PLAYING = 1
_MAX_BLOCKS = 200000  # ~10 minutes at 64 samples a block; a stuck loop cannot run away

_PROTOTYPES = (
    ("new_fluid_settings", ctypes.c_void_p, []),
    ("new_fluid_synth", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_player", ctypes.c_void_p, [ctypes.c_void_p]),
    ("new_fluid_file_renderer", ctypes.c_void_p, [ctypes.c_void_p]),
    ("fluid_synth_sfload", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("fluid_player_add_mem", ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
    ("fluid_player_play", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_player_get_status", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_file_renderer_process_block", ctypes.c_int, [ctypes.c_void_p]),
    ("fluid_settings_setstr", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
    ("fluid_settings_setnum", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_double]),
    ("fluid_settings_setint", ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]),
    ("delete_fluid_file_renderer", None, [ctypes.c_void_p]),
    ("delete_fluid_player", None, [ctypes.c_void_p]),
    ("delete_fluid_synth", None, [ctypes.c_void_p]),
    ("delete_fluid_settings", None, [ctypes.c_void_p]),
)


def _load_library():
    for name in ("libfluidsynth.so.3", "libfluidsynth.so.2", "libfluidsynth.so"):
        try:
            lib = ctypes.CDLL(name)
        except OSError:
            continue
        try:
            for fn, restype, argtypes in _PROTOTYPES:
                func = getattr(lib, fn)
                func.restype = restype
                func.argtypes = argtypes
        except AttributeError:
            continue
        return lib
    return None


def soundfont():
    for path in (os.getenv("DOOM_SOUNDFONT"), *SOUNDFONTS):
        if path and os.path.isfile(path):
            return path
    return None


def _pip_modules():
    try:
        import numpy
        import soundfile
        import tinysoundfont
    except ImportError:
        return None
    return numpy, soundfile, tinysoundfont


def _fluidsynth():
    lib = _load_library()
    return lib if lib is not None and shutil.which("ffmpeg") is not None else None


def unavailable_reason():
    """Why rendering cannot run, or None when it can."""
    if soundfont() is None:
        return "no General MIDI soundfont (set DOOM_SOUNDFONT to a .sf2)"
    if _fluidsynth() is None and _pip_modules() is None:
        return "neither fluidsynth and ffmpeg nor the tinysoundfont and soundfile packages found"
    return None


def _render_wav(lib, midi, sf2, wav_path):
    settings = lib.new_fluid_settings()
    synth = player = renderer = None
    try:
        lib.fluid_settings_setstr(settings, b"audio.file.name", wav_path.encode())
        lib.fluid_settings_setstr(settings, b"audio.file.type", b"wav")
        # Drive the clock off the samples produced, not the wall clock, or the
        # render takes as long as the track does.
        lib.fluid_settings_setstr(settings, b"player.timing-source", b"sample")
        lib.fluid_settings_setint(settings, b"synth.lock-memory", 0)
        lib.fluid_settings_setnum(settings, b"synth.sample-rate", SAMPLE_RATE)
        lib.fluid_settings_setint(settings, b"synth.audio-channels", 1)
        lib.fluid_settings_setnum(settings, b"synth.gain", GAIN)
        synth = lib.new_fluid_synth(settings)
        if not synth or lib.fluid_synth_sfload(synth, sf2.encode(), 1) < 0:
            return False
        player = lib.new_fluid_player(synth)
        if not player:
            return False
        buf = ctypes.create_string_buffer(midi, len(midi))
        if lib.fluid_player_add_mem(player, buf, len(midi)) != 0:
            return False
        lib.fluid_player_play(player)
        renderer = lib.new_fluid_file_renderer(synth)
        if not renderer:
            return False
        blocks = 0
        while lib.fluid_player_get_status(player) == FLUID_PLAYER_PLAYING:
            if lib.fluid_file_renderer_process_block(renderer) != 0:
                break
            blocks += 1
            if blocks >= _MAX_BLOCKS:
                break
        return blocks > 0
    finally:
        if renderer:
            lib.delete_fluid_file_renderer(renderer)
        if player:
            lib.delete_fluid_player(player)
        if synth:
            lib.delete_fluid_synth(synth)
        lib.delete_fluid_settings(settings)


def render(midi):
    """MIDI bytes -> Ogg Vorbis bytes, or None when it could not be rendered."""
    sf2 = soundfont()
    if sf2 is None:
        return None
    lib = _fluidsynth()
    if lib is not None:
        return _render_fluidsynth(lib, midi, sf2)
    if _pip_modules() is not None:
        return _render_tinysoundfont(midi, sf2)
    return None


def _render_tinysoundfont(midi, sf2):
    """TinySoundFont plays the MIDI on the soundfont; libsndfile encodes it."""
    numpy, soundfile, tinysoundfont = _pip_modules()
    from tinysoundfont.midi import load_memory
    rate = int(SAMPLE_RATE)
    synth = tinysoundfont.Synth(samplerate=rate)
    sfid = synth.sfload(sf2)
    for channel in range(16):
        # MIDI channel 10 (9 counting from zero) is General MIDI's percussion.
        synth.program_select(channel, sfid, 0, 0, channel == 9)
    sequencer = tinysoundfont.Sequencer(synth)
    sequencer.add(load_memory(bytes(midi)))
    block = rate // 10
    out, blocks = io.BytesIO(), 0
    # A block at a time: libsndfile's Vorbis encoder crashes on a whole
    # track in one write (LBDoom).
    with soundfile.SoundFile(out, mode="w", samplerate=rate, channels=1,
                             format="OGG", subtype="VORBIS") as ogg:
        while not sequencer.is_empty() and blocks < 600 * 10:  # 10 minutes at most
            stereo = numpy.frombuffer(synth.generate(block), dtype=numpy.float32).reshape(-1, 2)
            # Mono like the fluidsynth render, at its gain; a few tracks would clip.
            ogg.write(numpy.clip(stereo.mean(axis=1) * GAIN, -1.0, 1.0))
            blocks += 1
    return out.getvalue() if blocks else None


def _render_fluidsynth(lib, midi, sf2):
    with tempfile.TemporaryDirectory(prefix="doom-music-") as tmp:
        wav = os.path.join(tmp, "track.wav")
        ogg = os.path.join(tmp, "track.ogg")
        try:
            if not _render_wav(lib, midi, sf2, wav):
                return None
            if not os.path.isfile(wav) or os.path.getsize(wav) < 64:
                return None
            result = subprocess.run(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-i", wav, "-c:a", "libvorbis", "-q:a", VORBIS_QUALITY,
                 "-ac", "1", ogg],
                capture_output=True, timeout=300,
            )
            if result.returncode != 0 or not os.path.isfile(ogg):
                return None
            with open(ogg, "rb") as handle:
                return handle.read()
        except (OSError, subprocess.SubprocessError):
            return None
