#!/bin/bash
# Installs focus-trace into ~/.config/hypr and loads it from hyprland.lua.
set -euo pipefail

HYPR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
CONFIG="$HYPR/hyprland.lua"
LINE='require("hypr.focus-trace")'
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f $CONFIG ]] || { echo "No $CONFIG found. focus-trace needs Hyprland's Lua config (0.55+)." >&2; exit 1; }

cp "$HERE/focus-trace.lua" "$HYPR/focus-trace.lua"

if ! grep -qxF "$LINE" "$CONFIG"; then
  cp "$CONFIG" "$CONFIG.bak.$(date +%s)"
  printf '\n-- Border colour flows between windows on focus change.\n%s\n' "$LINE" >>"$CONFIG"
fi

if command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1; then
  errors="$(hyprctl configerrors)"
  [[ -z ${errors//[[:space:]]/} ]] || { echo "Hyprland reported config errors:" >&2; echo "$errors" >&2; exit 1; }
fi

echo "focus-trace installed. Settings are at the top of $HYPR/focus-trace.lua."
