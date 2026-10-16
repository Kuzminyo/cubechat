"""Build Cubi's smooth in-chat WebP animations.

The masters (design-previews/matcha-motion-v8) are 8 drawn poses per sticker,
or 15-16 for the few with drawn in-betweens, timed for a gallery.

History, because each step here replaced a worse one:

- Until 2026-10 this exporter put an even 80 ms beat on the drawings and
  inserted a 50 % cross-fade after each one: 1.2 s a loop.  Every other frame
  was then a double exposure -- two heads, two tails -- and the poses are
  separate redraws (mean pixel difference 14-33 of 255 between neighbours), so
  the cat flickered between a clean picture and a ghost eight times a second.
  The owner called it twitching, and an illusion of movement.
- The drawings also alternate: even poses carry a white border 5-9 px wide,
  odd ones 2-5 px, and the odd ones are 2-4 levels brighter.  In a loop that
  read as the outline breathing and the light flickering.

Now: every drawing gets the same border (redrawn from the cat's silhouette)
and the same colour (shifted onto the average of the set); each key drawing
rests for a moment; and the change to the next one is a morph -- dense
optical flow both ways, each picture warped part of the way toward the other,
then blended -- so shapes travel instead of fading through each other.  A
drawn in-between is passed through without a rest, and a move too big for
the flow (MORPH_LIMIT) is a straight change of drawing.  ~4 s a loop.

Run after the source art changes (all stickers, or the names given):

    python tool/build_smooth_cubi_assets.py [cat-sad ...]
"""

from __future__ import annotations

import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageSequence
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design-previews" / "matcha-motion-v8"
OUTPUT = ROOT / "assets" / "stickers"
ANIM_SIZE = 224
STILL_SIZE = 176
QUALITY = 62            # 80 gave 535 KB for cat-sad; the rest of the set ships at 58

KEY_HOLD_MS = 260       # a key drawing rests this long
KEY_STEPS, KEY_STEP_MS = 5, 54      # morph between two key drawings: 270 ms
INB_STEPS, INB_STEP_MS = 3, 45      # morph into or out of a drawn in-between
INBETWEEN_BELOW_MS = 600            # in a 15-16 frame master, shorter = in-between
# Mean difference left after warping one drawing onto the next.  cat-sad's
# moves all leave 6-8 and morph cleanly; cat-wave's arm swings leave 10-18 and
# smeared into a ghost paw.
MORPH_LIMIT = 9.0

BORDER_PX = 7.0                     # white sticker border, at 512 px
BORDER_RGB = np.array([249.0, 248.5, 246.5])


def webp_durations(path: Path) -> list[int]:
    """Read ANMF timing directly from the WebP container."""
    data = path.read_bytes()
    if data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        raise ValueError(f"Not a RIFF WebP: {path}")
    position = 12
    durations: list[int] = []
    while position + 8 <= len(data):
        kind = data[position:position + 4]
        length = int.from_bytes(data[position + 4:position + 8], "little")
        payload = data[position + 8:position + 8 + length]
        if len(payload) != length:
            raise ValueError(f"Truncated WebP chunk in {path}")
        if kind == b"ANMF":
            durations.append(int.from_bytes(payload[12:15], "little"))
        position += 8 + length + (length & 1)
    return durations


def source_frames(path: Path) -> list[np.ndarray]:
    return [np.asarray(f.convert("RGBA")).astype(np.float32)
            for f in ImageSequence.Iterator(Image.open(path))]


# ── one border, one light ───────────────────────────────────────────────────
def ink_mask(f: np.ndarray) -> np.ndarray:
    """The drawn cat without its white sticker border."""
    ink = (f[..., 3] > 200) & (f[..., :3].min(axis=2) < 215)
    return ndimage.binary_fill_holes(ndimage.binary_closing(ink, iterations=2))


def even_out(frames: list[np.ndarray]) -> list[np.ndarray]:
    inks = [ink_mask(f) for f in frames]
    means = [f[..., :3][m].mean(axis=0) for f, m in zip(frames, inks)]
    stds = [f[..., :3][m].std(axis=0) for f, m in zip(frames, inks)]
    mean_all, std_all = np.mean(means, axis=0), np.mean(stds, axis=0)
    out = []
    for f, ink, mu, sd in zip(frames, inks, means, stds):
        g = f.copy()
        rgb = (f[..., :3] - mu) / sd * std_all + mean_all
        g[..., :3] = np.where(ink[..., None], np.clip(rgb, 0, 255), f[..., :3])
        d = ndimage.distance_transform_edt(~ink)
        # Within ~1.5 px of the cat keep the drawing's own anti-aliased edge;
        # beyond it, one white border, fading out over its last 1.5 px.
        near = np.clip((d - 1.0) / 1.5, 0, 1)[..., None]
        g[..., :3] = g[..., :3] * (1 - near) + BORDER_RGB * near
        g[..., 3] = np.where(ink, f[..., 3], 255 * np.clip((BORDER_PX + 1.5 - d) / 1.5, 0, 1))
        out.append(g)
    return out


# ── morph ───────────────────────────────────────────────────────────────────
_dis = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)


def _gray(f: np.ndarray) -> np.ndarray:
    a = f[..., 3:] / 255
    return cv2.cvtColor((f[..., :3] * a + 235 * (1 - a)).astype(np.uint8), cv2.COLOR_RGB2GRAY)


