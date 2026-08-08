#!/usr/bin/env fish
# nixos/config/home/scripts/scripts/wifi_toggle.fish

set wifi_status (nmcli radio wifi)

if [ "$wifi_status" = "enabled" ]
    nmcli radio wifi off
else
    nmcli radio wifi on
end
