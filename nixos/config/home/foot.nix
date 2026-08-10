# nixos/config/home/foot.nix
# Foot terminal — fast, GPU-less, Wayland-native terminal emulator
{
  pkgs,
  lib,
  ...
}: {
  programs.foot = {
    enable = true;
    server.enable = true; # Daemon mode for instant new windows

    settings = {
      main = {
        selection-target = "clipboard";
        term = "foot";
        shell = "${pkgs.fish}/bin/fish";
        font = "JetBrainsMono Nerd Font Mono:size=12";
        font-bold = "JetBrainsMono Nerd Font Mono:style=Bold:size=12";
        font-italic = "JetBrainsMono Nerd Font Mono:style=Italic:size=12";
        font-bold-italic = "JetBrainsMono Nerd Font Mono:style=Bold Italic:size=12";
        pad = "12x10 center";
        font-size-adjustment = "0.5";
        # Dynamic theme: [colors-dark] comes from the wallpaper-rendered file
        # (theme/apps/foot.nix) via include — NOT from stylix (its foot target
        # is disabled in theme/stylix.nix so the include isn't shadowed).
        # foot reads this at server start only; running terminals recolor
        # live via the OSC hook in fish/default.nix.
        include = "~/.cache/theme/foot-colors.ini";
        dpi-aware = "no";
        initial-color-theme = "dark";
      };

      scrollback = {
        lines = 20000;
        multiplier = "3.0";
      };

      bell = {
        system = "no";
      };

      cursor = {
        style = "beam";
        blink = "yes";
        beam-thickness = "1.5";
      };

      # NOTE: no [colors] section here on purpose — stylix owns the palette via
      # [colors-dark] (stylix.opacity.terminal = 0.95). A legacy [colors] block
      # would be ignored at runtime AND log a deprecation warning on every foot
      # start. If the terminal ever needs more opacity, change
      # stylix.opacity.terminal in theme/stylix.nix instead.

      url = {
        launch = "${pkgs.xdg-utils}/bin/xdg-open \${url}";
        label-letters = "sadfjgklewcmpgh";
        osc8-underline = "url-mode";
      };

      mouse = {
        hide-when-typing = "yes";
      };

      key-bindings = {
        # Free up Ctrl+Shift+U (foot's unicode-input mode) so it reaches
        # pi's "jump to user message" shortcut instead of dimming the screen.
        unicode-input = "none";
      };
    };
  };
}
