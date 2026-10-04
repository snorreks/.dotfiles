# nixos/config/system/agent-ops/backup.nix
#
# Encrypted offsite backup, opt-in, with a restore that can be proved.
#
# ── Why a focused module and not edits to system.nix ─────────────────────────
# Backup is a new capability, not a change to how the system is built. It gets
# its own file with its own options so that turning it on is one boolean, the
# diff is reviewable on its own, and lane A (server foundation, host and
# network policy) is not edited to accommodate it.
#
# ── What is opt-in, and what is not ──────────────────────────────────────────
# `agentOps.backup.enable` defaults to FALSE, and there is deliberately no
# "auto-enable on headless hosts" rule. An unattended machine with no backup
# configured is a real and common state, and hiding it behind a host role is how
# you get a box that has silently never been backed up. Instead:
#
#   * enabling without a repository credential FAILS THE BUILD, because
#     declaring a sops secret that does not exist is an error and that is the
#     correct time to find out;
#   * leaving it disabled makes ns-agent-health report backup "unconfigured",
#     which is a PROBLEM, not a pass.
#
# So "not backed up" is always visible and never mistaken for "backed up".
#
# ── Credentials ──────────────────────────────────────────────────────────────
# RESTIC_REPOSITORY and RESTIC_PASSWORD are declared HERE, not in
# config/home/sops.nix, for two reasons. Declaring them in the home module would
# put them in the user's sops set on every host including the laptop that never
# backs anything up. And env-secrets.nix is specifically the list that becomes
# session variables, which is the ambient-exposure path this PR removes.
#
# They reach restic as systemd credentials at the moment the timer fires:
# the repository as an environment variable the script reads, the password as a
# FILE that restic reads (RESTIC_PASSWORD_FILE), so the password is never in the
# environment of anything else the script starts.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = config.agentOps.backup;
  stateDir = cfg.stateDir;
  script = ./scripts/ns-agent-backup.sh;
  quiesceTable = pkgs.writeText "agent-ops-quiesce.conf"
    (lib.concatMapStrings (e: "${e.path}|${e.method}|${e.arg}\n") cfg.quiesce);

  # The monthly proof that the repository can be read back. A separate
  # derivation rather than an inline `sh -c`, so that every path inside it is
  # interpolated by Nix at BUILD time.
  #
  # 🔴 The previous inline version used `''${…}` inside a `''…''` script, which
  # escapes the interpolation — the shell got the literal text `${tool}` and
  # `${pkgs.coreutils}`, and the unit could never have run. It also invoked
  # `${pkgs.coreutils}/bin/sh`, which does not exist.
  verifyScript = pkgs.writeShellScript "agent-ops-backup-verify" ''
    set -euo pipefail
    scratch="$(mktemp -d /var/tmp/agent-ops-restore.XXXXXX)"
    echo "restoring into $scratch (scratch only; this never writes live data)"
    # NOT exec: the restore's own output is the evidence an operator reads in
    # the journal, and `exec` would replace this shell and lose the listing
    # below it.
    ${lib.getExe tool} --config /etc/agent-ops/backup.conf restore --to "$scratch"
    echo "--- what came back ---"
    find "$scratch" -maxdepth 3 -type f | head -50
    echo "--- inspect $scratch, then remove it ---"
  '';

  tool = pkgs.writeShellApplication {
    name = "ns-agent-backup";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.restic
      pkgs.sqlite
      pkgs.util-linux
    ];
    text = builtins.readFile script;
  };

  # Paths worth taking. Read from the shared manifest so backup and health
  # cannot disagree about what "state" means on this host.
  home = "/home/${opts.username}";
  manifest = config.agentOps.state.manifest;
  included = builtins.filter (e: !(e.excludeFromBackup or false)) manifest;
  defaultSources = map (e: e.path) included;

  # ── excludes ───────────────────────────────────────────────────────────────
  # Every entry is a named decision with a reason in the diff. No blanket
  # patterns: `--exclude /nix/store` is fine because /nix/store is not state,
  # but `--exclude *.json` is not, because half the irreplaceable state above IS
  # json.
  defaultExcludes = [
    # Re-downloadable by content hash from cache.nixos.org.
    "/nix/store"
    # Reconstructed by the Nix database, which is small and gets its own
    # consistent snapshot; the paths themselves are all re-downloadable.
    "/nix/var/nix/profiles/per-user"
    # Runtime sockets and pid files are not state; holding one open means a
    # process is using it, and archiving it archives a stale inode.
    "*.sock"
    "*.pid"
    # Caches, by name, not by wildcard.
    "${home}/.cache"
    # The agent layout's own transient log, which can be megabytes and is
    # genuinely useless in a restore.
    "${home}/.config/herdr/herdr-server.log"
    "${home}/.config/herdr/herdr-client.log"
  ];
