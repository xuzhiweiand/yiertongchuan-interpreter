# -*- coding: utf-8 -*-
"""Generate the YierTong app icon set (HarmonyOS layered icon + legacy icon).

Design: deep-navy gradient, soft cyan bloom, and the "hearing" mark
(Material Icons, Apache-2.0) rendered as a white->ice gradient glyph.

The script is deterministic: re-running it rewrites the same assets.

Usage:
    python scripts/make_icon.py [--font PATH] [--preview]
"""

from __future__ import annotations

import argparse
import io
import os
import sys
import tempfile
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONT_URL = (
    "https://raw.githubusercontent.com/google/material-design-icons/"
    "master/font/MaterialIcons-Regular.ttf"
)
HEARING = "\ue023"

# Brand palette (matches entry/src/main/ets/pages/Index.ets).
BG_TOP = (14, 33, 58)       # #0E213A
BG_BOTTOM = (4, 10, 20)     # #040A14
BLOOM = (46, 138, 176)      # #2E8AB0
GLYPH_TOP = (255, 255, 255)
GLYPH_BOTTOM = (176, 232, 255)  # #B0E8FF
GLOW = (90, 209, 255)       # #5AD1FF

SCALE = 4                   # supersampling factor
BASE = 1024                 # output size for legacy / layered assets
GLYPH_RATIO = 0.52          # glyph height relative to canvas


def hexc(c) -> str:
    return "#%02X%02X%02X" % c


def background(size: int) -> Image.Image:
    """Diagonal gradient + radial bloom + faint vignette."""
    n = size
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) / (n - 1)

    # diagonal gradient (top-left -> bottom-right)
    t = np.clip((x * 0.65 + y * 0.35), 0, 1)[..., None]
    top = np.array(BG_TOP, dtype=np.float32)
    bottom = np.array(BG_BOTTOM, dtype=np.float32)
    img = top * (1 - t) + bottom * t

    # radial bloom behind the mark
    cx, cy, r = 0.50, 0.45, 0.58
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / r
    bloom = np.clip(1 - d, 0, 1) ** 2
    img = img + (np.array(BLOOM, dtype=np.float32) - img) * (bloom[..., None] * 0.34)

    # corner vignette keeps edges quiet
    vx = np.clip((x - 0.5) * 2, -1, 1)
    vy = np.clip((y - 0.5) * 2, -1, 1)
    vig = np.clip(1 - 0.42 * (vx ** 2 + vy ** 2), 0.55, 1)[..., None]
    img = img * vig

    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), "RGB")


