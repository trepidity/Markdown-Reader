#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/build-viewer-only.sh
destination="${1:-$HOME/Applications}/Markdown Reader.app"
if [ -e "$destination" ]; then
  printf 'Already exists: %s\nMove the existing app aside before installing.\n' "$destination" >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
ditto "dist/Markdown Reader.app" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf 'Installed and registered: %s\nSet the default in Finder: Get Info on a .md file → Open with → Markdown Reader → Change All.\n' "$destination"
