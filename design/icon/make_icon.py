#!/usr/bin/env python3
"""Generate the Sable app icon procedurally from a 32x32 pixel grid.

Artwork: a bold amber play triangle (near-equilateral pixel staircase, bevelled with a lighter
upper edge, a deeper lower edge and a one-cell drop shadow) above two cream subtitle bars of
different lengths: the upper one flush left, the lower one flush right (a hint of LTR / RTL
text). Flat warm near-black background. No text, opaque, square, no baked corners (iOS applies
the mask).

Outputs (design/icon/):
  AppIcon-1024.png          master (light/"any" appearance), opaque RGB
  AppIcon-1024-dark.png     iOS 18 dark appearance: same art on a transparent background
  AppIcon-1024-tinted.png   iOS 18 tinted appearance: grayscale art on black
  AppIcon-<n>.png           downsampled previews (180, 120, 87, 60, 40)
  preview-sheet.png         all variants on a rounded mask at several sizes
and, with --install, copies the three 1024 images into
App/Resources/Assets.xcassets/AppIcon.appiconset/.

Usage: python3 design/icon/make_icon.py [--install]     (requires Pillow)
"""
import os
import shutil
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APPICON = os.path.join(ROOT, "App", "Resources", "Assets.xcassets", "AppIcon.appiconset")
FONT = os.path.join(ROOT, "App", "Resources", "Fonts", "Silkscreen-Regular.ttf")

GRID = 32
SIZE = 1024
CELL = SIZE // GRID

# Colours (sRGB). Accent family = Palette.accent (#FFB43C) with a highlight and a shade.
BG = (14, 12, 10)
AMBER = (255, 180, 60)
AMBER_HI = (255, 212, 128)
AMBER_LO = (214, 138, 34)
AMBER_SHADOW = (58, 36, 8)
CREAM = (242, 239, 230)
CREAM_LO = (176, 170, 158)
CREAM_SHADOW = (38, 34, 29)

# Geometry (grid cells).
# Play triangle: 15 rows tall; each row grows by 2, 1, 2, 1... cells (about 1.5 per row), so
# it is 12 cells wide: close to equilateral (tip angle ~64 deg) while every stair stays crisp.
TRI_TOP, TRI_LEFT, TRI_H = 2, 11, 17          # 13 wide; centroid on the canvas centre column
BAR_THICK = 3
BAR1 = (21, 6, 20)                            # row, first col, last col  (flush left, 15 long)
BAR2 = (26, 12, 25)                           # (flush right, 14 long)


def triangle_widths(height):
    half = height // 2
    widths, w = [], 1
    for r in range(half + 1):
        widths.append(w)
        w += 2 if r % 2 == 0 else 1
    return widths + widths[:half][::-1] if height % 2 else widths[:half] + widths[:half][::-1]


def triangle():
    cells = set()
    for r, width in enumerate(triangle_widths(TRI_H)):
        for c in range(width):
            cells.add((TRI_LEFT + c, TRI_TOP + r))
    return cells


def bar(spec):
    row, c0, c1 = spec
    return {(c, row + t) for c in range(c0, c1 + 1) for t in range(BAR_THICK)}


def shade(cells, base, hi, lo):
    """Bevel, light from above: cells with nothing above -> hi; nothing below -> lo.
    Vertical edges stay `base` so the triangle's flat side does not read as a mast."""
    out = {}
    for (x, y) in cells:
        if (x, y - 1) not in cells:
            out[(x, y)] = hi
        elif (x, y + 1) not in cells:
            out[(x, y)] = lo
        else:
            out[(x, y)] = base
    return out


