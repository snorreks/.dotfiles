#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-toggles.sh
#
# One-shot JSON snapshot of the quick toggles that have no push source, for the
# dashboard's HomeView (qml/Sys.qml). VPN, brightness and eye protection are
# NOT here — those already arrive on `sys-daemon waybar <mod>` streams the
# panel reads directly, and duplicating them here would give the panel two
# disagreeing answers.
#
# One spawn per tick instead of the three swaync's buttons-grid ran (it gave
# every button its own `update-command`), and the tick only runs while HomeView
# is the visible tab.

set -eu

nmcli radio wifi 2>/dev/null | grep -q '^enabled' && wifi=true || wifi=false

# rfkill, not bluetoothctl: this is the same soft-block state the bluetooth
# toggle script flips, and it answers without a running bluetoothd.
rfkill list bluetooth 2>/dev/null | grep -qi 'soft blocked: yes' && bt=false || bt=true

# airplane_mode_toggle.fish records the pre-airplane radio state in this file;
# its existence is what "airplane mode is on" means for this setup.
[ -e "$HOME/.cache/airplane_backup" ] && air=true || air=false

printf '{"wifi":%s,"bluetooth":%s,"airplane":%s}\n' "$wifi" "$bt" "$air"
