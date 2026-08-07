#!/usr/bin/env bash
# Screenshot: select area with slurp, save with timestamp
set -euo pipefail
mkdir -p "$HOME/Pictures/Screenshots"
geometry=$(slurp -d)
[ -z "$geometry" ] && exit 1
grim -g "$geometry" "$HOME/Pictures/Screenshots/$(date +'%Y-%m-%d-At-%Ih%Mm%Ss').png"
