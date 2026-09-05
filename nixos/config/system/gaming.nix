# nixos/config/system/gaming.nix
#
# This file configures SYSTEM-LEVEL programs and settings for gaming.
{pkgs, ...}: let
  # Switch to performance profile during gameplay via power-profiles-daemon.
  # This drives the firmware's ACPI platform_profile (performance/balanced/power-saver)
  # and adjusts CPU/GPU power limits without requiring direct sysfs access.
  # gamemoded runs with a PATH of exactly one entry (the pkexec wrapper), so an
  # unqualified `powerprofilesctl` here is not found — and with `2>/dev/null ||
  # true` swallowing both the message and the exit code, the profile switch
  # silently did nothing on every launch. Absolute store path, and let failures
  # reach the journal.
  ppctl = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl";

  # Where the pre-game profile is stashed so `end` can put it back. gamemoded is
  # a user service, so XDG_RUNTIME_DIR is set; /tmp is a fallback, not a plan.
  ppStateFile = ''''${XDG_RUNTIME_DIR:-/tmp}/gamemode-previous-power-profile'';

  gamemode-start-script = pkgs.writeShellScriptBin "gamemode-start-system" ''
    # Remember whatever profile the user was on, so stopping a game restores it
    # instead of assuming they were on balanced.
    ${ppctl} get > "${ppStateFile}" 2>/dev/null || true
    ${ppctl} set performance || echo "gamemode: failed to set performance profile" >&2
  '';

  gamemode-end-script = pkgs.writeShellScriptBin "gamemode-end-system" ''
    previous=$(cat "${ppStateFile}" 2>/dev/null || true)
    case "$previous" in
      performance | balanced | power-saver) ;;
      *) previous=balanced ;;
    esac
    rm -f "${ppStateFile}"
    ${ppctl} set "$previous" || echo "gamemode: failed to restore $previous profile" >&2
  '';

  steam-patched = pkgs.steam.override {
    # CEF sandbox breaks pipes in pressure-vessel on NixOS
    extraArgs = "-no-cef-sandbox";
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
          # NOTE: no `softrealtime`. It asks for SCHED_ISO, which only exists in
          # -ck/MuQSS kernels — on mainline every client just logs
          #   ERROR: Failed setting client [N] into SCHED_ISO mode ... Invalid argument
          # once per process, and gets nothing.
          # Force the CPU governor to 'performance' for maximum clock speeds.
          desiredgov = "performance";
        };

        # NOTE: no `gpu` section on purpose. gamemode applies NVIDIA
        # optimisations by shelling out to `gpuclockctl`, which drives
        # nvidia-settings against an X display — there isn't one in a mango
        # session, so `apply_gpu_optimisations` / `nv_powermizer_mode` only
        # produced a burst of
        #   ERROR: Failed to get [gpu:0]/GPUPerfModes!
        #   ERROR: Failed to call gpuclockctl, could not apply optimisations!
        # in the journal on every single game launch, and changed nothing.
        # The dGPU clocks itself up under load anyway; the performance
        # power-profile switch below is what actually has an effect.

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
