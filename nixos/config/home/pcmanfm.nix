# nixos/config/home/pcmanfm.nix
#
# PCManFM-Qt — Native Wayland File Manager wrapped with Fusion styling,
# dynamic theme QSS (theme/lib.nix `mkPcmanfmQss`), and Papirus-Dark SVG icons.
#
# The wrapper resolves the stylesheet at launch:
#   • ~/.cache/theme/pcmanfm.qss (matugen render / theme-apply-static) if present
#   • else the build-time static QSS (tokyo-night fallback)
# Qt applies -stylesheet only at startup, so pcmanfm re-themes on next launch.
{
  pkgs,
  opts,
  config,
  lib,
  ...
}: let
  theme = import ./theme/lib.nix {inherit lib;};

  # Stylix Base16 Color Scheme Shortcuts (Tokyo Night Dark)
  c = config.lib.stylix.colors;

  # Static fallback stylesheet (tokyo-night) — used until the first render.
  qssTheme = pkgs.writeText "pcmanfm-qt-stylix.qss" (theme.mkPcmanfmQss c);

  pcmanfm-wrapped = pkgs.writeShellScriptBin "pcmanfm" ''
    qss="$HOME/.cache/theme/pcmanfm.qss"
    [ -f "$qss" ] || qss=${qssTheme}
    export QT_QPA_PLATFORM=wayland
    export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
    export QT_STYLE_OVERRIDE=fusion
    export QT_PLUGIN_PATH="${pkgs.qt6.qtsvg}/lib/qt-6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
    export XDG_DATA_DIRS="${config.gtk.iconTheme.package}/share:${pkgs.papirus-icon-theme}/share:${pkgs.hicolor-icon-theme}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
    exec ${pkgs.pcmanfm-qt}/bin/pcmanfm-qt -stylesheet "$qss" "$@"
  '';

  pcmanfm-settings = ''
    [System]
    Terminal=${opts.defaultTerminal}
    IconThemeName=Papirus-Dark
    FallbackIconThemeName=Papirus
    Archiver=file-roller

    [Behavior]
    BookmarkOpenMethod=0
    UseTrash=true
    SingleClick=false
    ConfirmDelete=true
    ConfirmTrash=true

    [FolderView]
    Mode=icon
    BigIconSize=48
    SmallIconSize=24
    SidePaneIconSize=24
    ThumbnailIconSize=64
    ShowHidden=false
    DisableSmoothScrolling=true

    [Volume]
    AutoRun=false
    MountOnOption=true
  '';
in {
  home.packages = [
    pcmanfm-wrapped
    pkgs.qt6.qtsvg
  ];

  # LXQt appearance defaults
  xdg.configFile."lxqt/lxqt.conf".text = ''
    [General]
    icon_theme=Papirus-Dark
    theme=system

    [Qt]
    style=fusion
  '';

  # Configuration profile paths
  xdg.configFile."pcmanfm-qt/settings.conf".text = pcmanfm-settings;
  xdg.configFile."pcmanfm-qt/default/settings.conf".text = pcmanfm-settings;
  xdg.configFile."pcmanfm-qt/mango/settings.conf".text = pcmanfm-settings;
  xdg.configFile."pcmanfm-qt/lxqt/settings.conf".text = pcmanfm-settings;

  # Desktop Entry Alias
  xdg.desktopEntries.pcmanfm = {
    name = "PCManFM";
    genericName = "File Manager";
    exec = "pcmanfm %U";
    icon = "system-file-manager";
    categories = ["System" "FileTools" "FileManager"];
    mimeType = ["inode/directory"];
  };

  # Declarative Right-Click Context Menu Actions (DES-EMA standard)
  xdg.dataFile = {
    # Open Editor: passes -n so Zed always opens in a new window
    "file-manager/actions/open-editor.desktop".text = ''
      [Desktop Entry]
      Type=Action
      Name=Open Editor (${opts.defaultEditor}) in this directory
      Icon=accessories-text-editor
      Profiles=profile-zero;

      [X-Action-Profile profile-zero]
      Exec=${opts.defaultEditor} -n %f
      MimeTypes=inode/directory;
    '';

    # Suppress legacy actions
    "file-manager/actions/kitty-open.desktop".text = ''
      [Desktop Entry]
      Type=Action
      NoDisplay=true
    '';
    "file-manager/actions/zeditor-open.desktop".text = ''
      [Desktop Entry]
      Type=Action
      NoDisplay=true
    '';
  };

  # Purge unmanaged/stale legacy action files on rebuild
  home.activation.cleanLegacyFileManagerActions = lib.hm.dag.entryBefore ["writeBoundary"] ''
    actions_dir="$HOME/.local/share/file-manager/actions"
    if [ -d "$actions_dir" ]; then
      $DRY_RUN_CMD rm -f "$actions_dir"/kitty* "$actions_dir"/zeditor* "$actions_dir"/open-terminal*
    fi
  '';

  home.file.".config/protonfixes/.keep".text = "";
}
