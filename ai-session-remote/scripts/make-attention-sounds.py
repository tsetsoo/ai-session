#!/usr/bin/env python3
"""Generate the app's attention sounds (original synthesis, no samples).

    scripts/make-attention-sounds.py   # writes App/AISessionRemote/Resources/Sounds/*.caf

Six sounds, a "needs you" and a "ready for review" per app skin, each layered like a small
instrument rather than a bare tone:

  Standard   a tuned vibraphone/celesta bar: soft mallet transient, bar modes (1 : 4 : 10),
             a slight pitch settle, a warm octave-down body. Review: one A5. Needs you: B5, E6.
  Neon noir  an FM electric-piano pluck layered with a detuned, chorused saw pad.
             Needs you: a C5 E5 G5 C6 arpeggio sweeping left to right. Review: one A5 blip with
             a ping-pong echo that darkens on each repeat.
  Phosphor   a clean retro terminal beep: rounded square with a pitch blip, a sine body and a
             faint relay click. Needs you: two C6 beeps. Review: one D5 beep.

Every sound goes through a stereo room (early reflections plus a tail whose highs die first),
gentle saturation and a soft limiter. Output: 48 kHz, 24-bit stereo CAF, peaks at -6 dBFS.
All oscillators stay band-limited (no partials above Nyquist, so no aliasing buzz). The same
files serve the Mac chimes and banners, iPhone notifications and pushes.

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
rng = np.random.default_rng(11)  # fixed seed: the files are reproducible


# ---------------------------------------------------------------------------------------------
# Building blocks (all mono, float64, at RATE)

def timeline(seconds):
    return np.arange(int(RATE * seconds)) / RATE


def ease_in(t, seconds):
    """Raised-cosine fade-in: no click."""
    return np.where(t < seconds, 0.5 - 0.5 * np.cos(np.pi * np.clip(t / seconds, 0, 1)), 1.0)


def ease_out(t, length, seconds):
    return np.clip((length - t) / seconds, 0, 1) ** 2


def phase_of(freq_curve):
    """Integrate an instantaneous frequency (Hz per sample) into a phase."""
    return 2 * np.pi * np.cumsum(freq_curve) / RATE


def settle(t, freq, amount, seconds):
    """A pitch that starts `amount` (fraction) sharp and settles: how a struck bar sounds."""
    return freq * (1 + amount * np.exp(-t / seconds))


def lowpass(x, cutoff, order=2):
    return sosfilt(butter(order, min(cutoff, NYQUIST * 0.95), "low", fs=RATE, output="sos"), x)


def bandpass(x, low, high, order=2):
    return sosfilt(butter(order, [low, min(high, NYQUIST * 0.95)], "band", fs=RATE, output="sos"), x)


def mallet(length=0.012, low=2000, high=9000, gain=0.25):
    """A soft strike: a few ms of band-passed noise with a fast decay."""
    t = timeline(length)
    burst = bandpass(rng.standard_normal(len(t)), low, high) * np.exp(-t / (length / 4))
    return gain * burst * ease_in(t, 0.0005)


def pad(sound, length):
    out = np.zeros(int(RATE * length))
    out[: min(len(out), len(sound))] += sound[: len(out)]
    return out


# ---------------------------------------------------------------------------------------------
# Instruments

def vibraphone(freq, length, brightness=1.0):
    """A tuned metal bar. Modes at 1, 4 and 10 times the fundamental (how vibraphone and celesta
    bars are tuned), each with its own decay; two voices 3 cents apart for life; a slight pitch
    settle; a soft mallet; and a quiet octave-down sine for warmth."""
    t = timeline(length)
    modes = [(1.0, 1.0, 2.6), (4.0, 0.28 * brightness, 7.0), (10.0, 0.08 * brightness, 16.0)]
    tone = np.zeros_like(t)
    for cents in (-3.0, 3.0):
        f = freq * 2 ** (cents / 1200)
        for ratio, amp, decay in modes:
            if f * ratio >= 10000:  # keep the shimmer below 10 kHz: bright, never piercing
                continue
            ph = phase_of(settle(t, f * ratio, 0.006, 0.012)) + rng.uniform(0, 2 * np.pi)
            tone += amp * np.exp(-decay * t) * np.sin(ph)
    tone *= 0.5
    body = 0.22 * np.exp(-3.2 * t) * np.sin(2 * np.pi * freq / 2 * t) * ease_in(t, 0.01)
    strike = pad(mallet(0.01, 2500, 9000, 0.1 * brightness), length)
    # Ends on a fade, never a cut: a note stopped while it still rings clicks.
    return (tone + body) * ease_in(t, 0.0015) * ease_out(t, length, 0.25) + strike


def fm_pluck(freq, length, index=2.4, brightness=1.0):
    """An FM electric-piano pluck: carrier and modulator at the same pitch, the modulation
    index decaying fast (bright attack, mellow body), plus a short tine ping near 7 kHz.
    Sidebands stay well under Nyquist at these pitches."""
    t = timeline(length)
    idx = index * brightness * np.exp(-t / 0.09)
    mod = idx * np.sin(2 * np.pi * freq * t)
    tone = np.sin(2 * np.pi * freq * t + mod) * np.exp(-3.8 * t / length * 2)
    # The tine sits around 7 kHz whatever the note, so it sparkles without piercing.
    tine_ratio = max(2, round(7000 / freq))
    tine = 0.07 * np.sin(2 * np.pi * freq * tine_ratio * t) * np.exp(-t / 0.01)
    return (tone + tine) * ease_in(t, 0.002) * ease_out(t, length, 0.15)


def saw_pad(freq, length, cutoff_from, cutoff_to, detune=9.0):
    """Two detuned band-limited saws under a falling low-pass (applied per harmonic, so exact),
    with a slow chorus wobble. Swells in, then fades."""
    t = timeline(length)
    out = np.zeros_like(t)
    cutoff = cutoff_from * (cutoff_to / cutoff_from) ** (t / length)
    for cents, lfo_rate in ((-detune, 0.7), (detune, 0.9)):
        f0 = freq * 2 ** (cents / 1200)
        wobble = 1 + 0.0015 * np.sin(2 * np.pi * lfo_rate * t + rng.uniform(0, 6.28))
        n_max = int(NYQUIST * 0.9 // f0)
        base = phase_of(f0 * wobble)
        for n in range(1, n_max + 1):
            gain = (1.0 / n) / np.sqrt(1.0 + (f0 * n / cutoff) ** 4)
            out += gain * np.sin(n * base + rng.uniform(0, 6.28))
    env = ease_in(t, 0.03) * np.exp(-2.5 * t / length) * ease_out(t, length, 0.15)
    return 0.35 * out * env


def retro_beep(freq, length):
    """A rounded square (odd harmonics, rolled off above 3.5 kHz) with a short pitch blip at
    the start, a sine body an octave down, and a faint relay click. Held flat, 6 ms edges."""
    t = timeline(length)
    f = freq * (1 + 0.03 * np.exp(-t / 0.004))
    base = phase_of(f)
    sq = np.zeros_like(t)
    n_max = int(NYQUIST * 0.9 // freq)
    for n in range(1, n_max + 1, 2):
        sq += (1.0 / n) / (1.0 + (freq * n / 3500.0) ** 2.4) * np.sin(n * base)
    # An octave-down body, but never below ~400 Hz: phone speakers can't play it and it would
    # only eat headroom.
    body = (0.35 if freq / 2 >= 400 else 0.0) * np.sin(base / 2)
    env = ease_in(t, 0.006) * ease_out(t, length, 0.012)
    click = pad(mallet(0.004, 1200, 5000, 0.08), length)
    return 0.6 * (sq + body) * env + click


# ---------------------------------------------------------------------------------------------
# Mixing

def place(buffer, sound, start, pan=0.0):
    """Mix mono `sound` into the stereo `buffer` at `start` seconds with an equal-power pan."""
    i = int(start * RATE)
    if i >= len(buffer):
        return
    end = min(len(buffer), i + len(sound))
    left, right = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    buffer[i:end, 0] += sound[: end - i] * left
    buffer[i:end, 1] += sound[: end - i] * right


def ping_pong(buffer, delay, feedback, repeats=4, darken=0.65):
    """Echoes of the dry mix alternating sides, each quieter and darker than the last. Built
    from the dry signal only, so the echoes don't compound."""
    dry = buffer.sum(axis=1) * 0.5
    d = int(RATE * delay)
    out = buffer.copy()
    tap = dry
    for k in range(1, repeats + 1):
        if d * k >= len(buffer):
            break
        tap = lowpass(tap, 9000 * darken ** k)
        shifted = np.zeros(len(buffer))
        shifted[d * k:] = tap[: len(buffer) - d * k]
        out[:, k % 2] += shifted * feedback ** k
    return out


