#!/usr/bin/env bash
#
# Regenerates the social sharing card (`public/brand/social-card.jpg`), the image
# X/Twitter, Slack, Discord, LinkedIn and friends show when a guaranate.dev link
# is unfurled. 1200x630 is the size every one of them crops to for a large card.
#
# The card is drawn from the brand assets and the theme palette: the terminal
# mascot on the warm near-black terminal background, behind a berry glow, with
# the wordmark, the tagline and a sample invocation.
#
# Type is set in system faces, not the site's own Space Grotesk / JetBrains Mono:
# Fontsource ships those as WOFF2 only, which FreeType (and so ImageMagick)
# cannot read. Avenir Next is the closest geometric grotesque macOS ships, and
# Menlo stands in for the mono.
#
# The card is a flattened, truecolor **JPEG**, not a PNG: X's crawler is the
# fussiest consumer of the three, and a JPEG of exactly this shape is what it
# renders reliably (guaranate.dev's sibling site, yokota.dev, ships the same).
# The first version of this card was a pngquant-palettized PNG, which X fetched
# and then declined to render.
#
# Requires ImageMagick. Only needed when the branding, the wordmark or the
# tagline changes — the generated JPEG is committed.
#
# Usage: docs-website/scripts/gen-social-card.sh

set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$docs_dir"

mascot="src/assets/brand/terminal.png"
out="public/brand/social-card.jpg"
[[ -f "$mascot" ]] || { echo "missing $mascot" >&2; exit 1; }

# Palette, from src/styles/theme.css.
bg='#17120f'            # terminal body, the darkest warm neutral
ink='#f5ebe8'           # --sl-color-gray-1, the wordmark
body='#c6b6b1'          # --sl-color-gray-2, the tagline
accent='#eda99f'        # --sl-color-accent-high, the command line
url='#e8503f'           # berry red, lifted for contrast on the dark card

display='/System/Library/Fonts/Avenir Next.ttc'
mono='/System/Library/Fonts/Menlo.ttc'
for font in "$display" "$mono"; do
  [[ -f "$font" ]] || { echo "missing font $font" >&2; exit 1; }
done

magick -size 1200x630 "xc:$bg" \
  \( -size 900x900 radial-gradient:'hsla(5,80%,45%,0.5)-#17120f00' \) \
  -geometry +420-140 -composite \
  \( "$mascot" -resize 430x430 \) -geometry +690+100 -composite \
  -font "$display" -fill "$ink" -pointsize 92 -annotate +80+250 'Guaranate' \
  -font "$display" -fill "$body" -pointsize 34 \
  -annotate +84+320 'Keep your Mac awake with native' \
  -annotate +84+368 'macOS power assertions.' \
  -font "$mono" -fill "$accent" -pointsize 30 -annotate +84+470 'guaranate 2h --reason build' \
  -font "$display" -fill "$url" -pointsize 28 -annotate +84+545 'guaranate.dev' \
  -background "$bg" -alpha remove -alpha off -colorspace sRGB -sampling-factor 4:2:0 \
  -quality 88 -strip -interlace none \
  "$out"

printf '%-12s %-32s %s\n' card "$out" \
  "$(magick "$out" -format '%wx%h %[magick] %[bit-depth]-bit' info:)"
