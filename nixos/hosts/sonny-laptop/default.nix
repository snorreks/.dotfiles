# nixos/hosts/sonny-laptop/default.nix
# Host module for the Lenovo Legion Pro 7 (primary machine).
{...}: {
  imports = [
    ./hardware.nix
  ];
}
