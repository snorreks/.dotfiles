# nixos/config/system/default.nix
# persistence.nix is imported only when opts.enablePersistence is true
# (see nixos/options.nix / hosts/<host>/options.nix).
{
  lib,
  opts,
  ...
}: {
  imports =
    [
      ./battery.nix
      ./boot.nix
      ./display-manager.nix
      ./environment.nix
      ./intel-nvidia.nix
      ./internationalization.nix
      ./kernel.nix
      ./networking.nix
      ./power-management.nix
      ./security.nix
      ./mouse.nix
      ./server.nix
      ./services.nix
      ./ssh.nix
      ./sound.nix
      ./user.nix
      ./gaming.nix
      ./hardware.nix
      ./docker.nix
      ./cache-cleanup.nix
    ]
    ++ lib.optionals opts.enablePersistence [./persistence.nix];
}
