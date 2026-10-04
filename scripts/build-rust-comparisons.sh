#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Build each independently so feature unification cannot silently change a renderer.
for framework in egui iced slint fltk wry; do
 cargo build --locked --release --manifest-path rust-comparison/Cargo.toml --features "$framework-ui" --bin "viewer-$framework"
 bundle="dist/rust-comparison/Markdown Reader Rust $framework.app"
 mkdir -p "$bundle/Contents/MacOS"
 cp "rust-comparison/target/release/viewer-$framework" "$bundle/Contents/MacOS/viewer-$framework"
 python3 - "$bundle" "$framework" <<'PY'
import plistlib, sys
bundle, framework = sys.argv[1:]
with open(bundle + '/Contents/Info.plist', 'wb') as target:
    plistlib.dump(dict(CFBundleName='Markdown Reader Rust ' + framework,
        CFBundleIdentifier='org.markdownreader.rust.' + framework,
        CFBundleExecutable='viewer-' + framework, CFBundlePackageType='APPL',
        CFBundleShortVersionString='0.1.0', CFBundleVersion='1',
        LSMinimumSystemVersion='12.0', NSHighResolutionCapable=True), target)
PY
 codesign --force --deep --sign - "$bundle"
 printf 'Built %s\n' "$bundle"
done
python3 scripts/summarize-rust-builds.py
