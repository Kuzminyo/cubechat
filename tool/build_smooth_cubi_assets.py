"""Build Cubi's smooth in-chat WebP animations.

The gallery masters use long presentation holds.  In chat those holds make
Cubi look frozen, then jump between poses.  This exporter keeps every original
drawing, puts an even 80 ms beat on the sequence, and inserts one half-way
transition for the eight-frame stickers.  It never applies a mesh, rotation,
or optical flow, so paws, ears and facial features keep their drawn shape.

Run after the source art changes:

    python tool/build_smooth_cubi_assets.py
"""

from pathlib import Path
from PIL import Image, ImageSequence

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "design-previews" / "matcha-motion-v8"
OUTPUT = ROOT / "assets" / "stickers"
ANIM_SIZE = 224
STILL_SIZE = 176
FRAME_MS = 80  # 12.5 fps: smooth while keeping the finished APK small.


def source_frames(path: Path) -> list[Image.Image]:
    image = Image.open(path)
    return [
        frame.convert("RGBA").resize((ANIM_SIZE, ANIM_SIZE), Image.Resampling.LANCZOS)
        for frame in ImageSequence.Iterator(image)
    ]


def smooth_frames(frames: list[Image.Image]) -> list[Image.Image]:
    if len(frames) > 8:
        return frames
    result: list[Image.Image] = []
    for index, frame in enumerate(frames):
        result.append(frame)
        # The bridge smooths adjacent hand-drawn poses instead of faking a
        # skeletal movement.  It is only one frame, therefore no ghostly hold.
        result.append(Image.blend(frame, frames[(index + 1) % len(frames)], 0.5))
    return result


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


def build(name: str) -> None:
    frames = smooth_frames(source_frames(SOURCE / f"{name}.webp"))
    target = OUTPUT / f"{name}.webp"
    frames[0].save(
        target,
        save_all=True,
        append_images=frames[1:],
        duration=[FRAME_MS] * len(frames),
        loop=0,
        quality=58,
        method=4,
    )
    still = Image.open(SOURCE / f"{name}.png").convert("RGBA").resize(
        (STILL_SIZE, STILL_SIZE), Image.Resampling.LANCZOS)
    still.save(OUTPUT / f"{name}.png", optimize=True)
    durations = webp_durations(target)
    if len(durations) != len(frames) or set(durations) != {FRAME_MS}:
        raise ValueError(f"Unexpected timing for {name}: {durations}")
    print(f"{name}: {len(frames)} frames, {sum(durations)} ms", flush=True)


def main() -> None:
    names = sorted(path.stem for path in SOURCE.glob("cat-*.webp"))
    if not names:
        raise SystemExit("No Cubi source animations found")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        build(name)
    print(f"Built {len(names)} smooth Cubi animations at {1000 / FRAME_MS:.1f} fps.")


if __name__ == "__main__":
    main()
