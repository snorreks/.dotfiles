# nixos/config/home/starship.nix
#
# Prompt config from theme/lib.nix `mkStarshipSettings` (single source):
#   • static baseline → programs.starship.settings (HM fallback)
#   • dynamic         → matugen template → ~/.cache/theme/starship.toml
#
# Shell init sets STARSHIP_CONFIG to the rendered file when it exists (see
# fish/default.nix), so the prompt follows the wallpaper without a rebuild.
{
  lib,
  config,
  ...
}: let
  theme = import ./theme/lib.nix {inherit lib;};
in {
  programs.starship = {
    enable = true;

    enableBashIntegration = true;
    enableFishIntegration = true;
    enableNushellIntegration = true;

    settings = theme.mkStarshipSettings config.lib.stylix.colors.withHashtag;
  };
}
