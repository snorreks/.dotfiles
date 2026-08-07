#!/usr/bin/env bash
# Toggle fuzzel app launcher: if running, kill it; otherwise launch
# Uses fuzzel config from fuzzel.nix (Catppuccin Mocha + QOL settings)
if pkill -x fuzzel 2>/dev/null; then
    exit 0
fi
fuzzel \
    --prompt="🚀 Run: " \
    --placeholder="Search apps..."
