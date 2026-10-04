#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app="dist/Markdown Reader Editor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
CGO_ENABLED=1 go build -trimpath -o "$app/Contents/MacOS/markdown-reader-editor" ./cmd/markdown-reader-editor
cp Info.plist "$app/Contents/Info.plist"
cp assets/icons/AppIcon.icns assets/icons/MarkdownDocument.icns "$app/Contents/Resources/"
codesign --force --deep --sign - "$app"
printf 'Built %s\n' "$app"
