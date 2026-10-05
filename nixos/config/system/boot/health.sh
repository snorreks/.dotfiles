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
: "${NM_BOOT_READY_TIMEOUT:=20}"
if [[ -n "${NM_BOOT_USER:-}" ]]; then
  uid="$(id -u "$NM_BOOT_USER" 2>/dev/null)" || {
    printf 'boot-health: cannot resolve management user\n' >&2
    exit 1
  }
  NM_BOOT_CRITICAL_UNITS+=" user@$uid.service"
fi
[[ "$NM_BOOT_READY_TIMEOUT" =~ ^[0-9]+$ ]] || exit 1

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
# A unit still activating is not proof of readiness. Wait a bounded total
# interval for local startup only; failed/absent critical units fail closed.
deadline=$((SECONDS + NM_BOOT_READY_TIMEOUT))
for unit in $NM_BOOT_CRITICAL_UNITS; do
  while :; do
    state="$(timeout 2 "$NM_SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
    [[ "$state" == active ]] && break
    if [[ "$state" != activating && "$state" != reloading ]] || ((SECONDS >= deadline)); then
      fail "critical unit $unit is ${state:-unknown}, not ready"
      break
    fi
    sleep 1
  done
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
