#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output="${1:-/private/tmp/markdown-viewer-ui-tests}"
app="$output/${2:-Markdown Viewer UI Tests}.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -fobjc-arc -framework Cocoa -framework WebKit tests/ui/host.m -o "$app/Contents/MacOS/ui-tests"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>ui-tests</string><key>CFBundleIdentifier</key><string>app.markdownviewer.ui-tests.$(basename "$output")</string><key>CFBundleName</key><string>Markdown Viewer UI Tests</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
python3 - "$app/Contents/Resources/test.html" <<'PY'
from pathlib import Path
import sys
ui = Path('cmd/markdown-viewer/ui')
html = (ui/'index.html').read_text().replace('/*APP_CSS*/',(ui/'style.css').read_text())
html = html.replace('/*APP_JS*/',(ui/'app.js').read_text()+'\n'+Path('tests/ui/regressions.js').read_text())
Path(sys.argv[1]).write_text(html)
PY
rm -f "$output/results.json"
codesign --force --sign - "$app"
printf 'Launch %s; results are written to %s/results.json.\n' "$app" "$output"
