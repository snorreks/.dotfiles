#!/usr/bin/env sh

# Toggle the touchpad state
toggle_touchpad() {
    touchpad_device_name="Your Touchpad Device Name"
    touchpad_id=$(xinput list | grep "$touchpad_device_name" | grep -o 'id=[0-9]*' | cut -d= -f2)
    touchpad_enabled=$(xinput list-props "$touchpad_id" | grep "Device Enabled" | grep -o '[01]$')

    if [ "$touchpad_enabled" -eq 1 ]; then
        xinput --disable "$touchpad_id"
        notify-send "Touchpad Disabled" -i ~/.config/dunst/icons/touchpad.svg -a "Touchpad Control" -r 91191 -t 800
    else
        xinput --enable "$touchpad_id"
        notify-send "Touchpad Enabled" -i ~/.config/dunst/icons/touchpad.svg -a "Touchpad Control" -r 91191 -t 800
    fi
}

toggle_touchpad
