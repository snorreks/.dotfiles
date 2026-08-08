#!/usr/bin/env bash
# wallpaper-add <image> — add a wallpaper to the collection.
#
#   1. Optimizes to webp: metadata stripped, resized to a sane cap, ~82 quality
#   2. Extracts + caches the color scheme (matugen check config: no rendering)
#   3. Regenerates the picker thumbnail (same cache as wallpaper-picker.sh)
#   4. Stages the file in git
#
# Does NOT apply the wallpaper — run `wall-change <out>` to apply it.
set -euo pipefail

SRC="${1:?usage: wallpaper-add <image>}"
DIR="$HOME/.dotfiles/wallpapers"
THUMB_CACHE="$HOME/.cache/wallpaper-thumbs"
CHECK_CONFIG="$HOME/.config/matugen/check.toml"

[ -f "$SRC" ] || { echo "wallpaper-add: '$SRC' does not exist" >&2; exit 1; }
mkdir -p "$DIR" "$THUMB_CACHE"

# ── 1. Optimize → webp ───────────────────────────────────────────────────
STEM="$(basename "$SRC")"
STEM="${STEM%.*}"
STEM="$(echo "$STEM" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | tr -cd 'a-z0-9._-')"
OUT="$DIR/$STEM.webp"

if [ "$OUT" = "$SRC" ]; then
    # Already an optimized .webp in the collection — just re-strip metadata
    magick "$SRC" -auto-orient -strip "$SRC"
    echo "Re-stripped metadata: $OUT"
else
    if [ -f "$OUT" ]; then
        echo "wallpaper-add: '$OUT' already exists (same slug) — aborting" >&2
        exit 1
    fi
    magick "$SRC" -auto-orient -strip -resize '3840x2160>' \
        -quality 82 -define webp:method=6 "$OUT"
fi

# ── 2. Extract + cache the color scheme (matugen: templates off) ────────
matugen image "$OUT" -m dark -c "$CHECK_CONFIG" --source-color-index 0 --show-colors

# ── 3. Refresh the picker thumbnail ──────────────────────────────────────
magick "$OUT[0]" -thumbnail 128x128 "$THUMB_CACHE/$STEM.webp.png" 2>/dev/null || true

# ── 4. Stage in git ──────────────────────────────────────────────────────
if git -C "$HOME/.dotfiles" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$HOME/.dotfiles" add "wallpapers/$STEM.webp"
fi

echo "Added $OUT — run 'wall-change $OUT' to apply it."