def room(stereo, size, mix):
    """A small stereo room: a few early reflections per side, then a diffuse tail made of a
    bright part that dies fast and a dark part that lingers (highs fade first, like a real room)."""
    n = int(RATE * size)
    t = np.arange(n) / RATE
    out = np.zeros((len(stereo) + n - 1, 2))
    for ch in range(2):
        ir = np.zeros(n)
        for ms, gain in zip(rng.uniform(5, 32, 6), (0.55, 0.42, 0.35, 0.3, 0.22, 0.18)):
            ir[int(ms * RATE / 1000)] += gain * rng.choice((-1, 1))
        start = int(0.02 * RATE)
        noise = rng.standard_normal(n)
        bright = lowpass(noise, 7000) * np.exp(-6.9 * t / (size * 0.45))
        dark = lowpass(noise, 1800) * np.exp(-6.9 * t / size)
        tail = (bright * 0.6 + dark) * ease_in(t, 0.02)
        tail[:start] = 0
        ir += tail * 0.12
        ir /= np.sqrt(np.sum(ir ** 2))
        out[:, ch] = fftconvolve(stereo[:, ch], ir)
    dry = np.zeros_like(out)
    dry[: len(stereo)] = stereo
    return dry * (1 - mix) + out * mix


def master(x):
    """Clean low end, gentle warmth, soft limiting, a fade at the very end, -6 dBFS peak."""
    x = sosfilt(butter(2, 70, "high", fs=RATE, output="sos"), x, axis=0)
    peak = np.max(np.abs(x)) or 1.0
    x = np.tanh(1.4 * x / peak) / np.tanh(1.4)  # gentle saturation: rounder, a touch warmer
    tail = int(RATE * 0.1)
    x[-tail:] *= np.linspace(1, 0, tail)[:, None] ** 2
    x *= 10 ** (-6 / 20) / (np.max(np.abs(x)) or 1.0)
    assert np.isfinite(x).all()
    return x


