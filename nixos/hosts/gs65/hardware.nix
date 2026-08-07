# nixos/hosts/gs65/hardware.nix
#
# PLACEHOLDER — replace with the real output of `nixos-generate-config`
# run on the GS65 itself:
#
#   sudo nixos-generate-config --show-hardware-config > nixos/hosts/gs65/hardware.nix
#
# Then re-add the two host-independent lines this repo always sets
# (nixpkgs.hostPlatform and the Intel microcode line) if the generator
# drops them, and wire up /mnt/shared if this machine also dual-boots
# into the shared NTFS drive (see hosts/sonny-laptop/hardware.nix for
# the pattern).
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # TODO: fill in from the GS65's own boot.initrd.availableKernelModules,
  # fileSystems, and swapDevices (nvme vs sata, LUKS if encrypted, etc).

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
