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
# ── Ordering, and why there is no PartOf ────────────────────────────────────
# After/WantedBy graphical-session.target so the unit starts once mango's
# autostart has pushed WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS and friends
# into the user manager environment (home-manager's autostart header runs
# `dbus-update-activation-environment --systemd --all`). Panes inherit the
# server's environment, so starting earlier would hand every agent a session
# env with no Wayland display and break wl-copy, xdg-open and `[ui.toast]
# delivery = "system"`.
#
# There is deliberately NO `PartOf` (contrast clipboard.nix, where dying with
# the compositor is correct): outliving its clients is the entire point. Wants
# only affects start, so a compositor restart leaves the server — and every
# running agent — untouched.
{
  inputs,
  pkgs,
  ...
}: let
  herdr = inputs.herdr.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  # Single owner of the package: `__herdr_launch_agent` and the contract
  # pipeline both resolve `herdr` from PATH, and the unit pins the store path.
  home.packages = [herdr];

  systemd.user.services.herdr = {
    Unit = {
      Description = "herdr — persistent terminal workspace server for AI agents";
      Documentation = ["https://herdr.dev"];
      After = ["graphical-session.target" "sops-import-environment.service"];
      Wants = ["sops-import-environment.service"];
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
      ExecCondition = "${pkgs.bash}/bin/bash -c '! ${herdr}/bin/herdr status server 2>/dev/null | ${pkgs.gnugrep}/bin/grep -qx \"status: running\"'";

      ExecStart = "${herdr}/bin/herdr server";

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

      WorkingDirectory = "%h";
    };

    Install.WantedBy = ["graphical-session.target"];
  };
}
