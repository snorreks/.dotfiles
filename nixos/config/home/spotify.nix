# nixos/config/home/spotify.nix
#
# Spotify with Spicetify (spicetify-nix module), themed from the static
# palette baseline (customColorScheme → color.ini).
#
# NOTE: spicetify is build-time only — it patches Spotify's asar in the store,
# so its colors can only change on `nixos-rebuild` (it follows the static
# tokyo-night palette; it is intentionally NOT part of the dynamic theme).
# The old NVIDIA blank-screen bug was a stale spicetify backup/theme state —
# a clean minimal customColorScheme + --disable-gpu should avoid it. If the
# screen still goes blank, run `spicetify restore backup` and report back.
{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  theme = import ./theme/lib.nix {inherit lib;};
  spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
  imports = [
    inputs.spicetify-nix.homeManagerModules.default
  ];

  programs.spicetify = {
    enable = true;
    spotifyPackage = pkgs.spotify;
    # NVIDIA + Wayland Electron workaround (blank-screen bug)
    spotifyLaunchFlags = "--disable-gpu";
    # Palette-driven theme (static baseline — see note above)
    customColorScheme = theme.mkSpicetifyColorScheme config.lib.stylix.colors;
    enabledCustomApps = with spicePkgs.apps; [];
    enabledExtensions = with spicePkgs.extensions; [];
  };
}
