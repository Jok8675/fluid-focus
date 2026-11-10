#!/bin/bash
# Removes focus-trace from ~/.config/hypr.
set -euo pipefail

HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
CONFIG="$HYPR/hyprland.lua"

if [[ -f $CONFIG ]]; then
  cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  sed -i -e '/^-- Border colour flows between windows on focus change\.$/d' \
    -e '/^require("hypr\.focus-trace")$/d' "$CONFIG"
fi
rm -f "$HYPR/focus-trace.lua"

command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true

echo "focus-trace removed."
echo "Open windows keep an explicit inactive border colour until Hyprland restarts;"
echo "log out and back in to clear it."
