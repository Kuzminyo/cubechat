"""Synthesise the incoming-call ringtone into assets/sounds/.

Generated rather than downloaded so the file has no licence attached to it and
can be remade with a different phrase by editing the note list below.

    python tool/make_call_tones.py
"""

import math
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"

# A rising three-note figure played twice, then a rest: about 2.4 s a loop.
# Mid-register on purpose. A phone speaker is thin below ~500 Hz and shrill
# above ~2 kHz, and a ring that is only loud is a ring people turn off.
PHRASE = [(880.00, 0.0), (1108.73, 0.14), (1318.51, 0.28),
          (880.00, 0.62), (1108.73, 0.76), (1318.51, 0.90)]
LENGTH = 2.4


def pluck(freq: float, t: float) -> float:
    """One struck note: a sine with a quiet octave, decaying like a marimba bar."""
    if t < 0:
        return 0.0
    attack = min(1.0, t / 0.004)
    decay = math.exp(-t / 0.18)
    tone = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(4 * math.pi * freq * t)
    return attack * decay * tone


def render() -> list[float]:
    samples = []
    for i in range(int(LENGTH * RATE)):
        t = i / RATE
        samples.append(sum(pluck(f, t - start) for f, start in PHRASE))
    peak = max(abs(s) for s in samples) or 1.0
    gain = 10 ** (-3 / 20) / peak  # -3 dBFS peak
    return [s * gain for s in samples]


def write(name: str, samples: list[float]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
    print(f"{path} {path.stat().st_size} B")


if __name__ == "__main__":
    write("call_incoming.wav", render())
