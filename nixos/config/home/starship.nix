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
    # No fish_prompt override to protect any more — the right-hand block is
    # native now ($fill in theme/apps/starship.nix), so let HM own the init.
    # (HM appends `starship init fish | source` AFTER interactiveShellInit,
    # which picks up the runtime STARSHIP_CONFIG from fish/default.nix.)
    enableFishIntegration = true;
    enableNushellIntegration = true;

    settings = theme.mkStarshipSettings config.lib.stylix.colors.withHashtag;
  };
}
