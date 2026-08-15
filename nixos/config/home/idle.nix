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
# savings with none of the suspend risk. To re-enable suspend later, add a
# second swayidle timeout running `sys-daemon idle-guard` (built from
# ./sys-daemon/package.nix, same as before — see git history for the exact
# wiring) with resumeCommand `pkill -f 'sys-daemon idle-guard'` — the
# Service.Environment
# PATH fix below already covers what it needs (`herdr`/`playerctl` by bare
# name, otherwise invisible to swayidle.service's minimal default PATH).
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
  dimThenLock = pkgs.writeShellScriptBin "idle-dim" ''
    ${pkgs.brightnessctl}/bin/brightnessctl -s set 0
    exec ${swaylockRuntime}/bin/swaylock-runtime
  '';
in {
  services.swayidle = {
    enable = true;
    timeouts = [
      {
        timeout = 600; # 10 min: dim, then lock behind it
        command = "${dimThenLock}/bin/idle-dim";
        resumeCommand = "${pkgs.brightnessctl}/bin/brightnessctl restore";
      }
    ];
  };

  systemd.user.services.swayidle.Service.Environment = [
    "PATH=${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
  ];
}
