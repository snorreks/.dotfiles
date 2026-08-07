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
        pad = "10x10";
      };

      scrollback = {
        lines = 10000;
      };

      bell = {
        system = "no";
      };

      cursor = {
        style = "block";
        blink = "no";
      };

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