def glyph_mask(size: int, font_path: str, ratio: float = GLYPH_RATIO) -> Image.Image:
    """White-on-transparent mark, ink box height == ratio * size."""
    px = 600
    font = ImageFont.truetype(font_path, px)
    big = Image.new("L", (px * 3, px * 3), 0)
    ImageDraw.Draw(big).text((px, px * 2), HEARING, font=font, fill=255, anchor="ls")

    ink = big.crop(big.getbbox())
    scale = (ratio * size) / ink.height
    mark = ink.resize((max(1, round(ink.width * scale)), round(ratio * size)), Image.LANCZOS)

    canvas = Image.new("L", (size, size), 0)
    canvas.paste(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return canvas


def tint(mask: Image.Image, top, bottom) -> Image.Image:
    """Vertical gradient fill through a mask."""
    w, h = mask.size
    line = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    a = np.array(top, dtype=np.float32)[None, :]
    b = np.array(bottom, dtype=np.float32)[None, :]
    grad = a * (1 - line) + b * line               # (h,3)
    rgb = np.repeat(grad[:, None, :], w, axis=1).astype(np.uint8)
    solid = Image.fromarray(rgb, "RGB").convert("RGBA")
    solid.putalpha(mask)
    return solid


def compose(size: int, font_path: str, with_bg: bool = True) -> Image.Image:
    bg = background(size).convert("RGBA") if with_bg else Image.new("RGBA", (size, size), (0, 0, 0, 0))
    mask = glyph_mask(size, font_path)

    # bloom halo under the mark
    if with_bg:
        halo = mask.filter(ImageFilter.GaussianBlur(size * 0.035))
        halo = halo.point(lambda v: int(v * 0.55))
        glow = Image.new("RGBA", (size, size), GLOW + (0,))
        glow.putalpha(halo)
        bg = Image.alpha_composite(bg, glow)

    mark = tint(mask, GLYPH_TOP, GLYPH_BOTTOM)
    return Image.alpha_composite(bg, mark)


def save(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)
    print(f"  {path.relative_to(ROOT)}  {img.width}x{img.height}  {path.stat().st_size/1024:.1f} KB")


def detect_font(font_arg: str | None) -> str:
    if font_arg:
        return font_arg
    candidates = [
        Path(tempfile.gettempdir()) / "MaterialIcons-Regular.ttf",
        ROOT / "scripts" / "assets" / "MaterialIcons-Regular.ttf",
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    dest = Path(tempfile.gettempdir()) / "MaterialIcons-Regular.ttf"
    print(f"downloading {FONT_URL}")
    urllib.request.urlretrieve(FONT_URL, dest)
    return str(dest)


def ascii_preview(img: Image.Image, cols: int = 72) -> None:
    ratio = img.height / img.width
    rows = max(1, int(cols * ratio * 0.5))
    small = img.convert("L").resize((cols, rows), Image.LANCZOS)
    px = small.load()
    ramp = " .:-=+*#%@"
    for yy in range(rows):
        print("".join(ramp[min(len(ramp) - 1, px[xx, yy] * len(ramp) // 256)] for xx in range(cols)))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default=None)
    ap.add_argument("--preview", action="store_true")
    args = ap.parse_args()

    font_path = detect_font(args.font)
    size = BASE * SCALE

    app_icon = compose(size, font_path, with_bg=True)
    layered_fg = compose(size, font_path, with_bg=False)
    layered_bg = background(size)

    app_icon_small = app_icon.resize((BASE, BASE), Image.LANCZOS)
    fg_small = layered_fg.resize((BASE, BASE), Image.LANCZOS)
    bg_small = layered_bg.resize((BASE, BASE), Image.LANCZOS)

    print("writing icon assets...")
    save(app_icon_small, ROOT / "AppScope/resources/base/media/app_icon.png")
    save(bg_small, ROOT / "entry/src/main/resources/base/media/background.png")
    save(fg_small, ROOT / "entry/src/main/resources/base/media/foreground.png")

    # splash / start-window mark: transparent, slightly smaller ink box
    start = compose(size, font_path, with_bg=False)
    start = start.crop(start.getbbox() or (0, 0, size, size))
    side = max(start.width, start.height)
    pad = int(side * 0.10)
    canvas = Image.new("RGBA", (side + pad * 2, side + pad * 2), (0, 0, 0, 0))
    canvas.paste(start, ((canvas.width - start.width) // 2, (canvas.height - start.height) // 2))
    save(canvas.resize((288, 288), Image.LANCZOS),
         ROOT / "entry/src/main/resources/base/media/startIcon.png")

    # readable previews for docs / review
    save(app_icon_small, ROOT / "docs/icon/app-icon-1024.png")
    preview = Image.new("RGBA", (BASE + 320, BASE), (9, 16, 28, 255))
    preview.paste(app_icon_small, (0, 0))
    # rounded-mask simulation at small sizes
    for i, s in enumerate((192, 128, 96)):
        thumb = app_icon_small.resize((s, s), Image.LANCZOS)
        m = Image.new("L", (s * 4, s * 4), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, s * 4 - 1, s * 4 - 1], radius=int(s * 1.1), fill=255)
        m = m.resize((s, s), Image.LANCZOS)
        thumb.putalpha(m)
        preview.alpha_composite(thumb, (BASE + 24 + (i % 2) * 0, 40 + i * 210))
    save(preview, ROOT / "docs/icon/icon-preview.png")

    if args.preview:
        print("\nASCII preview (app icon):")
        ascii_preview(app_icon_small)
    return 0


if __name__ == "__main__":
    sys.exit(main())
