#!/usr/bin/env bash
# nixos/config/system/boot/health.sh — the LOCAL half of "this boot is good".
#
# ── What this decides ────────────────────────────────────────────────────────
# With systemd-boot's Automatic Boot Assessment enabled, every NixOS entry is
# written with a boot counter. systemd-boot decrements it on each boot; an entry
# whose counter reaches zero is treated as bad and skipped in favour of an older
# entry. systemd-bless-boot.service turns the counter off once the OS reaches
# boot-complete.target — i.e. once the machine got far enough for someone to
# consider it up.
#
# "Got far enough to start a oneshot" is a low bar, and for an unattended box it
# is the wrong one. This script is the gate in front of it: if it fails,
# boot-complete.target is not reached, the counter is NOT cleared, and the next
# failed boot takes the machine back to the previous generation automatically.
#
# ── LOCAL only, and that is the load-bearing word ────────────────────────────
# Every check below answers a question about THIS machine's own storage, units
# and closure. None of them touches the network, and none of them waits for it.
# That is deliberate and it is the point:
#
#   * The recovery path must work with the internet down. An ISP outage, a
#     router reboot, a captive portal or a tunnel that has not come up yet is
#     not evidence that the OS is broken, and blessing decisions must not be
#     coupled to any of them — otherwise the machine condemns the good
#     generation it is running and falls back to an older one, for a network
#     problem, while the operator is on a plane.
#   * Therefore there is deliberately NO `systemctl --failed` here. A failed
#     unit is most often NetworkManager, systemd-resolved, tailscaled or a
#     fetch of something over the wire, and treating that as "this boot is bad"
#     is precisely the coupling described above. The unit list is an explicit,
#     local, per-host set instead (opts.bootHealth.criticalUnits).
#
# ── What it does NOT do ──────────────────────────────────────────────────────
#   * It does not reboot, and it does not schedule one. A kernel freeze or a
#     hard lock produces no failed service and never reaches this script at
#     all: there is no boot, so there is no counter to decrement and nothing to
#     fall back. Recovering from a hang needs a hardware watchdog, which this
#     machine has not been shown to have; nothing here should be read as a
#     promise that it does.
#   * It does not bless on a degraded boot. Failure is failure.
#   * It does not judge the update that is running. That is ns-maint's job
#     (`ns-maint confirm`), and this script never reads its record.
#
# Exit 0 = this boot is good. Exit non-zero = not blessed, and the machine says
# so in the journal with the specific check that failed.
set -o nounset -o pipefail

# Overridable so the tests can point the whole thing at a fixture. Production
# uses the real binaries; the units set nothing and take these defaults.
: "${NM_BOOTCTL:=bootctl}"
: "${NM_SYSTEMCTL:=systemctl}"
: "${NM_FINDMNT:=findmnt}"
: "${NM_CURRENT_SYSTEM:=/run/current-system}"
: "${NM_BOOTED_SYSTEM:=/run/booted-system}"
: "${NM_ROOT_DEVICE:=/}"
# Space-separated unit names that must be healthy. Local units only; see the
# header for why this is a list and not `systemctl --failed`.
: "${NM_BOOT_CRITICAL_UNITS:=local-fs.target systemd-modules-load.service}"

problems=0
fail() {
  printf 'boot-health: %s\n' "$*" >&2
  problems=$((problems + 1))
}

# ── 1. Root is mounted read-write ────────────────────────────────────────────
# The cheapest possible "this boot is not going to work" signal: a root that
# came up read-only means /etc could not be written, which means this
# generation's activation did not complete and nothing else here matters.
root_opts="$("$NM_FINDMNT" -no OPTIONS --target "$NM_ROOT_DEVICE" 2>/dev/null | head -n1)"
if [[ -z "$root_opts" ]]; then
  fail "cannot read the mount options of $NM_ROOT_DEVICE — is the root filesystem mounted?"
elif [[ ",$root_opts," != *,rw,* ]]; then
  fail "root filesystem $NM_ROOT_DEVICE is mounted read-only (options: $root_opts)"
fi

# ── 2. A generation is actually mounted ──────────────────────────────────────
# /run/current-system is published by switch-to-configuration; its absence means
# the system did not complete activation. /run/booted-system is what this
# particular BOOT came up as, and it is the one that must not silently differ
# from the profile — otherwise a boot is blessed while running something other
# than what the profile says is current.
if [[ ! -e "$NM_CURRENT_SYSTEM" ]]; then
  fail "$NM_CURRENT_SYSTEM does not exist — activation did not complete"
fi
if [[ ! -e "$NM_BOOTED_SYSTEM" ]]; then
  fail "$NM_BOOTED_SYSTEM does not exist — this boot is not running a NixOS generation"
elif [[ -e "$NM_CURRENT_SYSTEM" && ! "$NM_CURRENT_SYSTEM" -ef "$NM_BOOTED_SYSTEM" ]]; then
  fail "running system ($NM_CURRENT_SYSTEM) is not the booted system ($NM_BOOTED_SYSTEM); this machine was switched under itself"
fi

# ── 3. The local units that have to work before anything else can ────────────
#
# Read individually rather than by asking for "is the unit failed": a unit that
# is inactive because it has not been started yet must not count as a failure,
# and neither must one that is deliberately masked. `is-active` returns a status
# for both, which is what makes the distinction possible.
for unit in $NM_BOOT_CRITICAL_UNITS; do
  # Decide on the REPORTED STATE, not on `is-active`'s exit code.
  #
  # `systemctl is-active` exits non-zero for anything that is not exactly
  # "active", which includes "activating" — and local-fs.target is genuinely
  # "activating" on a slow boot. Trusting the exit code there would condemn a
  # healthy boot and send the machine back to the previous generation for having
  # taken a few seconds longer to mount its filesystems, which is the exact
  # class of false negative this gate exists to avoid.
  #
  # The states that DO fail — inactive, failed, deactivating, unknown (a unit
  # name that does not exist) — are all ones that report themselves in the
  # output, so the printed state is the reliable signal.
  state="$("$NM_SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
  case "$state" in
    active | activating | reloading)
      :
      ;;
    *)
      fail "critical unit $unit is ${state:-unknown}, not active"
      ;;
  esac
done

# ── 4. The boot loader still answers ─────────────────────────────────────────
#
# Not the entry — the loader. If bootctl cannot find systemd-boot on the ESP,
# the boot counting this whole mechanism depends on is not in effect, and
# blessing the entry would remove the counter that is the only fallback there
# is. Refusing to bless in that case is the conservative direction: the entry
# keeps its counter, so systemd-boot will still fall back if it has to.
if ! "$NM_BOOTCTL" --print-boot-path >/dev/null 2>&1; then
  fail "bootctl could not locate the boot partition — systemd-boot is not installed, so there is no boot counting to fall back to"
fi

if ((problems > 0)); then
  printf 'boot-health: %d local check(s) failed — this boot is NOT blessed.\n' "$problems" >&2
  printf 'boot-health: the boot counter stays set, so systemd-boot will fall back to the\n' >&2
  printf 'boot-health: previous entry after %s further failed boot(s). Nothing here reboots.\n' \
    "${NM_BOOT_TRIES:-3}" >&2
  exit 1
fi

printf 'boot-health: local checks passed — this boot can be blessed.\n'
