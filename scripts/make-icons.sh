#!/bin/sh
# Regenerates assets/icons from scripts/make-icon.m: the app icon (iconset, .icns, 1024 px master) and the
# Markdown document icon (iconset, .icns).
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
clang -O2 -fobjc-arc -framework Cocoa scripts/make-icon.m -o "$tmp/make-icon"
rm -rf assets/icons/AppIcon.iconset
"$tmp/make-icon" app assets/icons/AppIcon.iconset
iconutil -c icns assets/icons/AppIcon.iconset -o assets/icons/AppIcon.icns
cp assets/icons/AppIcon.iconset/icon_512x512@2x.png assets/icons/AppIcon-1024.png
rm -rf assets/icons/MarkdownDocument.iconset
"$tmp/make-icon" document assets/icons/MarkdownDocument.iconset
iconutil -c icns assets/icons/MarkdownDocument.iconset -o assets/icons/MarkdownDocument.icns
printf 'Wrote assets/icons/AppIcon.icns and assets/icons/MarkdownDocument.icns\n'