def write(name, stereo):
    pcm = np.ascontiguousarray(np.clip(np.round(stereo * (2 ** 23 - 1)), -(2 ** 23), 2 ** 23 - 1).astype("<i4"))
    frames = pcm.view(np.uint8).reshape(-1, 4)[:, :3].tobytes()  # 24-bit LE, interleaved
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(3)
            w.setframerate(RATE)
            w.writeframes(frames)
        out = os.path.join(OUT, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI24", wav, out], check=True)
        print("wrote", os.path.normpath(out))


def render(name, notes, total, room_size, room_mix, echo=None):
    """`notes`: (start seconds, mono sound, pan). `echo`: (delay, feedback) ping-pong."""
    buffer = np.zeros((int(RATE * total), 2))
    for start, sound, pan in notes:
        place(buffer, sound, start, pan)
    if echo:
        buffer = ping_pong(buffer, *echo)
    write(name, master(room(buffer, room_size, room_mix)))


# ---------------------------------------------------------------------------------------------
# The six sounds

os.makedirs(OUT, exist_ok=True)

# Standard. Review: a single soft A5 bar. Needs you: B5 then E6, brighter, 110 ms apart.
render("attention-review", [(0.0, vibraphone(880.0, 1.2, brightness=0.7), 0.0)],
       1.3, room_size=0.9, room_mix=0.2)
render("attention-needs-you",
       [(0.0, vibraphone(987.77, 1.1, 1.0), -0.15), (0.11, vibraphone(1318.51, 1.3, 1.0), 0.15)],
       1.5, room_size=0.9, room_mix=0.2)

# Neon noir. Needs you: an FM-piano + pad arpeggio C5 E5 G5 C6, 70 ms apart, left to right.
arp = []
for i, f in enumerate([523.25, 659.25, 783.99, 1046.5]):
    pan = -0.5 + i * 0.33
    arp.append((i * 0.07, fm_pluck(f, 0.5, index=2.2), pan))
    arp.append((i * 0.07, saw_pad(f, 0.55, 3600, 900) * 0.5, -pan * 0.6))
render("attention-needs-you-neon-noir", arp, 1.1, room_size=1.2, room_mix=0.28)
# Review: one soft A5 pluck with a darkening ping-pong echo.
render("attention-review-neon-noir",
       [(0.0, fm_pluck(880.0, 0.35, index=1.6), 0.0), (0.0, saw_pad(880.0, 0.3, 2400, 800, 5.0) * 0.35, 0.0)],
       1.1, room_size=1.0, room_mix=0.22, echo=(0.14, 0.38))

# Phosphor. Needs you: two C6 beeps, 90 ms each, 140 ms apart. Review: one short D5 beep.
render("attention-needs-you-phosphor",
       [(0.0, retro_beep(1046.5, 0.09), -0.1), (0.14, retro_beep(1046.5, 0.09), 0.1)],
       0.5, room_size=0.35, room_mix=0.12)
render("attention-review-phosphor", [(0.0, retro_beep(587.33, 0.12), 0.0)],
       0.4, room_size=0.35, room_mix=0.12)
