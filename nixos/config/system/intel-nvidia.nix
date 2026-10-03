# nixos/config/system/intel-nvidia.nix
{
  pkgs,
  config,
  opts,
  ...
}: let
  # ── Which driver, and why this one ─────────────────────────────────────────
  #
  # `production` is the closed-source driver branch; it is the right choice for
  # this hardware and has been checked rather than assumed:
  #
  #   # lspci -nn | grep -E 'VGA|3D' ; nvidia-smi --query-gpu=name --format=csv
  #   01:00.0 VGA compatible controller [0300]: NVIDIA Corporation
  #                                          TU117M [GeForce RTX 4090 Laptop GPU]
  #   # cat /sys/class/drm/card0/device/uevent
  #   PCI_ID=10DE:2757      ← AD103, Ada Lovelace
  #
  # 10DE:2757 is Ada, which is well past the Turing cut-off, so `open = true`
  # below is correct: the open kernel modules are the supported path for this
  # card and the proprietary ones are a choice, not a requirement. Switching
  # `open` to false would move to a branch that exists for pre-Turing parts and
  # would gain nothing here.
  #
  # The one thing that matters structurally is the line itself: the driver is
  # taken from `config.boot.kernelPackages`, never from the top-level `pkgs`.
  # That is what makes a kernel bump move the driver with the kernel. A driver
  # built for a different kernel is an nvidia module that refuses to load, which
  # on an unattended host is a machine with no graphics and no way to see why.
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

    # Use the open-source kernel modules for newer GPUs (Turing/20xx series and
    # newer). Set to false for older cards. Correct for this one: 10DE:2757 is
    # Ada — see the header for the check that established it.
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
