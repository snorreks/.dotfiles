# nixos/config/home/idle.nix
#
# Idle chain: dim the screen, lock behind it. That's it — no auto-suspend.
#
# ── Why there is no auto-suspend ────────────────────────────────────────────
# Auto-suspend (sys-daemon's `idle-guard`, still present and working — see
# sys-daemon/src/idle.rs) was wired up here through several rounds of fixes
# (systemd/NVIDIA freeze bug in power-management.nix, herdr/media/CPU/network/
# disk busy checks) and still got disabled after two separate real incidents
# where resume-from-suspend broke badly enough to need a hard power-off:
# compositor alive enough to move the cursor, but no repaint, no keybindings,
# no VT-switch. Root cause traced conclusively to actual suspend/resume on this
# NVIDIA + mango combo, not to the idle automation's timing or checks — logs
# showed idle-guard correctly decided it was safe and suspended cleanly both
# times; the break happened on resume. A manual `systemctl suspend` (bypassing
# idle-guard entirely) resumed fine, and even a manual replication of the exact
# locked+dimmed state idle-guard suspends from also resumed fine once — so this
# looks intermittent/timing-dependent (the real failures both sat locked+dimmed
# ~20 min before suspending; the clean manual repro only waited 2) rather than
# deterministically reproducible. Two hard-reboot incidents was enough signal to
# stop trusting it regardless.
#
# To re-enable it later, add another rung to `attempts` below running
# `sys-daemon idle-guard` (built from ./sys-daemon/package.nix, same as before —
# see git history for the exact wiring). Note idle-guard has its OWN retry loop,
# so it needs the same cancellation story the ladder was built to avoid; the
# simplest correct wiring is a one-shot `idle-check && systemctl suspend` rung,
# not the looping guard.
#
# ── Why dim+lock is gated on more than seat idleness ────────────────────────
# Seat idle alone (no keyboard/mouse input) used to be sufficient to dim+lock
# unconditionally — that's how a YouTube video with no mouse movement still got
# dimmed even though waybar's mpris module clearly showed it playing (that
# module just displays MPRIS state, it never fed back into swayidle), and how a
# headless `pi --mode json` run in a background herdr pane (see
# contract_pipeline's herdr_adapter.ts) could get dim/locked out from under it
# despite doing real work. So every attempt below is gated on the same
# `blocker()` checks idle-guard uses (herdr/pi agent working, media playing,
# CPU/network/disk busy), via the one-shot `sys-daemon idle-check` subcommand.
#
# ── Why this is a ladder of one-shot attempts, not a retry loop ─────────────
# THIS IS THE LOAD-BEARING PART. Do not "simplify" it back into a loop.
#
# The previous design ran ONE idle-dim per idle period which, if `idle-check`
# came back blocked, slept 60s and re-checked, forever, until it went clear —
# then dimmed and locked. Cancellation came from a single swayidle
# `resumeCommand` killing it by pid through a pidfile. Three things made that
# structurally unsafe, and it twice locked the screen while actively typing:
#
#   1. `idle-check` has no idea whether the seat is idle. blocker() only asks
#      "is the machine busy" (herdr/media/CPU/net/disk). So the loop meant
#      "wait, possibly for hours, until the machine goes quiet — then lock",
#      and machine-quiet is not user-absent. A 30s grace window was added to
#      re-confirm before committing, but it re-sampled the BLOCKERS, never the
#      seat, so it could not catch this at all.
#   2. swayidle sends exactly one resume per idle period, and the pidfile had
#      one slot. Every new idle period spawns a fresh idle-dim which overwrote
#      the pidfile — permanently orphaning any older loop still running. That
#      orphan could never be cancelled by anything, ever, and would lock the
#      screen at whatever arbitrary future moment the blockers happened to
#      clear.
#   3. idle-resume read the pidfile with `cat`. Any input landing right at the
#      timeout boundary, before idle-dim had written its pid, made the kill a
#      silent no-op — orphaning that instance from birth and seeding (2).
#
# Observed in the journal on 2026-08-20: instance 12881 polled
# "blocked: a herdr agent is actively working" every 60s for over two hours of
# an obviously-active workday, then locked at 15:59:48; a second concurrent
# instance, 112650, locked again 69 seconds later. Two live lockers at once.
#
# The fix is to stop keeping state between attempts. Each entry in `attempts`
# is an independent swayidle timeout, so the COMPOSITOR is the one tracking
# idleness: a rung fires only if there has been zero input for that long, and
# any input resets the entire ladder. idle-dim then either commits within a
# couple of seconds or gives up and leaves it to the next rung. There is no
# long-lived process to orphan, no pid to lose, and nothing to cancel — so
# resumeCommand no longer kills anything. It also costs far less: the old loop
# spawned a sys-daemon process every 60s indefinitely (hundreds of them in the
# log above); this spawns at most one per rung.
#
# A rung that fires while blocked simply loses that attempt. If the machine
# stays busy through the whole ladder, that idle period never locks — which is
# the correct outcome, since something was demonstrably running the whole time.
#
# ── Mechanics ───────────────────────────────────────────────────────────────
# Dim fires first, lock second, both from one command — so nothing
# lock-screen-related is ever visible while idle, whatever it looks like.
# Dimming uses brightnessctl (set 1% / restore), not wlr-output-power-management
# (wlopm) — wlopm was tried first, but toggling DPMS off/on left the
# compositor's repaint wedged (flat dark-grey background, hardware cursor only)
# on this NVIDIA + mango setup. That turned out to likely be a milder case of
# the same resume fragility above, not a DPMS-specific bug, but brightnessctl
# avoids the DRM connector power state entirely regardless, so there's no
# reason to go back to wlopm.
#
# The 1% floor (rather than 0) is deliberate: if swayidle's resumeCommand
# doesn't fire during session lock, the lock screen stays faintly visible and
# the user can recover without a hard power-off. The marker-based guard in
# idle-dim prevents a later rung from re-saving 1% as the restore point.
#
# Never reach for `pkill -f idle-dim` here. swayidle carries both the idle-dim
# store path and its own resume command on its own argv, so that pattern
# matches swayidle itself and the `sh -c` wrapper running the pkill — it killed
# both, never reached brightnessctl restore, and left a black screen with
# swaylock invisible behind it, looking exactly like a compositor crash. The
# flock below is the supported way to ask "is a locker already up".
{
  pkgs,
  config,
  ...
}: let
  swaylockRuntime = import ./swaylock-runtime.nix {inherit pkgs;};

  # Seconds of *continuous* seat idleness at which to attempt dim+lock. Each is
  # a separate swayidle timeout; the first one that finds every blocker clear
  # wins and the rest become no-ops (see the flock in idle-dim). Any input at
  # all resets the whole ladder, so the last rung is also the point past which
  # a busy-but-untouched machine simply won't lock this idle period.
  attempts = [600 900 1200 1800 2700 3600 5400 7200];

  runtimeDir = "\${XDG_RUNTIME_DIR:-/run/user/$(id -u)}";
  # Held for as long as a lock screen is up — fd 9 survives the exec into
  # swaylock — so later rungs can tell "already locked" from "free to lock".
  lockFile = "${runtimeDir}/idle-dim.lock";
  # Present only while this chain dimmed the backlight; its contents are the
  # pre-dim brightness percent (from /tmp/custom_brightness, the actual
  # source of truth waybar/the dashboard read — see change_brightness.sh and
  # Sys.qml). Keeps idle-resume idempotent across the several rungs that may
  # have fired, and keeps it from clobbering a brightness the user set by
  # hand during an idle period where nothing ever dimmed.
  dimmedMarker = "${runtimeDir}/idle-dim.dimmed";

  dimThenLock = pkgs.writeShellScriptBin "idle-dim" ''
    # One locker at a time. fd 9 stays open across the `exec` into
    # swaylock-runtime below, so the flock is held for the lifetime of the lock
    # screen itself: a later rung firing while the screen is already locked
    # fails to take it and falls through to the dim-only branch instead of
    # stacking a second swaylock on top of the first.
    exec 9>"${lockFile}"
    if ${pkgs.util-linux}/bin/flock -n 9; then
      alreadyLocked=0
    else
      alreadyLocked=1
    fi

    if [ "$alreadyLocked" = 0 ]; then
      # One instantaneous sample, no retry loop — see the header. Blocked means
      # this attempt is abandoned; the next rung tries again, but only if the
      # seat is still untouched by then.
      if ! sys-daemon idle-check; then
        echo "idle-dim: blocked — abandoning this attempt"
        exit 0
      fi
    fi

    # `brightnessctl -s` saves whatever is current, so dimming while already at
    # 0 saves 0 and makes every later `restore` a permanent no-op — that had
    # already happened here (/run/user/1000/brightnessctl held 0). Only save and
    # dim when we haven't already done so this idle period (marker check) AND
    # there's a lit backlight to save. The marker goes down BEFORE the dim on
    # purpose: a spurious restore (marker set, dim failed) is a harmless
    # brightness bump, while the reverse ordering can lose the resume in between
    # and strand the screen black. Note this step is decorative on an
    # external-monitor-only setup: DP/HDMI outputs have no /sys/class/backlight
    # entry, so the dim is invisible and the lock is the only thing that shows.
    #
    # Dim to 1% (not 0) to avoid total blackout if swayidle's resumeCommand
    # doesn't fire during session lock — the user can still see the lock screen
    # faintly and recover without a hard power-off. The marker guard below
    # prevents a later rung from re-saving 1% as the restore point.
    current=$(${pkgs.brightnessctl}/bin/brightnessctl -m | head -n1 | cut -d, -f3)
    if [ ! -e "${dimmedMarker}" ] && [ "''${current:-0}" -gt 0 ]; then
      # Save the app's brightness of record (/tmp/custom_brightness), not
      # just brightnessctl's own save-file: idle-resume restores through
      # change_brightness so waybar/the dashboard actually reflect the
      # restore, instead of quietly disagreeing with sysfs until the user
      # manually scrolls brightness. Falls back to the raw sysfs percent if
      # the state file hasn't been created yet.
      cat /tmp/custom_brightness 2>/dev/null >"${dimmedMarker}" || printf '%s' "''${current}" >"${dimmedMarker}"
      ${pkgs.brightnessctl}/bin/brightnessctl -s set 1%
    fi

    if [ "$alreadyLocked" = 1 ]; then
      # Screen was already locked and has since been re-lit (touching a key at
      # the lock screen restores brightness); this rung just puts it back down.
      exit 0
    fi

    echo "idle-dim: clear — dimming and locking"
    exec ${swaylockRuntime}/bin/swaylock-runtime
  '';

  # Runs on the first real input after an idle period — once for every rung
  # that fired, so it has to be idempotent. Nothing to cancel or kill any more:
  # idle-dim never outlives its own attempt.
  resumeFromDim = pkgs.writeShellScriptBin "idle-resume" ''
    marker="${dimmedMarker}"
    [ -e "$marker" ] || exit 0
    saved=$(cat "$marker" 2>/dev/null || echo "")
    rm -f "$marker"
    # Go through change_brightness (not brightnessctl restore) so the state
    # file, waybar's instant refresh, and the ddcutil fan-out to external
    # monitors all catch up too — otherwise the panel silently disagrees with
    # what the UI shows until the user manually scrolls brightness.
    if [ -n "$saved" ]; then
      change_brightness "$saved"
    else
      ${pkgs.brightnessctl}/bin/brightnessctl restore
    fi
  '';
in {
  services.swayidle = {
    enable = true;
    timeouts =
      map (seconds: {
        timeout = seconds;
        command = "${dimThenLock}/bin/idle-dim";
        resumeCommand = "${resumeFromDim}/bin/idle-resume";
      })
      attempts;
  };

  # swayidle.service ships a minimal default PATH, which `sys-daemon idle-check`
  # needs more than: it shells out to `herdr` and `playerctl` by bare name and
  # is otherwise invisible to them. Everything else here is referenced by full
  # store path for the same reason.
  systemd.user.services.swayidle.Service.Environment = [
    "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
  ];
}
