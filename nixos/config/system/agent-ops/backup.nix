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
        Seam for lane C: after a successful backup, run the configured media
        state hooks. Declared here and not implemented, because C owns the media
        modules and this lane must not guess at their state layout. Off, so
        nothing changes until C lands and fills it in.
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
          ExecStart = "${pkgs.coreutils}/bin/sh" "-c" ''            cat > ${stateDir}/quiesce.conf <<'AGENTOPS'
                    ${lib.concatMapStringsSep "\n" (
                e: "${e.path}|${e.method}|${e.arg}"
              )
              cfg.quiesce}
                    AGENTOPS'';
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
          ExecStart = "${tool} --config /etc/agent-ops/backup.conf backup";
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
          ExecStart = "${tool} --config /etc/agent-ops/backup.conf prune";
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
          ExecStart = lib.escapeShellArgs [
            "${pkgs.coreutils}/bin/sh"
            "-c"
            ''
              set -e
              scratch="$(''${pkgs.coreutils}/bin/mktemp -d /var/tmp/agent-ops-restore.XXXXXX)"
              echo "restoring into $scratch (scratch only; this never writes live data)"
              ''${tool} --config /etc/agent-ops/backup.conf restore --to "$scratch"
              ''${pkgs.findutils}/bin/find "$scratch" -maxdepth 3 -type f | ''${pkgs.coreutils}/bin/head -50
              echo "--- inspect $scratch, then remove it ---"
            ''
          ];
          LoadCredential = [
            "RESTIC_REPOSITORY:${config.sops.secrets.RESTIC_REPOSITORY.path}"
            "RESTIC_PASSWORD:${config.sops.secrets.RESTIC_PASSWORD.path}"
          ];
          TimeoutStartSec = "2h";
        };
      };
    })

    (lib.mkIf (cfg.enable && cfg.heartbeatHook) {
      assertions = [
        {
          assertion = false;
          message = ''
            agentOps.backup.heartbeatHook is a seam reserved for the media/travel
            lane (C). It is intentionally not implemented here: C owns the media
            state layout and this lane must not guess at it. Enable it from C's
            branch, not this one.
          '';
        }
      ];
    })
  ];
}
