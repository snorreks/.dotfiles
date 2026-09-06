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

    # fan_fullspeed is the Legion's equivalent of the MSI card's cooler-boost
    # toggle (forces both fans to max via WMI_METHOD_ID_FAN_SET_FULLSPEED).
    for attr in fan_fullspeed; do
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
