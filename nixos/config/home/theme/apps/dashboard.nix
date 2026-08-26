# nixos/config/home/theme/apps/dashboard.nix
#
# Flat base16 → hex JSON, same builtins.toJSON-over-template-strings trick
# apps/zed.nix uses: static writes real hex, the matugen instantiation writes
# `{{ colors.xxx.dark.hex }}` template text as the JSON string values, which
# matugen then substitutes in place. No alpha()/shade() math here (unlike
# waybar/swaync's GTK CSS) — QML applies its own opacity at the Rectangle
# level, so the JSON only needs to carry flat colors.
{lib}: {
  mkDashboardTheme = c: {
    bg = "#${c.base00}";
    surface = "#${c.base01}";
    overlay = "#${c.base02}";
    muted = "#${c.base03}";
    subtle = "#${c.base04}";
    fg = "#${c.base05}";
    red = "#${c.base08}";
    orange = "#${c.base09}";
    yellow = "#${c.base0A}";
    green = "#${c.base0B}";
    cyan = "#${c.base0C}";
    blue = "#${c.base0D}";
    magenta = "#${c.base0E}";
    txt = "#${c.base05}";
    hi = "#${c.base0D}";
    ok = "#${c.base0B}";
    warn = "#${c.base0A}";
    crit = "#${c.base08}";
  };
}
