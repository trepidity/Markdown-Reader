#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bundle="dist/Markdown Reader.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
./scripts/build-reader-plugins.sh
CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$bundle/Contents/Resources/markdown-reader" ./cmd/markdown-reader
clang -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 viewer-only/main.m -framework Cocoa -o "$bundle/Contents/MacOS/reader"
cp assets/icons/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
python3 - "$bundle" <<'PY'
import plistlib, sys
from pathlib import Path
p = dict(CFBundleName='Markdown Reader', CFBundleDisplayName='Markdown Reader',
         CFBundleIdentifier='org.markdownreader.reader', CFBundleExecutable='reader', CFBundleIconFile='AppIcon',
         CFBundlePackageType='APPL', CFBundleShortVersionString='0.1.0', CFBundleVersion='1',
         LSMinimumSystemVersion='13.0', NSHighResolutionCapable=True, NSPrincipalClass='NSApplication',
         CFBundleDocumentTypes=[dict(CFBundleTypeName='Markdown', CFBundleTypeRole='Viewer',
                                    LSHandlerRank='Alternate', CFBundleTypeExtensions=['md','markdown']),
                               dict(CFBundleTypeName='Folder', CFBundleTypeRole='Viewer',
                                    LSHandlerRank='Alternate', LSItemContentTypes=['public.folder'])])
with (Path(sys.argv[1])/'Contents/Info.plist').open('wb') as f: plistlib.dump(p,f)
PY
codesign --force --sign - "$bundle/Contents/Resources/markdown-reader"
codesign --force --deep --sign - "$bundle"
printf 'Built %s\n' "$bundle"
