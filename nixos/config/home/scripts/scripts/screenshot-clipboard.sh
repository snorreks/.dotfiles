#!/usr/bin/env bash
# Screenshot: select area, copy to clipboard (no file saved)
set -euo pipefail
geometry=$(slurp -d)
[ -z "$geometry" ] && exit 1
tmp=$(mktemp -t screenshot-XXXXXX.png)
grim -g "$geometry" "$tmp"
wl-copy < "$tmp"
rm -f "$tmp"
