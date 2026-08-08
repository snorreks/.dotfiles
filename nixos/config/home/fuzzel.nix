# nixos/config/home/fuzzel.nix
# Pimped Fuzzel Config: Modern Spotlight UI + Wrap-Around Scroll + Dynamic Theme
#
# Layout lives here (declarative). Colors are NOT in this file — they are
# rendered at runtime into ~/.cache/theme/fuzzel-colors.ini (single source:
# theme/lib.nix `mkFuzzelColors`) and imported via fuzzel's `include=`
# directive, which overrides with its own section scope.
#   • dynamic mode → wallpaper palette
#   • static mode  → tokyo-night (theme-apply-static on rebuild / toggle-off)
{
  pkgs,
  lib,
  opts,
  ...
}: let
  # Runtime colors include (always populated by theme-apply-static / matugen)
  colorsInclude = "/home/${opts.username}/.cache/theme/fuzzel-colors.ini";
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

        # ── Dynamic theme colors (rendered file overrides on its own scope) ──
        include = lib.mkForce colorsInclude;
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
    };
  };
}
