# nixos/config/system/sound.nix
{pkgs, ...}: {
  # # Pulseaudio:
  # hardware.pulseaudio.enable = true;
  # hardware.pulseaudio.support32Bit = true;

  # Pipewire:
  # sound.enable = true;
  # Enable Real-Time Kit for managing real-time priorities for audio processes.
  # This is important for low-latency audio applications.
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;

  # No system-level audio packages needed.
  # PipeWire + WirePlumber provide `wpctl`.
  # PulseAudio compatibility is handled by `pipewire.pulse.enable`.
  # If an app hard-requires `pactl`, re-add `pkgs.pulseaudio` here.

  # PipeWire is a new low-level multimedia framework.
  # It aims to offer capture and playback for both audio and video with minimal latency.
  # It support for PulseAudio-, JACK-, ALSA- and GStreamer-based applications.
  # PipeWire has a great bluetooth support, it can be a good alternative to PulseAudio.
  #     https://nixos.wiki/wiki/PipeWire
  services.pipewire = {
    enable = true; # Enable PipeWire to manage all sound I/O
    # package = pkgs-unstable.pipewire;

    alsa.enable = true; # Allow PipeWire to interact with ALSA for device management.
    alsa.support32Bit = true; # Enable support for 32-bit ALSA applications on 64-bit systems.

    # Enable PipeWire's PulseAudio module. This allows PipeWire to handle applications
    # that use the PulseAudio sound server.
    pulse.enable = true;

    # Enable WirePlumber session manager for PipeWire. WirePlumber is a more advanced
    # and configurable session and policy manager than the default pipewire-media-session.
    wireplumber.enable = true;

    jack.enable = false;
    audio.enable = true;

    # Add the following lines to prevent idle state

    # extraConfig.pipewire = {
    #   "context.properties" = {
    #     "log.level" = 2;
    #   };
    #   "context.modules" = [
    #     {
    #       name = "libpipewire-module-rt";
    #       args = {};
    #     }
    #     {
    #       name = "libpipewire-module-alsa-sink";
    #       args = {
    #         node.name = "alsa_output.pci-0000_00_1f.3.analog-stereo";
    #         node.pa.usedby = ["application" "stream"];
    #         session.suspend-timeout-seconds = 0;
    #       };
    #     }
    #     {
    #       name = "libpipewire-module-alsa-source";
    #       args = {
    #         node.name = "alsa_input.pci-0000_00_1f.3.analog-stereo";
    #       };
    #     }
    #   ];
    # };
  };

  # ── Lenovo Legion Pro 7 16IRX9H (ALC287) speaker-amp fix ──────────────
  # The speaker amplifiers power down after ~10 s of silence and the kernel
  # driver fails to re-initialize them (also when switching headphone →
  # speakers). See https://github.com/NixOS/nixos-hardware/issues/1039
  #
  # power_save=0            → never runtime-suspend the HDA codec
  # power_save_controller=N → keep the HDA controller awake too
  boot.extraModprobeConfig = ''
    options snd-hda-intel power_save=0 power_save_controller=N
  '';

  # Prevent WirePlumber from suspending the internal ALSA sink on idle,
  # which closes the PCM stream and lets the amps power down.
  services.pipewire.wireplumber.extraConfig."99-no-suspend-internal-audio" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          {"node.name" = "~alsa_output.pci.*";}
        ];
        actions.update-props = {
          "session.suspend-timeout-seconds" = 0;
          "node.pause-on-idle" = false;
        };
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    alsa-utils
    alsa-tools # provides hda-verb, used by speaker-revive
    # Re-initialize the ALC287 speaker amps at runtime (no reboot needed).
    # Run `sudo speaker-revive` when speakers die after headphone unplug.
    # Verbs from the community fix for Legion Pro 7 ALC287 amps:
    #   0x20 0x500 0x1b → select coef index 0x1b
    #   0x20 0x400 0x7774 → write coef value 0x7774 (enable speaker amps)
    (writeShellScriptBin "speaker-revive" ''
      set -eu
      card=$(grep -l 'Realtek ALC287' /proc/asound/card*/codec\#0 \
        | sed 's|.*card\([0-9]*\).*|\1|' | head -1)
      if [ -z "$card" ]; then
        echo "ALC287 codec not found" >&2
        exit 1
      fi
      ${alsa-tools}/bin/hda-verb /dev/snd/hwC"$card"D0 0x20 0x500 0x1b
      ${alsa-tools}/bin/hda-verb /dev/snd/hwC"$card"D0 0x20 0x400 0x7774
      echo "Speaker amps re-initialized on card $card."
    '')
  ];
}
