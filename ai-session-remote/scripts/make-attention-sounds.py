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

Every sound goes through a stereo room (early reflections plus a tail whose highs die first)
and gentle saturation, is matched to the same perceived loudness, and peaks are softly
limited to -3 dBFS. Output: 48 kHz, 16-bit stereo CAF (dithered).
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
dither_rng = np.random.default_rng(99)  # separate, so dither never changes the sounds


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

def vibraphone(freq, length, velocity=1.0):
    """A vibraphone bar. Modes as on real tuned aluminium bars: the fundamental, the tuned 4th
    and 10th, plus a faint untuned torsional mode at 2.76; each decays at its own rate and
    higher strikes (`velocity`) bring out the upper modes. Under the bar, its resonator tube:
    a sustained fundamental that blooms in over ~25 ms and rings longest. The motor's tremolo
    gently pulses the resonator at 5.2 Hz. Two voices 2.5 cents apart, a slight pitch settle,
    a soft mallet whose click follows the velocity."""
    t = timeline(length)
    bright = 0.55 + 0.45 * velocity
    modes = [(1.0, 1.0, 2.9), (2.76, 0.05 * bright, 9.0), (4.0, 0.30 * bright, 6.5),
             (10.0, 0.10 * bright ** 2, 15.0)]
    bar = np.zeros_like(t)
    for cents in (-2.5, 2.5):
        f = freq * 2 ** (cents / 1200)
        for ratio, amp, decay in modes:
            if f * ratio >= 10000:  # shimmer stays under 10 kHz: bright, never piercing
                continue
            ph = phase_of(settle(t, f * ratio, 0.005, 0.01)) + rng.uniform(0, 2 * np.pi)
            bar += amp * np.exp(-decay * t) * np.sin(ph)
    bar *= 0.5
    tremolo = 1 - 0.22 * (0.5 - 0.5 * np.cos(2 * np.pi * 5.2 * t))
    resonator = (0.55 * (1 - np.exp(-t / 0.025)) * np.exp(-1.6 * t) * tremolo
                 * np.sin(2 * np.pi * freq * t + rng.uniform(0, 6.28)))
    strike = pad(mallet(0.009, 2500, 9000, 0.06 + 0.06 * velocity), length)
    # Ends on a fade, never a cut: a note stopped while it still rings clicks.
    return velocity * ((bar + resonator) * ease_in(t, 0.0015) * ease_out(t, length, 0.3) + strike)


def fm_pluck(freq, length, index=2.4, velocity=1.0):
    """An FM electric-piano pluck: carrier and modulator at the same pitch, the modulation
    index decaying fast (bright attack, mellow body; harder `velocity` is brighter), plus a
    short tine ping near 7 kHz. Sidebands stay well under Nyquist at these pitches."""
    t = timeline(length)
    idx = index * (0.7 + 0.3 * velocity) * np.exp(-t / 0.09)
    mod = idx * np.sin(2 * np.pi * freq * t)
    tone = np.sin(2 * np.pi * freq * t + mod) * np.exp(-7.6 * t / length)
    # The tine sits around 7 kHz whatever the note, so it sparkles without piercing.
    tine_ratio = max(2, round(7000 / freq))
    tine = 0.06 * velocity * np.sin(2 * np.pi * freq * tine_ratio * t) * np.exp(-t / 0.01)
    # A soft octave below, only where phone speakers can still play it (>= ~380 Hz).
    sub = (0.18 if freq / 2 >= 380 else 0.0) * np.sin(np.pi * freq * t) * np.exp(-5 * t / length)
    return velocity * (tone + tine + sub) * ease_in(t, 0.002) * ease_out(t, length, 0.15)


