# /config/system/boot.nix
{...}: {
  boot = {
    supportedFilesystems = ["ntfs"];

    loader = {
      efi = {
        efiSysMountPoint = "/boot";
        canTouchEfiVariables = true;
      };
      timeout = 5;
      systemd-boot = {
        enable = true;
        # 500 MiB ESP shared with Windows - 20 generations will not fit.
        configurationLimit = 8;
        consoleMode = "max";

        # Manual Windows entry. sort-key "aa" sorts above NixOS ("nixos"),
        # so Windows sits at the top of the menu.
        extraEntries = {
          "aa-windows.conf" = ''
            title    Windows 11
            efi      /EFI/Microsoft/Boot/bootmgfw.efi
            sort-key aa
          '';
        };

        # systemd-boot auto-detects bootmgfw.efi on the shared ESP and adds its
        # own "Windows Boot Manager" entry at the BOTTOM of the menu, which
        # cannot be reordered. Turn auto-entries off so only the entry above
        # shows up.
        extraInstallCommands = ''
          grep -q '^auto-entries' /boot/loader/loader.conf \
            || echo 'auto-entries no' >> /boot/loader/loader.conf
        '';
      };
    };

    initrd = {
      enable = true;
      systemd.enable = true;
    };

    tmp = {
      # Disk-backed /tmp: large nix builds (e.g. ollama-cuda) get hundreds of
      # GB instead of ~7 GiB of a 15 GiB machine. systemd-tmpfiles ages stale
      # files; if impermanence is toggled on later, the root rollback clears
      # /tmp anyway.
      useTmpfs = false;
    };
  };
}
