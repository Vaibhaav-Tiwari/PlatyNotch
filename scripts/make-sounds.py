#!/usr/bin/env python3
"""Generates PlatyNotch's sounds (original, CC0 / public domain dedication).

Writes apps/mac/Sources/PlatyNotchUI/Resources/Sounds/{alarm,chime,plip}.wav: pure tones
made from sine waves with simple envelopes, nothing sampled and nothing imitated. plip.wav is
"Platy chatter", the optional sound when an agent needs you: a few soft rising chirps and a
short purr, about half a second. Deterministic: running it again
writes the same bytes. Usage: scripts/make-sounds.py
"""
import math
import os
import struct
import wave

RATE = 22050
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "apps", "mac", "Sources", "PlatyNotchUI", "Resources", "Sounds")


def tone(freqs, seconds, attack=0.01, decay=6.0, volume=0.5):
    """Sum of sines (freq, weight) with a short attack and an exponential decay."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack) * math.exp(-decay * t)
        s = sum(w * math.sin(2 * math.pi * f * t) for f, w in freqs)
        out.append(volume * env * s)
    return out


def chirp(f0, f1, seconds, volume):
    """A sine sweeping f0 -> f1 under a raised-cosine envelope (no clicks), a touch of 2nd harmonic."""
    n = int(RATE * seconds)
    out = []
    phase = 0.0
    for i in range(n):
        x = i / max(1, n - 1)
        f = f0 + (f1 - f0) * x
        phase += 2 * math.pi * f / RATE
        env = 0.5 - 0.5 * math.cos(2 * math.pi * x)
        out.append(volume * env * (math.sin(phase) + 0.15 * math.sin(2 * phase)))
    return out


def purr(freq, seconds, rate_hz, volume):
    """A short trill: a soft tone fluttering at rate_hz, fading out."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        x = i / max(1, n - 1)
        flutter = 0.55 + 0.45 * math.sin(2 * math.pi * rate_hz * t)
        env = min(1.0, t / 0.015) * (1 - x) ** 1.5
        out.append(volume * env * flutter * math.sin(2 * math.pi * freq * t))
    return out


def silence(seconds):
    return [0.0] * int(RATE * seconds)


def write(name, samples):
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = 0.85 / peak if peak > 0.85 else 1.0
    frames = b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    print(f"{path}: {len(samples) / RATE:.2f} s")


def main():
    os.makedirs(OUT, exist_ok=True)
    # Alarm: two bright double beeps, then a pause; loops while ringing.
    beep = tone([(1046.5, 1.0), (2093.0, 0.25)], 0.12, attack=0.005, decay=4.0)
    alarm = beep + silence(0.08) + beep + silence(0.35) + beep + silence(0.08) + beep + silence(0.6)
    write("alarm.wav", alarm)
    # Chime (timers): a soft rising C-E-G bell with a long tail.
    chime = []
    for k, f in enumerate([523.25, 659.25, 783.99]):
        note = tone([(f, 1.0), (2 * f, 0.3), (3 * f, 0.1)], 1.4 - 0.18 * k, decay=3.2, volume=0.45)
        start = int(RATE * 0.18 * k)
        if len(chime) < start + len(note):
            chime.extend([0.0] * (start + len(note) - len(chime)))
        for i, s in enumerate(note):
            chime[start + i] += s
    write("chime.wav", chime + silence(0.4))
    # Platy chatter: four quick chirps stepping gently down, then a short purr. Kept soft
    # (peak about -8 dBFS); the app also plays it at a moderate volume.
    chatter = []
    for k, (f0, f1, amp) in enumerate([(1650, 2250, 0.40), (1600, 2150, 0.34), (1700, 2300, 0.36), (1500, 2000, 0.28)]):
        chatter += chirp(f0, f1, 0.045 if k < 3 else 0.055, amp) + silence(0.03)
    chatter += purr(1850, 0.15, 32, 0.22) + silence(0.04)
    write("plip.wav", chatter)


if __name__ == "__main__":
    main()
