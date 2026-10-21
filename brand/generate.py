"""Regenerates the Hush logo SVG masters in this folder.

Run: python3 brand/generate.py   (then brand/make-icon.sh to rebuild AppIcon.icns)
The same measurements are drawn in code in Sources/Hush/Brand.swift; change both together.
The app's --selftest checks that the Swift drawing still covers the same area as these masters.
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
NIGHT, LAMP = "#12141C", "#F2B66B"
MARK_WEIGHT, WORD_WEIGHT = 28, 22
# The wordmark is drawn on a 256 high grid; its ink runs from y 42 to 214, so the file is cropped to that.
WORD_INK_TOP, WORD_INK_HEIGHT = 42, 172


def mark_path(x=51, top=36, base=220, r=47, tail_r=36, tail=24):
    """Stem, arch, then a right leg that settles into a flat line on the baseline."""
    leg = x + 2 * r
    arch_y = base - 78  # arch centre: the arch tops out at arch_y - r
    return (f"M{x},{top} V{base} M{x},{arch_y} A{r},{r} 0 0 1 {leg},{arch_y} "
            f"V{base - tail_r} A{tail_r},{tail_r} 0 0 0 {leg + tail_r},{base} H{leg + tail_r + tail}")


def wordmark_path():
    """Custom monoline "hush": ascender 53, x-height 103, baseline 203. Returns (path, width)."""
    parts = ["M11,53 V203 M11,143 A40,40 0 0 1 91,143 V203",
             "M121,103 V163 A40,40 0 0 0 201,163 V203 M201,103 V163"]
    # s: two stacked elliptical bowls; the terminals sit at -35 and 145 degrees
    cx, rx, ry = 262, 32, 25
    start, end = math.radians(-35), math.radians(145)
    parts.append(f"M{cx + rx * math.cos(start):.2f},{128 + ry * math.sin(start):.2f} A{rx},{ry} 0 1 0 {cx},153 "
                 f"A{rx},{ry} 0 1 1 {cx + rx * math.cos(end):.2f},{178 + ry * math.sin(end):.2f}")
    # last h: the leg settles into the baseline, the same idea as the mark
    parts.append("M335,53 V203 M335,143 A40,40 0 0 1 415,143 V178 A25,25 0 0 0 440,203 H456")
    return " ".join(parts), 456 + WORD_WEIGHT // 2


def stroke(d, weight, color):
    return (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{weight}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')


def write(name, body, width, height, top=0):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 {top} {width} {height}" '
           f'width="{width}" height="{height}"><title>Hush</title>{body}</svg>\n')
    with open(os.path.join(HERE, f"{name}.svg"), "w") as f:
        f.write(svg)


def main():
    word, word_width = wordmark_path()
    for suffix, color in (("", "#000"), ("-white", "#FFFFFF"), ("-lamp", LAMP), ("-night", NIGHT)):
        write(f"hush-wordmark{suffix}", stroke(word, WORD_WEIGHT, color), word_width, WORD_INK_HEIGHT, WORD_INK_TOP)
        write(f"hush-mark{suffix}", stroke(mark_path(), MARK_WEIGHT, color), 256, 256)
    # macOS app icon: 1024 canvas with the 824 tile of the system icon grid; the mark is scaled 2.5x and centred
    icon = (f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{NIGHT}"/>'
            f'<g transform="translate(192,192) scale(2.5)">{stroke(mark_path(), MARK_WEIGHT, LAMP)}</g>')
    write("app-icon", icon, 1024, 1024)


if __name__ == "__main__":
    main()
