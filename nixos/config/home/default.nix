# nixos/config/home/default.nix
{opts, lib, ...}: {
  home = {
    username = opts.username;
    homeDirectory = "/home/${opts.username}";
    stateVersion = "25.05";
  };

  programs.home-manager.enable = true;

  imports = [
    ./sops.nix # Dedicated secrets & environment config
    ./bat.nix # better cat command
    ./btop.nix # resources monitor
    ./git.nix # version control
    ./theme # gtk theme, stylix base, dynamic wallpaper theming (matugen render layer)
    ./mango.nix # window manager (mangowm)
    ./foot.nix # terminal (foot)
    ./swaync.nix # notification daemon + control center (replaces mako)
    ./dashboard # quickshell dashboard panel (toggleable, SUPER+D)
    ./packages.nix # other packages
    ./scripts/scripts.nix # personal scripts
    ./starship.nix # shell prompt
    ./discord # discord with catppuccino theme
    ./waybar # status bar
    ./sys-daemon.nix # rust event-driven daemon (waybar streams + dev-ports dashboard)
    ./herdr.nix # herdr headless server as a supervised user service (never a shell job)
    ./idle.nix # swayidle: dim + lock on real seat idleness, gated on herdr/media/CPU/net/disk
    ./zen-browser.nix # zen browser
    ./wlogout.nix
    ./fuzzel.nix # launcher
    ./spotify.nix # music streaming
    ./pcmanfm.nix # file manager (X11 backend for context menu fix)
    ./fish # fish shell
    ./files # hard copy over files
    ./mpv.nix # video player
    ./yazi.nix # file manager in terminal
    ./lsd.nix # better ls command
    ./eye-protection.nix
    ./xdg.nix
    ./variables.nix
    ./zed-editor.nix
    ./direnv.nix
    ./swaylock.nix
    ./clipboard.nix
    ./mouse.nix # logitech mouse (MX Master 3S) declarative settings
  ]
  # GS65-only: sync nbfc-linux fan profile to PPD power profile.
  ++ lib.optionals (opts.hostname == "gs65") [
    ../../hosts/gs65/power-hook.nix
  ];
}
