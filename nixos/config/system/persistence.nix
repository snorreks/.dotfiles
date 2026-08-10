# nixos/config/system/persistence.nix
#
# Enabled only AFTER the first successful boot on the new btrfs layout.
# Its import stays commented out in ./default.nix until then.
{...}: {
  fileSystems."/persist" = {
    neededForBoot = true;
  };

  environment.persistence."/persist/system" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/ssh" # SSH host keys — without this, host keys regenerate every
      # boot and every known_hosts entry for this machine breaks each time.
      "/var/log"
      "/var/lib/bluetooth"
      "/var/lib/nixos" # uid/gid allocation stability — do not remove
      "/var/lib/systemd/coredump"
      "/var/lib/systemd/backlight" # screen brightness across reboots
      "/var/lib/systemd/rfkill" # wifi/bluetooth on-off state
      "/var/lib/docker" # keep pulled images/containers across boots
      "/etc/NetworkManager/system-connections"
      {
        directory = "/var/lib/colord";
        user = "colord";
        group = "colord";
        mode = "u=rwx,g=rx,o=";
      }
    ];
    files = [
      "/etc/machine-id"
      "/etc/adjtime" # RTC drift — matters on a Windows dual-boot
      "/var/lib/systemd/random-seed"
    ];
  };

  # Nix build scratch space. /tmp lives on the root subvolume, which this
  # service archives wholesale on every boot — so large builds would pin
  # their extents in old_roots/ for the whole retention window.
  systemd.services.nix-daemon.environment.TMPDIR = "/nix/tmp";
  systemd.tmpfiles.rules = ["d /nix/tmp 1777 root root 7d"];

  # Rolls the `root` btrfs subvolume back to empty on every boot — this is
  # the actual "erase your darlings" mechanism. `home`, `nix`, and
  # `/persist/system` above are separate subvolumes/bind-mounts, so they
  # survive. Old roots are kept for 7 days as `old_roots/<timestamp>`.
  boot.initrd.systemd.services.rollback-root = {
    description = "Roll back the root btrfs subvolume to a blank state";
    wantedBy = ["initrd.target"];
    # REQUIRED: DefaultDependencies=no strips implicit ordering, so without
    # this the service can run before udev has created the disk node and the
    # mount below fails into an initrd emergency shell.
    after = ["initrd-root-device.target"];
    before = ["sysroot.mount"];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs_tmp
      mount -t btrfs -o subvol=/ LABEL=nixos /btrfs_tmp
      mkdir -p /btrfs_tmp/old_roots
      if [[ -e /btrfs_tmp/root ]]; then
        timestamp=$(date --date="@$(stat -c %Y /btrfs_tmp/root)" "+%Y-%m-%-d_%H:%M:%S")
        mv /btrfs_tmp/root "/btrfs_tmp/old_roots/$timestamp"
      fi
      delete_subvolume_recursively() {
        IFS=$'\n'
        for i in $(btrfs subvolume list -o "$1" | cut -f 9- -d ' '); do
          delete_subvolume_recursively "/btrfs_tmp/$i"
        done
        btrfs subvolume delete "$1"
      }
      for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +7 -mindepth 1); do
        delete_subvolume_recursively "$i"
      done
      btrfs subvolume create /btrfs_tmp/root
      umount /btrfs_tmp
    '';
  };
}
