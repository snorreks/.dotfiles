# /config/system/kernel.nix
{
  pkgs,
  config,
  ...
}: {
  # --- Kernel & Boot Modules ---
  boot = {
    # Use the latest stable kernel available in your Nixpkgs channel.
    kernelPackages = pkgs.linuxPackages_latest;

    # Explicitly load necessary kernel modules at boot.
    kernelModules = [
      "acpi_call" # For advanced ACPI functions, sometimes used by power management scripts.
    ];

    # Add extra packages for kernel modules, useful for things not in the kernel tree.
    extraModulePackages = with config.boot.kernelPackages; [
      # cpupower and cpupower-gui are user-space tools, not modules.
      # They are better placed in environment.systemPackages if you want them.
      acpi_call
    ];

    # Prevent conflicting drivers from loading.
    blacklistedKernelModules = [
      "nouveau" # The open-source NVIDIA driver, which conflicts with the proprietary one.
    ];

    # Low-level kernel module configuration.
    extraModprobeConfig = ''
      # Ensure nouveau is fully disabled to prevent any conflicts with the NVIDIA driver.
      blacklist nouveau
      options nouveau modeset=0
    '';

    # --- Kernel Boot Parameters (GRUB/systemd-boot) ---
    kernelParams = [
      # Reduces boot message verbosity for a cleaner visual boot.
      "quiet"

      # OPTIMIZATION: Enables GuC (Graphics uController) on the Intel iGPU.
      # Offloads scheduling and low-level tasks from the CPU to the iGPU,
      # improving performance and power efficiency. '2' enables GuC only.
      "i915.enable_guc=2"

      # STABILITY: Highly recommended for laptops that suspend/sleep on Wayland.
      # Prevents the NVIDIA driver from discarding video memory on suspend, which
      # can lead to applications (or the entire session) crashing upon resume.
      "nvidia.NVreg_PreserveVideoMemoryAllocations=1"

      # Tells the system firmware that it's running Linux. This can help with
      # compatibility and expose correct ACPI features for things like hotkeys.
      "acpi_osi=Linux"
    ];

    # --- Kernel System Controls (Sysctl) ---
    kernel.sysctl = {
      # Increases the maximum number of memory map areas a process can have.
      # Required by many modern games and applications running under Wine/Proton.
      "vm.max_map_count" = 262144;

      # Sets kernel tendency to swap. 10 is a good value for desktops/laptops
      # with ample RAM, telling it to avoid swapping unless necessary. Default is 60.
      "vm.swappiness" = 10;

      # Drastically increase inotify watcher limits.
      # Kitty's __watch_conf__ kitten recursively watches /etc/xdg for config
      # changes; on NixOS this tree is enormous (thousands of store symlinks),
      # easily consuming 500k+ watches. Modern tooling (TypeScript LSP, Biome,
      # Tailwind, Firebase emulators) also uses many watchers.
      # 2 million is the standard recommendation for NixOS dev environments.
      "fs.inotify.max_user_watches" = 2097152;
      # Raise max queued events to match the higher watch ceiling.
      "fs.inotify.max_queued_events" = 65536;
    };
  };

  # --- Systemd Optimizations ---

  # Lowers the default time Systemd waits for a service to stop at shutdown.
  # Can significantly speed up shutdown/reboot times by not waiting on stuck services.
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "30s";
    DefaultTimeoutStopSec = "10s";
  };
  # Disables a Systemd service that tries to manage the screen backlight via NVIDIA.
  # On most laptops, this is handled by other drivers, and this service just
  # produces harmless but annoying error messages in the journal.
  systemd.services."systemd-backlight@backlight:nvidia_0".enable = false;

  # --- Recommended User-space Tools ---
  # These are not kernel modules, but command-line tools you were including.
  # This is the correct place to install them for system-wide availability.
  environment.systemPackages = [
    config.boot.kernelPackages.cpupower
  ];
}
