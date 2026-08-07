# nixos/config/system/default.nix
{...}: {
  imports = [
    ./boot.nix
    ./display-manager.nix
    ./environment.nix
    ./intel-nvidia.nix
    ./internationalization.nix
    ./kernel.nix
    ./networking.nix
    ./power-management.nix
    ./security.nix
    ./services.nix
    ./sound.nix
    ./user.nix
    ./gaming.nix
    ./hardware.nix
    ./docker.nix
    # ./persistence.nix
  ];
}
