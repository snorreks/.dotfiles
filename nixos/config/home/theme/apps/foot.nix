# nixos/config/home/theme/apps/foot.nix
#
# foot terminal colors, rendered from the same base16 palette as everything
# else. Two artifacts:
#
#   • mkFootColors — a [colors-dark] block foot includes at startup. stylix's
#     own foot target is disabled (theme/stylix.nix) so this include is the
#     only colors source: NEW terminals get the wallpaper palette from the
#     first frame (foot has no live config reload — the server clones its
#     startup config for every window).
#   • mkFootOsc    — OSC 10/11/4 escape sequences. foot can't be told to
#     re-read config, but it responds to OSC color queries, so a shell hook
#     (fish prompt) emits these to recolor RUNNING terminals live.
#
# The 0-21 index map mirrors stylix's foot module (base16 → foot palette).
{lib}: let
  esc = builtins.fromJSON ''"\u001b"'';
in {
  mkFootColors = c: ''
    [colors-dark]
    alpha = 0.95
    foreground = ${c.base05}
    background = ${c.base00}
    regular0 = ${c.base00}
    regular1 = ${c.base08}
    regular2 = ${c.base0B}
    regular3 = ${c.base0A}
    regular4 = ${c.base0D}
    regular5 = ${c.base0E}
    regular6 = ${c.base0C}
    regular7 = ${c.base05}
    bright0 = ${c.base03}
    bright1 = ${c.base08}
    bright2 = ${c.base0B}
    bright3 = ${c.base0A}
    bright4 = ${c.base0D}
    bright5 = ${c.base0E}
    bright6 = ${c.base0C}
    bright7 = ${c.base07}
    16 = ${c.base09}
    17 = ${c.base0F}
    18 = ${c.base01}
    19 = ${c.base02}
    20 = ${c.base04}
    21 = ${c.base06}
  '';

  mkFootOsc = c: let
    st = s: "${esc}]${s}${esc}\\";
    reg = [
      c.base00
      c.base08
      c.base0B
      c.base0A
      c.base0D
      c.base0E
      c.base0C
      c.base05
    ];
    bri = [
      c.base03
      c.base08
      c.base0B
      c.base0A
      c.base0D
      c.base0E
      c.base0C
      c.base07
    ];
    ext = [c.base09 c.base0F c.base01 c.base02 c.base04 c.base06];
  in
    (st "10;#${c.base05}")
    + (st "11;#${c.base00}")
    + lib.concatStrings (
      lib.imap0 (i: hex: st "4;${toString i};#${hex}") (reg ++ bri ++ ext)
    );
}
