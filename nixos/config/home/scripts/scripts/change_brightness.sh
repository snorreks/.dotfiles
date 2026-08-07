#!/usr/bin/env bash
# nixos/config/home/scripts/scripts/change_brightness.sh

STATE_FILE="/tmp/custom_brightness"
LOCK_FILE="/tmp/change_brightness.lock"

# Initialize state file if missing
if [ ! -f "$STATE_FILE" ]; then
    echo "50" > "$STATE_FILE"
fi

CURRENT=$(cat "$STATE_FILE" 2>/dev/null || echo 50)

case "$1" in
    up|"+5%"|"+")
        NEW=$((CURRENT + 5))
        ;;
    down|"5%-"|"-")
        NEW=$((CURRENT - 5))
        ;;
    ''|status)
        echo "Current brightness: ${CURRENT}%"
        exit 0
        ;;
    *)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            NEW="$1"
        else
            echo "Usage: change_brightness [up|down|+5%|5%-|<number 1-100>]"
            exit 1
        fi
        ;;
esac

# Clamp brightness between 5% and 100%
[ "$NEW" -gt 100 ] && NEW=100
[ "$NEW" -lt 5 ] && NEW=5

# 1. Update state file & laptop panel instantly
echo "$NEW" > "$STATE_FILE"
brightnessctl set "${NEW}%" >/dev/null 2>&1 &

# 2. Refresh Waybar UI instantly
pkill -RTMIN+9 waybar 2>/dev/null || true

# 3. Debounced hardware update (Prevents I2C bus locking & laptop lag)
(
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0

    # Wait 0.15s to accumulate rapid scroll events
    sleep 0.15

    # Get the final requested target brightness after scrolling stops
    TARGET=$(cat "$STATE_FILE")

    if command -v ddcutil >/dev/null 2>&1; then
        ddcutil setvcp 10 "$TARGET" --display 1 >/dev/null 2>&1 &
        ddcutil setvcp 10 "$TARGET" --display 2 >/dev/null 2>&1 &
        wait
    fi
) &
