#!/usr/bin/env python3
"""Generate the Mac app's arrival sounds (original synthesis, no samples).

    scripts/make-attention-sounds.py   # writes App/AISessionRemote/Resources/Sounds/*.caf

Review: one soft bell note. Needs you: a brighter rising two-note chime.
The app skins get their own pair (`-neon-noir`, `-phosphor`): a filtered synth arpeggio and
blip with an echo, and square-wave terminal beeps.
Needs `afconvert` (macOS) to turn the WAV into CAF.
"""
import math, os, struct, subprocess, tempfile, wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "App", "AISessionRemote", "Resources", "Sounds")


def bell(freq, start, length, gain, brightness):
    """A bell-like note: a few partials, each decaying faster the higher it is."""
    partials = [(1.0, 1.0), (2.0, 0.35 * brightness), (3.0, 0.12 * brightness), (4.07, 0.05 * brightness)]
    def sample(t):
        t -= start
        if t < 0 or t > length:
            return 0.0
        attack = min(1.0, t / 0.006)
        v = 0.0
        for ratio, amp in partials:
            decay = math.exp(-t * (5.0 + 3.0 * ratio) / length)
            v += amp * decay * math.sin(2 * math.pi * freq * ratio * t)
        return gain * attack * v
    return sample


def square(t, freq):
    return 1.0 if math.sin(2 * math.pi * freq * t) >= 0 else -1.0


def saw(t, freq):
    phase = (t * freq) % 1.0
    return 2.0 * phase - 1.0


def synth_note(wave_fn, freq, start, length, gain, cutoff=None, hold=False):
    """A synth note: `wave_fn` through an optional one-pole low-pass whose cutoff falls to a
    third over the note. `hold` keeps the level flat (a beep) with a 10 ms release; otherwise
    the note decays exponentially. Rendered up front so the filter keeps its state."""
    n = int(RATE * length)
    out = []
    y = 0.0
    for i in range(n):
        t = i / RATE
        x = wave_fn(t, freq)
        if cutoff:
            fc = cutoff * (1 / 3) ** (t / length)
            a = 1 - math.exp(-2 * math.pi * fc / RATE)
            y += a * (x - y)
            x = y
        attack = min(1.0, t / 0.008)
        if hold:
            env = attack * min(1.0, (length - t) / 0.01)
        else:
            env = attack * math.exp(-5.0 * t / length)
        out.append(gain * env * x)
    begin = int(RATE * start)

    def sample(t):
        i = int(t * RATE) - begin
        return out[i] if 0 <= i < n else 0.0
    return sample


def echo(note, delay, feedback, repeats=4):
    """`note` plus decaying copies every `delay` seconds."""
    def sample(t):
        return sum(note(t - k * delay) * feedback ** k for k in range(repeats + 1))
    return sample


def render(name, notes, total):
    frames = int(RATE * total)
    samples = [sum(n(i / RATE) for n in notes) for i in range(frames)]
    peak = max(abs(s) for s in samples) or 1.0
    scale = 10 ** (-6 / 20) / peak  # peak at -6 dBFS
    tail = int(RATE * 0.03)
    data = bytearray()
    for i, s in enumerate(samples):
        fade = min(1.0, (frames - i) / tail)
        data += struct.pack("<h", int(max(-1, min(1, s * scale * fade)) * 32767))
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + ".wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(bytes(data))
        out = os.path.join(OUT, name + ".caf")
        subprocess.run(["afconvert", "-f", "caff", "-d", "LEI16", wav, out], check=True)
        print("wrote", os.path.normpath(out))


os.makedirs(OUT, exist_ok=True)
# Ready for review: a single soft A5.
render("attention-review", [bell(880.0, 0.0, 0.55, 1.0, 0.6)], 0.6)
# Needs you: B5 then E6, brighter, 110 ms apart.
render("attention-needs-you", [bell(987.77, 0.0, 0.5, 0.9, 1.0), bell(1318.51, 0.11, 0.65, 1.0, 1.0)], 0.8)

# Neon noir. Needs you: a quick rising sawtooth arpeggio C5 E5 G5 C6, 70 ms apart, low-passed.
render("attention-needs-you-neon-noir",
       [synth_note(saw, f, i * 0.07, 0.22, 0.5, cutoff=4200) for i, f in enumerate([523.25, 659.25, 783.99, 1046.5])],
       0.55)
# Review: one soft square blip at A5 with a short echo.
render("attention-review-neon-noir", [echo(synth_note(square, 880.0, 0.0, 0.18, 0.5, cutoff=2600), 0.13, 0.35)], 0.8)
# Phosphor. Needs you: two terminal beeps at C6, 90 ms each, 140 ms apart.
render("attention-needs-you-phosphor",
       [synth_note(square, 1046.5, 0.0, 0.09, 0.5, hold=True), synth_note(square, 1046.5, 0.14, 0.09, 0.5, hold=True)],
       0.3)
# Review: one short low beep at D5.
render("attention-review-phosphor", [synth_note(square, 587.33, 0.0, 0.12, 0.5, hold=True)], 0.2)
