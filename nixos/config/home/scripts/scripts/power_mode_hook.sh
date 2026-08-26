#!/usr/bin/env bash
# nixos/config/home/scripts/scripts/power_mode_hook.sh
#
# Called by the sys-daemon power cycle/set commands via a systemd user service
# or directly. Switches the nbfc-linux fan profile to match the power profile.
#
#   performance → aggressive cooling (nbfc "performance" or "aggressive")
#   balanced    → standard cooling (nbfc "balanced")
#   power-saver → quiet cooling (nbfc "silent" or "quiet")
#
# On non-GS65 machines this is a no-op (nbfc-linux won't be installed).

set -euo pipefail

PROFILE="${1:-}"
[ -z "$PROFILE" ] && exit 0

# Only act if nbfc-linux is installed.
if ! command -v nbfc &>/dev/null && ! command -v nbfc_service &>/dev/null; then
    exit 0
fi

case "$PROFILE" in
    performance)
        nbfc set -a -s performance 2>/dev/null || nbfc set -a -s aggressive 2>/dev/null || true
        ;;
    power-saver)
        nbfc set -a -s silent 2>/dev/null || nbfc set -a -s quiet 2>/dev/null || true
        ;;
    balanced)
        nbfc set -a -s balanced 2>/dev/null || true
        ;;
esac
