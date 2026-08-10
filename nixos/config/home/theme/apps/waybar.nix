# nixos/config/home/theme/apps/waybar.nix
#
# The stylesheet itself now lives in ../css/waybar.css as a real CSS file —
# syntax highlighting, formatters and LSP work on it, and diffs are readable.
# Contrast repair happens in GTK color functions inside that file rather than
# in Nix, because on the matugen path the palette values are template strings
# and Nix cannot do color math on them. See the header comment there.
{
  lib,
  palette,
}: {
  mkWaybarCss = c: palette.substPalette c (builtins.readFile ../css/waybar.css);
}
