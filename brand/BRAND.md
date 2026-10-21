# Hush brand

## The idea

Hush plays one pure tone that runs all night and fades out gently. The logo shows that moment:
the last stroke of the "h" settles into a flat line, the way a sound fades into silence.

- **Wordmark** `hush`: custom monoline lowercase letters. The final "h" carries the settle. This is the primary logo.
- **Mark**: the settling "h" on its own. Use it for the app icon, menu bar and anywhere square.

The letters are drawn, not typeset, so there is no font licence to worry about.

## Colour

| Name | HEX | RGB | Use |
|---|---|---|---|
| Lamp | `#F2B66B` | 242 182 107 | the logo on dark, the app icon mark |
| Night | `#12141C` | 18 20 28 | the logo on light, the app icon tile |

Warm lamplight on a night sky. The sleep category is full of purple gradients, moons and blue waves; amber on ink stays away from all of them.
Lamp on Night has a contrast ratio of about 10:1. On white backgrounds use Night, never Lamp (too low contrast).
One colour (black, white, Lamp or Night) is always allowed. No gradients, glows or shadows on the logo.

## Files

| File | Use |
|---|---|
| `hush-wordmark-night.svg` | wordmark on light backgrounds |
| `hush-wordmark-lamp.svg` | wordmark on dark backgrounds |
| `hush-wordmark.svg`, `hush-wordmark-white.svg` | one colour black and white |
| `hush-mark-*.svg` | the mark, same four colours |
| `app-icon.svg` | macOS app icon master (1024 grid, 824 tile) |
| `AppIcon.icns` | built app icon, copied into the bundle by `scripts/build.sh` |
| `generate.py` | regenerates every SVG above from the shared measurements |
| `make-icon.sh`, `MakeIcon.swift` | rebuild `AppIcon.icns` from the Swift drawing |

`Sources/Hush/Brand.swift` draws the same geometry in code for the window header and the menu bar.
If you change the geometry, change it in both places.

## Spacing and size

- **Clear space**: keep empty space around the logo at least the height of the wordmark's "u".
- **Minimum size**: wordmark 60 px wide; mark 16 px.
- The mark sits optically centred in its 256 box; do not crop it tighter for icons.

## Do not

- Retype the wordmark in a font, or change the letter spacing.
- Straighten the last "h" leg. The settle is the logo.
- Put Lamp on white, or recolour outside the two brand colours plus black and white.
- Add a moon, waves, headphones or zzz next to the logo.

## Rebuilding

```bash
python3 brand/generate.py   # SVG masters
./brand/make-icon.sh        # AppIcon.icns, drawn from Sources/Hush/Brand.swift
```

`swift run Hush --selftest` includes a check that the Swift drawing still covers the same area as the SVG masters.