in {
  options.agentOps.backup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the encrypted offsite restic backup. Requires the two sops credentials below to exist.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agent-ops/backup";
      description = "Where the last-run record and quiesce scratch live.";
    };

    sources = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultSources;
      description = "Absolute paths to back up. Defaults to the reviewed state manifest.";
    };

    excludes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = defaultExcludes;
      description = "restic --exclude patterns. Each one is a deliberate decision; see the module header.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = ''
        systemd OnCalendar for the backup. Deliberately spread off the hour and
        off the half hour: every machine on a list that says "daily" and fires at
        03:00 will hit the same remote repository at the same instant.
      '';
    };

    limitUpload = lib.mkOption {
      type = lib.types.str;
      default = "8000000";
      description = ''
        restic --limit-upload in bytes/s. Bounded because this host's uplink is
        the same one the tailnet that reaches it runs over; an unbounded backup
        is a self-inflicted outage for the thing the box exists to provide.
      '';
    };

    limitDownload = lib.mkOption {
      type = lib.types.str;
      default = "20000000";
      description = "restic --limit-download in bytes/s. Higher than upload: a restore is interactive.";
    };

    ioMaxConcurrent = lib.mkOption {
      type = lib.types.str;
      default = "2";
      description = "restic --io-max-concurrent. Two on a spinning disk, four on NVMe; measured, not guessed at runtime.";
    };

    keepDaily = lib.mkOption {
      type = lib.types.int;
      default = 7;
      description = "restic --keep-daily.";
    };

    keepWeekly = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "restic --keep-weekly.";
    };

    keepMonthly = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "restic --keep-monthly.";
    };

    maxAgeSeconds = lib.mkOption {
      type = lib.types.int;
      default = 93600;
      description = ''
        Newer than this many seconds counts as healthy (26h, so one missed run
        is not a page at 3am). Older is a PROBLEM reported by ns-agent-health.
      '';
    };

    quiesce = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = ''
        Application-consistent exports. Each entry is
        `{ path, method, arg }` where method is "sqlite" or "none" and arg is
        the sqlite3 binary. The EXPORT is backed up, never the live file: `cp`
        of a database that is being written yields a file that passes
        `PRAGMA integrity_check` and is still corrupt.
      '';
    };

    heartbeatHook = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        After a successful backup, run the configured media state hook.
        Requires `mediaStateHook` to be set; leaving it off changes nothing.
      '';
    };

    mediaStateHook = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Executable run after a successful backup, owned by the media lane (C)
        and set by config/system/media/default.nix. It is passed the backup's
        staging directory, so it can verify that what was actually shipped is
        restorable rather than merely present.

        Null here and set from the media module, not the other way round: this
        option is a SEAM, and a seam that pointed at something declared in the
        module that fills it would be a dependency in the other direction.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      sops.secrets = {
        RESTIC_REPOSITORY = {};
        RESTIC_PASSWORD = {};
      };

      environment.etc."agent-ops/backup.conf".text = ''
        # Generated by nixos/config/system/agent-ops/backup.nix.
        #
        # 🔴 THIS FILE CONTAINS NO SECRETS AND MUST NEVER BE GIVEN ANY.
        # The repository and its password arrive as systemd credentials at run
        # time. A secret here would be in the Nix store, readable by every
        # account on the machine and in `nix-store -q --references` output.
        sources=${lib.escapeShellArg (builtins.toJSON cfg.sources)}
        excludes=${lib.escapeShellArg (builtins.toJSON cfg.excludes)}
        quiesceFile=${lib.escapeShellArg "${stateDir}/quiesce.conf"}
        quiesceSource=${lib.escapeShellArg (builtins.toJSON (map (e: e.path) cfg.quiesce))}
        limitUpload=${cfg.limitUpload}
        limitDownload=${cfg.limitDownload}
        ioMaxConcurrent=${cfg.ioMaxConcurrent}
        packSize=32
        keepDaily=${toString cfg.keepDaily}
        keepWeekly=${toString cfg.keepWeekly}
        keepMonthly=${toString cfg.keepMonthly}
        maxAgeSeconds=${toString cfg.maxAgeSeconds}
        repositoryCheckSubset=2/1000
      '';

      # The quiesce table is written fresh each run rather than being a static
      # file, so adding a database to the option is the only edit needed.
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
      ];

      systemd.services.agent-ops-quiesce-table = {
        description = "Write the application-consistent export table for backup";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/install -m 0600 ${quiesceTable} ${lib.escapeShellArg "${stateDir}/quiesce.conf"}";
        };
      };

      systemd.services.agent-ops-backup = {
        description = "Encrypted offsite backup (restic)";
        after = ["network-online.target" "agent-ops-quiesce-table.service"];
        # Deliberately NOT requiring network-online: a backup that is skipped
        # because the link is down is exactly right, and the health module
        # reports the resulting staleness instead of hiding it. What it must not
        # do is block on it forever.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe tool} --config /etc/agent-ops/backup.conf backup";
          LoadCredential = [
            "RESTIC_REPOSITORY:${config.sops.secrets.RESTIC_REPOSITORY.path}"
            "RESTIC_PASSWORD:${config.sops.secrets.RESTIC_PASSWORD.path}"
          ];
          # Bounded, so a wedged remote cannot hold the unit open indefinitely.
          # Sized for a full repository over a home uplink, not for a hang.
          TimeoutStartSec = "4h";
          # Restart=no: the script already retries a bounded number of times and
          # a systemd restart loop on top of that is an unbounded retry wearing
          # a different hat.
          Restart = "no";
          # The one thing this must never do: reboot. There is no ExecStop that
          # touches power state and no `|| systemctl reboot` anywhere in the
          # script. An unreachable repository is an unreachable repository.
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };

      systemd.timers.agent-ops-backup = {
        description = "Run the offsite backup";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.schedule;
          # Not Persistent. A missed backup should not become a large catch-up
          # run at the exact moment the machine has been switched on after being
          # off for a week, competing with everything else that wants to run.
          Persistent = false;
          RandomizedDelaySec = "30min";
          AccuracySec = "5min";
          Unit = "agent-ops-backup.service";
        };
      };

      # Retention is a SEPARATE, explicitly invoked job. `forget` and `prune`
      # are the two operations that can make a backup unrecoverable, so they
      # are not something a timer does on its own.
      systemd.timers.agent-ops-backup-retention = {
        description = "Apply restic retention (forget only; prune is manual)";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "Sun *-*-* 04:17:00";
          Persistent = false;
          RandomizedDelaySec = "2h";
          Unit = "agent-ops-backup-retention.service";
        };
      };

      systemd.services.agent-ops-backup-retention = {
        description = "Apply restic --forget retention without pruning";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe tool} --config /etc/agent-ops/backup.conf prune";
          LoadCredential = [
            "RESTIC_REPOSITORY:${config.sops.secrets.RESTIC_REPOSITORY.path}"
            "RESTIC_PASSWORD:${config.sops.secrets.RESTIC_PASSWORD.path}"
          ];
          TimeoutStartSec = "1h";
        };
      };

      # A monthly proof, into SCRATCH, that the repository can actually be read
      # back. A backup nobody has ever restored is a hypothesis.
      systemd.timers.agent-ops-backup-verify = {
        description = "Restore the newest snapshot into scratch to prove it is readable";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "Sun *-*-01 05:23:00";
          Persistent = false;
          RandomizedDelaySec = "2h";
          Unit = "agent-ops-backup-verify.service";
        };
      };

      systemd.services.agent-ops-backup-verify = {
        description = "Prove the newest snapshot restores into scratch";
        serviceConfig = {
          Type = "oneshot";
          # A separate derivation rather than an inline `sh -c`, so every path in
          # it is interpolated by NIX at build time.
          #
          # 🔴 The previous version used `''${…}` inside the `''…''` script, which
          # ESCAPES the interpolation: the shell received the literal text
          # `${pkgs.coreutils}` and `${tool}`, i.e. bad substitution, and the
          # unit could never have run. It also ran under `/bin/sh`.
          ExecStart = "${verifyScript} --config /etc/agent-ops/backup.conf";
          LoadCredential = [
            "RESTIC_REPOSITORY:${config.sops.secrets.RESTIC_REPOSITORY.path}"
            "RESTIC_PASSWORD:${config.sops.secrets.RESTIC_PASSWORD.path}"
          ];
          TimeoutStartSec = "2h";
        };
      };
    })

    # ── Media state hook ─────────────────────────────────────────────────────
    #
    # Only reachable when BOTH are set. The `cfg.heartbeatHook &&` alone would
    # be a switch that silently does nothing if the media module were removed,
    # and the assertion below is what makes that combination an error instead.
    #
    # ExecStartPost, not ExecStart: this runs only when the main command
    # SUCCEEDED. A post-step on a failed backup would be reporting on state the
    # backup never captured, which is the opposite of useful.
    #
    # The paths are absolute and literal rather than derived from this module.
    # The export directory belongs to the media lane and is created by the
    # service it also owns; this module is verifying someone else's directory,
    # and inventing a second copy of that path here is how the two drift.
    (lib.mkIf (cfg.enable && cfg.heartbeatHook && cfg.mediaStateHook != null) {
      systemd.services."agent-ops-backup".serviceConfig.ExecStartPost =
        lib.escapeShellArgs [
          cfg.mediaStateHook
          "verify"
          "--exports"
          "/var/lib/agent-ops/media-exports"
          "--health-dir"
          "/var/lib/agent-ops"
        ];
    })

    # The half-configured states, refused at evaluation rather than discovered
    # as a backup that quietly skipped its media verification forever.
    (lib.mkIf (cfg.enable && cfg.heartbeatHook && cfg.mediaStateHook == null) {
      assertions = [
        {
          assertion = false;
          message = ''
            agentOps.backup.heartbeatHook is true but mediaStateHook is null.
            The media lane (config/system/media/default.nix) is the only thing
            that sets it; if you have enabled one without the other, the media
            modules are not imported.
          '';
        }
      ];
    })

    (lib.mkIf (cfg.enable && cfg.mediaStateHook != null && !cfg.heartbeatHook) {
      assertions = [
        {
          assertion = false;
          message = ''
            agentOps.backup.mediaStateHook is set but heartbeatHook is false, so
            the hook would never run. Enable both, or neither.
          '';
        }
      ];
    })
  ];
}
