# nixos/config/home/theme/lib.nix
#
# Aggregator. Every consumer keeps calling `theme.mkWaybarCss`,
# `theme.mkStarshipSettings`, `theme.matugenPalette`, … exactly as before, so
# waybar/default.nix, starship.nix and theme/default.nix need NO changes for
# the split. Move the remaining mkXxx bodies into ./apps/*.nix one at a time;
# the API surface here is what pins them together.
{lib}: let
  palette = import ./palette.nix {inherit lib;};
  render = import ./render.nix {inherit lib;};

  apps =
    (import ./apps/waybar.nix {inherit lib palette;})
    // (import ./apps/swaync.nix {inherit lib palette;})
    // (import ./apps/dashboard.nix {inherit lib;})
    // (import ./apps/starship.nix {inherit lib;})
    // (import ./apps/foot.nix {inherit lib;})
    // (import ./apps/fuzzel.nix {inherit lib;})
    // (import ./apps/swaylock.nix {inherit lib;})
    // (import ./apps/mango.nix {inherit lib;})
    // (import ./apps/yazi.nix {inherit lib;})
    // (import ./apps/zed.nix {inherit lib;})
    // (import ./apps/vesktop.nix {inherit lib;})
    // (import ./apps/pcmanfm.nix {inherit lib;})
    // (import ./apps/pyroclear.nix {inherit lib;})
    // (import ./apps/spicetify.nix {inherit lib;});
in
  palette // render // apps
