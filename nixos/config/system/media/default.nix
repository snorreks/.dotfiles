# nixos/config/system/media/default.nix
#
# Private media and isolated downloads: Jellyfin, a namespace-confined
# qBittorrent, optional Syncthing, and the hooks that connect them to the
# backup lane.
#
# Every service in this directory is OPT-IN and defaults to disabled. Importing
# the directory changes nothing on a machine that has not asked for it, which is
# why `imports` below is unconditional while every `mkIf` is not.
#
# Ownership boundary: this lane reuses the backup, health and resource modules
# that already exist in config/system/agent-ops/. It does not add a second
# backup mechanism, a second health collector or a second set of cgroup
# policies. Torrents add only a narrow backend UID rejection, never host NAT,
# forwarding, or a global firewall policy change.
{config, pkgs, lib, opts, ...}: let
  jellyfin = opts.media.jellyfin;
  torrents = opts.media.torrents;

  # Anything that should be exported before a backup runs.
  exportAny = jellyfin.enable || torrents.enable;
  exportDir = "/var/lib/agent-ops/media-exports";

  # Built once and used twice: installed into the system PATH for the operator,
  # and referenced by ABSOLUTE path from the unit. A bare `media-state` in
  # ExecStart resolves against the unit's PATH, which is NixOS's default
  # utility set rather than `environment.systemPackages` — so the pre-backup
  # export would not run, and the backup hook would then verify an export that
  # was never made.
  mediaState = pkgs.writeShellApplication {
    name = "media-state";
    runtimeInputs = [pkgs.sqlite pkgs.coreutils pkgs.util-linux pkgs.findutils pkgs.systemd pkgs.jq];
    text = builtins.readFile ./scripts/media-state.sh;
  };
  backupEnabled = config.agentOps.backup.enable;

