# nixos/config/home/xdg.nix
#
# Global XDG Standards: MIME defaults, user dirs, and generic desktop entries.
{
  pkgs,
  opts,
  ...
}: {
  home.packages = with pkgs; [
    xdg-utils # CLI tools like `xdg-mime`, `xdg-open`
    xdg-user-dirs
  ];

  # Default terminal for GTK/DConf aware applications
  dconf.settings = {
    "org/cinnamon/desktop/default-applications/terminal" = {
      exec = opts.defaultTerminal;
      exec-arg = "";
    };
  };

  xdg.configFile."mimeapps.list".force = true;

  xdg = {
    enable = true;

    mimeApps = {
      enable = true;

      defaultApplications = let
        browser = ["${opts.defaultBrowser}.desktop"];
        editor = ["${opts.defaultEditor}.desktop"];
        fileManager = ["${opts.defaultFileManager}.desktop"];
        image = ["imv-dir.desktop"];
        video = ["mpv.desktop"];
        archive = ["org.gnome.FileRoller.desktop"];
      in {
        # --- Coding / Data Formats ---
        "application/json" = editor;
        "text/xml" = editor;
        "application/xml" = editor;
        "application/yaml" = editor;
        "text/yaml" = editor;
        "text/x-yaml" = editor;
        "application/toml" = editor;

        # --- File Manager ---
        "inode/directory" = fileManager;
        "x-scheme-handler/file" = fileManager;

        # --- Text Formats ---
        "text/plain" = editor;
        "application/x-wine-extension-ini" = editor;

        # --- Web Formats ---
        "text/html" = browser;
        "application/xhtml+xml" = browser;
        "application/xhtml_xml" = browser;
        "application/rdf+xml" = browser;
        "application/rss+xml" = browser;
        "application/x-extension-htm" = browser;
        "application/x-extension-html" = browser;
        "application/x-extension-shtml" = browser;
        "application/x-extension-xht" = browser;
        "application/x-extension-xhtml" = browser;

        # --- Archives ---
        "application/pdf" = browser;
        "application/zip" = archive;
        "application/x-7z-compressed" = archive;
        "application/x-rar-compressed" = archive;
        "application/x-tar" = archive;
        "application/x-bzip-compressed-tar" = archive;
        "application/x-compressed-tar" = archive;
        "application/x-xz-compressed-tar" = archive;
        "application/gzip" = archive;
        "application/x-bzip2" = archive;
        "application/x-xz" = archive;

        # --- Scheme Handlers ---
        "x-scheme-handler/about" = browser;
        "x-scheme-handler/ftp" = browser;
        "x-scheme-handler/http" = browser;
        "x-scheme-handler/https" = browser;
        "x-scheme-handler/discord" = ["discord.desktop"];
        "x-scheme-handler/tg" = ["org.telegram.desktop.desktop"];

        # --- Media ---
        "audio/*" = video;
        "video/*" = video;
        "image/*" = image;
        "image/gif" = image;
        "image/jpeg" = image;
        "image/png" = image;
        "image/webp" = image;
      };

      # Explicitly remove stale/legacy terminal directory handlers
      associations.removed = {
        "inode/directory" = [
          "kitty-open.desktop"
          "zeditor-open.desktop"
        ];
      };
    };

    userDirs = {
      enable = true;
      createDirectories = true;
      setSessionVariables = false;
    };

    desktopEntries = {
      bsdtar = {
        name = "bsdtar";
        comment = "Extract archive files";
        exec = "bsdtar -xf %f";
        mimeType = [
          "application/zip"
          "application/x-7z-compressed"
          "application/x-rar-compressed"
          "application/x-tar"
          "application/x-bzip-compressed-tar"
          "application/x-compressed-tar"
          "application/x-xz-compressed-tar"
          "application/gzip"
          "application/x-bzip2"
          "application/x-xz"
        ];
        noDisplay = true;
        type = "Application";
      };

      yazi = {
        name = "Yazi";
        genericName = "Terminal File Manager";
        exec = "${opts.defaultTerminal} -a yazi yazi %u";
        icon = "yazi";
        terminal = false;
        categories = ["System" "FileTools" "FileManager"];
        mimeType = ["inode/directory"];
      };
    };
  };
}
