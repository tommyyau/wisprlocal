#!/bin/bash
# Copy the built app to ~/Applications (no sudo). Run build_app.sh first.
# Also removes the pre-rename ~/Applications/WisprLite.app (its data folder is left untouched).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../build.noindex/WisprLocal.app"
[ -d "$APP" ] || { echo "build first: $HERE/build_app.sh" >&2; exit 1; }
mkdir -p "$HOME/Applications"
for id in com.tommyyau.wisprlocal com.tommyyau.wisprlite; do
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
done
if [ -d "$HOME/Applications/WisprLite.app" ]; then
  echo "Removing old $HOME/Applications/WisprLite.app"
  rm -rf "$HOME/Applications/WisprLite.app"
fi
rm -rf "$HOME/Applications/WisprLocal.app"
ditto "$APP" "$HOME/Applications/WisprLocal.app"
echo "Installed: $HOME/Applications/WisprLocal.app"
echo "Launch:    open \"$HOME/Applications/WisprLocal.app\""
