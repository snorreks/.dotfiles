#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-fan.sh
#
# Read/write side of the dashboard's Cooling card (qml/SystemView.qml), backed
# by whichever of two platform devices this machine actually has:
#
#   msi-ec  — GS65, see hosts/gs65/fan-control.nix for how it comes to exist
#             and why its attributes are group-writable. Has real fan modes
#             (auto/silent/advanced) plus cooler_boost.
#   legion  — Legion Pro 7, see hosts/legion/fan-control.nix. No fan modes —
#             the EC just runs its own curve — so the only control surface is
#             fan_fullspeed, which this script reports through the same
#             "boost" field cooler_boost uses on the GS65.
#
# Everything here is sysfs, so a status read is a handful of file reads and no
# subprocess chain; it rides the same 3s tick as dashboard-stats, and only
# while the System tab is up.
#
# The whole thing is written to degrade to `{"available":false}` rather than
# fail: this script is installed on every machine (scripts.nix packages the
# directory wholesale), and wherever neither device is there — e.g. a GS65
# whose EC firmware msi-ec declined to match — the card is hidden on that
# flag, which is why no hostname ever appears in the QML.

set -eu

EC=/sys/devices/platform/msi-ec
LEGION=/sys/devices/platform/legion

# json_list "auto\nsilent" -> ["auto","silent"]
json_list() {
    printf '['
    sep=''
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s"%s"' "$sep" "$line"
        sep=','
    done
    printf ']'
}

status() {
    if [ -d "$EC" ]; then
        mode=$(cat "$EC/fan_mode" 2>/dev/null || echo "")
        modes=$(json_list <"$EC/available_fan_modes" 2>/dev/null || printf '[]')
        [ "$(cat "$EC/cooler_boost" 2>/dev/null || echo off)" = "on" ] && boost=true || boost=false

        # Surfaced so the card can say "needs a reboot for the udev rule" instead
        # of silently swallowing clicks.
        [ -w "$EC/fan_mode" ] && writable=true || writable=false

        printf '{"available":true,"modes":%s,"mode":"%s","boost":%s,"writable":%s}\n' \
            "$modes" "$mode" "$boost" "$writable"
        return 0
    fi

    if [ -d "$LEGION" ]; then
        [ "$(cat "$LEGION/fan_fullspeed" 2>/dev/null || echo 0)" = "1" ] && boost=true || boost=false
        [ -w "$LEGION/fan_fullspeed" ] && writable=true || writable=false

        printf '{"available":true,"modes":[],"mode":"","boost":%s,"writable":%s}\n' \
            "$boost" "$writable"
        return 0
    fi

    printf '{"available":false,"modes":[],"mode":"","boost":false,"writable":false}\n'
}

case "${1:-status}" in
status)
    status
    ;;
mode)
    # Validated against the driver's own list rather than a hardcoded one:
    # the mode names come from whichever msi_ec_conf matched this firmware.
    [ -d "$EC" ] || exit 0
    grep -qxF "${2:?usage: dashboard-fan mode <name>}" "$EC/available_fan_modes" || {
        echo "dashboard-fan: unknown fan mode: $2" >&2
        exit 1
    }
    printf '%s' "$2" >"$EC/fan_mode"
    ;;
boost)
    if [ -d "$EC" ]; then
        case "${2:-toggle}" in
        on) v=on ;;
        off) v=off ;;
        toggle)
            [ "$(cat "$EC/cooler_boost" 2>/dev/null || echo off)" = "on" ] && v=off || v=on
            ;;
        *)
            echo "dashboard-fan: usage: dashboard-fan boost on|off|toggle" >&2
            exit 1
            ;;
        esac
        printf '%s' "$v" >"$EC/cooler_boost"
        exit 0
    fi

    if [ -d "$LEGION" ]; then
        case "${2:-toggle}" in
        on) v=1 ;;
        off) v=0 ;;
        toggle)
            [ "$(cat "$LEGION/fan_fullspeed" 2>/dev/null || echo 0)" = "1" ] && v=0 || v=1
            ;;
        *)
            echo "dashboard-fan: usage: dashboard-fan boost on|off|toggle" >&2
            exit 1
            ;;
        esac
        printf '%s' "$v" >"$LEGION/fan_fullspeed"
        exit 0
    fi

    exit 0
    ;;
*)
    echo "dashboard-fan: usage: dashboard-fan [status | mode <name> | boost on|off|toggle]" >&2
    exit 1
    ;;
esac
