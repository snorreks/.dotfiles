#!/usr/bin/env bash
# nixos/config/system/battery/charge-limit.sh — cap the charge, and say what
# actually happened.
#
# Why this is a file and not a heredoc inside battery.nix: it is the only part
# of the battery policy that can be tested without a battery. It walks a
# fallback chain of kernel interfaces, writes to whichever one this hardware
# exposes, and then REPORTS what it got — which is the part that matters and
# the part a build-time string cannot check.
#
# ── Why the report is the point ──────────────────────────────────────────────
# There is no single kernel interface for "stop charging at N%", and the
# fallbacks are not equivalent:
#
#   1. charge_control_end_threshold   — exact, what you asked for
#   2. ideapad conservation_mode      — a BOOLEAN, not a percentage. Setting it
#                                       pins the pack at roughly 60%, whatever
#                                       you requested.
#
# So on hardware with only the second rung, "batteryChargeLimit = 80" produces
# a pack sitting at 60%, and nothing in the old script said so — it printed
# "charge limited to 80%" and moved on. This one prints what it asked for, what
# the hardware achieved, and which interface it used, and exits non-zero when
# it achieved NOTHING, so the systemd unit fails visibly instead of leaving a
# pack at 100% and a green result in the journal.
#
# Verified on the Legion (2026-10-03):
#   /sys/class/power_supply/BAT0/charge_control_end_threshold  does not exist
#   /sys/class/power_supply/BAT0/charge_control_support        does not exist
#   /sys/bus/platform/drivers/ideapad_acpi/VPC2004:00/conservation_mode = 1
# which is why the Legion's 80% is actually a pack held at about 60%.
set -o nounset -o pipefail

# Requested limit. An argument overrides the configured one for a single run —
# `sudo battery-charge-limit 100` before a trip, which is the whole reason it
# takes one.
limit="${1:-${NM_BATTERY_CHARGE_LIMIT:-}}"

# Where the sysfs interfaces live. Overridable ONLY so the tests can point this
# at a fixture tree: this script writes to kernel attributes, and a test that
# wrote to the real machine's charge thresholds would be a test suite that
# changes hardware state as a side effect of asserting about hardware state.
# Production never sets this.
sysfs="${NM_SYSFS_ROOT:-/sys}"

if [[ -z "$limit" ]]; then
  printf 'battery: no limit configured and none given (usage: battery-charge-limit [PERCENT])\n' >&2
  exit 2
fi
if ! [[ "$limit" =~ ^[0-9]+$ ]] || ((limit < 5 || limit > 100)); then
  printf 'battery: %s is not a charge percentage between 5 and 100\n' "$limit" >&2
  exit 2
fi

applied=0
achieved=""

printf 'battery: requested %s%%\n' "$limit"

# ── Rung 1 — the generic power_supply threshold ──────────────────────────────
# Exposed by thinkpad_acpi, recent ideapad_laptop/legion-laptop, asus-wmi,
# huawei-wmi and others. This is the only rung that can hit the number asked
# for, so it is tried first and, when present, is authoritative.
for bat in "$sysfs"/class/power_supply/BAT*; do
  [[ -d "$bat" ]] || continue
  end="$bat/charge_control_end_threshold"
  start="$bat/charge_control_start_threshold"
  [[ -w "$end" ]] || continue

  # Some firmware rejects an end threshold at or below the start one, so drop
  # start out of the way first. Failure here is not fatal: plenty of machines
  # expose a writable end and a read-only start.
  if [[ -w "$start" ]]; then
    if ((limit > 5)); then
      printf '%s\n' "$((limit - 5))" >"$start" || true
    else
      printf '0\n' >"$start" || true
    fi
  fi

  if printf '%s\n' "$limit" >"$end"; then
    # READ IT BACK. A write to sysfs can be accepted and clamped, ignored, or
    # rounded by the firmware, and the only way to know which is to ask the
    # kernel what it now thinks the value is.
    achieved="$(cat "$end" 2>/dev/null || true)"
    if [[ -z "$achieved" ]]; then
      achieved="unknown (wrote $limit, could not read it back)"
    fi
    printf 'battery: %s charge_control_end_threshold = %s (requested %s)\n' \
      "$(basename "$bat")" "$achieved" "$limit"
    applied=1
  else
    printf 'battery: %s refused a write to charge_control_end_threshold\n' "$(basename "$bat")" >&2
  fi
done

# ── Rung 2 — ideapad conservation mode ───────────────────────────────────────
# A boolean, so it cannot honour a percentage. Anything at or below 80 is a
# request for it (it holds around 60%); above 80 the closer match is off,
# because pinning a pack that low is not what was asked for.
if ((applied == 0)); then
  for cm in "$sysfs"/bus/platform/drivers/ideapad_acpi/*/conservation_mode; do
    [[ -w "$cm" ]] || continue
    if ((limit <= 80)); then
      target=1
    else
      target=0
    fi
    if printf '%s\n' "$target" >"$cm"; then
      readback="$(cat "$cm" 2>/dev/null || echo '?')"
      printf 'battery: ideapad conservation_mode = %s via %s\n' "$readback" "$cm"
      if [[ "$readback" == "1" ]]; then
        achieved="about 60 (conservation mode is a boolean, not a percentage; $limit% was requested)"
      else
        achieved="none (conservation mode OFF — it cannot represent $limit%)"
      fi
      applied=1
    fi
  done
fi

# ── Nothing worked ───────────────────────────────────────────────────────────
if ((applied == 0)); then
  printf 'battery: NO writable charge control on this hardware.\n' >&2
  printf 'battery: firmware left exactly as it was, which means the pack charges to 100%%.\n' >&2
  printf 'battery: to cap it you need the vendor tool or BIOS setting for this machine;\n' >&2
  printf 'battery: this is a hardware fact, not a configuration bug.\n' >&2
  exit 1
fi

printf 'battery: achieved %s\n' "$achieved"
if [[ "$achieved" != "$limit" ]]; then
  printf 'battery: note — that is NOT the requested %s%%. See the comment at the top of\n' "$limit" >&2
  printf 'battery: this script for which hardware interface was used.\n' >&2
fi
