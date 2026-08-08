# nixos/config/system/persistence.nix
#
# NOT YET ACTIVE — this whole file assumes the post-migration disk layout
# (a `/persist` btrfs subvolume, a `root` subvolume that gets wiped on boot).
# On this machine that layout doesn't exist yet; see README.md ("Migrating
# an existing install to impermanence"). Its import stays commented out in
# ./default.nix until that migration is done — uncommenting it first is the
# very last step of the runbook, since `/persist` won't exist before that.
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
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
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
    ];
  };

  # Rolls the `root` btrfs subvolume back to empty on every boot — this is
  # the actual "erase your darlings" mechanism. `home`, `nix`, and
  # `/persist/system` above are separate subvolumes/bind-mounts, so they
  # survive. Old roots are kept for 30 days (as `old_roots/<timestamp>`) in
  # case something wiped needs recovering, then garbage collected.
  boot.initrd.systemd.services.rollback-root = {
    description = "Roll back the root btrfs subvolume to a blank state";
    wantedBy = ["initrd.target"];
    before = ["sysroot.mount"];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs_tmp
      mount -o subvol=/ LABEL=nixos /btrfs_tmp

      if [[ -e /btrfs_tmp/root ]]; then
        mkdir -p /btrfs_tmp/old_roots
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

      for i in $(find /btrfs_tmp/old_roots/ -maxdepth 1 -mtime +30 -mindepth 1); do
        delete_subvolume_recursively "$i"
      done

      btrfs subvolume create /btrfs_tmp/root
      umount /btrfs_tmp
    '';
  };
}
