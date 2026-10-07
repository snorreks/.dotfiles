# nixos/config/home/herdr.nix
#
# herdr's headless server, owned by systemd instead of by whichever terminal
# happened to start it first.
#
# ── Why this unit exists ────────────────────────────────────────────────────
# THIS IS THE LOAD-BEARING PART. Do not "simplify" it back into a shell job.
#
# herdr splits into a persistent server (holds every workspace, pane and agent
# process) and thin clients that attach to it. Nothing that matters lives in a
# client — contract-pipeline workers, long pi/claude runs and the panes they
# occupy are all children of the server. Killing the server kills all of it.
#
# The server used to be started from `__herdr_launch_agent`, as:
#
#     nohup herdr server >/dev/null 2>&1 &
#
# That looks detached and is not. A backgrounded shell job stays in the
# starting shell's *session* with that foot window's pty as its controlling
# terminal (`ps -o sid,tty` showed sid = the fish pid, tty = pts/N, not the
# `sid == pid, tty = ?` a real daemon has). So the server's lifetime was
# silently pinned to one specific foot window — and with several windows open
# on the same session there was no way to tell which one.
#
# `nohup` does not save it. nohup only sets SIGHUP to SIG_IGN before exec, and
# herdr links `ctrlc` with the `termination` feature, whose set_handler
# installs fresh handlers for SIGINT, SIGTERM *and SIGHUP*, overriding that
# inherited ignore. The handler sets should_quit, which is exactly the "user
# asked to quit" path: `server shutdown initiated` -> every pane SIGHUPed ->
# every pipeline run gone. Closing that one window read as `herdr server stop`.
#
# Under systemd the coupling cannot exist: the service gets its own session
# and no controlling terminal, so no pty hangup can ever reach it, and it is
# supervised and restarted instead of silently vanishing.
#
# ── Boot lifetime: headless OR mobileAgents ─────────────────────────────────
# The rule and its rationale live in ./agent-lifetime.nix, which is the single
# definition shared with the tests. In short:
#
#     AGENT BOOT LIFETIME = opts.headless || opts.mobileAgents.enable
#
# It used to be `mobileAgents.enable` alone, which made agent continuity a
# property of owning a phone. A headless server with mobile access switched off
# is still an unattended server, and its agents must still come up at boot.
#
# 🔴 THE SYSTEM HALF IS NOT HERE. With WantedBy=default.target this unit is
# reachable at boot; whether the *user manager itself* starts without a login is
# `linger`, which is SYSTEM policy and belongs to config/system/mobile-agents.nix
# (lane A). B owns WantedBy/After/dependencies; A owns linger. Neither half is
# the other, and the combined headless=true + mobileAgents=false startup drill
# stays PENDING until A has merged — see docs/agent-operations.md.
#
# What is genuinely given up: at cold boot the server has no WAYLAND_DISPLAY,
# because nothing has run mango's autostart yet. Agents started into it before
# you log in cannot use wl-copy or xdg-open directly. Logging in does not change
# the existing daemon's environment: use `ns-gui <command>` to reach the current
# desktop without restarting Herdr. That is inherent to boot lifetime, and
# docs/mobile-agents.md says so rather than hiding it.
#
# 🔴 Do not add a second Wants here, or split the mobile path into its own
# unit: the server must have exactly one owner. ExecCondition below already
# treats "already listening" as a clean skip, and two owners would turn that
# into a restart that silently does nothing.
#
# 🔴 What this does NOT buy you: a process cannot survive a reboot. Across a
# reboot, herdr restores workspaces, tabs, panes and their cwds — but NOT their
# commands, because session.json has no command field. So after a reboot you
# get your layout back with bare shells in it. See herdr-resume.service below
# for the one case that IS automated, and for the three conditions it will not
# act without.
#
# ── Ordering, and why there is no PartOf ────────────────────────────────────
# On hosts WITHOUT boot lifetime, After/WantedBy graphical-session.target starts
# the unit once mango's autostart has pushed WAYLAND_DISPLAY,
# DBUS_SESSION_BUS_ADDRESS and friends into the user manager environment
# (home-manager's autostart header runs
# `dbus-update-activation-environment --systemd --all`). Panes inherit the
# server's environment, so starting earlier would hand every agent a session env
# with no Wayland display and break wl-copy, xdg-open and `[ui.toast]
# delivery = "system"`.
#
# With boot lifetime that ordering is REMOVED rather than merely not required:
# a unit ordered after a target that is never pulled in does not start at all,
# which on a lingering machine means the agents never come up.
#
# There is deliberately NO `PartOf` (contrast clipboard.nix, where dying with
# the compositor is correct): outliving its clients is the entire point. Wants
# only affects start, so a compositor restart leaves the server — and every
# running agent — untouched.
{
  config,
  inputs,
  lib,
  opts,
  pkgs,
  ...
}: let
  # The single definition, evaluated over the two existing options. No new role
  # name is introduced: A may add one, but until it merges this reads exactly
  # the booleans that exist today.
  lifetime = import ./agent-lifetime.nix;
  headless = opts.headless or false;
  mobile = opts.mobileAgents.enable or false;
  bootLifetime = lifetime.bootLifetime headless mobile;

  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  config = {
    # Single owner of the package: `__herdr_launch_agent` and the contract
    # pipeline both resolve `herdr` from PATH, and the unit resolves from the
    # stable home-manager profile symlink (/etc/profiles/per-user/%u) so the
    # unit text is stable across herdr version bumps — no forced restarts.
    #
    # 🔴 This stays the ONLY herdr in the closure. The mobile setup must not add
    # a second copy: Moshi's doctor explicitly flags two installs when the daemon
    # and the running server disagree, and a second binary would also break
    # MOSHI_HERDR_PATH's promise that it points at the running server. One
    # package, one server — config/home/moshi-hook.nix reuses this one.
    home.packages = [herdr];

    systemd.user.services.herdr = {
      Unit = {
        Description = "herdr — persistent terminal workspace server for AI agents";
        Documentation = ["https://herdr.dev"];
        # Configuration changes must not restart the daemon hosting the updater
        # or any other live agent. The new unit applies on its next deliberate
        # start; sd-switch still updates the files and reloads the user manager.
        X-SwitchMethod = lib.mkIf headless "keep-old";

        # The SOPS import must finish before herdr starts so its panes inherit
        # the session credentials. The graphical-session ordering still comes
        # from the shared agent-lifetime rule.
        After = lifetime.afterUnits headless mobile;
        Wants =
          ["sops-import-environment.service"]
          ++ lib.optionals (!lifetime.needsGraphicalSession headless mobile) ["sops-nix.service"];
      };

      Service = {
        Type = "simple";

        # Stand down instead of failing when a server is already listening —
        # `herdr server` exits 1 on AddrInUse, which with Restart=on-failure
        # would burn the start limit and leave the unit dead. ExecCondition's
        # non-zero exit skips activation cleanly (condition-failed, not failed).
        # This matters on the switchover: activating this unit while yesterday's
        # terminal-bound server is still holding the socket must be a no-op, not
        # a crash loop, and must never disturb the running agents.
        #
        # 🔴 Resolve herdr from the stable home-manager profile symlink
        # (/etc/profiles/per-user/%u) NOT a pinned store path — so the unit
        # file text is stable across herdr version bumps. If we pinned the
        # store path directly, every flake update that changes herdr would
        # alter the unit content and home-manager would restart the service,
        # killing all running agents. The SAME reasoning is why the running
        # daemon's own closure is pinned with a GC root instead: the unit stays
        # stable AND the binary the live server is executing cannot be collected
        # out from under it. See config/system/agent-ops/daemon-roots.nix.
        ExecCondition = "/run/current-system/sw/bin/bash -c '! /etc/profiles/per-user/%u/bin/herdr status server 2>/dev/null | /run/current-system/sw/bin/grep -qx \"status: running\"'";

        ExecStart = "/etc/profiles/per-user/%u/bin/herdr server";

        # herdr panicked once in 14h of pipeline use with
        #   src/app/ids.rs:16 — index out of bounds: the len is 7 but the index is 7
        # (a workspace index held across a workspace-list shrink; `pane move`
        # auto-closes a workspace it empties, so the list moves under whoever is
        # still holding an index into it). The message asks for RUST_BACKTRACE to
        # name the call site — ids.rs is reached from a dozen places and the bare
        # message cannot tell them apart. Costs nothing until a panic, and the
        # next one arrives report-ready for upstream.
        Environment = "RUST_BACKTRACE=1";

        # `herdr server stop` (and ctrl+b quit) exit 0 on purpose — only restart
        # on an actual crash, otherwise a deliberate stop would come straight
        # back up and there would be no way to stop the server at all.
        Restart = "on-failure";
        RestartSec = 2;

        # Panes are the server's own children. control-group (the default) would
        # SIGTERM them in parallel with the server, so agents die mid-write while
        # herdr is still trying to shut them down cleanly. mixed signals only the
        # main process and lets herdr tear its own panes down; SIGKILL to the
        # rest is the timeout backstop.
        KillMode = "mixed";
        KillSignal = "SIGTERM";
        TimeoutStopSec = 30;

        # An OOM-killed pane must not cause systemd to kill every other pane and
        # the multiplexer. This does not prevent kernel OOM kills; it prevents
        # systemd's stop-policy cascade after one child is killed.
        OOMPolicy = lib.mkIf headless "continue";

        WorkingDirectory = "%h";
      };

      # 🔴 The boot-lifetime hosts start at boot instead of at graphical login,
      # paired with the omitted graphical-session ordering above. The rule is in
      # agent-lifetime.nix, not here.
      Install.WantedBy = lifetime.wantedBy headless mobile;
    };

    # ── Is the server actually healthy, and does systemd own it? ────────────
    #
    # Runs once after every herdr start, and reports — it never fixes. All
    # three failures it names are invisible otherwise:
    #
    #   * a server started by a terminal keeps working while its lifetime is
    #     still tied to that terminal's pty, which is the exact failure this
    #     file's header exists to prevent;
    #   * `nix flake update herdr` moves the client and leaves the server on the
    #     old binary, and nothing surfaces the protocol mismatch;
    #   * Restart=on-failure with RestartSec=2 burns the start limit in ~25s and
    #     then the unit sits dead until someone runs `systemctl --user status`.
    #
    # Deliberately a separate oneshot rather than a condition on herdr.service:
    # failing the server unit because the CLIENT is newer would restart the
    # server, and restarting it kills every live agent pane.
    systemd.user.services.herdr-daemon-check = {
      Unit = {
        Description = "Report herdr server ownership, CLI compatibility and unit health";
        After = ["herdr.service"];
        Wants = ["herdr.service"];
        # Type=simple becomes active before the socket is ready. Retry only
        # this read-only diagnostic, with a bound so real conflicts stay visible.
        StartLimitIntervalSec = lib.mkIf headless 30;
        StartLimitBurst = lib.mkIf headless 5;
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${config.home.file.".config/agent-ops/herdr-daemon-check".source} --unit herdr.service";
        # Exit 1 means "conflicts were found and are printed". NOT success:
        # a manual daemon or a CLI/server mismatch is a condition an operator
        # needs to see, and hiding it in the journal of a unit nobody reads is
        # what this whole check exists to avoid.
        SuccessExitStatus = "0";
        # Retry the checker, never the daemon. A persistent mismatch exhausts
        # the short start limit and remains failed for the operator to inspect.
        Restart =
          if headless
          then "on-failure"
          else "no";
        RestartSec = lib.mkIf headless 2;
      };

      Install.WantedBy = ["herdr.service"];
    };

    # ── Resume explicitly opted-in agent runs ────────────────────────────────
    #
    # herdr's session restore rebuilds workspaces, tabs, panes and their cwd, but
    # NOT their commands — session.json has no command field, so every pane comes
    # back a bare shell. An interactive agent has to be restarted by hand.
    #
    # 🔴 This unit no longer hard-codes a project. It used to point at one
    # personal checkout and try to resume a `contract:resume-orphaned` task
    # there on EVERY host, whether or not the directory existed, and it declared
    # `SuccessExitStatus = "0 1"` so that a failed resume counted as healthy.
    # Both are gone: there is no default root (the script no-ops until
    # ~/.config/agent-ops/resume-roots names one), and exit 1 now means a task
    # failed to start.
    #
    # WantedBy=herdr.service (not a target) is what makes it fire on every herdr
    # START, restarts included — which is the only moment it has anything to do.
    # After= only orders it behind the process launching, so the script waits for
    # the server before touching anything.
    systemd.user.services.herdr-resume = {
      Unit = {
        Description = "Resume explicitly opted-in agent runs orphaned by a herdr restart";
        After = ["herdr.service"];
        # Not PartOf/Requires: if herdr is down there is simply nothing to do,
        # and this must never be able to hold herdr's own start up.
        Wants = ["herdr.service"];
      };

      Service = {
        Type = "oneshot";
        ExecStart = "${config.home.file.".config/agent-ops/herdr-resume".source}";

        # No SuccessExitStatus override. Each code means what the script's
        # header says it means, including 5 ("the herdr server is not running"),
        # which is a real and actionable failure rather than a reason to look
        # healthy.
        SuccessExitStatus = "0";

        # Long enough to reach the server, wait out a 120s first-heartbeat
        # window per task and stagger; short enough that a wedged resume does
        # not linger inside herdr's start transaction.
        TimeoutStartSec = 900;
      };

      Install.WantedBy = ["herdr.service"];
    };
  };
}
