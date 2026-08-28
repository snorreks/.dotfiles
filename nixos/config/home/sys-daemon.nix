# nixos/config/home/sys-daemon.nix
#
# sys-daemon — one small async Rust binary that replaces every polling loop
# in this setup:
#
#   OLD                                    NEW
#   ────────────────────────────────────── ─────────────────────────────────
#   bun local-port-checker (23 TCP/5s)     sys-daemon serve (event-driven)
#   waybar custom/vpn (interval=2)         sys-daemon waybar vpn  (zbus)
#   waybar custom/light (interval=2)       sys-daemon waybar light (sysfs)
#   waybar custom/tomato (interval=1)      sys-daemon waybar tomato (inotify)
#
# Modes:
#   sys-daemon serve               → systemd user service; dashboard on :3333
#   sys-daemon waybar <module>     → waybar exec stream; JSON only on change
#   sys-daemon idle-check          → run by swayidle's idle-dim; see idle.nix
#   sys-daemon idle-guard          → auto-suspend loop, currently unused; see idle.nix
{pkgs, ...}: let
  sys-daemon = pkgs.callPackage ./sys-daemon/package.nix {};
in {
  home.packages = [sys-daemon];

  # Ports config — edit this file to add projects/ports (restart the service).
  xdg.configFile."sys-daemon/ports.json".source = ./sys-daemon/ports.json;

  # The dashboard server is intentionally NOT auto-started: it only runs while
  # you're developing. Toggle it with `toggle-dev-ports` (aliased to `portcheck`);
  # systemd still manages its lifecycle once started. The waybar custom/dev-ports
  # pill that used to toggle it is gone — the center of the bar is calendar and
  # weather now — so `sys-daemon waybar ports` is kept but unused by the bar.
  systemd.user.services.sys-daemon = {
    Unit = {
      Description = "sys-daemon — dev-ports dashboard server (toggle while developing)";
    };
    Service = {
      ExecStart = "${sys-daemon}/bin/sys-daemon serve";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
