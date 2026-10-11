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
  #
  # Mounted when opts.mountShared is true (nixos/options.nix), which it now is.
  # The MSI dual-boots too and wants the same extra storage on the road as the
  # Legion has parked. It was OFF for the Fast Startup / hibernation reason only,
  # and that precondition is met — see the long note on the same mount in
  # hosts/legion/hardware.nix, which applies here, and opts.mountShared.
  #
  # 🔴 This is a DIFFERENT physical volume from the Legion's (see the device
  # below), so Fast Startup must be off in the GS65's own Windows install too —
  # disabling it on one machine says nothing about the other.
  #
  # The partition is not repartitioned and ntfs3 stays available by hand.
  #
  # 🔴 THIS VOLUME IS CURRENTLY DIRTY AND WILL NOT MOUNT. Measured, on this
  # machine, not guessed:
  #
  #   $ sudo mount -t ntfs3 ... /dev/nvme0n1p4 /mnt/shared
  #   ntfs3(nvme0n1p4): It is recommended to use chkdsk.
  #   ntfs3(nvme0n1p4): volume is dirty and "force" flag is not set!
  #   $ ntfsinfo -m /dev/nvme0n1p4
  #   Volume is scheduled for check.
  #
  # That is the NTFS dirty bit (boot sector 0x42), which Windows set and has
  # not cleared. It is NOT hibernation — ntfs3 says "dirty", never
  # "hibernated" — so the Fast Startup discussion above still holds; this is a
  # separate thing, and it is why the precondition being met was not enough.
  #
  # THE FIX IS WINDOWS-SIDE AND CANNOT BE DONE FROM HERE:
  #
  #   chkdsk <drive-letter>: /f        # in Windows, on THIS machine
  #   # then shut Windows down cleanly (not restart-to-Windows, not hibernate)
  #
  # `force` is deliberately NOT added. ntfs3 asks for it, and ntfsinfo asks
  # for it, and it would make the mount succeed — on a volume that its own
  # native tools have flagged as needing structural repair, mounting it rw is
  # how a filesystem that was dirty becomes a filesystem that is damaged. A
  # chkdsk costs ten minutes and a reboot; guessing here costs the data on a
  # drive this configuration deliberately treats as the shared one.
  #
  # `x-systemd.automount` is what makes the BOOT quiet regardless. It is here
  # because `nofail` does not do what the note in nixos/options.nix says it
  # does: `nofail` only means no unit *depends* on this mount succeeding, so
  # the boot carries on — but the unit still fails, and systemd still prints
  # "[FAILED] Failed to mount /mnt/shared." to the console. Three times a boot,
  # which is exactly what it was doing. With automount, systemd starts a cheap
  # .automount unit that always succeeds and mounts the volume on FIRST ACCESS
  # instead, so a volume that is absent, dirty or unplugged costs nothing at
  # boot and only the process that actually wanted the files sees a failure.
  # By then systemd has turned console status reporting off, so it lands in
  # the journal rather than on the screen.
  #
  # The trade: `findmnt /mnt/shared` no longer proves the volume is mounted,
  # because an automount unit reports as active while the filesystem is not
  # mounted. Use `findmnt -T /mnt/shared` after touching the path, or
  # `systemctl status mnt-shared.mount`.
  #
  # `x-systemd.device-timeout` is short on purpose: if the volume is not there
  # at all, a process that touches the path should get its error in 2 seconds,
  # not wait out systemd's 90-second default.
  fileSystems."/mnt/shared" = lib.mkIf opts.mountShared {
    device = "/dev/disk/by-uuid/EA6CD3956CD35AC1";
    fsType = "ntfs3";
    options = [
      "rw"
      "uid=1000"
      "gid=100"
      "nofail"
      "x-systemd.automount"
      "x-systemd.device-timeout=2s"
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
