# nixos/config/system/gaming.nix
#
# This file configures SYSTEM-LEVEL programs and settings for gaming.
{pkgs, ...}: let
  # Native ACPI platform profile switching for Lenovo Legion hardware.
  # Uses the kernel's standard interface instead of NBFC which writes
  # vendor-specific EC register maps (MSI map on Lenovo = dangerous).
  gamemode-start-script = pkgs.writeShellScriptBin "gamemode-start-system" ''
    if [ -w /sys/firmware/acpi/platform_profile ]; then
      echo "performance" > /sys/firmware/acpi/platform_profile
    fi
  '';

  gamemode-end-script = pkgs.writeShellScriptBin "gamemode-end-system" ''
    if [ -w /sys/firmware/acpi/platform_profile ]; then
      echo "balanced" > /sys/firmware/acpi/platform_profile
    fi
  '';

  steam-patched = pkgs.steam.override {
    # CEF sandbox breaks pipes in pressure-vessel on NixOS
    # GPU accelerated webview fails GetVSyncParameters on Wayland+Nvidia Xwayland
    extraArgs = "-no-cef-sandbox -cef-disable-gpu";
  };
in {
  # Steam's internal scripts (and some games) shell out to pactl.
  environment.systemPackages = with pkgs; [pulseaudio]; # gives pactl/pacmd without the daemon

  # --- System Fonts (required for Steam's embedded Chromium to render Library/Store) ---
  fonts.packages = with pkgs; [
    dejavu_fonts
    liberation_ttf
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
  ];

  programs = {
    # --- Steam System Service ---
    steam = {
      enable = true;
      package = steam-patched;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
      localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
    };

    # --- Gamescope micro-compositor ---
    gamescope = {
      enable = true;
      capSysNice = false; # Must be false to run Gamescope inside Steam on NixOS
    };

    # --- GameMode System Service ---
    # Optimises system performance on-demand for games.
    gamemode = {
      enable = true;

      settings = {
        general = {
          # This correctly raises the game's CPU priority.
          renice = -15;
          # Request a real-time CPU scheduler for lower latency.
          softrealtime = "auto";
          # Force the CPU governor to 'performance' for maximum clock speeds.
          desiredgov = "performance";
        };

        gpu = {
          # Forcing the NVIDIA GPU to its highest performance level.
          apply_gpu_optimisations = "accept-responsibility";
          # Set the PowerMizer mode: 0=Adaptive, 1=Prefer Maximum Performance
          nv_powermizer_mode = 1;
        };

        # Improve disk I/O performance.
        io = {
          # Set the I/O scheduler priority for the game process to the highest level.
          ioprio = "0";
        };

        # --- Custom Scripts ---
        # This tells GameMode to run our custom scripts when it starts and stops.
        # This part tells the SYSTEM-WIDE service to run our root scripts
        custom = {
          start = "${gamemode-start-script}/bin/gamemode-start-system";
          end = "${gamemode-end-script}/bin/gamemode-end-system";
        };
      };
    };
  };

  # if you play night reign and try to open map with ps5 controller, it will also trigger mouse click, aka attack (fixed by udev rules)
  services.udev.extraRules = ''
    # Disable Sony DualSense/DualShock touchpad mouse emulation (USB)
    ACTION=="add|change", ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
    # Disable touchpad mouse emulation over Bluetooth
    ACTION=="add|change", ATTRS{name}=="Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
  '';
}