def saw_voice(freq, length, cutoff_from, cutoff_to, cents, lfo_rate):
    """One band-limited saw, detuned by `cents`, with a slow chorus wobble, under a falling
    low-pass applied per harmonic (exact, alias-free). Swells in, then fades."""
    t = timeline(length)
    f0 = freq * 2 ** (cents / 1200)
    wobble = 1 + 0.002 * np.sin(2 * np.pi * lfo_rate * t + rng.uniform(0, 6.28))
    cutoff = cutoff_from * (cutoff_to / cutoff_from) ** (t / length)
    base = phase_of(f0 * wobble)
    out = np.zeros_like(t)
    for n in range(1, int(NYQUIST * 0.9 // f0) + 1):
        out += (1.0 / n) / np.sqrt(1.0 + (f0 * n / cutoff) ** 4) * np.sin(n * base + rng.uniform(0, 6.28))
    env = ease_in(t, 0.03) * np.exp(-2.5 * t / length) * ease_out(t, length, 0.15)
    return 0.3 * out * env


def chorus_pad(freq, length, cutoff_from, cutoff_to, spread=9.0):
    """Three saw voices (flat, centre, sharp) placed left, centre and right: a wide, moving pad.
    Returns (sound, pan) pairs for `place`."""
    return [(saw_voice(freq, length, cutoff_from, cutoff_to, c, r), pan)
            for c, r, pan in ((-spread, 0.61, -0.7), (0.0, 0.83, 0.0), (spread, 1.07, 0.7))]


def retro_beep(freq, length):
    """A warm retro beep: two rounded squares (odd harmonics, rolled off above 3 kHz) a few
    cents apart with a slow analog drift, a short pitch blip at the start, a sine body an
    octave down (never below 400 Hz, which phone speakers can't play) and a faint relay click.
    Held flat, soft edges."""
    t = timeline(length)
    out = np.zeros_like(t)
    for cents, gain, drift in ((0.0, 1.0, 0.7), (4.0, 0.45, 1.1)):
        f = freq * 2 ** (cents / 1200) * (1 + 0.03 * np.exp(-t / 0.004))
        f = f * (1 + 0.0012 * np.sin(2 * np.pi * drift * t + rng.uniform(0, 6.28)))
        base = phase_of(f)
        for n in range(1, int(NYQUIST * 0.9 // freq) + 1, 2):
            out += gain * (1.0 / n) / (1.0 + (freq * n / 3000.0) ** 2.6) * np.sin(n * base)
        if cents == 0.0 and freq / 2 >= 400:
            out += 0.35 * np.sin(base / 2)
    env = ease_in(t, 0.006) * ease_out(t, length, 0.014)
    click = pad(mallet(0.004, 1200, 5000, 0.06), length)
    return 0.45 * out * env + click


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


def loudness(x):
    """Roughly how loud it sounds: K-weighted (cut below 100 Hz, +4 dB above 1.5 kHz, as in
    ITU-R BS.1770) RMS over the loudest 400 ms. In dB."""
    m = x.mean(axis=1)
    m = sosfilt(butter(2, 100, "high", fs=RATE, output="sos"), m)
    m = m + 0.58 * sosfilt(butter(1, 1500, "high", fs=RATE, output="sos"), m)  # ~+4 dB shelf
    win = int(RATE * 0.4)
    power = np.convolve(m ** 2, np.ones(win) / win, mode="valid") if len(m) > win else [np.mean(m ** 2)]
    return 10 * np.log10(np.max(power) + 1e-12)


TARGET_LOUDNESS = -15.0  # dB, same for all six: no theme sounds weaker than another
CEILING = 10 ** (-3 / 20)  # peaks never above -3 dBFS


def master(x):
    """Clean low end, gentle warmth, the same loudness for every sound, a soft limiter for
    peaks, and a fade at the very end."""
    x = sosfilt(butter(2, 70, "high", fs=RATE, output="sos"), x, axis=0)
    x = np.tanh(1.2 * x / (np.max(np.abs(x)) or 1.0)) / np.tanh(1.2)  # gentle saturation
    x *= 10 ** ((TARGET_LOUDNESS - loudness(x)) / 20)
    # Soft limiter: transparent below 70 % of the ceiling, rounds off above it.
    knee = 0.7 * CEILING
    over = np.abs(x) > knee
    x[over] = np.sign(x[over]) * (knee + (CEILING - knee) * np.tanh((np.abs(x[over]) - knee) / (CEILING - knee)))
    tail = int(RATE * 0.1)
    x[-tail:] *= np.linspace(1, 0, tail)[:, None] ** 2
    assert np.isfinite(x).all() and np.max(np.abs(x)) <= CEILING + 1e-9
    return x


def write(name, stereo):
    """16-bit stereo CAF. 16 bits are plenty for a two-second alert at these levels (24-bit
    sounded the same at twice the size); TPDF dither keeps the quietest reverb tails smooth
    instead of grainy."""
    dither = (dither_rng.random(stereo.shape) - dither_rng.random(stereo.shape)) / (2 ** 15)
    pcm = np.clip(np.round((stereo + dither) * (2 ** 15 - 1)), -(2 ** 15), 2 ** 15 - 1).astype("<i2")
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(np.ascontiguousarray(pcm).tobytes())
        out = os.path.join(OUT, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, out], check=True)
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

# Standard. Review: a single soft A5 bar. Needs you: B5 then E6, the second struck harder.
render("attention-review", [(0.0, vibraphone(880.0, 1.4, velocity=0.75), 0.0)],
       1.5, room_size=1.0, room_mix=0.2)
render("attention-needs-you",
       [(0.0, vibraphone(987.77, 1.3, 0.85), -0.15), (0.11, vibraphone(1318.51, 1.5, 1.0), 0.15)],
       1.7, room_size=1.0, room_mix=0.2)

# Neon noir. Needs you: an FM-piano + wide chorus-pad arpeggio C5 E5 G5 C6, ~70 ms apart,
# sweeping left to right, played by hand: a few ms early or late, a little uneven in strength.
arp = []
for i, (f, nudge, vel) in enumerate(zip([523.25, 659.25, 783.99, 1046.5],
                                        [0.0, 0.004, -0.003, 0.002], [0.85, 0.78, 0.9, 1.0])):
    start, pan = i * 0.07 + nudge, -0.5 + i * 0.33
    arp.append((start, fm_pluck(f, 0.55, index=2.2, velocity=vel), pan))
    for voice, vpan in chorus_pad(f, 0.6, 3600, 900):
        arp.append((start, voice * 0.4 * vel, max(-1, min(1, vpan * 0.6 - pan * 0.3))))
render("attention-needs-you-neon-noir", arp, 1.2, room_size=1.3, room_mix=0.28)
# Review: one soft A5 pluck with a darkening ping-pong echo.
blip = [(0.0, fm_pluck(880.0, 0.4, index=1.6, velocity=0.9), 0.0)]
blip += [(0.0, voice * 0.25, vpan * 0.5) for voice, vpan in chorus_pad(880.0, 0.35, 2400, 800, spread=5.0)]
render("attention-review-neon-noir", blip, 1.2, room_size=1.1, room_mix=0.22, echo=(0.14, 0.38))

# Phosphor. Needs you: two C6 beeps, 90 ms each, 140 ms apart. Review: one short D5 beep.
render("attention-needs-you-phosphor",
       [(0.0, retro_beep(1046.5, 0.09), -0.1), (0.14, retro_beep(1046.5, 0.09), 0.1)],
       0.5, room_size=0.35, room_mix=0.12)
render("attention-review-phosphor", [(0.0, retro_beep(587.33, 0.12), 0.0)],
       0.4, room_size=0.35, room_mix=0.12)