def compose(variant="light"):
    """Return a GRID x GRID list of RGBA tuples."""
    transparent = (0, 0, 0, 0)
    grid = [[transparent] * GRID for _ in range(GRID)]
    if variant in ("light", "tinted"):
        for y in range(GRID):
            for x in range(GRID):
                grid[y][x] = (BG if variant == "light" else (0, 0, 0)) + (255,)
    tri = triangle()
    bars = bar(BAR1) | bar(BAR2)
    shapes = tri | bars
    # Drop shadows (+1, +1) where they do not overlap the shapes.
    for cells, color in ((tri, AMBER_SHADOW), (bars, CREAM_SHADOW)):
        for (x, y) in cells:
            s = (x + 1, y + 1)
            if s not in shapes and 0 <= s[0] < GRID and 0 <= s[1] < GRID:
                grid[s[1]][s[0]] = color + (255,)
    for (x, y), c in shade(tri, AMBER, AMBER_HI, AMBER_LO).items():
        grid[y][x] = c + (255,)
    for (x, y), c in shade(bars, CREAM, CREAM, CREAM_LO).items():
        grid[y][x] = c + (255,)
    if variant == "tinted":
        def gray(c):
            r, g, b, a = c
            if a == 0:
                return c
            lum = int(round(0.2126 * r + 0.7152 * g + 0.0722 * b))
            return (lum, lum, lum, a)
        grid = [[gray(c) for c in row] for row in grid]
        # Push the play triangle to full white so the system tint reads strongest there.
        for (x, y) in tri:
            lum = grid[y][x][0]
            v = min(255, int(lum * 1.25))
            grid[y][x] = (v, v, v, 255)
    return grid


def render(grid, size=SIZE, mode="RGBA"):
    img = Image.new("RGBA", (GRID, GRID))
    img.putdata([c for row in grid for c in row])
    img = img.resize((size, size), Image.NEAREST)
    return img.convert(mode) if mode != "RGBA" else img


def rounded_mask(size):
    """Approximation of the iOS app icon mask (continuous corners ~22.37%)."""
    scale = 4
    m = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * scale - 1, size * scale - 1],
                                        radius=int(size * scale * 0.2237), fill=255)
    return m.resize((size, size), Image.LANCZOS)


def preview_sheet(light, dark, tinted, out):
    sizes = [180, 120, 87, 60, 40]
    rows = [("LIGHT", light, (64, 66, 72)), ("DARK", dark, (20, 20, 22)), ("TINTED", tinted, (20, 20, 22))]
    W = 40 + 300 + sum(s + 40 for s in sizes)
    H = 60 + len(rows) * 330 + 20
    sheet = Image.new("RGB", (W, H), (34, 34, 38))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype(FONT, 18)
    except OSError:
        font = ImageFont.load_default()
    d.text((20, 20), "SABLE APP ICON  32x32 GRID -> 1024", font=font, fill=(242, 241, 236))
    y = 60
    for name, img, wall in rows:
        d.rectangle([20, y, W - 20, y + 310], fill=wall)
        d.text((30, y + 8), name, font=font, fill=(242, 241, 236))
        big = 280
        x = 30
        for s in [big] + sizes:
            icon = img.resize((s, s), Image.LANCZOS).convert("RGBA")
            if name == "TINTED":
                # Simulate the system tint (amber) over a dark backdrop.
                g = icon.convert("L")
                tint = Image.new("RGBA", (s, s), (255, 196, 92, 255))
                base = Image.new("RGBA", (s, s), (24, 22, 20, 255))
                icon = Image.composite(tint, base, g)
            elif name == "DARK":
                base = Image.new("RGBA", (s, s), (28, 28, 30, 255))
                base.alpha_composite(icon)
                icon = base
            mask = rounded_mask(s)
            sheet.paste(icon.convert("RGB"), (x, y + 30 + (big - s) // 2 if s != big else y + 30), mask)
            x += s + 40
        y += 330
    sheet.save(out)


def main():
    light = render(compose("light"), mode="RGB")
    dark = render(compose("dark"))
    tinted = render(compose("tinted"), mode="RGB")
    outputs = {
        "AppIcon-1024.png": light,
        "AppIcon-1024-dark.png": dark,
        "AppIcon-1024-tinted.png": tinted,
    }
    for name, img in outputs.items():
        img.save(os.path.join(HERE, name), optimize=True)
    for s in (180, 120, 87, 60, 40):
        light.resize((s, s), Image.LANCZOS).save(os.path.join(HERE, "AppIcon-%d.png" % s), optimize=True)
    preview_sheet(light, dark, tinted, os.path.join(HERE, "preview-sheet.png"))
    print("wrote", ", ".join(sorted(outputs)), "+ previews + preview-sheet.png")
    if "--install" in sys.argv:
        for name in outputs:
            shutil.copyfile(os.path.join(HERE, name), os.path.join(APPICON, name))
        print("installed into", APPICON)


if __name__ == "__main__":
    main()
