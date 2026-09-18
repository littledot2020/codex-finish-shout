"""Rebuild the original completion cues (Python standard library + ffmpeg).

MIDI files contain the editable melody; MP3 files render the same notes with a
small bell synthesizer so playback does not depend on a system MIDI sound bank.
"""
from pathlib import Path
import json
import math
import shutil
import struct
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[2]
DESTINATIONS = [ROOT / "codex-finish-shout/assets/music", ROOT / "codex-finish-shout-controls/assets/music"]
TRACKS = [
    ("soft-chime", "轻柔风铃", "Soft chime", [(76, .00, .42), (79, .34, .42), (84, .68, .82)], 2.4),
    ("bright-finish", "明亮完成", "Bright finish", [(72, .00, .22), (76, .20, .22), (79, .40, .22), (84, .60, .62)], 2.2),
    ("gentle-rise", "舒缓上扬", "Gentle rise", [(67, .00, .52), (72, .47, .52), (74, .94, .52), (79, 1.41, .80)], 3.2),
]


def variable_length(value):
    result = [value & 127]
    while value >> 7:
        value >>= 7
        result.insert(0, 128 | (value & 127))
    return bytes(result)


def midi_bytes(notes, name):
    # 480 ticks per quarter note, 120 BPM, General MIDI music-box instrument.
    name_bytes = name.encode("ascii")
    events = [(0, b"\xff\x51\x03\x07\xa1\x20"),
              (0, b"\xff\x03" + variable_length(len(name_bytes)) + name_bytes),
              (0, b"\xc0\x0a")]
    for pitch, start, duration in notes:
        events.extend([(round(start * 960), bytes([0x90, pitch, 78])),
                       (round((start + duration) * 960), bytes([0x80, pitch, 0]))])
    previous = 0
    track = bytearray()
    for timestamp, event in sorted(events, key=lambda value: value[0]):
        track.extend(variable_length(timestamp - previous) + event)
        previous = timestamp
    track.extend(b"\x00\xff\x2f\x00")
    return b"MThd" + struct.pack(">IHHH", 6, 0, 1, 480) + b"MTrk" + struct.pack(">I", len(track)) + track


def write_wave(target, notes, duration):
    sample_rate = 44100
    samples = [0.0] * round(duration * sample_rate)
    for pitch, start, note_duration in notes:
        frequency = 440 * 2 ** ((pitch - 69) / 12)
        begin = round(start * sample_rate)
        end = min(len(samples), begin + round((note_duration + .62) * sample_rate))
        for index in range(begin, end):
            t = (index - begin) / sample_rate
            attack = min(1.0, t / .012)
            decay = math.exp(-3.8 * t)
            release = min(1.0, max(0.0, (note_duration + .62 - t) / .18))
            tone = (math.sin(2 * math.pi * frequency * t)
                    + .22 * math.sin(2 * math.pi * frequency * 2 * t)
                    + .08 * math.sin(2 * math.pi * frequency * 3 * t))
            samples[index] += tone * attack * decay * release * .32
    with wave.open(str(target), "wb") as output:
        output.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
        output.writeframes(b"".join(struct.pack("<h", round(max(-.95, min(.95, value)) * 32767)) for value in samples))


def main():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required only when rebuilding the bundled MP3 assets.")
    for destination in DESTINATIONS:
        destination.mkdir(parents=True, exist_ok=True)
    catalog = []
    with tempfile.TemporaryDirectory(prefix="codex-completion-cues-") as temporary:
        for track_id, zh, en, notes, duration in TRACKS:
            wave_path = Path(temporary) / (track_id + ".wav")
            write_wave(wave_path, notes, duration)
            mp3 = DESTINATIONS[0] / (track_id + ".mp3")
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(wave_path),
                            "-codec:a", "libmp3lame", "-b:a", "128k", "-map_metadata", "-1",
                            "-metadata", "artist=Codex Finish Shout", "-metadata", "title=" + en,
                            str(mp3)], check=True, timeout=60)
            midi = midi_bytes(notes, en)
            for destination in DESTINATIONS:
                (destination / (track_id + ".mid")).write_bytes(midi)
                if destination != DESTINATIONS[0]:
                    shutil.copyfile(mp3, destination / mp3.name)
            catalog.append(dict(id=track_id, zh=zh, en=en, seconds=duration, mp3=track_id + ".mp3", midi=track_id + ".mid"))
    for destination in DESTINATIONS:
        (destination / "catalog.json").write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (destination / "LICENSE.txt").write_text(
            "Codex Finish Shout original completion cues\n\n"
            "These three short melodies, their synthesized MP3 recordings, and MIDI files\n"
            "were created for this project. They may be used, copied, modified, and\n"
            "redistributed with or without this plugin, without charge or attribution.\n"
            "Provided without warranty. No third-party recordings or samples are used.\n",
            encoding="utf-8")
    print("Generated 3 original MP3 cues and 3 MIDI sources in both plugin packages.")


if __name__ == "__main__":
    main()
