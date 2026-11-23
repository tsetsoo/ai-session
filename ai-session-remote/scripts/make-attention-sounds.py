#!/usr/bin/env python3
"""Generate the Mac app's arrival sounds (original synthesis, no samples).

    scripts/make-attention-sounds.py   # writes App/AISessionRemote/Resources/Sounds/*.caf

Review: one soft bell note. Needs you: a brighter rising two-note chime.
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
