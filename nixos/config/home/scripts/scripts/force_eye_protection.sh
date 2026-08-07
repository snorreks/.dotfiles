#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/force_eye_protection.sh

STATE_FILE="/tmp/wlsunset-forced"

if pgrep -x wlsunset > /dev/null; then
    # If already running (auto or forced), kill it completely
    rm -f "$STATE_FILE"
    systemctl --user stop wlsunset.service 2>/dev/null
    pkill -9 -x wlsunset 2>/dev/null
else
    # Start forced 3500K mode (-S 00:00 -s 00:00 forces 24/7 night temperature)
    touch "$STATE_FILE"
    wlsunset -t 3500 -T 3501 -S 00:00 -s 00:00 &
fi

pkill -RTMIN+9 waybar 2>/dev/null || true
