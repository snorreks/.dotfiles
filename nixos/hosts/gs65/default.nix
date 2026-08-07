# nixos/hosts/gs65/default.nix
# Host module for the MSI GS65 Stealth.
{...}: {
  imports = [
    ./hardware.nix
    ./fan-control.nix
  ];
}
