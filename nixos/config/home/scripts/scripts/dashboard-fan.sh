#!/usr/bin/env sh
# nixos/config/home/scripts/scripts/dashboard-fan.sh
#
# Read/write side of the dashboard's Cooling card (qml/SystemView.qml), backed
# by whichever of two platform devices this machine actually has:
#
#   msi-ec  — GS65, see hosts/gs65/fan-control.nix for how it comes to exist
#             and why its attributes are group-writable. Has real fan modes
#             (auto/silent/advanced) plus cooler_boost.
#   legion  — Legion Pro 7, see hosts/legion/fan-control.nix. Its fan modes
#             live in powermode — the firmware's smartFanMode, which the EC
#             uses to pick the fan curve — and are reported through the same
#             "modes"/"mode" fields the GS65's fan_mode uses. "boost" is
#             fan_fullspeed, but the firmware only honours it while powermode
#             is custom: outside custom the WMI write stores the flag, reads
#             back 1, and the fan controller ignores it. Measured on this
#             machine: powermode=3 with fan_fullspeed=1 held ~2100 RPM, while
#             powermode=255 with fan_fullspeed=1 held ~6000 RPM. So the Legion
#             boost path flips to custom first and restores the previous mode
#             on the way out, and custom stays out of `modes`: it is an
#             implementation detail of boost, not a profile the card should
#             offer next to quiet/balanced/perf.
#
# ── Cooling is not the CPU profile ──────────────────────────────────────────
# On the Legion, powermode is the COOLING control. It used to be the same knob
# as the CPU profile, because PPD's platform_profile driver and this attribute
# are the same EC register; hosts/legion/power.nix now starts PPD with
# --block-driver=platform_profile, so PPD only drives intel_pstate/EPP and this
# script is the only writer of powermode. Nothing here reads or writes PPD, and
# nothing here should: the saved boost state is the previous COOLING mode, not
# the CPU profile.
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

# Where the Legion boost path stashes the cooling mode it is leaving. Next to
# the session (gamemode.nix uses the same XDG_RUNTIME_DIR-or-/tmp trick); only
# advisory, and a missing/garbage file falls back to performance rather than
# blocking the write.
legionState=${XDG_RUNTIME_DIR:-/tmp}/dashboard-fan-legion-powermode

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

# write_attr <path> <value>
#
# Writes value and reads it back. Returns non-zero (with a message on stderr)
# when the attribute did not take, so callers can report a real failure instead
# of pretending the requested state was applied. The Legion driver's
# powermode_store sleeps 500ms before returning, so the readback is not racing
# the EC.
write_attr() {
    _path=$1
    _want=$2
    if ! printf '%s' "$_want" >"$_path" 2>/dev/null; then
        echo "dashboard-fan: write to $_path failed" >&2
        return 1
    fi
    _got=$(cat "$_path" 2>/dev/null || echo "")
    if [ "$_got" != "$_want" ]; then
        echo "dashboard-fan: $_path did not take '$_want' (reads back '$_got')" >&2
        return 1
    fi
    return 0
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
        # Legion fan modes are powermode (smartFanMode). Only the three
        # profiles are offered as buttons: custom (255) is not a profile the
        # user picks, it is the state the boost pill enters internally so the
        # firmware will honour fan_fullspeed. mode still reports "custom" while
        # there, so the card can distinguish it from a profile with no segment
        # lit; 224 (extreme/max power) has no button for the same reason.
        case "$(cat "$LEGION/powermode" 2>/dev/null || echo "")" in
        1) mode=quiet ;;
        2) mode=balanced ;;
        3) mode=performance ;;
        255) mode=custom ;;
        *) mode="" ;;
        esac
        [ "$(cat "$LEGION/fan_fullspeed" 2>/dev/null || echo 0)" = "1" ] && boost=true || boost=false
        [ -w "$LEGION/powermode" ] && [ -w "$LEGION/fan_fullspeed" ] && writable=true || writable=false

        printf '{"available":true,"modes":["quiet","balanced","performance"],"mode":"%s","boost":%s,"writable":%s}\n' \
            "$mode" "$boost" "$writable"
        return 0
    fi

    printf '{"available":false,"modes":[],"mode":"","boost":false,"writable":false}\n'
}

