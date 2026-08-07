#!/usr/bin/env bash
# Start/stop GIF recording of a selected area.
# If already recording, stops and converts to GIF (toggle behavior).
set -euo pipefail

OUTPUT_DIR="$HOME/Pictures/Screenshots"
mkdir -p "$OUTPUT_DIR"

# If already recording, stop and convert
if [ -f /tmp/gif-recording-pid ]; then
    RECORDER_PID=$(cat /tmp/gif-recording-pid)
    if kill -0 "$RECORDER_PID" 2>/dev/null; then
        screenshot-gif-stop
        exit 0
    fi
    rm -f /tmp/gif-recording-pid
fi

# Select area to record
geometry=$(slurp -d)
[ -z "$geometry" ] && exit 1

TMP_VIDEO="/tmp/gif-recording-$USER.mp4"
rm -f "$TMP_VIDEO"

# Start recording in background
wf-recorder -g "$geometry" -f "$TMP_VIDEO" -c libx264 -r 15 &
RECORDER_PID=$!
echo "$RECORDER_PID" > /tmp/gif-recording-pid

notify-send -t 5000 \
    -h string:x-canonical-private-synchronous:gif-record \
    "🎥 Recording GIF" \
    "Press SUPER+ALT+Print again to stop"

# Wait for wf-recorder to exit (killed by screenshot-gif-stop.sh)
wait $RECORDER_PID 2>/dev/null || true
