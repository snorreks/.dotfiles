# nixos/config/home/waybar/default.nix
#
# Waybar with a runtime-renderable stylesheet.
#
# The CSS is generated once from `theme/lib.nix`'s `mkWaybarCss` (single
# source of truth) and instantiated twice:
#   • static baseline → programs.waybar.style (also the launcher fallback)
#   • dynamic         → matugen template → ~/.cache/theme/waybar.css
#
# A small launcher passes `-s <runtime css>` so waybar picks up wallpaper
# colors on every SIGUSR1 reload (SUPER+SHIFT+b) — without fighting the
# home-manager-managed style.css path.
{
  pkgs,
  lib,
  config,
  ...
}: let
  theme = import ../theme/lib.nix {inherit lib;};

  waybar-launch = pkgs.writeShellScriptBin "waybar-launch" ''
    css="$HOME/.cache/theme/waybar.css"
    [ -f "$css" ] || css="$HOME/.config/waybar/style.css"
    exec ${pkgs.waybar}/bin/waybar -s "$css" "$@"
  '';
in {
  imports = [
    ./settings.nix
  ];

  programs.waybar = {
    enable = true;

    # Use standard pre-compiled binary from binary cache (no long builds)
    package = pkgs.waybar;

    # Static baseline stylesheet (tokyo-night) — also the launcher's fallback.
    style = theme.mkWaybarCss config.lib.stylix.colors;

    # Let systemd manage starting, logging, and restarting Waybar on crashes
    systemd = {
      enable = true;
      targets = ["graphical-session.target"];
    };
  };

  # Point the systemd unit at the launcher (resolves runtime css at start)
  systemd.user.services.waybar.Service.ExecStart =
    lib.mkForce ["${waybar-launch}/bin/waybar-launch"];

  home.packages = [waybar-launch];
}
