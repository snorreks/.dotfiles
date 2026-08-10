# nixos/config/home/theme/apps/pyroclear.nix
#
# pyroclear — terminal fire animation. Only the `[color]` block is rendered
# here; theme-render merges it into ~/.config/pyroclear/config.toml,
# preserving the [animation] section (fps/wind/height/direction) that
# pyroclear's own --settings writes.
#
# Flame gradient follows the Doom-fire direction (deep color at the base,
# bright at the tips): base08 (error red) → base0A (yellow accent, hue 90).
# Both slots are pinned warm hues (palette.nix), so the flame stays fire-
# colored on any wallpaper — static (tokyo-night) or dynamic (matugen).
{lib}: {
  mkPyroclearColors = c: ''
    [color]
    from = "#${c.base08}"
    to = "#${c.base0A}"
  '';
}
