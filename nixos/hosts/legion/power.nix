# nixos/hosts/legion/power.nix
#
# Legion-only split of CPU policy from cooling policy.
#
# ── The problem ─────────────────────────────────────────────────────────────
# On this machine (Legion Pro 7 16IRX9H, DMI 83DE / BIOS N2CN) the
# legion_laptop driver exposes ONE EC smart-fan/power-mode register through two
# interfaces:
#
#   /sys/firmware/acpi/platform_profile   (the driver's platform_profile)
#   /sys/devices/platform/legion/powermode
#
# and they are not independent. model_n2cn uses ACCESS_METHOD_WMI for
# powermode, and both write paths land on the same WMI call:
#
#   legion_platform_profile_set() -> write_powermode() -> wmi_write_powermode()
#   powermode_store()             -> write_powermode() -> wmi_write_powermode()
#                                                        -> SETSMARTFANMODE
#
# Verified live on this machine: `powerprofilesctl set performance` moved
# powermode 1 -> 3 and thermalmode 1 -> 3; `set balanced` moved them to 2;
# `set power-saver` moved them back to 1. So as long as PPD owns
# platform_profile, the CPU profile and the fan mode are one knob, and the
# useful combination "CPU performance + quiet fans" is impossible.
#
# ── The fix: ownership, not arbitration ─────────────────────────────────────
# PPD keeps the CPU (intel_pstate / EPP) and stops writing platform_profile
# entirely, so dashboard-fan's powermode writes are the only thing that moves
# the EC cooling mode. There is deliberately no watcher and no restore loop:
# two writers fighting over one register is the bug, not the fix.
#
# --block-driver is a PPD 0.30 option (src/power-profiles-daemon.c:
# driver_blocked() skips a driver by name). Blocking platform_profile leaves
# intel_pstate as the CPU driver, and intel_pstate advertises
# PERFORMANCE | BALANCED | POWER_SAVER (src/ppd-driver-intel-pstate.c), so the
# Performance profile stays available and is applied as EPP. PPD then falls
# back to its generic "placeholder" platform driver, which has no
# activate_profile and writes nothing.
#
# Verify after a rebuild:
#
#   powerprofilesctl list        # performance must still be listed, CpuDriver intel_pstate
#   journalctl -b -u power-profiles-daemon | grep -i "blocked\|intel"
#   cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference
#
# The ExecStart override is a systemd drop-in: nixpkgs installs the upstream
# unit via systemd.packages, and NixOS turns systemd.services.<name> into
# overrides.conf. The leading "" resets the upstream ExecStart list before the
# replacement is appended (systemd's own "empty assignment clears the list"
# rule). The executable path is derived from the configured package rather than
# hardcoded, so a PPD version bump cannot silently point at a stale store path.
{
  config,
  lib,
  ...
}: {
  systemd.services.power-profiles-daemon = lib.mkIf config.services.power-profiles-daemon.enable {
    serviceConfig.ExecStart = [
      ""
      "${config.services.power-profiles-daemon.package}/libexec/power-profiles-daemon --block-driver=platform_profile"
    ];
  };

  # ── thermald ──────────────────────────────────────────────────────────────
  # thermald cannot build its adaptive policy on this model. On the current
  # boot it logged, then exited 1:
  #
  #   Adaptive policy couldn't create any zones
  #   Possibly some sensors in the PSVT are missing
  #   Restart in non adaptive mode via systemd
  #
  # It then falls back to the generic thermal-conf.xml, whose EXAMPLE_SYSTEM /
  # TSKN sensor does not exist on this machine, so it manages no zones at all.
  # The failure is race-dependent (it has also started cleanly on other boots),
  # which is worse than a hard failure: a boot where it loses the race silently
  # loses thermal management. The firmware and the Legion EC already own
  # thermal protection and fan control, and measured PL1/PL2/PL3 are identical
  # in every firmware mode, so thermald is not buying anything here.
  #
  # Disabled on this host only. The GS65 keeps it — see
  # config/system/power-management.nix.
  services.thermald.enable = lib.mkForce false;
}