case "${1:-status}" in
status)
    status
    ;;
mode)
    if [ -d "$EC" ]; then
        # Validated against the driver's own list rather than a hardcoded one:
        # the mode names come from whichever msi_ec_conf matched this firmware.
        grep -qxF "${2:?usage: dashboard-fan mode <name>}" "$EC/available_fan_modes" || {
            echo "dashboard-fan: unknown fan mode: $2" >&2
            exit 1
        }
        printf '%s' "$2" >"$EC/fan_mode"
        exit 0
    fi

    if [ -d "$LEGION" ]; then
        # The Legion's names are ours, not the driver's: powermode is an int
        # enum (the driver has no name table for it). `custom` is still
        # accepted here for the shell (and so `status`'s mode round-trips) even
        # though the card doesn't offer it.
        case "${2:?usage: dashboard-fan mode <name>}" in
        quiet) v=1 ;;
        balanced) v=2 ;;
        performance) v=3 ;;
        custom) v=255 ;;
        *)
            echo "dashboard-fan: unknown fan mode: $2" >&2
            exit 1
            ;;
        esac

        # powermode first: it is the actual cooling mode. Only then drop a
        # sticky boost, so a failed mode write cannot leave the EC in custom
        # with the boost flag already cleared.
        write_attr "$LEGION/powermode" "$v" || exit 1
        if [ "$v" != 255 ]; then
            # Picking a real profile leaves custom, where the firmware ignores
            # fan_fullspeed; clear it so the boost pill cannot lie.
            write_attr "$LEGION/fan_fullspeed" 0 || exit 1
            rm -f "$legionState"
        fi
        exit 0
    fi

    exit 0
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

        if [ "$v" = "1" ]; then
            # Remember the COOLING mode we are leaving — never the CPU profile,
            # which PPD owns and this script must not touch. Only save when not
            # already boosted: a second `boost on` would otherwise overwrite
            # the real previous mode with 255, and `boost off` would restore
            # custom instead of the user's profile.
            if [ "$(cat "$LEGION/fan_fullspeed" 2>/dev/null || echo 0)" != "1" ]; then
                cur=$(cat "$LEGION/powermode" 2>/dev/null || echo "")
                case "$cur" in
                1 | 2 | 3 | 255) printf '%s' "$cur" >"$legionState" 2>/dev/null || true ;;
                *) rm -f "$legionState" ;;
                esac
            fi

            # fan_fullspeed is only honoured in custom powermode, so boosting
            # always enters custom. If either write fails, roll back to the
            # saved mode rather than leaving the EC in custom with no boost.
            write_attr "$LEGION/powermode" 255 || exit 1
            if ! write_attr "$LEGION/fan_fullspeed" 1; then
                prev=$(cat "$legionState" 2>/dev/null || echo 3)
                case "$prev" in 1 | 2 | 3 | 255) ;; *) prev=3 ;; esac
                write_attr "$LEGION/powermode" "$prev" || true
                exit 1
            fi
            exit 0
        fi

        # boost off: drop the flag first, then put the cooling mode back. The
        # saved value is the previous cooling mode; a missing/garbage file
        # falls back to performance rather than blocking the write.
        write_attr "$LEGION/fan_fullspeed" 0 || exit 1
        prev=$(cat "$legionState" 2>/dev/null || echo 3)
        rm -f "$legionState"
        case "$prev" in
        1 | 2 | 3 | 255) ;;
        *) prev=3 ;;
        esac
        write_attr "$LEGION/powermode" "$prev" || exit 1
        exit 0
    fi

    exit 0
    ;;
*)
    echo "dashboard-fan: usage: dashboard-fan [status | mode <name> | boost on|off|toggle]" >&2
    exit 1
    ;;
esac
