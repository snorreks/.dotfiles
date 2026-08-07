#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# toggle-dev-ports.sh — Start / stop the sys-daemon dev-ports dashboard
# ═══════════════════════════════════════════════════════════════════════════════
#
# The dashboard server (sys-daemon serve, a Home Manager systemd user service)
# is on-demand: it only runs while you're developing. systemd manages its
# lifecycle once started (restart on crash, journal logs, no orphan processes).
#
# USAGE:
#   toggle-dev-ports            # toggle on/off
#   toggle-dev-ports on          # start the dashboard (opens the browser)
#   toggle-dev-ports off         # stop the dashboard
#   toggle-dev-ports status      # show current state
#
# The dashboard runs on http://localhost:3333 and shows live status of all
# project ports (Firebase emulators, frontend dev servers, etc.).
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SERVICE="sys-daemon.service"
URL="http://localhost:3333"

is_active() {
    systemctl --user is-active --quiet "$SERVICE"
}

notify() {
    local urgency="${2:-normal}"
    notify-send -u "$urgency" "🔌 dev-ports" "$1" 2>/dev/null || true
}

case "${1:-}" in
    on | enable | start)
        if is_active; then
            echo "ℹ️  dev-ports is already running — $URL"
            exit 0
        fi
        echo "🚀 Starting dev-ports on $URL ..."
        systemctl --user start "$SERVICE"
        sleep 0.5
        if is_active; then
            echo "✅ dev-ports running — $URL"
            notify "Running — $URL"
            (xdg-open "$URL" >/dev/null 2>&1 &) || true
        else
            echo "❌ Failed to start dev-ports (see: journalctl --user -u sys-daemon.service)"
            notify "Failed to start" "critical"
            exit 1
        fi
        ;;
    off | disable | stop)
        if ! is_active; then
            echo "ℹ️  dev-ports is not running"
            exit 0
        fi
        systemctl --user stop "$SERVICE"
        echo "✅ dev-ports stopped"
        notify "Stopped"
        ;;
    status)
        if is_active; then
            echo "🟢 dev-ports is RUNNING — $URL"
        else
            echo "🔴 dev-ports is STOPPED"
        fi
        ;;
    "" | toggle)
        if is_active; then
            "$0" off
        else
            "$0" on
        fi
        ;;
    *)
        echo "Usage: toggle-dev-ports [on|off|status]"
        exit 1
        ;;
esac
