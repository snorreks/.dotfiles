#!/usr/bin/env bash
# Screenshot: freeze screen → select area → capture → unfreeze

OUTPUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +'%Y-%m-%d-At-%Ih%Mm%Ss')
export OUTPUT="$OUTPUT_DIR/$TIMESTAMP.png"

# Build helper script
CAPTURE_HELPER=$(mktemp -t screenshot-freeze-helper-XXXXXX.sh)
chmod +x "$CAPTURE_HELPER"

# Using 'SCRIPT' (quoted) avoids messy backslash escaping inside the heredoc
cat > "$CAPTURE_HELPER" << 'SCRIPT'
#!/usr/bin/env bash
geometry=$(slurp -d)

if [ -n "$geometry" ]; then
    grim -g "$geometry" "$OUTPUT"
    wl-copy < "$OUTPUT"
    notify-send -t 3000 "📸 Screenshot Saved" "$(basename "$OUTPUT")"
else
    notify-send -t 2000 "❌ Cancelled" "No area selected"
fi

# Unfreeze screen
pkill -x wayfreeze 2>/dev/null
SCRIPT

# Freeze screen and execute capture workflow
wayfreeze --after-freeze-cmd "$CAPTURE_HELPER"

# Cleanup
rm -f "$CAPTURE_HELPER"
