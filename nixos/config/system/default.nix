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
    ./cache-cleanup.nix
    # ./persistence.nix — enable after the impermanence disk migration is
    # done (needs /persist to exist). See README.md "Migrating an existing
    # install to impermanence".
  ];
}
