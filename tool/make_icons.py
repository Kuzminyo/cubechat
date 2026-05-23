"""Crop the MESH CHAT brand image into harmonious launcher icons.

Input : assets/logo/mesh_chat_src.png  (the full 1:1 art with the cube +
        "MESH CHAT" caption on a dark-green background)
Output: assets/logo/cube.png             (square, opaque — iOS/Windows/splash)
        assets/logo/cube_transparent.png  (cube padded into a safe-zone square
                                            for the Android adaptive foreground)

We keep the artwork's own dark-green background (it matches the app theme),
so the icon reads as a cohesive green tile rather than a pasted photo. The
caption row at the bottom is cropped away.

Crop box is expressed as fractions of the source so it works for any square
export. Tune CX/CY/SIDE if the cube isn't centred after a visual check.
"""
import sys
from PIL import Image

SRC = "assets/logo/mesh_chat_src.png"
OUT_OPAQUE = "assets/logo/cube.png"
OUT_FOREGROUND = "assets/logo/cube_transparent.png"

# Cube sits slightly above centre (caption lives below it).
CX = 0.50   # horizontal centre of the cube
CY = 0.42   # vertical centre of the cube (caption sits below, so bias up)
SIDE = 0.60  # square side as a fraction of min(W, H)
OUT_SIZE = 1024
# Extra breathing room around the cube for the adaptive-icon safe zone
# (Android masks ~⅓ off the foreground edges).
FOREGROUND_PAD = 0.30


def main() -> int:
    try:
        img = Image.open(SRC).convert("RGB")
    except FileNotFoundError:
        print(f"!! source not found: {SRC}\n"
              f"   Save the MESH CHAT image there, then re-run.")
        return 1

    w, h = img.size
    side = int(min(w, h) * SIDE)
    cx, cy = int(w * CX), int(h * CY)
    left = max(0, cx - side // 2)
    top = max(0, cy - side // 2)
    right = min(w, left + side)
    bottom = min(h, top + side)
    cube = img.crop((left, top, right, bottom))

    # Sample the source's corner colour for the matching fill so padding
    # blends seamlessly with the artwork background.
    bg = img.getpixel((4, 4))

    opaque = cube.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    opaque.save(OUT_OPAQUE)

    # Foreground: cube shrunk inside a padded canvas filled with the same bg.
    inner = int(OUT_SIZE * (1 - FOREGROUND_PAD))
    fg = Image.new("RGB", (OUT_SIZE, OUT_SIZE), bg)
    cube_small = cube.resize((inner, inner), Image.LANCZOS)
    off = (OUT_SIZE - inner) // 2
    fg.paste(cube_small, (off, off))
    fg.save(OUT_FOREGROUND)

    print(f"crop box = ({left},{top},{right},{bottom})  bg={bg}")
    print(f"wrote {OUT_OPAQUE} and {OUT_FOREGROUND} ({OUT_SIZE}px)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
