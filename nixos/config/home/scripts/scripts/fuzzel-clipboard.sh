#!/usr/bin/env bash
# Clipboard history via fuzzel + cliphist
set -euo pipefail

# Toggle: if already running, kill and exit
if pkill -x fuzzel 2>/dev/null; then
    exit 0
fi

cliphist list \
    | fuzzel \
        --dmenu \
        --prompt="📋 Clipboard: " \
        --placeholder="Search clipboard history..." \
        --width=60 \
        --lines=20 \
        --no-run-if-empty \
    | cliphist decode \
    | wl-copy
