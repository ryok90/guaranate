#!/usr/bin/env bash
#
# Regenerates the brand assets from the branding sample sheet.
#
# The sheet (`src/assets/brand/source-sheet.png`) is a 3x2 grid of mascot
# variants on a black background. Each variant is cropped out, the connected
# black background is flood-filled to transparency, and the result is trimmed and
# quantized. Fuzz is per-variant: the round badge and die-cut sticker were drawn
# with a drop shadow, so they need a wide fuzz for the shadow to go with the
# background, while the terminal-window variant needs a narrow one — its window
# body (#191716) is barely lighter than the background, and at 5% the fill leaks
# through the window's left border and punches 1px holes in it.
#
# Requires ImageMagick and pngquant. Only needed when the sheet or a crop
# changes — the generated PNGs are committed.
#
# Usage: docs/scripts/gen-brand-assets.sh

set -euo pipefail

docs_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$docs_dir"

sheet="src/assets/brand/source-sheet.png"
[[ -f "$sheet" ]] || { echo "missing $sheet" >&2; exit 1; }

# name|output|crop WxH+X+Y|fuzz
variants=(
  "mascot|src/assets/brand/mascot.png|407x496+70+42|5"
  "terminal|src/assets/brand/terminal.png|449x445+1017+538|2"
  "sticker|src/assets/brand/sticker.png|449x496+1017+42|15"
  "wink|public/brand/wink.png|407x445+70+538|5"
  "happy|public/brand/happy.png|473x445+540+538|5"
  "badge|public/brand/badge.png|473x496+540+42|15"
)

for variant in "${variants[@]}"; do
  IFS='|' read -r name out crop fuzz <<< "$variant"
  mkdir -p "$(dirname "$out")"
  magick "$sheet" -crop "$crop" +repage \
    -alpha set -fuzz "${fuzz}%" -fill none -floodfill +0+0 black \
    -trim +repage "$out"
  pngquant --force --skip-if-larger --quality 70-95 --output "$out" "$out" || true
  printf '%-9s %-32s %s\n' "$name" "$out" "$(magick "$out" -format '%wx%h' info:)"
done

# The favicon is the round badge on a square, transparent canvas.
magick public/brand/badge.png -resize 256x256 \
  -background none -gravity center -extent 256x256 public/favicon.png
pngquant --force --skip-if-larger --quality 70-95 --output public/favicon.png public/favicon.png || true
printf '%-9s %-32s %s\n' favicon public/favicon.png "$(magick public/favicon.png -format '%wx%h' info:)"
