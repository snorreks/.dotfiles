# nixos/hosts/legion/fan-control.nix
#
# Legion Pro 7 fan control via the out-of-tree legion-laptop kernel module
# (the LenovoLegionLinux project, packaged in nixpkgs as
# linuxPackages.lenovo-legion-module).
#
# The in-tree mainline driver (lenovo-wmi-other, lenovo-wmi-gamezone) already
# binds this machine's WMI devices fine, but explicitly refuses fan control on
# this model:
#
#   lenovo_wmi_other DC2A8805-...: fan reporting/tuning is unsupported on this device
#
# That driver gates fan control behind a firmware capability table (capdata)
# it reads at bind time, and this Legion Pro 7's table doesn't mark the fan
# feature bit — so there is no config on our end that unlocks it; the mainline
# driver's own code path stops there regardless of anything in nix. See
# dashboard/qml/SystemView.qml and dashboard-fan.sh for how the exact same
# "hidden unless the backend says it's available" shape hides the Cooling card
# on the GS65 when msi-ec doesn't bind, and hid it on this machine when nothing
# backed it at all.
#
# legion-laptop talks to the same two WMI methods directly instead of reading
# that table:
#
#   LEGION_WMI_GAMEZONE_GUID            = 887B54E3-DDDC-4B2C-8B88-68A26A8835D0
#   LEGION_WMI_LENOVO_OTHER_METHOD_GUID = DC2A8805-3A8C-41BA-A6F7-092E0089CD3B
#
# which are exactly the aliases lenovo-wmi-gamezone and lenovo-wmi-other bind
# to — the WMI bus is exclusive per GUID, so both drivers cannot hold the same
# device, and legion-laptop has to be the one that wins. Hence the blacklist
# below. lenovo-wmi-events/helpers/capdata/hotkey-utilities are left alone:
# none of their aliases overlap legion-laptop's, so Fn-key hotkeys etc. still
# work through them.
#
# ── powermode is the COOLING control, not the CPU profile ───────────────────
# legion-laptop registers a platform_profile, and on model_n2cn that handler
# and the powermode sysfs attribute are two doors onto the SAME EC register:
#
#   legion_platform_profile_set() -> write_powermode() -> wmi_write_powermode()
#   powermode_store()             -> write_powermode() -> wmi_write_powermode()
#                                                        -> SETSMARTFANMODE
#
# Verified live: `powerprofilesctl set performance` moved powermode 1 -> 3 and
# thermalmode 1 -> 3; `set balanced` moved them to 2. So as long as PPD owns
# platform_profile, the CPU profile and the fan mode are one knob and
# "CPU performance + quiet fans" is impossible.
#
# hosts/legion/power.nix breaks that by starting PPD with
# --block-driver=platform_profile, so PPD only drives intel_pstate/EPP and the
# powermode writes below are the only thing that moves the EC cooling mode.
# Read that file before changing anything here.
#
# ── Why there is no local src pin any more ──────────────────────────────────
# This module used to override the nixpkgs package to the v0.0.26 tag, because
# the nixpkgs pin at the time had no DMI 83DE / BIOS N2CN (Legion Pro 7
# 16IRX9H) entry and the probe bailed before fan control was reached:
#
#   legion legion: is_denied: 0; is_allowed: 0; do_load_by_list: 0; do_load: 0
#   legion legion: Module not usable ... it is not in allowlist. ... param force.
#   legion legion: probe with driver legion failed with error -12
#
# nixpkgs has since caught up: its lenovo-legion-module is at rev e3b21167
# (v0.0.26, 2026-09-11), the same revision the override pinned, and its model
# table contains the 83DE / N2CN -> model_n2cn entry this machine needs.
# Verified live on the running module:
#
#   legion legion: is_denied: 0; is_allowed: 1; do_load_by_list: 1; do_load: 1
#   legion legion: Using configuration for system: N2CN
#   legion legion: Read embedded controller ID 0x5507
#
# so the override is gone. Do not reintroduce a pin without checking
# `nix eval .#nixosConfigurations.legion.config.boot.kernelPackages.lenovo-legion-module.version`
# first, and never use force=1 to bypass model matching — with no model match
# the probe falls back to optimistic_allowlist[0], whose register map is the
# wrong one for this EC, the exact class of mistake this repo refuses to make
# for msi-ec (see gs65/fan-control.nix).
{
  config,
  pkgs,
  ...
}: let
  # Same shape as gs65/fan-control.nix's msi-ec-perms: these are sysfs
  # attributes on a platform device (and its hwmon child), not /dev nodes, so
  # udev's GROUP=/MODE= don't apply — permissions have to be set by hand from
  # a RUN rule.
  legion-perms = pkgs.writeShellScript "legion-perms" ''
    dev=/sys/devices/platform/legion
    [ -d "$dev" ] || exit 0

    # Two attributes back the dashboard's Cooling card, so both are opened
    # up to `users`:
    #
    #   fan_fullspeed — the Legion's equivalent of the MSI card's cooler-boost
    #                   toggle. The firmware only honours it in custom
    #                   powermode (see dashboard-fan.sh), which is why the
    #                   card enters custom around it.
    #   powermode     — the firmware's smartFanMode: quiet/balanced/
    #                   performance/custom. This is the Legion's COOLING
    #                   selector (what the GS65 backs with fan_mode). It is
    #                   NOT the CPU profile: PPD is started with
    #                   --block-driver=platform_profile on this host (see
    #                   power.nix), so nothing but dashboard-fan writes it.
    for attr in fan_fullspeed powermode; do
        [ -e "$dev/$attr" ] || continue
        ${pkgs.coreutils}/bin/chgrp users "$dev/$attr"
        ${pkgs.coreutils}/bin/chmod g+w "$dev/$attr"
    done

    # fan1_input/fan2_input (RPM) are read-only in the driver and world-
    # readable by default — nothing to chmod there. fan curve points
    # (pwm1_auto_point*_{pwm,temp}) are RW but intentionally not opened up
    # here: there's no curve editor in the dashboard yet, and writing them
    # wrong is a lot easier to get hurt by than a single fullspeed bit.
  '';
in {
  boot.blacklistedKernelModules = ["lenovo_wmi_gamezone" "lenovo_wmi_other"];
  boot.extraModulePackages = [config.boot.kernelPackages.lenovo-legion-module];
  boot.kernelModules = ["legion_laptop"];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="platform", KERNEL=="legion", RUN+="${legion-perms}"
  '';
}
