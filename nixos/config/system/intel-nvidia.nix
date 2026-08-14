# nixos/config/system/intel-nvidia.nix
{
  pkgs,
  config,
  opts,
  ...
}: let
  driverPkg = config.boot.kernelPackages.nvidiaPackages.production; # stable
in {
  # --- Global Package Configuration ---
  nixpkgs.config = {
    packageOverrides = pkgs: {
      vaapi-intel = pkgs.vaapi-intel.override {enableHybridCodec = true;};
    };
  };

  # --- Main Graphics Configuration ---
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # For compatibility with 32-bit games and applications.
    extraPackages = with pkgs; [
      # Installs all necessary video acceleration drivers for both GPUs.
      intel-media-driver # Modern VA-API driver for the Intel iGPU.
      intel-vaapi-driver # Older VA-API driver, kept for system stability.
      nvidia-vaapi-driver # VA-API backend for the NVIDIA dGPU.
      libva-vdpau-driver # VDPAU-to-VAAPI compatibility bridge.
      libvdpau-va-gl # VA-API-to-OpenGL compatibility bridge.
    ];
  };

  # This legacy setting for the X.org server appears to be required for stability
  # on this specific system configuration, even when running Wayland. Do not remove.
  services.xserver.videoDrivers = ["nvidia"];

  # --- NVIDIA Driver Configuration ---
  hardware.nvidia = {
    # Critical setting for using NVIDIA drivers with Wayland compositors.
    modesetting.enable = true;

    # Enables RTD3 power management, allowing the dGPU to power down completely when idle.
    powerManagement.enable = true;
    powerManagement.finegrained = false; # Fine-grained can be unstable, start with it off.

    # Use the open-source kernel modules for newer GPUs (Turing/20xx series and newer).
    # Set to false for older cards.
    open = true;
    nvidiaSettings = true;
    package = driverPkg;

    # Configure PRIME render offload.
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
        offloadCmdMainProgram = "prime-run"; # Adds prime-run binary to your system path
      };
      # Use the specific PCI bus IDs for your hardware.
      intelBusId = "PCI:${opts.intelBusId}";
      nvidiaBusId = "PCI:${opts.nvidiaBusId}";
    };

    # --- NVIDIA Persistence Daemon ---
    # Keeps the driver initialized and prevents the GPU from dropping into
    # the problematic "stuck in P8" low-power state (causes mouse lag/stutter).
    nvidiaPersistenced = true;
  };

  # Enable NVIDIA Container Toolkit for Docker GPU passthrough
  hardware.nvidia-container-toolkit.enable = true;
}
