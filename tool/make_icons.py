#!/usr/bin/env python3
"""Regenerates the Android launcher icons from tool/icon/jet-scanner-logo.png.

Run from the project root whenever the logo changes:

    pip install pillow numpy scipy
    python3 tool/make_icons.py

Output goes to tool/android_res/, which tool/setup_android.dart copies into
the generated android/ project.
"""
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "icon" / "jet-scanner-logo.png"
RES = ROOT / "android_res"

# density -> (legacy launcher icon px = 48dp, adaptive layer px = 108dp)
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

# Share of the 108dp adaptive layer covered by the logo tile. Launchers only
# guarantee the central 66dp, so the logo artwork has to sit well inside it.
ADAPTIVE_TILE_SCALE = 0.66

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

# Vertical blue gradient matching the logo tile (bright at the top, dark at the bottom).
BACKGROUND_XML = """<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <gradient
        android:angle="270"
        android:startColor="#0050E0"
        android:endColor="#001E70" />
</shape>
"""


def extract_tile(path):
    """Returns the rounded logo tile as a square RGBA image with transparent corners."""
    pixels = np.asarray(Image.open(path).convert("RGB"))

    # The white backdrop is the near-white region touching the top-left corner.
    # White parts inside the logo (the scanner lid) are not connected to it.
    near_white = (pixels >= 200).all(axis=2)
    labels, _ = ndimage.label(near_white)
    outside = labels == labels[0, 0]

    # Trim the light anti-aliased fringe, then soften the edge again.
    tile = ndimage.binary_erosion(~outside, iterations=4)
    alpha = ndimage.gaussian_filter(tile.astype(np.float32), sigma=1.2)
    rgba = np.dstack([pixels, (alpha * 255).round().astype(np.uint8)])

    image = Image.fromarray(rgba)
    bbox = image.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    image = image.crop(bbox)

    side = max(image.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    return square


def save_png(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, optimize=True)


def save_text(text, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def main():
    tile = extract_tile(SOURCE)

    for density, (legacy_px, layer_px) in DENSITIES.items():
        folder = RES / f"mipmap-{density}"

        # Legacy icon (Android 7 and older).
        save_png(tile.resize((legacy_px, legacy_px), Image.LANCZOS), folder / "ic_launcher.png")

        # Adaptive foreground layer: the tile centred on a transparent canvas.
        inner = round(layer_px * ADAPTIVE_TILE_SCALE)
        layer = Image.new("RGBA", (layer_px, layer_px), (0, 0, 0, 0))
        offset = (layer_px - inner) // 2
        layer.paste(tile.resize((inner, inner), Image.LANCZOS), (offset, offset))
        save_png(layer, folder / "ic_launcher_foreground.png")

    save_text(ADAPTIVE_XML, RES / "mipmap-anydpi-v26" / "ic_launcher.xml")
    save_text(BACKGROUND_XML, RES / "drawable" / "ic_launcher_background.xml")
    print(f"Icons written to {RES}")


if __name__ == "__main__":
    main()
