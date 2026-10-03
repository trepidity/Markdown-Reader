#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./scripts/build.sh
destination="${1:-$HOME/Applications}/Markdown Viewer.app"
if [ -e "$destination" ]; then
  printf 'Already exists: %s\nMove the existing app aside before installing.\n' "$destination" >&2
  exit 1
fi
mkdir -p "$(dirname "$destination")"
ditto "dist/Markdown Viewer.app" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
printf 'Installed and registered: %s\nSet the default in Finder: Get Info on a .md file → Open with → Markdown Viewer → Change All.\n' "$destination"
