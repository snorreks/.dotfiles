#!/usr/bin/env bash
# theme-toggle [on|off] — switch wallpaper-derived dynamic theming on/off.
#
#   on   → colors are extracted from the active wallpaper (matugen) and
#          applied to waybar / fuzzel / swaylock / starship / pcmanfm / mango
#   off  → rewrite ~/.cache/theme with the static tokyo-night palette
#          (exactly today's look; HM configs are the fallback baseline)
#
# No argument: toggle. State lives in ~/.cache/theme/mode.
set -euo pipefail

STATE_DIR="$HOME/.cache/theme"
MODE_FILE="$STATE_DIR/mode"
mkdir -p "$STATE_DIR"

case "${1:-}" in
    on)
        mode="dynamic"
        ;;
    off)
        mode="static"
        ;;
    "")
        if [ "$(cat "$MODE_FILE" 2>/dev/null || echo static)" = "dynamic" ]; then
            mode="static"
        else
            mode="dynamic"
        fi
        ;;
    *)
        echo "usage: theme-toggle [on|off]" >&2
        exit 1
        ;;
esac

printf '%s\n' "$mode" > "$MODE_FILE"
theme-render
echo "theme: $mode"
