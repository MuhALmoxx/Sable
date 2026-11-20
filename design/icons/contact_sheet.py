#!/usr/bin/env python3
"""Validate every PixelGlyph grid in App/DesignSystem/PixelIcon.swift and render a contact sheet.

The Swift file is the single source of truth: this script parses the `PixelGlyph` cases and the
`PixelGlyphArt.art` dictionary from it, checks the same rules as
`PixelGlyphArt.validationErrors()` (N rows of N characters, only '#' and '.', some ink, art for
every case, no duplicate drawings, a one-cell empty margin), and renders:

  design/icons/contact-sheet.png   every glyph at 6 px/cell (with grid) plus 20 pt@3x / 16 pt@2x
                                   previews and an amber "active" sample

Usage:  python3 design/icons/contact_sheet.py [--check]
        --check   validate only (exit 1 on any problem), no image output.
Requires Pillow for rendering.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT = os.path.join(ROOT, "App", "DesignSystem", "PixelIcon.swift")
FONT = os.path.join(ROOT, "App", "Resources", "Fonts", "Silkscreen-Regular.ttf")
OUT = os.path.join(ROOT, "design", "icons", "contact-sheet.png")
GRID = 12

BG = (0, 0, 0)
SURFACE = (22, 21, 19)
BORDER = (46, 44, 41)
INK = (242, 241, 236)
DIM = (142, 139, 132)
ACCENT = (255, 180, 60)


def parse(path):
    src = open(path, encoding="utf-8").read()
    enum = re.search(r"enum PixelGlyph[^{]*\{(.*?)\n\}", src, re.S)
    if not enum:
        sys.exit("PixelGlyph enum not found")
    body = re.sub(r"//[^\n]*", "", enum.group(1))
    cases = []
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("case "):
            cases += [c.strip() for c in line[5:].split(",") if c.strip()]
    art_block = re.search(r"static let art: \[PixelGlyph: \[String\]\] = \[(.*)\n    \]", src, re.S)
    if not art_block:
        sys.exit("PixelGlyphArt.art not found")
    art = {}
    order = []
    for m in re.finditer(r"\.(\w+):\s*\[((?:\s*\"[^\"]*\",?)+)\s*\]", art_block.group(1)):
        name = m.group(1)
        rows = re.findall(r"\"([^\"]*)\"", m.group(2))
        if name in art:
            art[name + "#dup"] = rows
        art[name] = rows
        order.append(name)
    return cases, art


def validate(cases, art):
    errors = []
    for name in cases:
        if name not in art:
            errors.append("%s: no art" % name)
    for name, rows in art.items():
        if name.endswith("#dup"):
            errors.append("%s: defined twice" % name[:-4])
            continue
        if name not in cases:
            errors.append("%s: art for unknown case" % name)
        if len(rows) != GRID:
            errors.append("%s: %d rows (expected %d)" % (name, len(rows), GRID))
        for i, r in enumerate(rows):
            if len(r) != GRID:
                errors.append("%s: row %d has %d chars (expected %d)" % (name, i, len(r), GRID))
            if set(r) - set("#."):
                errors.append("%s: row %d has characters other than '#' and '.'" % (name, i))
        if not any("#" in r for r in rows):
            errors.append("%s: no ink" % name)
        if rows and (("#" in rows[0]) or ("#" in rows[-1]) or any(r[:1] == "#" or r[-1:] == "#" for r in rows)):
            errors.append("%s: ink touches the outer margin" % name)
    seen = {}
    for name, rows in art.items():
        key = "\n".join(rows)
        if key in seen and not name.endswith("#dup"):
            errors.append("%s: identical to %s" % (name, seen[key]))
        seen.setdefault(key, name)
    return errors


ART_SWIFT = os.path.join(ROOT, "App", "DesignSystem", "PixelArt.swift")
ART_INKS = {"+": (110, 106, 98), "#": (142, 139, 132), "o": (163, 162, 156), "a": ACCENT}


def parse_artworks(path):
    if not os.path.exists(path):
        return {}
    src = open(path, encoding="utf-8").read()
    block = re.search(r"static let art: \[PixelArtwork: \[String\]\] = \[(.*)\n    \]", src, re.S)
    if not block:
        return {}
    out = {}
    for m in re.finditer(r"\.(\w+):\s*\[((?:\s*\"[^\"]*\",?)+)\s*\]", block.group(1)):
        out[m.group(1)] = re.findall(r"\"([^\"]*)\"", m.group(2))
    return out


def validate_artworks(arts):
    errors = []
    for name, rows in arts.items():
        if not rows or any(len(r) != len(rows[0]) for r in rows):
            errors.append("artwork %s: rows differ in length" % name)
        if any(set(r) - set("+#oa.") for r in rows):
            errors.append("artwork %s: unknown ink" % name)
    return errors


def draw_glyph(d, rows, x0, y0, cell, color, grid=None):
    if grid:
        for i in range(GRID + 1):
            d.line([(x0 + i * cell, y0), (x0 + i * cell, y0 + GRID * cell)], fill=grid)
            d.line([(x0, y0 + i * cell), (x0 + GRID * cell, y0 + i * cell)], fill=grid)
    for y, r in enumerate(rows):
        for x, ch in enumerate(r):
            if ch == "#":
                d.rectangle([x0 + x * cell, y0 + y * cell, x0 + (x + 1) * cell - 1, y0 + (y + 1) * cell - 1], fill=color)


def render(cases, art, out, artworks=None):
    from PIL import Image, ImageDraw, ImageFont

    artworks = artworks or {}
    cols = 7
    big = 6
    tile_w, tile_h = 210, 150
    rows_n = (len(cases) + cols - 1) // cols
    header = 64
    art_h = 200 if artworks else 0
    W, H = cols * tile_w + 32, header + rows_n * tile_h + 24 + art_h
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype(FONT, 16)
        title = ImageFont.truetype(FONT, 24)
    except OSError:
        font = title = ImageFont.load_default()
    d.text((16, 18), "SABLE PIXELGLYPH  %d GLYPHS  12x12 GRID" % len(cases), font=title, fill=INK)
    for i, name in enumerate(cases):
        rows = art[name]
        tx = 16 + (i % cols) * tile_w
        ty = header + (i // cols) * tile_h
        d.rectangle([tx, ty, tx + tile_w - 10, ty + tile_h - 10], fill=SURFACE, outline=BORDER)
        draw_glyph(d, rows, tx + 8, ty + 8, big, INK, grid=(34, 33, 30))
        # 20 pt @3x (5 px/cell) and 16 pt @2x (~2.67 -> 3 px/cell fitted) previews.
        draw_glyph(d, rows, tx + 92, ty + 8, 5, INK)
        draw_glyph(d, rows, tx + 160, ty + 8, 3, DIM)
        draw_glyph(d, rows, tx + 160, ty + 50, 3, ACCENT)
        draw_glyph(d, rows, tx + 92, ty + 76, 2, INK)
        d.text((tx + 8, ty + tile_h - 34), name.upper(), font=font, fill=DIM)
    # PixelEmptyArt artworks at 4 pt @3x (12 px per art pixel is too big; use 6 px).
    ax = 16
    ay = header + rows_n * tile_h + 16
    for name, rows in artworks.items():
        for y, r in enumerate(rows):
            for x, ch in enumerate(r):
                if ch in ART_INKS:
                    d.rectangle([ax + x * 6, ay + y * 6, ax + x * 6 + 5, ay + y * 6 + 5], fill=ART_INKS[ch])
        d.text((ax, ay + len(rows) * 6 + 8), "ART " + name.upper(), font=font, fill=DIM)
        ax += len(rows[0]) * 6 + 48
    img.save(out)
    return out


def main():
    cases, art = parse(SWIFT)
    artworks = parse_artworks(ART_SWIFT)
    errors = validate(cases, art) + validate_artworks(artworks)
    for e in errors:
        print("ERROR", e)
    if errors:
        sys.exit(1)
    print("%d glyphs, all valid %dx%d grids; %d artworks valid" % (len(cases), GRID, GRID, len(artworks)))
    if "--check" in sys.argv:
        return
    print("wrote", render(cases, art, OUT, artworks))


if __name__ == "__main__":
    main()
