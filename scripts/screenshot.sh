#!/bin/sh
# Capture the booted simulator into docs/screenshots/<name>.png, scaled to 600 px
# wide so the repo stays small. Run from the repo root with Carrel on screen:
#
#   scripts/screenshot.sh home-for-you
#   scripts/screenshot.sh shorts
#
# Names the README uses: home-for-you, shorts, shorts-not-for-me, your-taste,
# wallet, tip-sheet, wrap
set -e
name="${1:?usage: scripts/screenshot.sh <name>}"
out="docs/screenshots/$name.png"
mkdir -p docs/screenshots
xcrun simctl io booted screenshot --type=png "$out" >/dev/null
sips --resampleWidth 600 "$out" >/dev/null
echo "saved $out ($(du -h "$out" | cut -f1))"
