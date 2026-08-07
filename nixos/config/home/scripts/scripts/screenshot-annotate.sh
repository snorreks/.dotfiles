#!/usr/bin/env bash
# Screenshot: select area, annotate with satty before saving
set -euo pipefail
mkdir -p "$HOME/Pictures/Screenshots"
filepath="$HOME/Pictures/Screenshots/$(date +'%Y-%m-%d-At-%Ih%Mm%Ss').png"
geometry=$(slurp -d)
[ -z "$geometry" ] && exit 1
grim -g "$geometry" "$filepath"
satty --filename "$filepath" --output-filename "$filepath" --actions-on-enter save-to-file --early-exit
