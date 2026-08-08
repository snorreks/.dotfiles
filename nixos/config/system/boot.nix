# /config/system/boot.nix
{...}: {
  # Boot configuration settings
  boot = {
    # This is needed to access shared drives with windows /mnt/shared
    supportedFilesystems = ["ntfs"];
    # Systemd-boot configuration
    loader = {
      # grub = {
      #   enable = true;
      #   efiSupport = true;
      #   useOSProber = true;
      #   devices = ["nodev"];
      # };
      # If you have a separate /boot, ensure:
      efi = {
        efiSysMountPoint = "/boot";
        canTouchEfiVariables = true; # Allow modification of EFI variables
      };
      timeout = 1; # Boot menu timeout duration
      systemd-boot = {
        enable = true;
        configurationLimit = 20; # Maximum number of boot entries
        consoleMode = "max"; # pick the highest resolution for systemd-boot's console.
        # Create a manual entry for Windows.
        # The filename "aa-windows.conf" will sort before "nixos-generation-..."
        extraEntries = {
          # This creates a file named "aa-windows.conf"
          "aa-windows.conf" = ''
            title   Windows 11
            efi     /EFI/Microsoft/Boot/bootmgfw.efi
            sort-key aa
          '';
        };
      };
    };

    # Initial RAM disk settings
    initrd = {
      enable = true; # Enable the use of an initial RAM disk
      systemd.enable = true; # Use systemd in the initrd

      # Load NVIDIA modules at the earliest possible stage (early KMS)
      # This is crucial for Wayland compositors like Hyprland.
      # kernelModules = ["nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm"];
    };

    # The impermanence root-rollback service lives in
    # config/system/persistence.nix (disabled until the disk migration is
    # done — see README.md).
    # Temporary filesystem configuration
    tmp = {
      # cleanOnBoot = true; # Clean /tmp on boot
      # false will make /tmp a regular directory on your main (/) partition, giving it access to the 804 GB of free space. The downside is slightly slower I/O in /tmp compared to RAM, but for most desktop use cases, this is unnoticeable and avoids build failures like this one.
      useTmpfs = true; # Use a RAM-based temp filesystem
      # tmpfsSize = "75%"; # Size of the temporary file system
    };
  };
}
