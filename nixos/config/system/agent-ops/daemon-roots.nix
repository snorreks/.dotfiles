# nixos/config/system/agent-ops/daemon-roots.nix
#
# Keep the running herdr daemon's Nix closure alive across a garbage collection.
#
# ── The hole this closes ────────────────────────────────────────────────────
# herdr.service resolves its binary through /etc/profiles/per-user/%u rather than
# a pinned store path, on purpose: pinning the path would change the unit text on
# every herdr version bump, home-manager would restart the service, and
# restarting the server kills every live agent pane. See the header in
# config/home/herdr.nix.
#
# The consequence is that the store path the server is EXECUTING is referenced by
# nothing a garbage collector can see: not /run/current-system, not the booted
# closure, not any generation. `ns-maint` pins the system's closures very
# carefully and none of them is this one, so PR #4's running-system roots
# provide no protection here at all. After an `nix-collect-garbage` the binary
# is unlinked; the process survives on its inode and dies at the next dlopen or
# spawn, far from anything that explains why.
#
# This module pins what the RUNNING process is executing, read from
# /proc/PID/exe, with its own root namespace.
#
# ── Why it does not touch ns-maint ───────────────────────────────────────────
#   * The roots are created in the SAME gcroots directory, with a different
#     name prefix. `nix-store --gc` honours every root it can find there, so
#     `ns-maint gc` protects these with no cooperation at all, and it still
#     never passes --delete.
#   * The transaction format, the phase machine, the record and the rollback
#     deadline are untouched. This lane does not edit that script while lane A is
#     working in it.
#   * The known, stated gap: `ns-maint roots` globs `ns-maint-*` and therefore
#     will not list these. That is why this module installs its own `list` and
#     says so in its help text and in docs/agent-operations.md. Widening that
#     glob is a one-word change in a file another lane owns.
#
# ── When it runs ─────────────────────────────────────────────────────────────
# After every herdr start, and once per boot. NOT inside a maintenance
# transaction, and not on a timer that could coincide with one: the pin must
# exist whether or not a transaction record does, because the failure it
# prevents is a daemon dying after somebody ran plain `nix-collect-garbage`
# with no transaction anywhere in sight.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.agentOps.daemonRoots;
  script = ./scripts/ns-agent-daemon-roots.sh;

  tool = pkgs.writeShellApplication {
    name = "ns-agent-daemon-roots";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile script;
  };
in {
  options.agentOps.daemonRoots = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Pin the running herdr daemon's Nix closure with a GC root so an ordinary
        collection cannot delete the binary the live server is executing.
      '';
    };

    gcrootsDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/gcroots";
      description = ''
        Where the roots are written. The SAME directory ns-maint uses, so one
        collector honours both. Changing it means the roots stop being honoured
        by `ns-maint gc`.
      '';
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["herdr.service"];
      description = "User units whose MainPID's executable closure is pinned.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [tool];

    systemd.tmpfiles.rules = [
      "d ${cfg.gcrootsDir} 0755 root root -"
    ];

    # Once at boot. WantedBy, not requiredBy: a failure to pin must be loud but
    # must not stop the machine reaching multi-user, because reaching multi-user
    # is what makes it fixable.
    systemd.services.agent-ops-daemon-roots = {
      description = "Pin the running agent daemons' Nix closures against collection";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tool} pin --unit ${lib.head cfg.units}";
        # 1 means "a pin failed, or a root is dangling". Reported through the
        # unit's state and through ns-agent-health; never silently treated as
        # fine.
        SuccessExitStatus = "0 1";
        TimeoutStartSec = 300;
      };
      environment.NM_GCROOTS = cfg.gcrootsDir;
    };

    # Re-pin on every herdr start. WantedBy=herdr.service is a wants-symlink
    # INTO the herdr unit, so it is pulled in whenever herdr starts (including
    # a restart); After= puts it behind the process, so /proc/PID/exe is there by
    # the time it runs.
    #
    # This is deliberately NOT an ExecStartPost drop-in: a drop-in that appended
    # ExecStartPost would change the effective unit, and the whole design point
    # of herdr.service is that its text stays byte-identical across version
    # bumps so home-manager never restarts it.
    systemd.user.services.agent-ops-daemon-roots = {
      description = "Pin the running herdr server's Nix closure against collection";
      After = ["herdr.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${tool} pin --unit ${lib.head cfg.units}";
        SuccessExitStatus = "0 1";
        TimeoutStartSec = 300;
      };
      environment.NM_GCROOTS = cfg.gcrootsDir;
    };

    systemd.user.services.agent-ops-daemon-roots.Install = {
      wantedBy = ["herdr.service"];
    };

    # A cheap daily proof that the pin still resolves. Without it, a root that
    # silently stopped matching (a manual `rm`, a root directory recreated by
    # tmpfiles with the wrong ownership) is invisible until the daemon dies.
    systemd.timers.agent-ops-daemon-roots-verify = {
      description = "Verify the pinned agent-daemon closures still resolve";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "15min";
        OnUnitActiveSec = "24h";
        AccuracySec = "5min";
        # NOT Persistent: a missed daily check must not become a thundering herd
        # on a machine that has just been off for a week.
        Persistent = false;
        Unit = "agent-ops-daemon-roots-verify.service";
      };
    };

    systemd.services.agent-ops-daemon-roots-verify = {
      description = "Check that every pinned agent-daemon closure still resolves";
      wantedBy = ["timers.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tool} verify";
        TimeoutStartSec = 120;
      };
      environment.NM_GCROOTS = cfg.gcrootsDir;
    };
  };
}
