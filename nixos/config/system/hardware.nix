# nixos/config/system/hardware.nix
#
# Hardware-level configuration: I2C/DDC-CI for external monitor control,
# and other hardware enablement that doesn't fit into kernel tuning.
{
  pkgs,
  ...
}: {
  # Enable I2C kernel module + udev rules for DDC/CI monitor control.
  # Allows ddcutil to talk to external displays without sudo.
  hardware.i2c.enable = true;

  # CLI tool for DDC/CI monitor control (brightness, input source, etc.)
  environment.systemPackages = [ pkgs.ddcutil ];
}
