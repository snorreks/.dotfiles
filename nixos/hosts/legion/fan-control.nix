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
# legion-laptop registers its own platform_profile too, so the existing
# "Power mode" card (already reading/writing /sys/firmware/acpi/platform_profile
# — see dashboard's Sys.qml) keeps working unchanged; this module doesn't add
# a second one.
#
# The nixpkgs package pin (2026-05-12) predates this machine: its optimistic
# allowlist has no DMI 83DE / BIOS N2CN (Legion Pro 7 16IRX9H) entry, so probe
# bails before fan control is ever reached:
#
#   legion legion: is_denied: 0; is_allowed: 0; do_load_by_list: 0; do_load: 0
#   legion legion: Module not usable ... it is not in allowlist. ... param force.
#   legion legion: probe with driver legion failed with error -12
#
# force=1 is not a workaround: with no model match the probe falls back to
# optimistic_allowlist[0], whose register map is the wrong one for this EC — the
# exact class of mistake this repo refuses to make for msi-ec (see
# gs65/fan-control.nix). Upstream added the 83DE/N2CN -> model_n2cn entry after
# the pin, so the src is bumped to the v0.0.26 tag; delete the override once
# nixpkgs' lenovo-legion-module advances past it.
{
  config,
  pkgs,
  ...
}: let
  legion-module = config.boot.kernelPackages.lenovo-legion-module.overrideAttrs (_: {
    version = "0.0.26";
    src = pkgs.fetchFromGitHub {
      owner = "johnfanv2";
      repo = "LenovoLegionLinux";
      rev = "e3b2116714b639c852133a44398d03fc64fe9217";
      hash = "sha256-pXu0ZKUeZumvFic4rTDcXJW7alTUDie6RR2gTqjY4BI=";
    };
  });

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
    #                   performance/custom. This is the Legion's fan-mode
    #                   selector (what the GS65 backs with fan_mode). The
    #                   driver registers a platform_profile on top of it, so
    #                   this is the same value the Power mode card drives
    #                   through PPD; both write the same register.
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
  boot.extraModulePackages = [legion-module];
  boot.kernelModules = ["legion_laptop"];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="platform", KERNEL=="legion", RUN+="${legion-perms}"
  '';
}
