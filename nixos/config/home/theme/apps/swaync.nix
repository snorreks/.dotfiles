# nixos/config/home/theme/apps/swaync.nix
#
# Wired exactly like apps/waybar.nix: the stylesheet is a real CSS file
# (../css/swaync.css) instantiated twice via palette.substPalette — static
# tokyo-night bake and matugen-rendered dynamic template.
{
  lib,
  palette,
}: {
  mkSwayncCss = c: palette.substPalette c (builtins.readFile ../css/swaync.css);
}
