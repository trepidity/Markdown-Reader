#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD
: "${QT_ROOT:?Set QT_ROOT to a Qt 6 macOS installation containing bin/macdeployqt}"
mkdir -p build/comparison dist/comparison
./scripts/build.sh
(cd comparison && go build -mod=readonly -trimpath -buildmode=c-archive -o ../build/comparison/mvcore.a ./nativecore)
clang -O2 -fobjc-arc -Ibuild/comparison comparison/appkit/main.m build/comparison/mvcore.a -framework Cocoa -framework Security -framework CoreFoundation -o build/comparison/appkit
clang++ -O2 -std=c++17 -Ibuild/comparison -I"$QT_ROOT/include" -F"$QT_ROOT/lib" comparison/qt/main.cpp build/comparison/mvcore.a -framework QtWidgets -framework QtGui -framework QtCore -framework Cocoa -framework Security -framework CoreFoundation -Wl,-rpath,"$QT_ROOT/lib" -o build/comparison/qt
(cd comparison && go build -mod=readonly -trimpath -o ../build/comparison/fyne ./fyne && go build -mod=readonly -trimpath -o ../build/comparison/gio ./gio)
for name in WebKit AppKit Fyne Qt Gio; do
 lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
 bundle="dist/comparison/Markdown Reader $name.app"
 mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
 if [ "$name" = WebKit ]; then
  cp 'dist/Markdown Reader Editor.app/Contents/MacOS/markdown-reader-editor' "$bundle/Contents/MacOS/viewer"
 else
  cp "build/comparison/$lower" "$bundle/Contents/MacOS/viewer"
 fi
 python3 - "$bundle" "$name" "$lower" <<'PY'
import plistlib,sys
bundle,name,lower=sys.argv[1:]
p=dict(CFBundleName='Markdown Reader '+name,CFBundleDisplayName='Markdown Reader '+name,CFBundleIdentifier='org.markdownreader.comparison.'+lower,CFBundleExecutable='viewer',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',LSMinimumSystemVersion='12.0',NSHighResolutionCapable=True,NSPrincipalClass='NSApplication')
# Separate the baseline settings as well as the four alternate settings stores.
if name=='WebKit':
 p['LSEnvironment']={'MARKDOWN_READER_CONFIG':__import__('os').path.expanduser('~/Library/Application Support/Markdown Reader Comparisons/WebKit')}
with open(bundle+'/Contents/Info.plist','wb') as f:plistlib.dump(p,f)
PY
 if [ "$name" = Qt ]; then "$QT_ROOT/bin/macdeployqt" "$bundle" -always-overwrite; fi
 codesign --force --deep --sign - "$bundle"
 printf 'Built %s\n' "$bundle"
done
