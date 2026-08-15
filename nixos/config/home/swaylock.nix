# nixos/config/home/swaylock.nix
#
# swaylock-effects with a runtime-renderable config.
#
# Config comes from theme/lib.nix `mkSwaylockSettings` (single source):
#   • static baseline → programs.swaylock.settings (HM fallback)
#   • dynamic         → matugen template → ~/.cache/theme/swaylock.conf
#
# `swaylock-runtime` prefers the rendered config when present, else falls
# back to the HM-managed one. Invocations (mango bind + wlogout) use it.
{
  pkgs,
  lib,
  config,
  ...
}: let
  theme = import ./theme/lib.nix {inherit lib;};
  c = config.lib.stylix.colors;
in {
  # Disable Stylix's auto-generated swaylock config to prevent definition conflicts
  stylix.targets.swaylock.enable = false;

  programs.swaylock = {
    enable = true;
    package = pkgs.swaylock-effects;

    settings = theme.mkSwaylockSettings {
      inherit c;
      font = config.stylix.fonts.monospace.name;
    };
  };

  home.packages = [(import ./swaylock-runtime.nix {inherit pkgs;})];
}