in {
  imports = [
    ./jellyfin.nix
    ./torrents.nix
    ./syncthing.nix
  ];

  # ── Resource containment ──────────────────────────────────────────────────
  #
  # A system slice, because Jellyfin is a system service and the user slices in
  # config/system/agent-ops/resources.nix do not apply to it.
  #
  # Two properties matter here. First, the numbers are LIMITS: transcoding and
  # scanning a large library are genuinely CPU- and memory-hungry, and the
  # failure mode when they are not bounded is that SSH to a box in a basement
  # stops responding — which, from where you are, is indistinguishable from the
  # box being down. Per-service memory limits contain those workloads; no empty
  # "management" slice can guarantee protection for the operator's real session.
  #
  # NVIDIA is untouched. Inference runs as the operator's own process and keeps
  # the discrete GPU; see jellyfin.nix for why Jellyfin is never pointed at it.
  # NAMED `system-mediaWorkload.slice`, not `mediaWorkload.slice`.
  #
  # systemd derives a unit's parent from its name: everything before the final
  # `-<name>` is the hierarchy. A slice called `mediaWorkload.slice` therefore
  # resolves to a top-level slice with no named parent, and asking for
  # `Slice = "system.slice"` as well does not fix that — it is the NAME that
  # places the unit, and the two disagreed. The prefix is the parent.
  systemd.slices."system-mediaWorkload" = lib.mkIf exportAny {
    description = "Media workloads: transcoding, scanning, downloading";
    sliceConfig = {
      IOAccounting = true;
      TasksAccounting = true;
      MemoryAccounting = true;
      # A low IOWeight means downloads and library scans yield to the machine's
      # other work at the block layer, without either being stopped.
      IOWeight = 50;
      # Valid normal candidacy if oomd is enabled elsewhere. "evacuate" is
      # invalid and was silently ignored by systemd; this is not an OOM priority
      # guarantee or a reason to skip host load calibration.
      ManagedOOMPreference = "none";
      ManagedOOMSwap = "kill";
      ManagedOOMMemoryPressure = "kill";
    };
  };

  # THE OPERATOR'S SIDE IS NOT CONFIGURED HERE, AND CANNOT BE.
  #
  # This previously declared a `mediaAvoidOom.slice` carrying
  # `ManagedOOMPreference = avoid` with `Slice = "user.slice"`, on the theory
  # that it protected the operator's session. It did not: the slice was EMPTY,
  # so nothing ran in it, and the operator's login session lives in the
  # system-managed `user-<uid>.slice`, which cannot be given `avoid` from here
  # without claiming the whole system-managed slice.
  #
  # Media is not exempted from oomd, but its candidates and pressure thresholds
  # still depend on the host's actual oomd configuration. Protecting the real
  # operator slice requires separate, measured logind/cgroup policy.

  # `Slice` lives under serviceConfig in NixOS' systemd submodule — there is no
  # `sliceConfig` option, and `systemd.services.jellyfin` already exists
  # (nixpkgs' own jellyfin module defines it), so this merges across modules
  # rather than conflicting within this one.
  systemd.services.jellyfin.serviceConfig = lib.mkIf jellyfin.enable {
    Slice = "system-mediaWorkload.slice";
  };

  # ── Commands ──────────────────────────────────────────────────────────────
  #
  # Composed into one list and declared once: `environment.systemPackages`
  # assigned twice in one attribute set is "already defined", not a merge.
  #
  # `media-state` exports Jellyfin's library index (SQLite, via the backup API
  # plus integrity_check) and qBittorrent's settings into a DURABLE tree. It
  # must run before the backup so the tree exists when the backup reads it, and
  # it is durable rather than the backup lane's per-run staging because the
  # point of verifying afterwards is having something to verify.
  #
  # `media-offline-prep` copies already-chosen library items to a cache the
  # travel laptop can carry: no downloads, no purchases, no subscriptions, no
  # services. The selector is required, so "copy the library" is never
  # something it does on its own.
  environment.systemPackages =
    lib.optional exportAny mediaState
    ++ lib.optional jellyfin.enable (
      pkgs.writeShellApplication {
        name = "media-offline-prep";
        runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.findutils pkgs.util-linux];
        text = builtins.readFile ./scripts/media-offline-prep.sh;
      }
    );

  systemd.tmpfiles.rules = lib.mkIf exportAny [
    "d ${exportDir} 0700 root root -"
  ];

  # ── The backup seam ───────────────────────────────────────────────────────
  #
  # The seam config/system/agent-ops/backup.nix declares, filled in here. The
  # `after` includes the media services on purpose: exporting a database that
  # has never been created would report success for a state that does not exist.
  systemd.services.media-state-export = lib.mkIf (exportAny && backupEnabled) {
    description = "Export media service state for the backup (application-consistent)";
    before = ["agent-ops-backup.service"];
    after = [
      "local-fs.target"
      "jellyfin.service"
      "qbittorrent.service"
    ];

    # `environment`, not `serviceConfig.Environment`: the latter is a systemd
    # unit option, and an attrset there cannot serialise into `Environment=`
    # lines. NixOS's `environment` option does that conversion.
    environment = {
      MEDI_STATE_DIR = exportDir;
      MEDI_JELLYFIN_DB =
        lib.optionalString jellyfin.enable "${jellyfin.dataDir}/data/library.db";
      MEDI_QBITTORRENT_PATHS_JSON = builtins.toJSON (lib.optionals torrents.enable
        (lib.unique [torrents.stateDir torrents.configDir]));
      MEDI_QBITTORRENT_UNIT = lib.optionalString torrents.enable "qbittorrent.service";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      ExecStart = "${lib.getExe mediaState} export";
    };
  };

  # Requires + ordering makes a failed export fail the backup transaction, and
  # a non-remaining oneshot is refreshed on every timer/manual backup start.
  systemd.services.agent-ops-backup = lib.mkIf (exportAny && backupEnabled) {
    requires = ["media-state-export.service"];
    after = ["media-state-export.service"];
  };

  agentOps.backup = lib.mkIf (exportAny && backupEnabled) {
    # Both switches, or neither: backup.nix refuses one without the other,
    # because a hook that never runs and a hook that runs against nothing look
    # identical from the outside.
    heartbeatHook = true;
    mediaStateHook = ./scripts/media-state.sh;
    # Registered with the ordinary backup rather than with a second one.
    additionalSources = [exportDir];
  };
}