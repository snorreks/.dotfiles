# nixos/config/system/maintenance.nix
#
# The maintenance transaction, as system units.
#
# ── Why this is its own module ───────────────────────────────────────────────
# config/system/server.nix used to carry `nswitch-safe`, which armed a
# 20-minute dead-man timer BEFORE building and rolled back with
# `systemctl reboot`. Three separate things were wrong with that, and none of
# them is fixable by reordering a couple of lines inside a wrapper:
#
#   1. The timer was armed before the build, so a build that simply took longer
#      than the window rebooted a machine nobody could reach. The arming has to
#      happen immediately before MUTATION, which means the build has to be a
#      separate, unarmed command.
#   2. Rollback used `systemctl reboot`. On a host reached only over the tailnet
#      that is the single worst possible response to "I am not sure about this
#      change": it kills every running agent and stream, and it destroys the
#      evidence needed to work out why. Recovery here is LIVE — runtime, profile
#      and boot intent are restored in place and the kernel is left alone.
#   3. A nonzero `nh` exit was treated as "no new generation exists, so nothing
#      needs reverting". Pinned NH activates with `switch-to-configuration test`
#      before it sets the profile, so a failed activation can have reconfigured
#      live units and then failed — leaving changed services behind an
#      UNCHANGED profile. That is precisely the case the old code declared safe.
#      Nothing here infers safety from the profile: a failed activation restores
#      regardless of what the profile says.
#
# ── What this installs ───────────────────────────────────────────────────────
#   ns-maint                     the transaction tool (see its header comment)
#   ns-maint-verify.service      checks the invariants ns-maint assumes
#   ns-maint-reconcile.service   classifies a persistent record after a cold boot
#   ns-maint-deadline.timer      persistent deadline watchdog
#   /var/lib/nixos/maintenance   root-owned transaction state
#
# ── Why the watchdog is a PERSISTENT timer ────────────────────────────────────
# The obvious implementation arms a transient `systemd-run --on-active=`
# one-shot, which is what the old wrapper did. A transient timer lives in
# /run and is gone after a reboot, so a machine that reboots inside the
# confirmation window comes back with a record that says "awaiting
# confirmation" and nothing at all watching it. This timer is enabled at boot
# and simply asks `ns-maint tick` to look at the record every 30 seconds, so it
# survives every restart, and so `ns-maint reconcile` has something to clear.
#
# ── Why ns-maint is installed on desktop hosts too ────────────────────────────
# It is inert until something runs it, it is one shell script, and gating it on
# opts.headless would mean the day headless flips the safe path arrives without
# having been evaluated on that host at all. WHICH commands the shell aliases
# route through it is decided in config/home/fish/default.nix, which is where
# the desktop/server distinction actually lives today.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = config.maintenance;

  dir = "/var/lib/nixos/maintenance";
  profile = "/nix/var/nix/profiles/system";
  gcroots = "/nix/var/nix/gcroots";

  # How often the persistent watchdog asks the record whether its deadline has
  # passed. 30s bounds how long a machine can sit past the operator's
  # confirmation window; the tick itself is a single flock + read, so this is
  # not a busy loop.
  tickSeconds = 30;

  # Defined in package.nix rather than inline so the NixOS VM test can install
  # the SAME derivation the Legion does. See that file's header.
  nsMaint = pkgs.callPackage ./maintenance/package.nix {deploymentConfig = nsEnv;};

  nsMaintExe = lib.getExe nsMaint;

  nsEnv =
    {
      NM_DIR = "/var/lib/nixos/maintenance";
      NM_GCROOTS = "/nix/var/nix/gcroots";
      NM_PROFILE = "/nix/var/nix/profiles/system";
      NM_HOST = opts.hostname;
      NM_FLAKE = opts.flakeDir;
      NM_DEFAULT_TIMEOUT = cfg.deadlineTimeout;
      NM_SSH_UNIT = cfg.confirmSSHUnit;
      # The ESP preflight in `ns-maint stage` (see esp_preflight in ns-maint.sh).
      # Exported with the rest so the operator's own invocation and the units
      # agree on which partition is being measured and what floor applies.
      NM_ESP_PATH = cfg.espPath;
      NM_ESP_MIN_MIB = toString cfg.espMinMib;
    }
    // lib.optionalAttrs (cfg.activationCommand != null) {
      # The seam through which every activation and every restore actually runs.
      # With this unset (the default) ns-maint runs the CANDIDATE's own
      # bin/switch-to-configuration, which is what a live update must do.
      #
      # It exists to be set. Wrapping activation — to log it, to run a pre-hook,
      # to route it through nh, or to substitute a stub in a test — is a real need
      # and is not something to leave to a hand-edited systemd drop-in.
      NM_SWITCH_TO_CONFIGURATION = cfg.activationCommand;
    };
