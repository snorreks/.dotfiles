{
  pkgs,
  opts,
  inputs,
  config,
  lib,
  ...
}: {
  gtk = {
    enable = true;

    gtk2.extraConfig = ''
      gtk-toolbar-style=GTK_TOOLBAR_BOTH
      gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
      gtk-button-images=1
      gtk-menu-images=1
      gtk-enable-event-sounds=1
      gtk-enable-input-feedback-sounds=1
      gtk-xft-antialias=1
      gtk-xft-hinting=1
      gtk-xft-hintstyle="hintfull"
      gtk-xft-rgba="rgb"
    '';

    gtk3 = {
      bookmarks = [
        "file:///home/${opts.username}/Downloads"
        "file:///home/${opts.username}/Development/Projects"
        "file:///home/${opts.username}/Videos"
        "file:///mnt/shared"
        "file:///home/${opts.username}/Pictures"
      ];

      extraConfig = {
        gtk-application-prefer-dark-theme = 1;
        gtk-toolbar-style = "GTK_TOOLBAR_BOTH";
        gtk-toolbar-icon-size = "GTK_ICON_SIZE_LARGE_TOOLBAR";
        gtk-button-images = 1;
        gtk-menu-images = 1;
        gtk-enable-event-sounds = 1;
        gtk-enable-input-feedback-sounds = 1;
        gtk-xft-antialias = 1;
        gtk-xft-hinting = 1;
        gtk-xft-hintstyle = "hintfull";
        gtk-xft-rgba = "rgb";
      };
    };

    gtk4.extraConfig = {
      gtk-application-prefer-dark-theme = 1;
    };

    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.catppuccin-papirus-folders.override {
        flavor = "mocha";
        accent = "lavender";
      };
    };
  };

  imports = [
    inputs.stylix.homeModules.stylix
  ];

  # Stylix translates `stylix.cursor` into `home.pointerCursor` but (at the
  # pinned version) does not set the new explicit enable flag, which trips
  # home-manager's deprecation warning. Set it explicitly until the stylix
  # input is updated to a version that does this itself.
  home.pointerCursor.enable = true;

  fonts.fontconfig.defaultFonts = {
    monospace = ["JetBrainsMono Nerd Font Mono" "Noto Color Emoji"];
    sansSerif = ["JetBrainsMono Nerd Font" "Noto Color Emoji"];
    serif = ["JetBrainsMono Nerd Font" "Noto Color Emoji"];
  };

  stylix = {
    enable = true;

    targets.qt.enable = false;

    # targets.vscode.enable = false;
    targets.nixvim.enable = false;
    targets.zed.enable = false;
    targets.waybar.enable = false;
    targets.swaync.enable = false;
    targets.starship.enable = false;
    # foot colors are owned by the dynamic theme (theme/apps/foot.nix — the
    # include in programs.foot would otherwise be shadowed by stylix's own
    # [colors-dark]). Fonts are set explicitly in foot.nix.
    targets.foot.enable = false;
    # yazi theme is owned by the dynamic theme module (theme/lib.nix mkYaziTheme)
    targets.yazi.enable = false;
    polarity = "dark";
    # https://github.com/tinted-theming/base16-schemes
    base16Scheme = "${pkgs.base16-schemes}/share/themes/tokyo-night-dark.yaml";
    targets.firefox.profileNames = ["default"];
    cursor = {
      name = "Nordzy-cursors";
      package = pkgs.nordzy-cursor-theme;
      size = 24;
    };

    opacity = {
      applications = 0.96;
      terminal = 0.95;
      desktop = 0.95;
      popups = 0.96;
    };

    fonts = {
      sizes = {
        applications = 12;
        terminal = 12;
        desktop = 10;
        popups = 10;
      };

      monospace = {
        package = pkgs.nerd-fonts.jetbrains-mono;
        name = "JetBrainsMono Nerd Font Mono";
      };
      # Use full "JetBrainsMono Nerd Font" (non-mono) for standard text & browser rendering
      sansSerif = {
        package = pkgs.nerd-fonts.jetbrains-mono;
        name = "JetBrainsMono Nerd Font";
      };

      serif = config.stylix.fonts.sansSerif;

      emoji = {
        package = pkgs.noto-fonts-color-emoji;
        name = "Noto Color Emoji";
      };
    };
  };
}
