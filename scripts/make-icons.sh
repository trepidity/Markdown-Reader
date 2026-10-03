#!/bin/sh
# Regenerates assets/icons from scripts/make-icon.m: the iconset PNGs, AppIcon.icns, and a 1024 px master.
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
clang -O2 -fobjc-arc -framework Cocoa scripts/make-icon.m -o "$tmp/make-icon"
rm -rf assets/icons/AppIcon.iconset
"$tmp/make-icon" assets/icons/AppIcon.iconset
iconutil -c icns assets/icons/AppIcon.iconset -o assets/icons/AppIcon.icns
cp assets/icons/AppIcon.iconset/icon_512x512@2x.png assets/icons/AppIcon-1024.png
printf 'Wrote assets/icons/AppIcon.icns\n'
