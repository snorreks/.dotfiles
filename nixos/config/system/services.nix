# nixos/config/system/services.nix
# This file configures system-level services and daemons.
{
  pkgs,
  opts,
  lib,
  ...
}: {
  # --- Core System Services ---

  services = {
    dbus.enable = true;
    fstrim.enable = true;
    fwupd.enable = true;
    upower = {
      enable = true;
      percentageLow = 20;
      percentageCritical = 5;
      percentageAction = 3;
      criticalPowerAction = "PowerOff";
    };
  };

  # Ollama Service for LLM Inference
  # Controlled via opts.enableOllama (default true).
  # Use nswitch-fast (or build sonny-laptop-fast) to skip it.
  services.ollama = lib.mkIf opts.enableOllama {
    enable = true;
    package = pkgs.ollama-cuda;
    # This makes it listen on all interfaces (0.0.0.0) instead of just localhost
    host = "0.0.0.0";
  };

  # direct instruction to systemd to never start gdm.service, regardless of where it came from.
  systemd.services."gdm".enable = false;

  # Unblock rfkill before bluetoothd starts.
  # The ideapad_bluetooth platform driver (Lenovo) soft-blocks the adapter
  # at boot, so powerOnBoot fails unless rfkill is cleared first.
  systemd.services.bluetooth.serviceConfig.ExecStartPre = [
    "${pkgs.util-linux}/bin/rfkill unblock bluetooth"
  ];

  # --- Power Management ---
  # TLP is your primary power manager, so other conflicting services are disabled.
  services.auto-cpufreq.enable = false;
  systemd.packages = []; # auto-cpufreq removed from here.

  # --- Graphical & Desktop Environment ---

  # Enable MangoWM at the system level
  programs.mango.enable = true;

  programs = {
    # CORRECTED SECTION: We tell the main Hyprland module to use the package from your flake input.
    # This automatically configures the correct compositor AND portal backend.
    # hyprland = {
    #   enable = true;
    #   package = pkgs.hyprland;
    #   # package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
    #   xwayland.enable = true;
    # };

    dconf.enable = true;
    fish.enable = true;
    nm-applet.enable = true;
    nix-ld.enable = true;
    fuse.userAllowOther = true;
  };

  # This is a pure Wayland setup, so the traditional X.Org server is disabled.
  services.xserver.enable = false;
  services.libinput.enable = true;
  services.gvfs.enable = true;
  services.udisks2.enable = true;
  # Disabled: udiskie (in home.packages) handles automounting; devmon would double-mount.
  services.devmon.enable = false;
  services.tumbler.enable = true;
  # services.mpd.enable = true;

  # --- XDG Portals (CRITICAL for Screen Sharing & App Stability) ---
  # Enables the portal service with mango backend for screencasting
  # and GTK fallback for file pickers.

  xdg.portal = {
    enable = true;
    extraPortals = with pkgs; [
      xdg-desktop-portal-gtk
      xdg-desktop-portal-wlr
    ];
    xdgOpenUsePortal = true;

    config = {
      common.default = lib.mkForce ["wlr" "gtk"];
      mango = {
        default = lib.mkForce ["wlr" "gtk"];
        "org.freedesktop.impl.portal.Screenshot" = lib.mkForce ["wlr"];
        "org.freedesktop.impl.portal.ScreenCast" = lib.mkForce ["wlr"];
      };
    };
  };

  # --- Hardware Support ---

  # Explicitly load Logitech HID modules for full MX Master 3S support
  # (side buttons, thumb wheel, gesture button, Smart Shift, DPI, etc.)
  # These SHOULD be loaded by hardware.logitech.wireless below,
  # but NixOS 26.11 isn't adding them to boot.kernelModules automatically.
  boot.kernelModules = ["hid-logitech-dj" "hid-logitech-hidpp"];

  hardware = {
    bluetooth = {
      enable = true;
      powerOnBoot = true; # Automatically power on Bluetooth on boot

      settings = {
        General = {
          Experimental = true; # Showing battery charge of bluetooth devices
          Enable = "Source,Sink,Media,Socket"; # Ensures all profiles are available

          # Faster reconnection for Sony headsets
          ReconnectAttempts = 7;
          ReconnectInterval = 1;
        };
      };
    };

    enableRedistributableFirmware = true;
    logitech.wireless = {
      enable = true;
      enableGraphical = true;
    };
  };

  # For mouse and keyboard configuration
  services.ratbagd.enable = true;

  # --- System Performance ---

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    priority = 5;
    memoryPercent = 50;
  };

  # --- Other User Programs (System-wide) ---
  # programs.adb.enable = true;
}
