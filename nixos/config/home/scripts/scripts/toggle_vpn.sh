#!/usr/bin/env bash
# toggle_vpn.sh
# Toggle or rotate Proton VPN WireGuard connection on NixOS.

set -euo pipefail

BUSY_FILE="${XDG_RUNTIME_DIR:-/tmp}/vpn-busy"
SERVER_STATUS_FILE="${XDG_RUNTIME_DIR:-/tmp}/current-vpn-server"
FAILED_MARKER_DIR="${XDG_RUNTIME_DIR:-/tmp}/vpn-failed-servers"

update_waybar() {
    pkill -RTMIN+8 waybar 2>/dev/null || true
}

notify() {
    notify-send -t 2000 "VPN" "$1" 2>/dev/null || true
}

# Pass-through commands like --list or --help directly without locking
if [[ "${1:-}" == "--list" || "${1:-}" == "-l" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    exec vpn-connect "$@"
fi

if [ -f "$BUSY_FILE" ]; then
    notify "Operation in progress..."
    exit 0
fi

touch "$BUSY_FILE"
update_waybar

cleanup() {
    rm -f "$BUSY_FILE"
    update_waybar
}
trap cleanup EXIT

disconnect() {
    if sudo /run/current-system/sw/bin/systemctl stop wg-quick-wg0.service 2>/dev/null; then
        rm -f "$SERVER_STATUS_FILE"
        notify-send -i network-vpn-offline-symbolic -t 2000 "VPN" "Disconnected" 2>/dev/null || true
    else
        notify-send -i dialog-error -t 3000 "VPN" "Failed to disconnect" 2>/dev/null || true
    fi
}

# --- Action Logic ---
if [ "${1:-}" = "--rotate" ]; then
    if [ -f "$SERVER_STATUS_FILE" ]; then
        CURRENT_SERVER=$(cat "$SERVER_STATUS_FILE" 2>/dev/null || true)
        if [ -n "$CURRENT_SERVER" ]; then
            mkdir -p "$FAILED_MARKER_DIR"
            touch "$FAILED_MARKER_DIR/$CURRENT_SERVER"
        fi
    fi
    vpn-connect
elif [ $# -gt 0 ]; then
    # Forward CLI filters (e.g. vpn-connect us, vpn-connect nl-free-30)
    vpn-connect "$@"
elif systemctl is-active --quiet wg-quick-wg0.service 2>/dev/null; then
    disconnect
else
    vpn-connect
fi
