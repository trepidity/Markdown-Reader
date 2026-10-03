#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app="dist/Markdown Viewer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
CGO_ENABLED=1 go build -trimpath -o "$app/Contents/MacOS/markdown-viewer" ./cmd/markdown-viewer
cp Info.plist "$app/Contents/Info.plist"
cp assets/icons/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app"
printf 'Built %s\n' "$app"
