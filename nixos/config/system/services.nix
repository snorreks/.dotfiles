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
  # Use nswitch-fast (or build legion-fast) to skip it.
  services.ollama = lib.mkIf opts.enableOllama {
    enable = true;
    package = pkgs.ollama-cuda;
    # This makes it listen on all interfaces (0.0.0.0) instead of just localhost
    host = "0.0.0.0";

    # Tuned for the 4090 Laptop's 16GB VRAM. The desktop renders on the Intel
    # iGPU, so effectively all 16GB is available to models — the budget is
    # weights + KV cache, and the cache is the part we can shrink.
    environmentVariables = {
      # Halves KV cache VRAM vs f16. At 16GB of weights (Qwen3.8 iq4_xs) this
      # is the difference between a ~2GB spill to CPU and a ~5GB one.
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_KV_CACHE_TYPE = "q8_0";

      # pi leaves gaps between turns; the default 5m reloads weights mid-task.
      OLLAMA_KEEP_ALIVE = "30m";

      # One model owns the GPU. Loading a second evicts layers of the first
      # into system RAM, which is worse than just swapping models.
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_NUM_PARALLEL = "1";
    };
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
  # power-profiles-daemon is the primary power manager (see power-management.nix);
  # conflicting auto-tuners are disabled here.
  # NOTE: `systemd.packages = []` used to live here with a comment about removing
  # auto-cpufreq. It never removed anything — the option is a merged list, so
  # setting it to [] is a no-op. Dropped.
  services.auto-cpufreq.enable = false;

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

  # nm-applet crashes with SIGSEGV inside the unmaintained libdbusmenu-glib
  # when the tray host (waybar) restarts/re-registers while its menu is being
  # updated. No upstream fix exists (library is dead). Self-heal instead:
  # restart the applet automatically if it ever crashes again.
  systemd.user.services.nm-applet = {
    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "2s";
    };
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

  # ratbagd (libratbag) is deliberately OFF: nothing here uses it — piper isn't
  # installed — and it contends with Solaar for the same Logitech HID++ device.
  # Mouse configuration is handled declaratively in config/home/mouse.nix.
  services.ratbagd.enable = false;

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
