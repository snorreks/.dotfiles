#!/usr/bin/env bash
# Wallpaper picker using fuzzel dmenu mode with smart image previews
# Generates and caches PNG thumbnails in ~/.cache/wallpaper-thumbs
# Toggle: if fuzzel is already running, kill it and exit

set -euo pipefail

if pkill -x fuzzel 2>/dev/null; then
    exit 0
fi

WALLPAPER_PATH="$HOME/.dotfiles/wallpapers"
THUMB_CACHE="$HOME/.cache/wallpaper-thumbs"

# Ensure folders exist
if [ ! -d "$WALLPAPER_PATH" ]; then
    echo "Error: Wallpapers folder '$WALLPAPER_PATH' does not exist." >&2
    exit 1
fi
mkdir -p "$THUMB_CACHE"

# ── 1. Thumbnail Generator ───────────────────────────────────────────────
generate_thumbnails() {
    find "$WALLPAPER_PATH" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
        -o -iname "*.gif" -o -iname "*.webp" -o -iname "*.bmp" \
    \) -print0 | while IFS= read -r -d '' filepath; do
        filename=$(basename "$filepath")
        thumbpath="$THUMB_CACHE/${filename}.png"

        if [ ! -f "$thumbpath" ] || [ "$filepath" -nt "$thumbpath" ]; then
            # [0] grabs frame 0 for animated GIFs/WEBP
            magick "$filepath[0]" -thumbnail 128x128 "$thumbpath" 2>/dev/null &
        fi
    done
    wait # Wait for background generations to complete
}

generate_thumbnails

# ── 2. Stream directly into Fuzzel (Preserves \0 null bytes) ────────────
build_fuzzel_input() {
    find "$WALLPAPER_PATH" -maxdepth 1 -type f \( \
        -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \
        -o -iname "*.gif" -o -iname "*.webp" -o -iname "*.bmp" \
    \) -printf '%f\n' | sort | while IFS= read -r filename; do
        thumbpath="$THUMB_CACHE/${filename}.png"
        printf "%s\0icon\x1f%s\n" "$filename" "$thumbpath"
    done
}

# Pipe directly to fuzzel so the \0 byte isn't swallowed by bash variable assignment
WALLPAPER_NAME=$(
    build_fuzzel_input | fuzzel \
        --dmenu \
        --prompt="🎨 Wallpaper: " \
        --placeholder="Type to filter wallpapers..." \
        --width=50 \
        --lines=14 \
        --no-run-if-empty
)

# Exit gracefully if nothing was selected (ESC pressed)
if [ -z "${WALLPAPER_NAME:-}" ]; then
    echo "No wallpaper selected."
    exit 0
fi

# Clean up selected filename (strip any trailing nulls/metadata)
WALLPAPER_NAME=$(echo "$WALLPAPER_NAME" | head -n 1 | sed 's/\x00.*//; s/\x1f.*//')
SELECTED_FILE="$WALLPAPER_PATH/$WALLPAPER_NAME"

if [ -f "$SELECTED_FILE" ]; then
    wall-change "$SELECTED_FILE"
    echo "Applied '$WALLPAPER_NAME' — saved as the default wallpaper."
else
    echo "Error: Wallpaper '$WALLPAPER_NAME' not found in $WALLPAPER_PATH" >&2
    exit 1
fi
