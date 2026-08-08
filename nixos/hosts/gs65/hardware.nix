{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = ["xhci_pci" "nvme"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  # Post-impermanence-migration layout (see docs/impermanence-migration.md):
  # single btrfs partition (LABEL=nixos) with root/home/nix/persist subvolumes.
  # root gets rolled back to empty on every boot once persistence.nix is active.
  fileSystems."/" = {
    device = "LABEL=nixos";
    fsType = "btrfs";
    options = ["subvol=/root" "compress=zstd" "noatime"];
  };

  fileSystems."/home" = {
    device = "LABEL=nixos";
    fsType = "btrfs";
    options = ["subvol=/home" "compress=zstd" "noatime"];
  };

  fileSystems."/nix" = {
    device = "LABEL=nixos";
    fsType = "btrfs";
    options = ["subvol=/nix" "compress=zstd" "noatime"];
  };

  fileSystems."/persist" = {
    device = "LABEL=nixos";
    fsType = "btrfs";
    options = ["subvol=/persist" "compress=zstd" "noatime"];
    neededForBoot = true; # required by impermanence's persistence assertion
  };

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
      "fmask=0000" # Grants +x permissions to all files
      "dmask=0000" # Grants +x permissions to all directories
      "iocharset=utf8"
      "discard"
    ];
  };

  swapDevices = [
    {device = "/dev/disk/by-uuid/4d79fcc0-788c-4396-af5e-632e4e46daf0";}
  ];

  # Enables DHCP on each ethernet and wireless interface. In case of scripted
  # networking (the default) this is the recommended approach.
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
