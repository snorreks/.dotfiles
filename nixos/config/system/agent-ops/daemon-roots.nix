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
  opts,
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
      pkgs.gawk
      pkgs.nix
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile script;
  };
  pinCommand = lib.escapeShellArgs (["${lib.getExe tool}" "pin"] ++ lib.concatMap (unit: ["--unit" unit]) cfg.units);
  daemonEnvironment = {NM_GCROOTS = cfg.gcrootsDir; NS_OPS_USER = opts.username;};
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

    repinInterval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = ''
        How often to re-pin while running.

        The pin is idempotent and cheap, and it exists to close the window where
        the daemon has been restarted onto a store path that no generation
        references. Fifteen minutes bounds that window without a user-visible
        re-pin storm: nothing about a daemon restart changes its lifetime, only
        which closure it is executing.
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
        ExecStart = pinCommand;
        TimeoutStartSec = 300;
      };
      environment = daemonEnvironment;
    };

    # ── Re-pinning after a daemon restart ────────────────────────────────────
    #
    # 🔴 THIS IS A SYSTEM TIMER, AND IT USED TO BE A USER UNIT. Two separate
    # reasons, both of which made the user unit a unit that could never succeed:
    #
    #   1. `systemd.user.services.<name>` in NixOS is a submodule with `after`,
    #      `wantedBy`, `serviceConfig` and `sliceConfig`. It has no `After` or
    #      `Install` option — those are Home Manager spellings, and using them
    #      fails EVALUATION the moment this module is enabled. It was not caught
    #      because the module is off by default.
    #
    #   2. Even with the right option names it could not have worked: `pin`
    #      writes into the root-owned `$NM_GCROOTS`, and a user unit cannot.
    #      `require_privileged` returns 3 for a non-root caller, so the unit
    #      would have failed on every single start while looking configured.
    #
    # A system timer every few minutes is what actually closes the gap: a
    # `nix flake update herdr` plus a herdr restart moves the daemon onto a new
    # store path that no generation references, and this re-pins it. `pin` is
    # idempotent and cheap (one readlink, one `nix-store --query`, one
    # --add-root against an existing root).
    systemd.timers.agent-ops-daemon-roots-pin = {
      description = "Re-pin the running agent daemons' Nix closures";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = cfg.repinInterval;
        AccuracySec = "1min";
        # NOT Persistent: a missed re-pin must not become a thundering herd on a
        # machine that has just been off for a week. The boot-time service
        # covers that case instead.
        Persistent = false;
        RandomizedDelaySec = "60s";
        Unit = "agent-ops-daemon-roots-pin.service";
      };
    };

    systemd.services.agent-ops-daemon-roots-pin = {
      description = "Re-pin the running agent daemons' Nix closures against collection";
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pinCommand;
        TimeoutStartSec = 300;
      };
      environment = daemonEnvironment;
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
        ExecStart = "${lib.getExe tool} verify";
        TimeoutStartSec = 120;
      };
      environment.NM_GCROOTS = cfg.gcrootsDir;
    };
  };
}
