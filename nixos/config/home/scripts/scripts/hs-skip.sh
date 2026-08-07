#!/usr/bin/env bash
# Hearthstone Combat Skip Script for NixOS
set -euo pipefail

SLEEP_DURATION=6
IPTABLES="/run/current-system/sw/bin/iptables"

cleanup() {
    sudo "$IPTABLES" -D INPUT -p tcp -j DROP 2>/dev/null || true
    sudo "$IPTABLES" -D OUTPUT -p tcp -j DROP 2>/dev/null || true
}
trap cleanup EXIT INT TERM

notify-send "Hearthstone Skip" "Dropping connection..." -u low -i network-offline -t 1500

if sudo "$IPTABLES" -A INPUT -p tcp -j DROP && sudo "$IPTABLES" -A OUTPUT -p tcp -j DROP; then
    sleep "$SLEEP_DURATION"
    cleanup
    notify-send "Hearthstone Skip" "Restored!" -u normal -i network-transmit-receive -t 1500
else
    notify-send "Hearthstone Skip Error" "Check sudo rules!" -u critical
fi
