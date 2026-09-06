{
  pkgs,
  opts,
  config,
  ...
}: {
  # Configure user accounts
  users = {
    # Don't allow mutation of users outside the config.
    mutableUsers = false;

    groups = {
      "${opts.username}" = {};
      docker = {
        # gid = 131; # Match the existing GID
      };
      wireshark = {};
      # for android platform tools's udev rules
      adbusers = {};
      dialout = {};
      # for openocd (embedded system development)
      plugdev = {};
      # for DDC/CI monitor control via ddcutil
      i2c = {};
      # misc
      uinput = {};
    };
    users = {
      "${opts.username}" = {
        home = "/home/${opts.username}";

        subUidRanges = [
          {
            startUid = 100000;
            count = 65536;
          }
        ];
        subGidRanges = [
          {
            startGid = 100000;
            count = 65536;
          }
        ];

        homeMode = "755";
        hashedPasswordFile = config.sops.secrets.password.path;
        isNormalUser = true;
        description = "${opts.username}";
        extraGroups = [
          opts.username # Allows the user to access their own files
          "users" # Allows the user to access the system
          "docker" # Allows Docker to run without sudo
          "wireshark" # Allows Wireshark to capture packets
          "docker"
          "podman"
          "networkmanager" # Necessary for managing network settings
          "wheel" # Allows sudo access
          "audio" # Access to audio devices
          "input" # Direct input device access
          "video" # Direct video device access
          "kvm" # Access to KVM virtualization for hardware acceleration in android emulation
          "adbusers" # Allows access to the Android Debug Bridge
          "gamemode"
          "i2c" # DDC/CI monitor control (ddcutil)
          # "libvirtd"      # Uncomment if managing virtual machines
          # "tss"           # Uncomment if using TPM software
        ];
        shell = pkgs.fish; # Sets Fish as the default shell for the user
      };
    };
  };
}
