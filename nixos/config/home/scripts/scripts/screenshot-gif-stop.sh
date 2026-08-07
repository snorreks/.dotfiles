#!/usr/bin/env bash
# Stop GIF recording and convert to GIF.
set -euo pipefail

OUTPUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +'%Y-%m-%d-At-%Ih%Mm%Ss')
TMP_VIDEO="/tmp/gif-recording-$USER.mp4"
OUTPUT_GIF="$OUTPUT_DIR/$TIMESTAMP.gif"

# Kill the recorder if running
if [ -f /tmp/gif-recording-pid ]; then
    RECORDER_PID=$(cat /tmp/gif-recording-pid)
    kill "$RECORDER_PID" 2>/dev/null || true
    rm -f /tmp/gif-recording-pid
    # Wait for it to actually flush and exit
    sleep 0.5
fi

# Also try pkill as fallback
pkill -f "wf-recorder.*gif-recording" 2>/dev/null || true

if [ ! -f "$TMP_VIDEO" ]; then
    notify-send -t 3000 "❌ No recording found" "Start one with SUPER+ALT+Print first"
    exit 1
fi

notify-send -t 3000 \
    -h string:x-canonical-private-synchronous:gif-convert \
    "⏳ Converting to GIF..." \
    "This may take a moment"

# Convert to GIF with a good palette
ffmpeg -i "$TMP_VIDEO" \
    -filter_complex "fps=10,scale=iw:ih:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=256:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" \
    "$OUTPUT_GIF" -y 2>/dev/null

rm -f "$TMP_VIDEO"

# Copy GIF to clipboard
wl-copy -t image/gif < "$OUTPUT_GIF"

notify-send -t 5000 \
    -h string:x-canonical-private-synchronous:gif-done \
    "✅ GIF Saved" \
    "$(basename "$OUTPUT_GIF")\nCopied to clipboard"
