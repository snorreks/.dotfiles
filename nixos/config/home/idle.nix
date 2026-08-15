# nixos/config/home/idle.nix
#
# Idle chain: screen off (locked in the background) → suspend (if safe).
#
# Screen-off fires first, lock second, both from one command — so nothing
# lock-screen-related is ever visible while idle, whatever it looks like.
# swaylock keeps the session locked the whole time regardless of display
# power state, so when `wlopm --on` fires on resume, swaylock's prompt is
# the first (and only) thing shown. Only the final suspend is gated — screen
# blanking costs nothing and is wanted even if you're just AFK, not gone.
#
# Wayland idle-notify (what swayidle watches, confirmed implemented in mango
# via `wlr_idle_notifier_v1`) only means "no input"; it says nothing about a
# herdr agent mid-turn, a build compiling, or a download in flight, all of
# which run with zero input. So the 30-min timeout doesn't call `systemctl
# suspend` directly — it hands off to sys-daemon's `idle-guard`, which checks
# herdr, CPU load, network throughput, and disk I/O, then re-checks on its
# own retry interval until all are clear before suspending. See
# sys-daemon/src/idle.rs — also see power-management.nix for the
# systemd/NVIDIA suspend-freeze fix that addresses the other half of the
# incident that motivated the disk check.
#
# swayidle's `resume` handler kills idle-guard (and turns the screen back on)
# on real user activity, so a pending retry never races a manual wake-up.
{pkgs, ...}: let
  sys-daemon = pkgs.callPackage ./sys-daemon/package.nix {};
  swaylockRuntime = import ./swaylock-runtime.nix {inherit pkgs;};
  screenOffThenLock = pkgs.writeShellScriptBin "idle-screen-off" ''
    ${pkgs.wlopm}/bin/wlopm --off '*'
    exec ${swaylockRuntime}/bin/swaylock-runtime
  '';
in {
  home.packages = [pkgs.wlopm];

  services.swayidle = {
    enable = true;
    timeouts = [
      {
        timeout = 600; # 10 min: screen off, then lock behind it
        command = "${screenOffThenLock}/bin/idle-screen-off";
        resumeCommand = "${pkgs.wlopm}/bin/wlopm --on '*'";
      }
      {
        timeout = 1800; # 30 min: suspend, but only once idle-guard agrees
        command = "${sys-daemon}/bin/sys-daemon idle-guard";
        resumeCommand = "${pkgs.procps}/bin/pkill -f 'sys-daemon idle-guard'";
      }
    ];
  };
}
