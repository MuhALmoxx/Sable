#!/usr/bin/env python3
"""WCAG 2.x contrast check for the Sable palette.

Reads the hex values straight from App/DesignSystem/Theme.swift (the single source of truth),
computes contrast ratios for text and control tokens against the background and every surface,
and fails (exit 1) when a pair is below its requirement:

  text tokens        >= 4.5:1  (AA, normal text) on background/surface/surfaceRaised/surfaceHigh
  borderStrong       >= 3.0:1  (AA non-text, 1.4.11) on background/surface/surfaceRaised
  onAccent           >= 4.5:1  on accent and accentPressed
  accent on accentDim (composited over background) >= 4.5:1  (selected segment label)
  danger on dangerDim (composited over surfaceRaised) >= 4.5:1 (pressed destructive button)

Usage:  python3 design/tokens/contrast.py            print the markdown table
        python3 design/tokens/contrast.py --write    also replace the table in docs/DESIGN.md
                                                     (between <!-- contrast:start/end --> markers)
Standard library only.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
THEME = os.path.join(ROOT, "App", "DesignSystem", "Theme.swift")
DOC = os.path.join(ROOT, "docs", "DESIGN.md")


def load_palette(path):
    src = open(path, encoding="utf-8").read()
    block = re.search(r"enum Palette \{(.*?)\n\}", src, re.S).group(1)
    colors = {}
    for m in re.finditer(r"static let (\w+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)(?:\.opacity\(([\d.]+)\))?", block):
        name, hexv, alpha = m.group(1), int(m.group(2), 16), float(m.group(3) or 1)
        colors[name] = (((hexv >> 16) & 255, (hexv >> 8) & 255, hexv & 255), alpha)
    return colors


def composite(fg, alpha, bg):
    return tuple(round(f * alpha + b * (1 - alpha)) for f, b in zip(fg, bg))


def luminance(rgb):
    def lin(c):
        c = c / 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def hexs(rgb):
    return "#%02X%02X%02X" % rgb


def build():
    p = load_palette(THEME)
    rgb = {k: v[0] for k, v in p.items() if v[1] == 1}
    surfaces = ["background", "surface", "surfaceRaised", "surfaceHigh"]
    rows, failures = [], []

    def check(label, fg, bg_name, bg, need):
        r = ratio(fg, bg)
        ok = r >= need
        if not ok:
            failures.append("%s on %s: %.2f < %.1f" % (label, bg_name, r, need))
        return r, ok

    header = "| Token | Hex | " + " | ".join(surfaces) + " | Needs |"
    sep = "|---|---|" + "---:|" * len(surfaces) + "---|"
    for token, need in [("textPrimary", 4.5), ("textSecondary", 4.5), ("textTertiary", 4.5),
                        ("accent", 4.5), ("danger", 4.5), ("success", 4.5), ("borderStrong", 3.0),
                        ("border", None)]:
        cells = []
        for s in surfaces:
            if need is None:
                cells.append("%.2f" % ratio(rgb[token], rgb[s]))
                continue
            if token == "borderStrong" and s == "surfaceHigh":
                cells.append("%.2f" % ratio(rgb[token], rgb[s]))
                continue
            r, ok = check(token, rgb[token], s, rgb[s], need)
            cells.append(("%.2f" % r) + ("" if ok else " FAIL"))
        needs = "decorative" if need is None else (">= %.1f (%s)" % (need, "non-text" if need == 3.0 else "AA text"))
        rows.append("| `%s` | %s | %s | %s |" % (token, hexs(rgb[token]), " | ".join(cells), needs))

    pairs = []
    r, ok = check("onAccent", rgb["onAccent"], "accent", rgb["accent"], 4.5)
    pairs.append(("`onAccent` on `accent` (primary button)", r, ok))
    r, ok = check("onAccent", rgb["onAccent"], "accentPressed", rgb["accentPressed"], 4.5)
    pairs.append(("`onAccent` on `accentPressed`", r, ok))
    dim, a = p["accentDim"]
    sel_bg = composite(dim, a, rgb["background"])
    r, ok = check("accent", rgb["accent"], "accentDim/background", sel_bg, 4.5)
    pairs.append(("`accent` on `accentDim` over background (%s, selected segment)" % hexs(sel_bg), r, ok))
    sel_bg2 = composite(dim, a, rgb["surfaceRaised"])
    r, ok = check("accent", rgb["accent"], "accentDim/surfaceRaised", sel_bg2, 4.5)
    pairs.append(("`accent` on `accentDim` over surfaceRaised (%s)" % hexs(sel_bg2), r, ok))
    ddim, da = p["dangerDim"]
    d_bg = composite(ddim, da, rgb["surfaceRaised"])
    r, ok = check("danger", rgb["danger"], "dangerDim/surfaceRaised", d_bg, 4.5)
    pairs.append(("`danger` on `dangerDim` over surfaceRaised (%s, pressed destructive)" % hexs(d_bg), r, ok))
    r, ok = check("textPrimary", rgb["textPrimary"], "accentDim/background", sel_bg, 4.5)
    pairs.append(("`textPrimary` on `accentDim` over background", r, ok))
    r, ok = check("accent", rgb["accent"], "surfaceHigh", rgb["surfaceHigh"], 3.0)
    pairs.append(("`accent` focus ring / switch track vs `surfaceHigh` (non-text)", r, ok))

    out = [header, sep] + rows + ["", "| Pair | Ratio | AA |", "|---|---:|---|"]
    out += ["| %s | %.2f | %s |" % (label, r, "pass" if ok else "FAIL") for label, r, ok in pairs]
    return "\n".join(out), failures


def main():
    table, failures = build()
    print(table)
    if "--write" in sys.argv:
        doc = open(DOC, encoding="utf-8").read()
        if "<!-- contrast:start -->" not in doc or "<!-- contrast:end -->" not in doc:
            sys.exit("contrast markers not found in docs/DESIGN.md")
        new = re.sub(r"<!-- contrast:start -->.*?<!-- contrast:end -->",
                     lambda m: "<!-- contrast:start -->\n" + table + "\n<!-- contrast:end -->", doc, flags=re.S)
        open(DOC, "w", encoding="utf-8").write(new)
        print("updated", DOC)
    if failures:
        print("\n".join("FAIL " + f for f in failures), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
