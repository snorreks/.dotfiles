# nixos/tests/maintenance-vm.nix
#
# A disposable NixOS VM test for the maintenance transaction.
#
# WHY A VM AT ALL, when nixos/tests/ns-maint-transaction.sh already drives the
# same script with fakes:
#
# Because the shell suite proves the STATE MACHINE. It cannot prove that the
# things the state machine depends on are true on a real system, and those are
# exactly the things that break silently:
#
#   * that `ns-maint` is installed, on PATH, and runs as root;
#   * that systemd actually starts the deadline timer and the reconcile unit,
#     and that they do not fight each other at boot;
#   * that the state directory is created with the mode verify-installation
#     insists on;
#   * that /run/current-system and /run/booted-system exist and point at store
#     paths, because every arm-time sanity check reads them;
#   * that a real activation, with the REAL switch-to-configuration, updates
#     the profile and the running system — which is what the confirm-time health
#     evidence compares against.
#
# The activation is faked (`activationCommand`) rather than a real system switch:
# switching the test machine to a different closure is neither possible nor
# meaningful. Everything else is real systemd, real units, real permissions.
{
  pkgs,
  maintenanceModule,
  maintenancePackage,
  testDir,
  username ? "maintenance",
  hostname ? "legion-vm",
  ...
}: let
  # A candidate closure for the fake activation to move to. It only has to be a
  # real store path with the shape of a system closure, because the kernel check
  # reads candidate/kernel-modules/lib/modules.
  candidateSystem = pkgs.runCommand "test-candidate-system" {} ''
    mkdir -p "$out/kernel-modules/lib/modules/6.1.0-test"
    mkdir -p "$out/bin"
    cp ${pkgs.writeShellScript "switch-to-configuration" ''echo "real switch $*"; exit 0''} \
      "$out/bin/switch-to-configuration"
    chmod +x "$out/bin/switch-to-configuration"
  '';

  # The fake activation: records what it was asked to do, and on success does
  # what a real `switch-to-configuration switch` does to the three variables
  # ns-maint's health evidence compares against — the profile and
  # /run/current-system. It does NOT touch the booted kernel, because a live
  # switch cannot; ns-maint refuses kernel-dirty candidates before ever getting
  # here.
  activationCommand = pkgs.writeShellScript "vm-activation" ''
    set -euo pipefail
    closure="''${1:?closure}"
    mode="''${2:?mode}"
    log=/tmp/vm-activation-log
    printf '%s %s\n' "$mode" "$closure" >>"$log"

    # The injected outcome applies to the CANDIDATE only. Restoring the recovery
    # closure always succeeds here, because that closure is by definition the one
    # that was working before — a stub that failed both directions would make
    # every restore look like restore-failed and prove nothing.
    case "$closure" in
    *candidate*)
      if [ -r /run/vm-activation-outcome ]; then
        outcome=$(cat /run/vm-activation-outcome)
      else
        outcome=success
      fi
      ;;
    *)
      outcome=success
      ;;
    esac
    case "$outcome" in
    success)
      mkdir -p /nix/var/nix/profiles
      ln -sfn "$closure" /nix/var/nix/profiles/vm-candidate-link
      ln -sfn /nix/var/nix/profiles/vm-candidate-link /nix/var/nix/profiles/system
      ln -sfn "$closure" /run/current-system
      exit 0
      ;;
    fail)
      # Refuse BEFORE touching anything, which is the dangerous shape: a failed
      # activation that leaves the profile exactly where it was.
      echo "vm-activation: refusing, deliberately, before touching anything" >&2
      exit 7
      ;;
    partial)
      # The worse shape: units are reconfigured, then it fails, and the profile
      # is NOT moved. ns-maint must restore anyway.
      ln -sfn "$closure" /run/current-system
      echo "vm-activation: applied part of the candidate, then failing" >&2
      exit 7
      ;;
    *)
      echo "vm-activation: unknown VM_ACTIVATION_OUTCOME" >&2
      exit 2
      ;;
    esac
  '';

  # A record writer, shipped as a store path.
  #
  # NOT an inline multi-line string passed to machine.succeed(): the driver's
  # shell quoting mangles a block containing single quotes and `$(...)`, and the
  # failure surfaces as "syntax error near unexpected token '('" pointing at
  # arithmetic that never had anything wrong with it. A store script has no
  # quoting layer at all.
  writeRecord = pkgs.writeShellScript "vm-write-record" ''
    set -eu
    phase="''${1:?usage: vm-write-record <phase> <deadline-offset-seconds> <note> <txid-suffix>}"
    offset="''${2:?}"
    note="''${3:-vm}"
    suffix="''${4:?}"

    rec=/var/lib/nixos/maintenance/record.env
    mkdir -p /var/lib/nixos/maintenance
    now=$(date +%s)
    current=$(readlink -f /run/current-system)
    booted=$(readlink -f /run/booted-system)
    genlink=$(readlink /nix/var/nix/profiles/system || true)
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    {
      printf 'schema_version=1\n'
      printf 'phase=%s\n' "$phase"
      printf 'txid=tx-%s-%s\n' "$stamp" "$suffix"
      printf 'host=${hostname}\n'
      printf 'operation=activate\n'
      printf 'candidate=${candidateSystem}\n'
      printf 'old_running=%s\n' "$current"
      printf 'old_profile=%s\n' "$genlink"
      printf 'old_gen=\n'
      printf 'booted=%s\n' "$booted"
      printf 'deadline=%s\n' "$((now + offset))"
      printf 'armed_at=%s\n' "$((now - 120))"
      printf 'activated_at=\n'
      printf 'restore_result=\n'
      printf 'restore_detail=\n'
      printf 'staged_candidate=\n'
      printf 'confirmed_at=\n'
      printf 'confirm_peer=\n'
      printf 'confirm_connection=\n'
      printf 'health_failed_units=\n'
      printf 'health_checked_at=\n'
      printf 'reconciled_at=\n'
      printf 'note=%s\n' "$note"
    } >"$rec"
    chmod 0644 "$rec"
  '';
