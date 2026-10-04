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
# policies, and it does not touch the host OUTPUT firewall at all.
{config, pkgs, lib, opts, ...}: let
  jellyfin = opts.media.jellyfin;
  torrents = opts.media.torrents;

  # Anything that should be exported before a backup runs.
  exportAny = jellyfin.enable || torrents.enable;
  exportDir = "/var/lib/agent-ops/media-exports";
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
  # box being down. Second, `ManagedOOMPreference = avoid` on the operator's own
  # slice means a memory spike in a transcoder is resolved by killing the
  # transcoder rather than the thing you are using to fix it.
  #
  # NVIDIA is untouched. Inference runs as the operator's own process and keeps
  # the discrete GPU; see jellyfin.nix for why Jellyfin is never pointed at it.
  systemd.slices.mediaWorkload = lib.mkIf exportAny {
    description = "Media workloads: transcoding, scanning, downloading";
    sliceConfig = {
      # Under system.slice, NOT under user.slice: management responsiveness is
      # the property being protected, and this is the workload it protects
      # against.
      Slice = "system.slice";
      IOAccounting = true;
      TasksAccounting = true;
      MemoryAccounting = true;
      # A low IOWeight means downloads and library scans yield to the machine's
      # other work at the block layer, without either being stopped.
      IOWeight = 50;
    };
  };

  # The operator's own slice is preferred as an OOM victim over the media
  # workloads. `avoid` does not forbid the OOM killer; it makes the choice
  # explicit and predictable instead of leaving it to allocation order.
  systemd.user.slices.mediaAvoidOom = lib.mkIf exportAny {
    description = "Prefer the operator's session over media workloads under memory pressure";
    sliceConfig = {
      Slice = "user.slice";
      ManagedOOMPreference = "avoid";
      ManagedOOMSwap = "kill";
      ManagedOOMMemoryPressure = "kill";
    };
  };

  # `Slice` lives under serviceConfig in NixOS' systemd submodule — there is no
  # `sliceConfig` option, and `systemd.services.jellyfin` already exists
  # (nixpkgs' own jellyfin module defines it), so this merges across modules
  # rather than conflicting within this one.
  systemd.services.jellyfin.serviceConfig = lib.mkIf jellyfin.enable {
    Slice = "mediaWorkload.slice";
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
    lib.optional exportAny (
      pkgs.writeShellApplication {
        name = "media-state";
        runtimeInputs = [pkgs.sqlite pkgs.coreutils pkgs.util-linux];
        text = builtins.readFile ./scripts/media-state.sh;
      }
    )
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
  systemd.services.media-state-export = lib.mkIf (exportAny && opts.agentOps.backup.enable) {
    description = "Export media service state for the backup (application-consistent)";
    before = ["agent-ops-backup.service"];
    after = lib.mkMerge [
      "local-fs.target"
      "jellyfin.service"
      "qbittorrent.service"
    ];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = {
        MEDI_STATE_DIR = exportDir;
        MEDI_JELLYFIN_DB =
          lib.optionalString jellyfin.enable "${jellyfin.dataDir}/data/library.db";
        MEDI_QBITTORRENT_PATHS =
          lib.optionalString torrents.enable "${torrents.stateDir}/qBittorrent.conf";
      };
      ExecStart = "media-state export";
    };
  };

  agentOps.backup = lib.mkIf (exportAny && opts.agentOps.backup.enable) {
    # Both switches, or neither: backup.nix refuses one without the other,
    # because a hook that never runs and a hook that runs against nothing look
    # identical from the outside.
    heartbeatHook = true;
    mediaStateHook = ./scripts/media-state.sh;
    # Registered with the ordinary backup rather than with a second one.
    sources = [{paths = [exportDir];}];
  };
}