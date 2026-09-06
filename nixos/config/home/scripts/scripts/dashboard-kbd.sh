#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-kbd.sh
#
# Read/write side of the dashboard's Keyboard light card (qml/SystemView.qml),
# wrapping msi-perkeyrgb — see hosts/gs65/keyboard-rgb.nix for the packaging
# and the udev rule that makes /dev/hidraw* openable as the user.
#
# msi-perkeyrgb is strictly write-only: the SteelSeries controller accepts
# lighting packets and reports nothing back, so "what colour is the keyboard
# right now" is not a question the hardware can answer. The state file below
# IS the answer — this script is the only thing that writes the lighting, so
# as long as every path through it records what it sent, the file and the
# keyboard agree. hosts/gs65/keyboard-restore.nix replays it at session start,
# which is what makes that true again after a power cycle.
#
# Availability is the USB HID device, not the hostname: on the Legion (no
# 1038:1122) this answers `{"available":false}` and the card stays hidden.
#
# Brightness is not a thing the controller has. msi-perkeyrgb can set a colour
# and nothing else, so "50% brightness" here means the chosen colour scaled to
# half its RGB values before it is sent. That is why the state file keeps the
# *base* colour and the brightness separately: the swatch in the dashboard has
# to stay lit on the colour you picked, not on the dimmed value on the wire.
# It follows that brightness only applies to a steady colour — the vendor
# presets are pre-baked packet sequences with their own colours in them.

set -eu

# GS65 keymap. Only matters for per-key configs — the steady/preset commands
# this script uses are model-independent — but msi-perkeyrgb defaults to GE63
# and prints a warning line when it isn't told, which would land in stdout.
MODEL=GS65

STATE_DIR="$HOME/.cache/dashboard"
STATE="$STATE_DIR/kbd.json"

kb_present() {
    [ -n "$(kb_nodes)" ]
}

# The controller exposes two hidraw interfaces and only one of them takes the
# lighting packets, so this prints both and the caller treats "any of them is
# writable" as good enough — msi-perkeyrgb picks the right one itself, via
# hid_open() on the vendor/product pair.
kb_nodes() {
    for uevent in /sys/class/hidraw/*/device/uevent; do
        [ -e "$uevent" ] || continue
        grep -qs '^HID_ID=0003:00001038:00001122$' "$uevent" || continue
        node=$(basename "$(dirname "$(dirname "$uevent")")")
        printf '/dev/%s\n' "$node"
    done
}

# False until the udev rule from hosts/gs65/keyboard-rgb.nix has actually been
# applied, which needs a reboot (or a `udevadm trigger`) after the rebuild that
# introduces it. Reported so the dashboard card can say why its clicks are not
# landing instead of just doing nothing.
kb_writable() {
    for node in $(kb_nodes); do
        [ -w "$node" ] && return 0
    done
    return 1
}

# mode is one of: off | steady | preset
save() {
    mkdir -p "$STATE_DIR"
    printf '{"mode":"%s","color":"%s","preset":"%s","brightness":"%s"}\n' \
        "$1" "$2" "$3" "$4" >"$STATE"
}

# Defaults to 100 so a state file written before brightness existed, or none at
# all, reads as full brightness rather than as off.
brightness() {
    b=$(field brightness)
    case "$b" in
    '' | *[!0-9]*) printf '100' ;;
    *) printf '%s' "$b" ;;
    esac
}

# RRGGBB scaled by a 0..100 percentage. Pure parameter expansion and shell
# arithmetic — no subprocess, because this runs on every drag of the slider.
scale() {
    rest=${1#??}
    r=$((0x${1%????} * $2 / 100))
    g=$((0x${rest%??} * $2 / 100))
    b=$((0x${rest#??} * $2 / 100))
    printf '%02x%02x%02x' "$r" "$g" "$b"
}

field() {
    # Every value here was written by save() above and is always [0-9a-z-]*,
    # so one sed is enough and this stays free of a JSON dependency — which
    # matters because `restore` runs before the graphical session is up.
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$STATE" 2>/dev/null
}

apply() {
    # $1 mode, $2 base color, $3 preset, $4 brightness
    case "$1" in
    off) msi-perkeyrgb --model "$MODEL" -d >/dev/null ;;
    steady) msi-perkeyrgb --model "$MODEL" -s "$(scale "$2" "$4")" >/dev/null ;;
    preset) msi-perkeyrgb --model "$MODEL" -p "$3" >/dev/null ;;
    esac
}

case "${1:-status}" in
status)
    if ! kb_present; then
        printf '{"available":false,"writable":false,"mode":"","color":"","preset":"","brightness":100}\n'
        exit 0
    fi
    kb_writable && writable=true || writable=false
    printf '{"available":true,"writable":%s,"mode":"%s","color":"%s","preset":"%s","brightness":%s}\n' \
        "$writable" "$(field mode)" "$(field color)" "$(field preset)" "$(brightness)"
    ;;
color)
    kb_present || exit 0
    c=$(printf '%s' "${2:?usage: dashboard-kbd color RRGGBB}" | tr 'A-Z' 'a-z' | tr -d '#')
    case "$c" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *)
        echo "dashboard-kbd: not a 6-digit hex colour: $2" >&2
        exit 1
        ;;
    esac
    apply steady "$c" "" "$(brightness)"
    save steady "$c" "" "$(brightness)"
    ;;
brightness)
    kb_present || exit 0
    n="${2:?usage: dashboard-kbd brightness 0-100}"
    case "$n" in
    '' | *[!0-9]*)
        echo "dashboard-kbd: brightness must be 0-100: $2" >&2
        exit 1
        ;;
    esac
    [ "$n" -le 100 ] || n=100

    # Only steady mode has a colour to scale. Recorded either way, so the
    # slider keeps its position and the next colour picked lands at the
    # brightness that is already showing on it.
    if [ "$(field mode)" = "steady" ] && [ -n "$(field color)" ]; then
        apply steady "$(field color)" "" "$n"
    fi
    save "$(field mode)" "$(field color)" "$(field preset)" "$n"
    ;;
preset)
    kb_present || exit 0
    p="${2:?usage: dashboard-kbd preset <name>}"
    apply preset "" "$p" "$(brightness)"
    save preset "" "$p" "$(brightness)"
    ;;
off)
    kb_present || exit 0
    apply off "" "" "$(brightness)"
    save off "" "" "$(brightness)"
    ;;
restore)
    # Session-start path (keyboard-restore.nix). Silent no-op with no keyboard
    # and no saved state, so it is inert on a fresh install and on the Legion.
    kb_present || exit 0
    [ -r "$STATE" ] || exit 0
    m=$(field mode)
    [ -n "$m" ] || exit 0
    apply "$m" "$(field color)" "$(field preset)" "$(brightness)"
    ;;
presets)
    kb_present || exit 0
    msi-perkeyrgb --model "$MODEL" --list-presets
    ;;
*)
    echo "dashboard-kbd: usage: dashboard-kbd [status | color RRGGBB | brightness 0-100 | preset <name> | off | restore | presets]" >&2
    exit 1
    ;;
esac
