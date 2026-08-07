# nixos/config/home/direnv.nix
{pkgs, ...}: {
  programs.direnv = {
    enable = true;

    # This enables the ultra-fast nix-direnv caching layer so
    # your shells load in milliseconds instead of seconds.
    nix-direnv.enable = true;
  };
}
