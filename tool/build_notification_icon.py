"""Make the Android status-bar icon out of the cube.

Android does not draw a notification's small icon. It draws its *alpha*: every
opaque pixel becomes the accent colour, everything else is nothing. So an icon
with no transparency is a solid block — which is what shipping `ic_launcher`
here produced, reported as a black square on MIUI.

What it needs is a silhouette: white everywhere the drawing is, transparent
everywhere else. The cube already has the alpha channel for it, so this throws
the colour away and keeps the shape.

Sizes are the platform's, and they are small on purpose — the status bar is
24dp and Android will not scale up a bitmap it thinks is the right size.

    python tool/build_notification_icon.py

Run it when the logo changes. The output is committed; a phone cannot run
Python and CI should not have to.
"""

import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "logo", "cube_transparent.png")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

# The five densities Android asks for, at 24dp.
DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}

# The glyph does not fill its square, and the status bar wants it to. Trimming
# to the drawing and then padding by a tenth gives the same optical weight as
# the system's own icons beside it.
PAD = 0.10


def main():
    source = Image.open(SRC).convert("RGBA")
    alpha = source.split()[3]
    # The drawing carries a soft drop shadow, and a shadow in an alpha channel
    # is not a shadow to the status bar — it is more icon, tinted the same
    # colour as the rest. Cutting everything under a third opaque leaves the
    # cube and drops the halo under it.
    alpha = alpha.point(lambda v: 255 if v > 90 else 0)
    box = alpha.getbbox()
    if box:
        alpha = alpha.crop(box)

    for folder, size in DENSITIES.items():
        inner = round(size * (1 - PAD * 2))
        shape = alpha.resize((inner, inner), Image.LANCZOS)
        icon = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        # White, with the drawing's alpha. The system tints it; the colour here
        # only decides what it looks like on a platform that does not.
        white = Image.new("RGBA", (inner, inner), (255, 255, 255, 255))
        white.putalpha(shape)
        icon.alpha_composite(white, ((size - inner) // 2, (size - inner) // 2))

        out_dir = os.path.join(RES, folder)
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, "ic_notification.png")
        icon.save(out, optimize=True)
        print(f"{folder}/ic_notification.png  {size}x{size}  "
              f"{os.path.getsize(out)} B")


main()
