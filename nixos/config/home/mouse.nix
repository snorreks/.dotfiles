# nixos/config/home/mouse.nix
#
# Solaar tray applet — battery indicator only.
#
# Device settings (DPI, smart-shift, ...) are NOT applied here: they live in
# config/system/mouse.nix and are pushed by the `mouse-apply` system unit on
# boot / hotplug / resume. Nothing about the mouse depends on this applet
# running, which is the whole point — it used to be the only thing applying
# settings, and it was launched from mango's autostart with a bare `&`, so a
# race or a crash meant sensitivity silently stayed wrong.
{
  pkgs,
  lib,
  opts,
  ...
}:
lib.mkIf (opts.mouse.enable && opts.mouse.tray) {
  systemd.user.services.solaar = {
    Unit = {
      Description = "Solaar tray applet (Logitech battery indicator)";
      # Ordering only — deliberately NOT Requires=tray.target: waybar hosts the
      # tray via the StatusNotifier D-Bus name and never activates tray.target,
      # so requiring it would keep this unit from ever starting.
      After = ["graphical-session.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${lib.getExe pkgs.solaar} --window=hide";
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
