#!/usr/bin/env bash

# Show keybindings for MangoWM
if [ -f ~/.config/mango/config.conf ]; then
    config_file=~/.config/mango/config.conf
    keybinds=$(grep -oP '(?<=^bind =).*' "$config_file")
    keybinds=$(echo "$keybinds" | sed 's/,\([^,]*\)$/ = \1/' | sed 's/, exec//g' | sed 's/^,//g')
else
    notify-send "Keybinds" "No mango config found"
    exit 1
fi

fuzzel --dmenu --width=750 --prompt="Keybinds " <<< "$keybinds"
