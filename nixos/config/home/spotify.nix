# nixos/config/home/spotify.nix
#
# Spotify with --disable-gpu workaround for NVIDIA/Wayland blank-screen bug.
#
# NOTE: spicetify is currently disabled because it causes a blank/dark screen
# on this system (NVIDIA GPU + Wayland + MangoWM). The spicetify CSS/JS
# injection triggers the GPU rendering issue even with --disable-gpu.
# TODO: re-enable spicetify when spicetify-nix or spotify fix the rendering bug.
#
# To re-enable spicetify, uncomment the block below and remove pkgs.spotify
# from home.packages.
#
# {
#   inputs,
#   ...
# }: let
#   spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
# in {
#   imports = [inputs.spicetify-nix.homeManagerModules.default];
#   programs.spicetify = {
#     enable = true;
#     spotifyPackage = pkgs.spotify;
#     spotifyLaunchFlags = "--disable-gpu";
#     enabledCustomApps = with spicePkgs.apps; [];
#     enabledExtensions = with spicePkgs.extensions; [];
#   };
# }

{
  pkgs,
  ...
}: let
  spotify-wrapped = pkgs.writeShellScriptBin "spotify" ''
    exec ${pkgs.spotify}/bin/spotify --disable-gpu "$@"
  '';
in {
  home.packages = [spotify-wrapped];

  # Override .desktop file to launch with --disable-gpu
  xdg.desktopEntries.spotify = {
    name = "Spotify";
    exec = "spotify --disable-gpu %U";
    icon = "spotify-client";
    type = "Application";
    categories = ["Audio" "Music" "Player" "AudioVideo"];
    mimeType = ["x-scheme-handler/spotify"];
    terminal = false;
  };
}
