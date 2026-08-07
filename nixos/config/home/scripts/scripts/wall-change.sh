#!/usr/bin/env bash
# wall-change [FILE] — apply a wallpaper via awww.
#
# No argument:  restore the saved default wallpaper (from ~/.dotfiles/wallpapers/.default),
#               falling back to the first available wallpaper on a fresh machine.
# With FILE:    apply FILE and remember it as the default, so the choice
#               survives sessions and reboots (~/.dotfiles is persisted).

set -euo pipefail

WALLPAPERS_DIR="$HOME/.dotfiles/wallpapers"
STATE_FILE="$HOME/.dotfiles/wallpapers/.default"

# Ensure awww-daemon is running
if ! pgrep awww-daemon > /dev/null; then
    awww-daemon &
    sleep 1  # Wait briefly to ensure the daemon starts
fi

target="${1:-}"

if [ -z "$target" ]; then
    # Restore the saved default wallpaper
    if [ -f "$STATE_FILE" ]; then
        target="$(cat "$STATE_FILE")"
    fi

    # Fresh machine / no state yet: fall back to the first available wallpaper
    if [ ! -f "$target" ]; then
        target="$(find "$WALLPAPERS_DIR" -maxdepth 1 -type f \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
            -printf '%f\n' | sort | head -n 1 | sed "s|^|$WALLPAPERS_DIR/|")"
    fi

    if [ ! -f "$target" ]; then
        echo "wall-change: no wallpaper found in $WALLPAPERS_DIR" >&2
        exit 1
    fi
else
    # Explicit wallpaper: persist it as the default for next boot
    if [ ! -f "$target" ]; then
        echo "wall-change: '$target' does not exist" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$STATE_FILE")"
    printf '%s\n' "$target" > "$STATE_FILE"
fi

# Apply the wallpaper with transition effects
awww img --transition-type fade --transition-duration 2 "$target"