in {
  options.maintenance = {
    activationCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Command invoked as `<command> <closure> <switch|boot|test>` instead of
        the closure's own bin/switch-to-configuration. Null (the default) means
        ns-maint uses the candidate's switch-to-configuration directly, which is
        what a real update does. Set it to wrap activation, or to substitute a
        stub — which is how nixos/tests/maintenance-vm.nix exercises the restore
        path without re-activating a running system.
      '';
    };

    deadlineTimeout = lib.mkOption {
      type = lib.types.str;
      default = "20min";
      description = ''
        Default confirmation window, used when `ns-maint activate` is called
        without --timeout. Long enough for a human to open a second connection
        and look, short enough that an unattended machine is not left in an
        armed window overnight.
      '';
    };

    confirmSSHUnit = lib.mkOption {
      type = lib.types.str;
      default = "sshd.service";
      description = ''
        The systemd unit whose journal is asked whether a NEW session was
        accepted after the switch was armed. Renamed only if a host moves sshd
        out of its socket-activated unit.

        One unit covers BOTH OpenSSH listeners on these hosts, and that is not
        an assumption: `services.openssh.ports = [ 22 2222 ]` runs both
        listeners from the same sshd.service, and journald records their
        sessions under it (`sshd-session[NNN]: Accepted publickey for … from …
        port …`) — checked on the Legion with both ports listening at once. A
        confirmation made over the phone's 2222 session is therefore evidence in
        exactly the same way one made over 22 is.

        What this does NOT cover is Tailscale SSH, which answers on tailnet port
        22 before the OS sshd ever sees the connection and is recorded by
        tailscaled instead. Confirm from an OpenSSH session (22 or 2222). The
        refusal message says so when the peer is a tailnet address, because
        "no evidence found" from Tailscale SSH otherwise reads like a failed
        update.
      '';
    };

    espPath = lib.mkOption {
      type = lib.types.str;
      default = "/boot";
      description = ''
        Where the EFI system partition is mounted, used by `ns-maint stage` to
        check there is room for a kernel, an initrd and a boot entry BEFORE it
        writes one. Writing there is not atomic: an ESP that fills up part-way
        leaves an entry behind that is not obviously the good one.
      '';
    };

    espMinMib = lib.mkOption {
      type = lib.types.int;
      default = 150;
      description = ''
        Free space `ns-maint stage` requires on the ESP. Roughly one NixOS entry
        with its kernel and initrd, plus room for one more replacement after
        this one.

        This floor exists because the real partition was measured at 36 MiB free
        of 511 MiB (shared with Windows) while the bootloader was configured to
        keep eight generations. See config/system/boot.nix.
      '';
    };
  };

  config = {
    environment.systemPackages = [nsMaint];

    # nsEnv is compiled into the store executable, not taken from the caller's
    # environment: sudo and transient activation use the same trusted settings.

    # The state directory. Root-owned and not group/other-writable: a
    # non-privileged caller that could write record.env could forge a
    # transaction and make root activate something. `ns-maint verify-installation`
    # re-checks this at every boot rather than trusting it once at build time.
    #
    # The gcroots directory is where Nix itself looks for GC roots, so roots
    # created there are honoured by an ordinary `nix-collect-garbage` — including
    # the one `ns-maint gc` runs, which deliberately never passes -d.
    systemd.tmpfiles.rules = [
      "d ${dir} 0750 root root -"
      "d ${gcroots} 0755 root root -"
    ];

    # ── Boot-time invariant check ──────────────────────────────────────────────
    #
    # `RemainAfterExit` is deliberately unset and the unit is `wantedBy`, not
    # `requiredBy`, anything: a maintenance misconfiguration must be LOUD but must
    # not stop the machine from reaching multi-user, because the machine reaching
    # multi-user is what makes the misconfiguration fixable from a phone.
    systemd.services.ns-maint-verify = {
      description = "Verify the ns-maint state directory and GC root invariants";
      wantedBy = ["multi-user.target"];
      after = ["local-fs.target"];
      serviceConfig = {
        Type = "oneshot";
        # RemainAfterExit so the result stays VISIBLE: `systemctl status
        # ns-maint-verify` answers "did the maintenance invariants hold at boot?"
        # without anyone having to read a journal. Without it the unit goes
        # inactive the moment it succeeds and the check is unfindable.
        RemainAfterExit = true;
        ExecStart = "${nsMaintExe} verify-installation";
      };
    };

    # ── Cold-boot reconciliation ───────────────────────────────────────────────
    #
    # Runs once per boot, after the store and the profile are mounted and the
    # systemd units that publish /run/current-system and /run/booted-system have
    # run. `ns-maint reconcile` never arms, never activates and never reboots; it
    # only classifies whatever the persistent record was left saying and clears
    # the deadline so no watchdog acts on a stale expectation. That is what keeps
    # a restore/reboot/restore cycle from ever starting.
    systemd.services.ns-maint-reconcile = {
      description = "Classify any pending ns-maint transaction after a cold boot";
      wantedBy = ["multi-user.target"];
      after = [
        "local-fs.target"
        "systemd-modules-load.service"
        "ns-maint-verify.service"
      ];
      # Deliberately NOT After=network.target. Reconciliation is a local-state
      # decision, and an offline box that cannot resolve a name still has to
      # classify its own record and clear its deadline.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${nsMaintExe} reconcile";
        # A failure here is reported, not retried in a loop.
        Restart = "no";
      };
    };

    # ── The deadline watchdog ──────────────────────────────────────────────────
    #
    # Persistent (not armed per transaction, not transient), so it is still there
    # after the reboot that reconciliation is designed to survive. `tick` is a
    # no-op unless a pending record's deadline has actually passed.
    systemd.services.ns-maint-deadline = {
      description = "ns-maint deadline watchdog tick";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${nsMaintExe} tick";
        # Bounded so a wedged tick cannot pile up behind itself.
        TimeoutStartSec = 120;
      };
    };

    systemd.timers.ns-maint-deadline = {
      description = "Watch the pending ns-maint transaction deadline";
      wantedBy = ["timers.target"];
      timerConfig = {
        # Late enough that ns-maint-reconcile has already had its say, so a
        # machine that rebooted inside a window does not get a spurious restore
        # on top of its reconciliation.
        OnBootSec = "2min";
        OnUnitActiveSec = toString tickSeconds;
        AccuracySec = "1s";
        # NOT Persistent=true: a missed tick is meaningful only while a
        # transaction is pending, and the record's own absolute deadline is what
        # decides that, so replaying yesterday's catch-up tick would be noise.
        Persistent = false;
        Unit = "ns-maint-deadline.service";
      };
    };

    # ── What the tool is told at runtime ───────────────────────────────────────
    #
    # One shared map, used by all three units and exported system-wide. A second,
    # hand-maintained copy of these values is how a unit ends up watching a
    # different state directory from the one the operator inspects.
    # No manager or shell NM_* injection is required.
  };
}
