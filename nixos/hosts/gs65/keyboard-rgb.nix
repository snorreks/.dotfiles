# nixos/hosts/gs65/keyboard-rgb.nix
#
# The GS65's keyboard is a SteelSeries per-key RGB unit that is wired up as
# two independent devices: PS/2 for keypresses, and a USB HID interface
# (1038:1122, "SteelSeries KLC") that takes the lighting commands. Nothing in
# the kernel drives the second one — there is no /sys/class/leds entry for it,
# and msi-ec explicitly marks kbd_bl unsupported on this board because the
# backlight is RGB rather than the single-zone kind its registers describe.
#
# So lighting goes over hidraw, via msi-perkeyrgb (packaged in ../../pkgs).
# The udev rule is the whole reason this is a system module rather than a home
# one: /dev/hidraw* is root-only by default, and the tool has to open it as
# the user for the dashboard to drive it without a privileged helper.
#
# Legion never imports this — it has no 1038:1122 device, and the dashboard
# card is gated on the device existing rather than on the hostname, so the
# same QML is correct on both machines.
{pkgs, ...}: {
  environment.systemPackages = [
    (pkgs.callPackage ../../pkgs/msi-perkeyrgb.nix {})
  ];

  # Upstream ships this as 99-msi-rgb.rules with MODE="0666". Narrowed to the
  # users group: this is a laptop with one human on it, and world-writable
  # raw HID access to a keyboard is more than the job needs.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1038", ATTRS{idProduct}=="1122", GROUP="users", MODE="0660"
  '';
}
