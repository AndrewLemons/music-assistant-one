#!/usr/bin/env python3
"""Synthesize the review server's sample library: original, deterministic, and rights-free.

  samples.py OUTPUT_DIR

Writes one album ("Review Samples" by Various Artists, with cover art) of short instrumental
tracks as tagged FLAC, plus two .m3u playlists that Music Assistant's local-files provider
imports. Needs only Python and FFmpeg, both present in the server image.
"""
import math
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import wave

RATE = 44100
ALBUM = "Review Samples"
ALBUM_ARTIST = "Various Artists"
# (title, artist, tempo, key root in Hz, chord progression as semitone offsets, seconds)
TRACKS = [
    ("Harbor Lights", "The Lemon Trees", 92, 220.00, [(0, 4, 7), (-3, 0, 4), (5, 9, 12), (7, 11, 14)], 40),
    ("Slow Tide", "Morning Ensemble", 72, 196.00, [(0, 3, 7), (5, 8, 12), (-2, 2, 5), (3, 7, 10)], 40),
    ("Paper Kites", "Northbound", 112, 246.94, [(0, 4, 7), (7, 11, 14), (9, 12, 16), (5, 9, 12)], 36),
    ("Evening Bells", "Morning Ensemble", 84, 174.61, [(0, 4, 7), (4, 7, 11), (5, 9, 12), (2, 5, 9)], 40),
]
PLAYLISTS = {"Morning Mix": [1, 0, 2], "Evening Mix": [3, 1]}


def note(root, semitones):
    return root * 2 ** (semitones / 12)


def render(tempo, root, progression, seconds, seed):
    """A gentle arpeggiated pad: soft sine voices with a plucked envelope and a bass note."""
    rng = random.Random(seed)
    beat = 60 / tempo
    frames = int(seconds * RATE)
    left, right = [0.0] * frames, [0.0] * frames
    step = beat / 2
    steps = int(seconds / step)
    for index in range(steps):
        chord = progression[(index // 8) % len(progression)]
        pitch = note(root, chord[index % 3] + 12 * (1 if index % 6 >= 3 else 0))
        pan = 0.5 + 0.35 * math.sin(index * 0.7 + seed)
        start = int(index * step * RATE)
        length = int(min(step * 3, seconds - index * step) * RATE)
        velocity = 0.18 + 0.04 * rng.random()
        for n in range(length):
            t = n / RATE
            envelope = math.exp(-3.2 * t) * min(1.0, t * 200)
            sample = velocity * envelope * (math.sin(2 * math.pi * pitch * t) + 0.3 * math.sin(4 * math.pi * pitch * t))
            left[start + n] += sample * (1 - pan)
            right[start + n] += sample * pan
        if index % 8 == 0:  # Bass on each bar.
            bass = note(root, chord[0] - 12)
            for n in range(min(int(beat * 4 * RATE), frames - start)):
                t = n / RATE
                sample = 0.16 * math.exp(-1.1 * t) * min(1.0, t * 80) * math.sin(2 * math.pi * bass * t)
                left[start + n] += sample
                right[start + n] += sample
    fade = int(2.5 * RATE)
    peak = max(max(abs(x) for x in left), max(abs(x) for x in right)) or 1.0
    data = bytearray()
    for n in range(frames):
        gain = 0.85 / peak * min(1.0, n / (0.05 * RATE), (frames - n) / fade)
        for value in (left[n] * gain, right[n] * gain):
            data += int(max(-1.0, min(1.0, value)) * 32767).to_bytes(2, "little", signed=True)
    return bytes(data)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    output = Path(sys.argv[1])
    album = output / ALBUM
    album.mkdir(parents=True, exist_ok=True)
    cover = album / "cover.jpg"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "gradients=s=800x800:c0=0xF6C744:c1=0xE8613C:c2=0x3B5BA5:n=3:seed=7:duration=1",
                    "-frames:v", "1", "-q:v", "3", str(cover)], check=True)
    names = []
    with tempfile.TemporaryDirectory() as temporary:
        for number, (title, artist, tempo, root, progression, seconds) in enumerate(TRACKS, start=1):
            raw = Path(temporary, f"{number}.wav")
            with wave.open(str(raw), "wb") as file:
                file.setnchannels(2)
                file.setsampwidth(2)
                file.setframerate(RATE)
                file.writeframes(render(tempo, root, progression, seconds, seed=number))
            name = f"{number:02d} - {title}.flac"
            metadata = {"title": title, "artist": artist, "album": ALBUM, "album_artist": ALBUM_ARTIST,
                        "track": f"{number}/{len(TRACKS)}", "disc": "1/1", "date": "2026", "genre": "Ambient",
                        "copyright": "Original synthesized sample for Music Assistant One review"}
            arguments = [arg for key, value in metadata.items() for arg in ("-metadata", f"{key}={value}")]
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(raw), "-i", str(cover), "-map", "0:a", "-map", "1:v",
                            "-c:a", "flac", "-c:v", "mjpeg", "-disposition:v", "attached_pic", *arguments,
                            str(album / name)], check=True)
            names.append(name)
    for playlist, order in PLAYLISTS.items():
        lines = ["#EXTM3U"] + [f"{ALBUM}/{names[index]}" for index in order]
        (output / f"{playlist}.m3u").write_text("\n".join(lines) + "\n")
    print(f"Wrote {len(names)} tracks and {len(PLAYLISTS)} playlists to {output}")


if __name__ == "__main__":
    main()
