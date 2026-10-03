#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
plugin=viewer-only/plugins/mermaid
destination="dist/Markdown Reader.app/Contents/Resources/Plugins/mermaid"
mkdir -p "$destination"
if [ ! -d "$plugin/node_modules/mermaid" ]; then
 npm ci --ignore-scripts --no-audit --no-fund --prefix "$plugin"
fi
npm run build --prefix "$plugin"
clang -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 "$plugin/render.m" -framework Cocoa -framework WebKit -o "$destination/render"
cp "$plugin/plugin.json" "$destination/plugin.json"
cp "$plugin/build/mermaid.js" "$destination/mermaid.js"
cp "$plugin/build/mermaid.js.LEGAL.txt" "$destination/mermaid.js.LEGAL.txt"
cp "$plugin/build/THIRD-PARTY-NOTICES.txt" "$destination/THIRD-PARTY-NOTICES.txt"
cp "$plugin/node_modules/mermaid/LICENSE" "$destination/Mermaid-LICENSE"
codesign --force --sign - "$destination/render"
