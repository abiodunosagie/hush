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


BANNER_LINES = {
    # file: (tag after the wordmark, line, detail)
    "banner-hush": ("", "Calm and sleep sounds for macOS, synthesized live.", "Swift · SwiftUI · AVAudioEngine"),
    "banner-hush-core": ("core", "A real-time calm and sleep sound engine in Rust.", "Rust · terminal player · WebAssembly"),
    "banner-hush-audio": ("audio", "Calm and sleep sounds for Flutter, powered by Rust.", "Flutter · dart:ffi · Rust · iOS, Android, macOS"),
}


def banner(tag, line, detail):
    """Animated 1280 x 640 README header (banner.png in each repo is the still social preview).
    The word wipes in, then the last h's tail settles flat, like the tone fading; the lines fade in.
    Everything is visible by default; hidden start states live only inside the keyframes."""
    word, _ = wordmark_path()
    body, tail = word.rsplit(" H456", 1)[0], "M440,203 H456"
    scale, left, top = 0.93, 115, 160
    style = """<style>
.wipe{transform-box:fill-box;transform-origin:left center;animation:grow 1.2s cubic-bezier(.65,0,.35,1) .2s both}
.tail{transform-box:fill-box;transform-origin:left center;animation:grow .7s cubic-bezier(.22,1,.36,1) 1.4s both}
.line{animation:fade .8s ease-out 1.9s both}
@keyframes grow{from{transform:scaleX(0)}to{transform:scaleX(1)}}
@keyframes fade{from{opacity:0}to{opacity:1}}
@media (prefers-reduced-motion:reduce){.wipe,.tail,.line{animation:none}}
</style><defs><clipPath id="reveal"><rect class="wipe" x="0" y="0" width="445" height="256"/></clipPath></defs>"""
    letters = (f'<g transform="translate({left},{top - WORD_INK_TOP * scale:.1f}) scale({scale})">'
               f'<g clip-path="url(#reveal)">{stroke(body, WORD_WEIGHT, LAMP)}</g>'
               f'<path class="tail" d="{tail}" fill="none" stroke="{LAMP}" stroke-width="{WORD_WEIGHT}" stroke-linecap="round"/></g>')
    font = 'font-family="-apple-system,BlinkMacSystemFont,Helvetica Neue,Arial,sans-serif"'
    tag_svg = (f'<text class="line" x="{left + 467 * scale + 22:.0f}" y="{top + 160}" font-family="Menlo,monospace" '
               f'font-size="44" fill="#9A9AA6">{tag}</text>') if tag else ""
    text = (f'<g class="line"><text x="{left}" y="{top + 245}" {font} font-size="40" fill="#E9E5DC">{line}</text>'
            f'<text x="{left}" y="{top + 300}" font-family="Menlo,monospace" font-size="24" fill="#9A9AA6">{detail}</text></g>')
    return f'<rect width="1280" height="640" fill="{NIGHT}"/>{style}{letters}{tag_svg}{text}'


def main():
    word, word_width = wordmark_path()
    for suffix, color in (("", "#000"), ("-white", "#FFFFFF"), ("-lamp", LAMP), ("-night", NIGHT)):
        write(f"hush-wordmark{suffix}", stroke(word, WORD_WEIGHT, color), word_width, WORD_INK_HEIGHT, WORD_INK_TOP)
        write(f"hush-mark{suffix}", stroke(mark_path(), MARK_WEIGHT, color), 256, 256)
    # macOS app icon: 1024 canvas with the 824 tile of the system icon grid; the mark is scaled 2.5x and centred
    icon = (f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{NIGHT}"/>'
            f'<g transform="translate(192,192) scale(2.5)">{stroke(mark_path(), MARK_WEIGHT, LAMP)}</g>')
    write("app-icon", icon, 1024, 1024)
    for name, (tag, line, detail) in BANNER_LINES.items():
        write(name, banner(tag, line, detail), 1280, 640)


if __name__ == "__main__":
    main()
