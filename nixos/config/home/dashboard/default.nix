# nixos/config/home/dashboard/default.nix
#
# Quickshell dashboard: a single toggleable panel (weather/calendar/agenda/
# mpris/stats/power-mode). See shell.qml's own header for the "why one
# PanelWindow, why no per-screen Variants" reasoning.
#
# Always running (systemd user service) so the IPC toggle has something to
# talk to — `qs -c dashboard ipc call dash toggle`, bound to SUPER+D in
# mango.nix. The window itself starts hidden and costs basically nothing
# while closed; QSG_RENDER_LOOP=basic avoids spinning up a render thread
# for a single window that's invisible most of the time.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  dashboard-launch = pkgs.writeShellScriptBin "dashboard-launch" ''
    export QSG_RENDER_LOOP=basic
    ${lib.optionalString (opts.hostname == "gs65") ''
      # gs65 is Optimus (Intel + NVIDIA): without this, EGL picks the
      # NVIDIA vendor lib and the dGPU never goes to sleep on battery for
      # what is, most of the time, an invisible 1x1 render loop. Pin to
      # Mesa (Intel) explicitly instead. legion is single-GPU — no-op there.
      export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
    ''}
    exec ${lib.getExe pkgs.quickshell} -c dashboard "$@"
  '';
in {
  home.packages = [pkgs.quickshell dashboard-launch];

  xdg.configFile."quickshell/dashboard/shell.qml".source = ./shell.qml;

  systemd.user.services.quickshell-dashboard = {
    Unit = {
      Description = "Quickshell dashboard (toggleable panel, SUPER+D)";
      After = ["graphical-session-pre.target"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      ExecStart = "${dashboard-launch}/bin/dashboard-launch";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = ["graphical-session.target"];
  };
}
