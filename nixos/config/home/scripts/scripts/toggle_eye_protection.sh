#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/toggle_eye_protection.sh

rm -f /tmp/wlsunset-forced 2>/dev/null || true

if pgrep -x wlsunset > /dev/null; then
    # Stop both systemd service AND any standalone PIDs explicitly
    systemctl --user stop wlsunset.service 2>/dev/null
    pkill -9 -x wlsunset 2>/dev/null
else
    systemctl --user start wlsunset.service 2>/dev/null || wlsunset &
fi

pkill -RTMIN+9 waybar 2>/dev/null || true
