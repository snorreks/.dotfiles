# /config/system/boot.nix
#
# The bootloader, the EFI partition, and — opt-in — Automatic Boot Assessment.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  bootHealth = opts.bootHealth;
  criticalUnits = bootHealth.criticalUnits ++ lib.optionals opts.headless ["sshd.service"];
in {
  boot = {
    # ── Shared NTFS volume ──────────────────────────────────────────────────
    #
    # The kernel MODULE is kept: reading a Windows volume by hand (to grab a
    # file during recovery) needs ntfs3 available and does not need it mounted
    # at boot. That is a different question from whether this machine should
    # depend on the volume being mountable, and the answer on an unattended box
    # is no — see opts.mountShared in nixos/options.nix.
    supportedFilesystems = ["ntfs"];

    loader = {
      efi = {
        efiSysMountPoint = "/boot";
        canTouchEfiVariables = true;
      };
      timeout = 5;
      systemd-boot = {
        enable = true;
        # 500 MiB ESP shared with Windows.
        #
        # 🔴 8 WAS TOO MANY, and the number was never rechecked against a real
        # partition. Each NixOS entry carries a kernel, an initrd and the
        # closure's boot files — tens of MiB — and the budget is shared with
        # Windows. What the ESP actually reported when this was changed:
        #
        #   Filesystem      Size  Used Avail Use% Mounted on
        #   /dev/nvme0n1p1  511M  476M   36M  93% /boot
        #
        # 36 MiB free with 8 entries claimed. systemd-boot's own
        # `configurationLimit` enforcement happens while ACTIVATING: when a new
        # entry cannot be written, `switch-to-configuration boot` fails — on a
        # server that is the moment `ns-maint stage` should have refused. So the
        # limit is three (the current generation, the one it replaces, and one
        # spare) and `ns-maint stage` preflights the space before it writes
        # anything. Reclaim space with:
        #
        #   sudo bootctl cleanup     # entries no longer referenced by any profile
        #   sudo nixos-rebuild boot  # installs the current profile's entry
        #
        # Do NOT raise this to get more old generations back: the recovery path
        # that matters is the one systemd-boot can fall back to on boot counting
        # (below), which needs the PREVIOUS entry, not a list of them.
        configurationLimit = 3;
        consoleMode = "max";

        # Automatic Boot Assessment: a freshly written entry gets a counter, and
        # systemd-boot falls back to an older entry when it runs out. This is
        # nixpkgs' supported implementation of "a bad update should not leave me
        # at a boot menu in a basement", and it works with no reboot from our
        # side at all — systemd-boot does the fallback itself on the next boot.
        #
        # Off by default (opts.bootHealth.enable) because the first observation
        # of it working is a reboot you have to take deliberately, and until
        # then the counter is a mechanism nobody has seen fire. See
        # docs/headless-server.md § "Testing the boot blessing".
        bootCounting = {
          enable = bootHealth.enable;
          inherit (bootHealth) tries;
        };

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

  # ── The local boot-health gate ─────────────────────────────────────────────
  #
  # In front of the blessing, never instead of it. systemd-bless-boot.service is
  # the thing that clears the boot counter, so requiring and ordering our gate
  # ahead of IT means: if a local check fails, the blessing never runs and the
  # counter stays on the entry we just booted. systemd-boot then falls back by
  # itself on a later boot — no reboot from here, no timer, no rescue script,
  # and nothing that needs the network.
  #
  # Attached to systemd-bless-boot rather than to boot-complete.target on
  # purpose. Touching boot-complete.target means defining a target that nixpkgs
  # did not, which drags in the startLimit* options that a hand-declared target
  # has no value for ("The option systemd.targets.boot-complete.startLimitBurst
  # was accessed but has no value defined"). This is the same dependency
  # expressed on the unit that actually does the blessing.
  #
  # Deliberately NOT After=network.target / network-online.target. See the
  # script's header: the whole reason this gate exists is that it must still
  # pass on a machine whose uplink is down.
  systemd.services.boot-health-local = lib.mkIf bootHealth.enable {
    description = "Local (offline-capable) boot health gate for boot counting";
    after = criticalUnits;
    path = [pkgs.coreutils pkgs.systemd pkgs.util-linux];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.runtimeShell} ${./boot/health.sh}";
      # Nothing here should take long. A slow check is a check that is not
      # answering the question, and it holds up every boot after this one.
      TimeoutStartSec = "30s";
    };
    environment = {
      NM_BOOT_CRITICAL_UNITS = lib.concatStringsSep " " criticalUnits;
      NM_BOOT_TRIES = toString bootHealth.tries;
      NM_BOOT_USER = if opts.headless then opts.username else "";
    };
  };

  systemd.services.systemd-bless-boot = lib.mkIf bootHealth.enable {
    requires = ["boot-health-local.service"];
    after = ["boot-health-local.service"];
  };
}
