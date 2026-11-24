#!/usr/bin/env python3
"""Generate the app's attention sounds (original synthesis, no samples).

    scripts/make-attention-sounds.py   # writes App/AISessionRemote/Resources/Sounds/*.caf

Six sounds, each a "needs you" and a "ready for review":
  Standard   a bell: one soft note for review, a brighter rising two-note chime for needs you
  Neon noir  a filtered, detuned synth arpeggio, and a soft blip with a stereo echo
  Phosphor   clean terminal beeps

Quality: 48 kHz, 24-bit stereo CAF. Oscillators are band-limited (additive, no partials above
Nyquist, so no aliasing buzz), attacks are smoothed (no clicks), and every sound goes through
a short stereo room so it isn't dry. Peaks sit at -6 dBFS, like before, so loudness matches.
The same files serve the Mac chimes and banners, iPhone notifications and pushes.

Needs numpy, scipy and `afconvert` (macOS).
"""
import os
import subprocess
import tempfile
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

RATE = 48000
NYQUIST = RATE / 2
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "AISessionRemote", "Resources", "Sounds")
rng = np.random.default_rng(7)  # fixed seed: the files are reproducible


def timeline(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def smooth_attack(t, attack):
    """A raised-cosine fade-in: no click at the start of a note."""
    return np.where(t < attack, 0.5 - 0.5 * np.cos(np.pi * np.clip(t / attack, 0, 1)), 1.0)


def additive(t, freq, partials, detune_cents=0.0):
    """Sum of `(ratio, amp, decay)` partials, skipping any at or above Nyquist."""
    f = freq * 2 ** (detune_cents / 1200)
    out = np.zeros_like(t)
    for ratio, amp, decay in partials:
        if f * ratio >= NYQUIST * 0.95:
            continue
        phase = rng.uniform(0, 2 * np.pi)
        out += amp * np.exp(-decay * t) * np.sin(2 * np.pi * f * ratio * t + phase)
    return out


def saw_partials(freq, decay=0.0):
    """A band-limited sawtooth: harmonics 1/n."""
    n_max = int(NYQUIST * 0.95 // freq)
    return [(n, 1.0 / n, decay) for n in range(1, n_max + 1)]


def square_partials(freq, decay=0.0, rolloff=1.0):
    """A band-limited square: odd harmonics 1/n, with an extra gentle roll-off above 4 kHz so the
    beep is clean rather than shrill."""
    n_max = int(NYQUIST * 0.95 // freq)
    out = []
    for n in range(1, n_max + 1, 2):
        soften = 1.0 / (1.0 + (freq * n / 4000.0) ** (2 * rolloff))
        out.append((n, soften / n, decay))
    return out


def place(buffer, note, start):
    """Mix a mono `note` into the stereo `buffer` at `start` seconds, with a pan (-1..1)."""
    sound, pan = note
    i = int(start * RATE)
    end = min(len(buffer), i + len(sound))
    left = np.cos((pan + 1) * np.pi / 4)
    right = np.sin((pan + 1) * np.pi / 4)
    buffer[i:end, 0] += sound[: end - i] * left
    buffer[i:end, 1] += sound[: end - i] * right


def bell(freq, length, brightness, pan=0.0):
    """A struck glass bell: slightly inharmonic partials, the high ones dying first, a soft
    mallet, and two copies a few cents apart for a gentle shimmer."""
    t = timeline(length)
    partials = [
        (1.0, 1.0, 3.2),
        (2.0, 0.42 * brightness, 5.5),
        (2.76, 0.22 * brightness, 8.0),
        (4.07, 0.10 * brightness, 12.0),
        (5.40, 0.05 * brightness, 16.0),
        (0.5, 0.06, 2.5),  # a quiet hum underneath for body
    ]
    tone = additive(t, freq, partials, -2.0) + additive(t, freq, partials, 2.0)
    return tone * smooth_attack(t, 0.004) * 0.5, pan


def synth(freq, length, cutoff_from, cutoff_to, pan=0.0, detune=7.0):
    """Two detuned band-limited saws through a falling low-pass (applied per harmonic, so it
    is exact and alias-free), with a soft attack and a smooth decay."""
    t = timeline(length)
    out = np.zeros_like(t)
    for cents in (-detune, detune):
        f = freq * 2 ** (cents / 1200)
        cutoff = cutoff_from * (cutoff_to / cutoff_from) ** (t / length)
        for ratio, amp, _ in saw_partials(f):
            h = f * ratio
            gain = 1.0 / np.sqrt(1.0 + (h / cutoff) ** 4)  # 2-pole low-pass response
            out += amp * gain * np.sin(2 * np.pi * h * t + rng.uniform(0, 2 * np.pi))
    env = smooth_attack(t, 0.006) * np.exp(-4.5 * t / length)
    return out * env * 0.5, pan


def beep(freq, length, pan=0.0):
    """A clean terminal beep: a softened band-limited square, held flat, with 8 ms edges."""
    t = timeline(length)
    tone = additive(t, freq, square_partials(freq, rolloff=1.2))
    edge = 0.008
    env = smooth_attack(t, edge) * np.clip((length - t) / edge, 0, 1)
    return tone * env, pan


def room(stereo, size, mix):
    """A small stereo room: decorrelated, exponentially decaying, darkened noise per side."""
    n = int(RATE * size)
    t = np.arange(n) / RATE
    darken = butter(2, 5000, "low", fs=RATE, output="sos")
    out = np.zeros((len(stereo) + n - 1, 2))
    for ch in range(2):
        ir = sosfilt(darken, rng.standard_normal(n)) * np.exp(-6.9 * t / size)  # -60 dB at `size`
        ir[: int(RATE * 0.004)] = 0  # pre-delay
        ir /= np.sqrt(np.sum(ir ** 2))
        out[:, ch] = fftconvolve(stereo[:, ch], ir)
    dry = np.zeros_like(out)
    dry[: len(stereo)] = stereo
    return dry * (1 - mix) + out * mix


def render(name, notes, total, room_size=0.6, room_mix=0.18, echo=None):
    """`notes` is a list of (start seconds, (mono note, pan)). `echo` = (delay, feedback): a
    ping-pong echo between the two sides."""
    buffer = np.zeros((int(RATE * total), 2))
    for start, note in notes:
        place(buffer, note, start)
    if echo:
        delay, feedback = echo
        d = int(RATE * delay)
        for k in range(1, 5):
            gain = feedback ** k
            side = k % 2  # alternate sides
            shifted = np.zeros(len(buffer))
            shifted[d * k:] = buffer[: len(buffer) - d * k].sum(axis=1)[: max(0, len(buffer) - d * k)] * 0.5
            buffer[:, side] += shifted * gain
    wet = room(buffer, room_size, room_mix)
    # Clean up: no DC or rumble, a gentle fade at the very end, peak at -6 dBFS.
    wet = sosfilt(butter(2, 60, "high", fs=RATE, output="sos"), wet, axis=0)
    tail = int(RATE * 0.08)
    wet[-tail:] *= np.linspace(1, 0, tail)[:, None] ** 2
    peak = np.max(np.abs(wet)) or 1.0
    wet *= 10 ** (-6 / 20) / peak
    assert np.isfinite(wet).all()

    pcm = np.clip(np.round(wet * (2 ** 23 - 1)), -(2 ** 23), 2 ** 23 - 1).astype("<i4")
    frames = bytearray()
    for l, r in pcm:  # 24-bit little-endian, interleaved
        frames += int(l).to_bytes(4, "little", signed=True)[:3] + int(r).to_bytes(4, "little", signed=True)[:3]
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(3)
            w.setframerate(RATE)
            w.writeframes(bytes(frames))
        out = os.path.join(OUT, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI24", wav, out], check=True)
        print("wrote", os.path.normpath(out))


os.makedirs(OUT, exist_ok=True)

# Standard. Review: a single soft A5 bell.
render("attention-review", [(0.0, bell(880.0, 0.9, 0.6))], 1.1)
# Needs you: B5 then E6, brighter, 110 ms apart, the second a little to the right.
render("attention-needs-you",
       [(0.0, bell(987.77, 0.9, 1.0, pan=-0.15)), (0.11, bell(1318.51, 1.0, 1.0, pan=0.15))], 1.3)

# Neon noir. Needs you: a rising arpeggio C5 E5 G5 C6, 70 ms apart, sweeping left to right,
# each note's filter closing from 4.2 kHz to a third.
render("attention-needs-you-neon-noir",
       [(i * 0.07, synth(f, 0.26, 4200, 1400, pan=-0.45 + i * 0.3))
        for i, f in enumerate([523.25, 659.25, 783.99, 1046.5])],
       1.0, room_size=0.8, room_mix=0.24)
# Review: one soft blip at A5 with a ping-pong echo.
render("attention-review-neon-noir", [(0.0, synth(880.0, 0.18, 2600, 900, detune=4.0))],
       1.0, room_size=0.7, room_mix=0.2, echo=(0.13, 0.35))

# Phosphor. Needs you: two beeps at C6, 90 ms each, 140 ms apart.
render("attention-needs-you-phosphor", [(0.0, beep(1046.5, 0.09)), (0.14, beep(1046.5, 0.09))],
       0.5, room_size=0.3, room_mix=0.1)
# Review: one short low beep at D5.
render("attention-review-phosphor", [(0.0, beep(587.33, 0.12))], 0.4, room_size=0.3, room_mix=0.1)
