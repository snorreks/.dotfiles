{
  config,
  lib,
  modulesPath,
  opts,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = ["xhci_pci" "nvme" "usb_storage" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  # --- btrfs subvolumes on the NixOS disk (label: nixos) ---
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = ["subvol=root" "compress=zstd" "noatime"];
  };

  fileSystems."/home" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = ["subvol=home" "compress=zstd" "noatime"];
    # neededForBoot: the initrd runs the NixOS activation at every boot, which
    # decrypts the sops password secret (neededForUsers). The age key lives in
    # /home — without this, /home isn't mounted in the initrd, decryption
    # fails, and the users-groups snippet locks every account (`!`) at boot.
    neededForBoot = true;
  };

  fileSystems."/nix" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = ["subvol=nix" "compress=zstd" "noatime"];
  };

  # Mounted only when impermanence is enabled (opts.enablePersistence) — the
  # subvolume exists either way (created by the installer), so flipping the
  # boolean is all it takes to switch on the root wipe.
  fileSystems."/persist" = lib.mkIf opts.enablePersistence {
    device = "/dev/disk/by-label/nixos";
    fsType = "btrfs";
    options = ["subvol=persist" "compress=zstd" "noatime"];
    neededForBoot = true;
  };

  # --- ESP, shared with the Windows Boot Manager. Never reformatted. ---
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/EA9B-3864";
    fsType = "vfat";
    options = ["fmask=0077" "dmask=0077"];
  };

  # --- Shared NTFS Drive (Windows dual-boot) ---
  fileSystems."/mnt/shared" = {
    device = "/dev/disk/by-uuid/EA6CD3956CD35AC1";
    fsType = "ntfs3";
    options = [
      "rw"
      "uid=1000"
      "gid=100"
      "nofail"
      "exec"
      "fmask=0000"
      "dmask=0000"
      "iocharset=utf8"
      "discard"
    ];
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/4d79fcc0-788c-4396-af5e-632e4e46daf0";}
  ];

  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
