# nixos/config/home/fuzzel.nix
# Pimped Fuzzel Config: Modern Spotlight UI + Wrap-Around Scroll + Stylix Integration
{
  pkgs,
  lib,
  config,
  ...
}: let
  # Stylix color bridge (falls back to Catppuccin Mocha Lavender if stylix colors aren't present)
  c =
    config.lib.stylix.colors or {
      base00 = "1e1e2e"; # Base
      base02 = "585b70"; # Surface2 (Selection)
      base04 = "7f849c"; # Overlay0 (Placeholder/Counter)
      base05 = "cdd6f4"; # Text
      base07 = "bac2de"; # Subtext1 (Prompt)
      base0D = "b4befe"; # Lavender Accent
    };
in {
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        # ── Typography & Icons ───────────────────────────────────────
        font = lib.mkForce "JetBrainsMono Nerd Font:size=11";
        icon-theme = lib.mkForce "Papirus-Dark";
        terminal = lib.mkForce "foot";

        # ── Spotlight Geometry ───────────────────────────────────────
        width = lib.mkForce 48;
        lines = lib.mkForce 12; # Compact, clean list view
        line-height = lib.mkForce 28; # Tall, touch-friendly items
        horizontal-pad = lib.mkForce 24;
        vertical-pad = lib.mkForce 14;
        inner-pad = lib.mkForce 8;
        tabs = lib.mkForce 4;

        layer = lib.mkForce "overlay";
        anchor = lib.mkForce "center";

        # ── Search & Matching ────────────────────────────────────────
        match-mode = lib.mkForce "fuzzy";
        fields = lib.mkForce "name,generic,comment,keywords,categories";

        # ── Behavior & Quality of Life ───────────────────────────────
        auto-select = lib.mkForce "no"; # Prevents accidental launches on sole match
        show-actions = lib.mkForce "yes";
        list-executables-in-path = lib.mkForce "no";
        filter-desktop = lib.mkForce "no";
        exit-on-keyboard-focus-loss = lib.mkForce "yes"; # Quick dismiss on click-away
        delayed-filter-ms = lib.mkForce 150;

        render-workers = lib.mkForce 4;
        match-workers = lib.mkForce 2;
      };

      # ── Border & Corner Rounding (Moved from main section) ─────────
      border = {
        width = lib.mkForce 2; # Matches MangoWM border accent
        radius = lib.mkForce 12; # Outer corner rounding
        selection-radius = lib.mkForce 8; # Inner selection pill rounding
      };

      # ── Key Bindings (Wrap-around Scrolling Enabled) ───────────────
      key-bindings = {
        prev = "none";
        prev-with-wrap = "Up Control+p";
        next = "none";
        next-with-wrap = "Down Control+n";
      };

      # ── Color Scheme (Frosted Glass + Stylix Palette) ──────────────
      colors = {
        background = lib.mkForce "${c.base00}dd"; # 87% Opacity for MangoWM blur
        text = lib.mkForce "${c.base05}ff";
        prompt = lib.mkForce "${c.base07}ff";
        placeholder = lib.mkForce "${c.base04}ff";
        input = lib.mkForce "${c.base05}ff";
        match = lib.mkForce "${c.base0D}ff"; # Highlighted search matches
        selection = lib.mkForce "${c.base02}ff"; # Selected pill background
        selection-text = lib.mkForce "${c.base05}ff";
        selection-match = lib.mkForce "${c.base0D}ff";
        counter = lib.mkForce "${c.base04}ff"; # Match stats text color
        border = lib.mkForce "${c.base0D}ff"; # Accent border
      };
    };
  };
}
