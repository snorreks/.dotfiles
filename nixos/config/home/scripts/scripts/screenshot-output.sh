#!/usr/bin/env bash
# Screenshot: full output with cursor, save with timestamp
set -euo pipefail
mkdir -p "$HOME/Pictures/Screenshots"
grim -c "$HOME/Pictures/Screenshots/$(date +'%Y-%m-%d-At-%Ih%Mm%Ss').png"
