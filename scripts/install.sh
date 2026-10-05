#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/build-viewer-only.sh
destination="${1:-$HOME/Applications}/Markdown Reader.app"
rm -rf "$destination"
mkdir -p "$(dirname "$destination")"
ditto "dist/Markdown Reader.app" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf 'Installed and registered: %s\nSet the default in Finder: Get Info on a .md file → Open with → Markdown Reader → Change All.\n' "$destination"
