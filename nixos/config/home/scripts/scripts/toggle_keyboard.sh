#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/toggle_keyboard.sh
# Toggle keyboard layout (mangowm uses wlr-randr / xkb)

# 1. Cycle the layout via MangoWM's IPC command
mmsg dispatch switch_keyboard_layout

# 2. Get the new layout to show in the notification
LAYOUT_RAW=$(mmsg get keyboardlayout 2>/dev/null)

# 3. Extract layout ID safely (supports both raw text or JSON response)
NEW_LAYOUT=$(echo "$LAYOUT_RAW" | grep -o '"keyboardlayout": *"[^"]*"' | cut -d':' -f2 | tr -d '" ' | tr '[:lower:]' '[:upper:]')

if [ -z "$NEW_LAYOUT" ]; then
    # Fallback to simple clean if JSON parsing fails
    NEW_LAYOUT=$(echo "$LAYOUT_RAW" | tr -d '" ' | tr '[:lower:]' '[:upper:]')
fi

# 4. Trigger notification
notify-send "Keyboard" "Layout switched to: ${NEW_LAYOUT:-Toggle Layout}" -t 2000
