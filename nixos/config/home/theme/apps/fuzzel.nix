# nixos/config/home/theme/apps/fuzzel.nix
#
# fuzzel colors — rendered into a tiny include file that overrides the
# static fuzzel.ini (fuzzel supports `include=` with its own section scope).
{lib}: {
  mkFuzzelColors = c: {
    background = "${c.base00}dd"; # 87% opacity for MangoWM blur
    text = "${c.base05}ff";
    prompt = "${c.base07}ff";
    placeholder = "${c.base04}ff";
    input = "${c.base05}ff";
    match = "${c.base0D}ff"; # Highlighted search matches
    selection = "${c.base02}ff"; # Selected pill background
    selection-text = "${c.base05}ff";
    selection-match = "${c.base0D}ff";
    counter = "${c.base04}ff"; # Match stats text color
    border = "${c.base0D}ff"; # Accent border
  };
}
