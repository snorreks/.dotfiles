# nixos/disko.nix
#
# Fresh-install disk layout: ESP + swap + one btrfs partition holding the
# `root`, `home`, `nix`, `persist` subvolumes. Only `root` gets rolled back to
# empty on every boot (see config/system/persistence.nix) — `home`, `nix`,
# and `persist` are ordinary persistent subvolumes.
#
# Use this for a genuine from-scratch install (nixos-anywhere, or booting a
# blank disk from the installer). It is NOT what turned this machine's
# existing dual-boot disk into this layout — that was done in place with
# btrfs-convert to avoid wiping the Windows-shared ESP/swap partitions and to
# avoid needing to back up ~900G with nowhere to put it. See README.md
# ("Migrating an existing install to impermanence") for that procedure.
#
# Usage once a host actually wants this to manage its disk:
#   disko.devices = (import ../../disko.nix { device = "/dev/${opts.deviceName}"; }).disko.devices;
{device ? throw "Set this to your disk device, e.g. /dev/nvme0n1", ...}: {
  disko.devices = {
    disk.main = {
      inherit device;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          esp = {
            name = "ESP";
            size = "500M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          swap = {
            size = "8G";
            content = {
              type = "swap";
              resumeDevice = true;
            };
          };
          root = {
            name = "root";
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = ["-f" "-L" "nixos"];

              subvolumes = {
                "/root" = {
                  mountpoint = "/";
                  mountOptions = ["compress=zstd" "noatime"];
                };

                "/home" = {
                  mountpoint = "/home";
                  mountOptions = ["compress=zstd" "noatime"];
                };

                "/nix" = {
                  mountpoint = "/nix";
                  mountOptions = ["compress=zstd" "noatime"];
                };

                "/persist" = {
                  mountpoint = "/persist";
                  mountOptions = ["compress=zstd" "noatime"];
                };
              };
            };
          };
        };
      };
    };
  };
}
