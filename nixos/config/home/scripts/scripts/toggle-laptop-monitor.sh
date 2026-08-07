#!/usr/bin/env bash
# Toggle laptop monitor (eDP-1) on/off for performance (MangoWM via mmsg)

MONITOR="eDP-1"
STATE_FILE="/tmp/.toggle-laptop-monitor-state"

log() { echo "[$(date +'%H:%M:%S')] $1"; }

is_enabled() {
    # Trust the state file (wlr-randr not available; mmsg is mango-specific)
    if [ -f "$STATE_FILE" ]; then
        grep -qx "on" "$STATE_FILE" && return 0 || return 1
    fi
    # No state file yet — assume enabled (monitor is on by default)
    return 0
}

enable_monitor() {
    log "Enabling $MONITOR..."
    mmsg dispatch enable_monitor,"$MONITOR" >/dev/null 2>&1
    echo "on" > "$STATE_FILE"
    log "$MONITOR enabled."
}

disable_monitor() {
    log "Disabling $MONITOR..."
    mmsg dispatch disable_monitor,"$MONITOR" >/dev/null 2>&1
    echo "off" > "$STATE_FILE"
    log "$MONITOR disabled."
}

case "${1:-}" in
    on|enable)  enable_monitor ;;
    off|disable) disable_monitor ;;
    help|-h|--help)
        echo "Usage: $(basename "$0") [on|off|enable|disable]"
        ;;
    "")
        if is_enabled; then disable_monitor; else enable_monitor; fi
        ;;
esac