def _warp(img: np.ndarray, flow: np.ndarray, t: float) -> np.ndarray:
    h, w = img.shape[:2]
    gy, gx = np.mgrid[0:h, 0:w].astype(np.float32)
    return cv2.remap(img, gx + flow[..., 0] * t, gy + flow[..., 1] * t, cv2.INTER_LINEAR,
                     borderMode=cv2.BORDER_CONSTANT, borderValue=0)


def morphs(a: np.ndarray, b: np.ndarray, steps: int) -> tuple[list[np.ndarray], float]:
    """`steps` pictures on the way from a to b, eased at both ends, and how
    well the flow explains b from a (mean leftover difference, 0-255).

    Above MORPH_LIMIT the move is too big for flow -- a paw swung from the lap
    to the ear smears into a ghost -- and no pictures are returned: the
    drawing simply changes, the way a drawn in-between would.
    """
    fab = _dis.calc(_gray(a), _gray(b), None)
    fba = _dis.calc(_gray(b), _gray(a), None)
    both = (a[..., 3] > 128) | (b[..., 3] > 128)
    leftover = float(np.abs(_warp(a, fba, 1.0)[..., :3] - b[..., :3]).mean(axis=2)[both].mean())
    if leftover > MORPH_LIMIT:
        return [], leftover
    pa = a.copy(); pa[..., :3] *= a[..., 3:] / 255   # premultiplied: clean edges
    pb = b.copy(); pb[..., :3] *= b[..., 3:] / 255
    out = []
    for s in range(1, steps + 1):
        t = s / (steps + 1)
        t = t * t * (3 - 2 * t)
        m = _warp(pa, fba, t) * (1 - t) + _warp(pb, fab, 1 - t) * t
        alpha = np.clip(m[..., 3:], 0, 255)
        rgb = m[..., :3] / np.maximum(alpha / 255, 1e-3)
        out.append(np.dstack([np.clip(rgb, 0, 255), alpha]))
    return out, leftover


def _small(f: np.ndarray) -> Image.Image:
    return Image.fromarray(f.astype(np.uint8), "RGBA").resize(
        (ANIM_SIZE, ANIM_SIZE), Image.Resampling.LANCZOS)


def build(name: str) -> None:
    master = SOURCE / f"{name}.webp"
    drawings = even_out(source_frames(master))
    timing = webp_durations(master)
    if len(timing) != len(drawings):
        raise ValueError(f"{name}: {len(drawings)} frames but {len(timing)} durations")
    # Eight-frame masters are all key drawings; longer ones mark their drawn
    # in-betweens with a short gallery duration.
    key = [len(drawings) <= 8 or ms >= INBETWEEN_BELOW_MS for ms in timing]

    frames: list[Image.Image] = []
    durations: list[int] = []
    cuts: list[str] = []
    n = len(drawings)
    for i in range(n):
        j = (i + 1) % n
        if key[i] and key[j]:
            steps, step_ms = KEY_STEPS, KEY_STEP_MS
            between, leftover = morphs(drawings[i], drawings[j], steps)
        else:
            # A drawn in-between already is the in-between.  Morphing into
            # or out of one is where every ghost of the first full build
            # was -- a paw that one drawing hides melted away half-seen in
            # cat-wave, wisps in cat-laugh and cat-sleep -- while all 31
            # eight-frame stickers came out clean.
            steps, step_ms = INB_STEPS, INB_STEP_MS
            between, leftover = [], float("nan")
        frames.append(_small(drawings[i]))
        hold = KEY_HOLD_MS if key[i] else INB_STEP_MS
        if not between:
            # A straight change: the travel time stays on this drawing, so
            # the rhythm of the loop does not speed up.
            hold += steps * step_ms
            if leftover == leftover:  # measured, not a drawn in-between
                cuts.append(f"{i}->{j} ({leftover:.0f})")
        durations.append(hold)
        for m in between:
            frames.append(_small(m))
            durations.append(step_ms)

    target = OUTPUT / f"{name}.webp"
    frames[0].save(target, save_all=True, append_images=frames[1:], duration=durations,
                   loop=0, quality=QUALITY, method=6)
    still = Image.open(SOURCE / f"{name}.png").convert("RGBA").resize(
        (STILL_SIZE, STILL_SIZE), Image.Resampling.LANCZOS)
    still.save(OUTPUT / f"{name}.png", optimize=True)
    # libwebp merges identical neighbours, so compare total time, not count.
    written = webp_durations(target)
    if sum(written) != sum(durations):
        raise ValueError(f"Unexpected timing for {name}: {sum(written)} != {sum(durations)} ms")
    print(f"{name}: {n} drawings -> {len(frames)} frames, {sum(durations)} ms, "
          f"{target.stat().st_size // 1024} KB, straight changes: {', '.join(cuts) or 'none'}",
          flush=True)


def main() -> None:
    names = sys.argv[1:] or sorted(path.stem for path in SOURCE.glob("cat-*.webp"))
    if not names:
        raise SystemExit("No Cubi source animations found")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        build(name)
    print(f"Built {len(names)} Cubi animations.")


if __name__ == "__main__":
    main()
