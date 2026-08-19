# nixos/config/home/idle.nix
#
# Idle chain: dim screen, locked in the background. That's it — no
# auto-suspend right now.
#
# Auto-suspend (sys-daemon's `idle-guard`, still present and working — see
# sys-daemon/src/idle.rs) was wired up here through several rounds of fixes
# (systemd/NVIDIA freeze bug in power-management.nix, herdr/media/CPU/
# network/disk busy checks) and still got disabled after two separate
# real incidents where resume-from-suspend broke badly enough to need a
# hard power-off: compositor alive enough to move the cursor, but no
# repaint, no keybindings, no VT-switch. Root cause traced conclusively to
# actual suspend/resume on this NVIDIA + mango combo, not to the idle
# automation's timing or checks — logs showed idle-guard correctly decided
# it was safe and suspended cleanly both times; the break happened on
# resume. A manual `systemctl suspend` (bypassing idle-guard entirely)
# resumed fine, and even a manual replication of the exact locked+dimmed
# state idle-guard suspends from also resumed fine once — so this looks
# intermittent/timing-dependent (the real failures both sat locked+dimmed
# ~20 min before suspending; the clean manual repro only waited 2) rather
# than deterministically reproducible. Two hard-reboot incidents was enough
# signal to stop trusting it regardless.
#
# So: dim (and lock behind it) still fires at idle, since that's real power
# savings with none of the suspend risk — but it's now gated on the SAME
# `blocker()` checks idle-guard uses (herdr/pi agent working, media playing,
# CPU/network/disk busy), via the one-shot `sys-daemon idle-check`
# subcommand, so it never fires while a background pi session is mid-turn or
# a video is playing. Seat idle alone (no keyboard/mouse input) used to be
# sufficient to dim+lock unconditionally — that's how a YouTube video with no
# mouse movement still got dimmed even though waybar's mpris module clearly
# showed it playing (that module just displays MPRIS state, it never fed
# back into swayidle), and how a headless `pi --mode json` run in a
# background herdr pane (see contract_pipeline's herdr_adapter.ts) could get
# dim/locked out from under it despite doing real work. To re-enable
# auto-suspend itself later, add a second swayidle timeout running
# `sys-daemon idle-guard` (built from ./sys-daemon/package.nix, same as
# before — see git history for the exact wiring) with resumeCommand
# `pkill -f 'sys-daemon idle-guard'` — the Service.Environment PATH fix below
# already covers what it needs (`herdr`/`playerctl` by bare name, otherwise
# invisible to swayidle.service's minimal default PATH).
#
# Dim fires first, lock second, both from one command — so nothing
# lock-screen-related is ever visible while idle, whatever it looks like.
# Dimming uses brightnessctl (set 0 / restore), not wlr-output-power-management
# (wlopm) — wlopm was tried first, but toggling DPMS off/on left the
# compositor's repaint wedged (flat dark-grey background, hardware cursor
# only) on this NVIDIA + mango setup. That turned out to likely be a milder
# case of the same resume fragility above, not a DPMS-specific bug, but
# brightnessctl avoids the DRM connector power state entirely regardless, so
# there's no reason to go back to wlopm.
{
  pkgs,
  config,
  ...
}: let
  swaylockRuntime = import ./swaylock-runtime.nix {inherit pkgs;};
  # Where idle-dim publishes its pid while it is still cancellable. Dropped the
  # moment it commits to dimming, so idle-resume can never target swaylock.
  pidFile = "\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/idle-dim.pid";
  dimThenLock = pkgs.writeShellScriptBin "idle-dim" ''
    # Gate on the same blocker logic idle-guard uses before suspending (herdr/pi
    # agent working, media playing, sustained CPU/network/disk — see
    # sys-daemon/src/idle.rs `blocker()`), reused here via the one-shot
    # `idle-check` subcommand. Seat idle only means "no keyboard/mouse input" —
    # it says nothing about a pi session mid-turn in a background herdr pane or
    # a YouTube video playing (waybar's mpris module reads the same MPRIS data
    # but that's display-only, it never fed back into swayidle). Re-check on a
    # short interval, mirroring idle-guard's retry loop, until clear.
    pidfile="${pidFile}"
    echo $$ >"$pidfile"
    trap 'rm -f "$pidfile"' EXIT
    until sys-daemon idle-check; do
      sleep 60
    done
    # Point of no return: past here this pid becomes swaylock (exec below), so
    # drop the pidfile first — idle-resume must only ever get a handle on the
    # retry loop above, never on the lock screen.
    rm -f "$pidfile"
    trap - EXIT
    ${pkgs.brightnessctl}/bin/brightnessctl -s set 0
    exec ${swaylockRuntime}/bin/swaylock-runtime
  '';
  # Resume: cancel a still-looping idle-dim (by pid, never by name) and undo the
  # dim. Must NOT go back to `pkill -f idle-dim` — swayidle carries both the
  # idle-dim store path and its own resume command on its own argv, so that
  # pattern matched swayidle itself and the `sh -c` wrapper running the pkill.
  # It killed both, never reached brightnessctl restore, and left a black screen
  # with swaylock invisible behind it — looking exactly like a compositor crash.
  # It never matched idle-dim either, which by then had exec'd into
  # swaylock-runtime and no longer carried the name.
  resumeFromDim = pkgs.writeShellScriptBin "idle-resume" ''
    pidfile="${pidFile}"
    if pid=$(cat "$pidfile" 2>/dev/null) && [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      rm -f "$pidfile"
    fi
    ${pkgs.brightnessctl}/bin/brightnessctl restore
  '';
in {
  services.swayidle = {
    enable = true;
    timeouts = [
      {
        timeout = 600; # 10 min: dim, then lock behind it (once idle-check clears)
        command = "${dimThenLock}/bin/idle-dim";
        # Cancels idle-dim if it's still stuck in its idle-check retry loop
        # (never got to dimming), so a stale retry doesn't fire minutes after
        # real activity resumed, then restores brightness — a harmless no-op in
        # the cancelled case since brightness was never zeroed.
        resumeCommand = "${resumeFromDim}/bin/idle-resume";
      }
    ];
  };

  systemd.user.services.swayidle.Service.Environment = [
    "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
  ];
}