in
  pkgs.testers.nixosTest {
    # The maintenance module is written against this repository's `opts`, which
    # the flake normally supplies as a special argument. nixosTest takes no
    # specialArgs, so it is injected as a module argument instead — the same
    # mechanism `flake.nix` uses, reached the other way round.

    name = "maintenance-transaction-vm";

    nodes.machine = {...}: {
      imports = [
        ({...}: {
          imports = [maintenanceModule];
          _module.args = {
            opts = {
              username = username;
              hostname = hostname;
              flakeDir = testDir;
            };
          };
        })
        ({
          config,
          lib,
          pkgs,
          ...
        }: {
          # nixpkgs must be configured where the pkgs INSTANCE is created, not
          # through the `nixpkgs.config` option; nixpkgs asserts otherwise. The
          # module does not need unfree software, so nothing is enabled here.
          system.stateVersion = "25.05";

          virtualisation.memorySize = 1024;
          virtualisation.diskSize = 4096;

          # Keep the boot short and the machine quiet: no swap, no extra units,
          # no graphics.
          boot.kernelParams = ["console=ttyS0"];
          services.xserver.enable = false;
          documentation.enable = false;

          environment.systemPackages = [maintenancePackage];

          # `maintenance.activationCommand` is the seam. It exists in production
          # too — it is how an operator wraps activation — and the shell suite's
          # fake occupies the same slot.
          #
          # The VM needs it because the alternative is running the test system's
          # REAL switch-to-configuration during a restore, which re-activates a
          # running machine for a test that is about the transaction's logic.
          maintenance.activationCommand = "${activationCommand}";
          # Default outcome for the fake activation, before any test flips it.
          environment.etc."vm-activation-outcome".text = "success\n";
          maintenance.deadlineTimeout = "20min";

          # A directory the fake activation appends to, so the test can see what
          # activation and restore actually ran.
          systemd.tmpfiles.rules = ["d /tmp 0755 root root -"];

          # A faster watchdog than the real 30s one, so the VM test does not
          # spend minutes waiting for a timer that is otherwise correct.
          systemd.services.ns-maint-watchdog = {
            # Inherit the SAME environment the real deadline unit gets. Without
            # this the test watchdog runs ns-maint with none of the NM_* values,
            # so it falls back to defaults, ignores maintenance.activationCommand
            # and tries to run the test closure's real switch-to-configuration —
            # a failure that looks like a transaction bug and is not one.
            environment = config.environment.variables;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${maintenancePackage}/bin/ns-maint tick";
            };
          };
          systemd.timers.vm-watchdog = {
            description = "drive ns-maint tick quickly in the test VM";
            wantedBy = ["timers.target"];
            timerConfig = {
              OnBootSec = "5s";
              OnUnitActiveSec = "2s";
              AccuracySec = "1s";
              Unit = "ns-maint-watchdog.service";
            };
          };
        })
      ];
    };

    testScript = ''
      # The driver script is PYTHON. A bare shell line like
      # `ns_maint status` does not parse here, and the type checker reports it
      # as an unrelated storm of "name not defined" errors.
      start_all()

      ns_maint = "${maintenancePackage}/bin/ns-maint"

      # The same environment the module gives the units. Invoking the tool
      # directly is how the OPERATOR invokes it, and the operator's shell has
      # these from the deployment's shellHook — not, as here, from systemd.
      ns_env = (
          "NM_DIR=/var/lib/nixos/maintenance "
          "NM_GCROOTS=/nix/var/nix/gcroots "
          "NM_PROFILE=/nix/var/nix/profiles/system "
          "NM_HOST=${hostname} "
      )

      def ns(*args, check=True):
          # execute(), not succeed(): ns-maint writes its operator-facing
          # messages to stderr, and succeed() returns stdout only, so every
          # assertion about wording would silently be asserting on an empty
          # string.
          # `2>&1` rather than relying on the driver merging streams: ns-maint's
          # operator-facing messages all go to stderr, and a capture that missed
          # them would turn every wording assertion into a vacuous one.
          cmd = ns_env + ns_maint + " " + " ".join(args) + " 2>&1"
          rc, out = machine.execute(cmd, check_return=False)
          if check and rc != 0:
              machine.fail(f"ns-maint {' '.join(args)} failed ({rc}):\n{out}")
          return out

      def unit_result(unit):
          return machine.execute(
              f"systemctl show -p Result --value {unit}", check_return=False
          )[1].strip()

      # -- the module's own boot-time check passes on a real system ----------
      # Asserted through the UNIT rather than by running the binary by hand, so
      # the environment the module actually configures is what gets tested.
      machine.wait_for_unit("ns-maint-verify.service", timeout=120)
      assert unit_result("ns-maint-verify.service") == "success", machine.execute(
          "systemctl status ns-maint-verify.service", check_return=False
      )[1]
      ns("verify-installation")

      # -- the units the module declares are actually enabled ----------------
      machine.wait_for_unit("multi-user.target")
      for unit in [
          "ns-maint-verify.service",
          "ns-maint-reconcile.service",
          "ns-maint-deadline.timer",
      ]:
          enabled = machine.execute("systemctl is-enabled " + unit, check_return=False)[1].strip()
          assert enabled == "enabled", f"{unit} is not enabled (got: {enabled})"

      # -- the real closure symlinks are store paths -------------------------
      # activate refuses to arm unless it can read all three, so this is a
      # precondition of every arm, checked on a real boot rather than assumed.
      current = machine.succeed("readlink -f /run/current-system").strip()
      booted = machine.succeed("readlink -f /run/booted-system").strip()
      # The system profile is created by switch-to-configuration / nixos-rebuild,
      # not by the boot, so it legitimately does not exist on a freshly booted
      # test VM. ns-maint tolerates that: an absent profile is recorded as an
      # absent profile, and restoring it is a no-op. The two /run symlinks below
      # ARE created at boot and ARE arm-time preconditions, so those are the
      # ones asserted here.
      profile = machine.execute(
          "readlink /nix/var/nix/profiles/system", check_return=False
      )[1].strip()
      print(f"profile={profile!r} (empty is expected on a booted test VM)")
      assert current.startswith("/nix/store/"), f"/run/current-system is not a store path: {current}"
      assert booted.startswith("/nix/store/"), f"/run/booted-system is not a store path: {booted}"
      print(f"current={current}")
      print(f"booted={booted}")

      # -- status works with no transaction, and reboot is opt-in ------------
      ns("status")
      out = ns("reboot", check=False)
      assert "Nothing in this tool reboots implicitly" in out, out
      out = ns("reconcile")
      assert "nothing pending" in out, out

      # -- the watchdog really runs, on a real timer, with nothing pending ---
      machine.wait_for_unit("vm-watchdog.timer", timeout=60)
      machine.sleep(6)
      assert unit_result("ns-maint-watchdog.service") == "success", machine.execute(
          "systemctl status ns-maint-watchdog.service", check_return=False
      )[1]

      # -- a cold boot leaves a record behind; reconcile classifies it -------
      # A real `armed` record, in the real state directory, with a deadline
      # already in the past, classified by the real code. Nothing here can be
      # simulated by pretending the record does not exist.
      machine.succeed("${writeRecord} armed -60 cold-boot-reconcile abcdef")

      out = ns("reconcile")
      status = ns("status", "--json")
      assert '"phase":"reconciled-not-applied"' in status, status
      # The deadline MUST be cleared. If it is not, the real watchdog fires a
      # restore against a stale expectation on its next tick, which is how a
      # restore / reboot / restore loop starts.
      assert '"deadline":""' in status, status
      assert "nothing was retried" in out, out

      # -- and the running watchdog stays quiet afterwards --------------------
      machine.sleep(6)
      assert unit_result("ns-maint-watchdog.service") == "success", machine.execute(
          "systemctl status ns-maint-watchdog.service", check_return=False
      )[1]
      assert '"phase":"reconciled-not-applied"' in ns("status", "--json")

      # -- a pending transaction really is restored by the real timer --------
      # The property the shell suite cannot reach: a REAL systemd timer firing a
      # REAL `ns-maint tick`, which takes the real lock, reads the real record
      # and runs the real restore path.
      # An already-applied candidate with the deadline two seconds out: the real
      # timer must pick this up and restore it.
      machine.succeed("${writeRecord} awaiting-confirm 2 timer-restores fedcba")
      machine.sleep(25)
      status = ns("status", "--json")
      assert '"phase":"restored"' in status, f"the real watchdog did not restore:\n{status}"
      # The record's own note is the evidence, not the journal: a test VM's
      # journald is volatile and "No entries --" says nothing about the contract.
      assert '"note":"restoring (deadline-expired)"' in status, status
      assert '"restore_result":"restored-live"' in status, status

      # -- a REFUSED activation restores, even though the profile never moved --
      # This is the case the old nswitch-safe declared safe: activation exits
      # nonzero, the profile is untouched, and the code concluded "no new
      # generation exists, nothing to revert".
      machine.succeed("echo partial > /run/vm-activation-outcome")
      machine.succeed("${writeRecord} awaiting-confirm 600 refused-activation 999999")
      ns("abort")
      status = ns("status", "--json")
      assert '"phase":"restored"' in status, status
      assert '"restore_result":"restored-live"' in status, status
      machine.succeed("echo success > /run/vm-activation-outcome")

      # -- an operator-initiated restore is also reboot-free -----------------
      machine.succeed("${writeRecord} awaiting-confirm 600 operator-abort 123456")
      ns("abort")
      assert '"phase":"restored"' in ns("status", "--json")

      # -- and nothing rebooted, at any point in any of the above -----------
      uptime = float(machine.succeed("cut -d' ' -f1 /proc/uptime").strip())
      assert uptime < 1200, f"the VM looks like it restarted (uptime {uptime}s)"
      print(f"uptime at end: {uptime}s")
    '';
  }
