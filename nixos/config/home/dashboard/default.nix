# nixos/config/home/dashboard/default.nix
#
# Quickshell shell: the merged dashboard (Home / System / Notifications) plus
# the notification daemon itself. This replaced swaync — see qml/Notifs.qml for
# why the merge forces it (both bind org.freedesktop.Notifications, so the
# panel that shows the notification list has to be the process that owns it).
#
# Always running as a systemd user service: it must be, now that it is the
# notification daemon, and the IPC toggle needs something to talk to —
# `qs -c dashboard ipc call dash toggle`, bound to SUPER+D in mango.nix. The
# drawer window starts unmapped and costs essentially nothing while closed;
# QSG_RENDER_LOOP=basic avoids spinning up a render thread for windows that are
# invisible most of the time.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  dashboard-launch = pkgs.writeShellScriptBin "dashboard-launch" ''
    export QSG_RENDER_LOOP=basic

    # qml/Notifs.qml writes the waybar pill's JSON here; FileView will not
    # create the directory itself, and waybar reads the file once at startup.
    mkdir -p "$HOME/.cache/dashboard"

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
  # libnotify (notify-send) does not come from the notification daemon on any
  # provider — several scripts (toggle_vpn.sh etc.) call it directly and used
  # to depend on swaync.nix pulling it in.
  home.packages = [pkgs.quickshell dashboard-launch pkgs.libnotify];

  # Whole directory, not a single file: Quickshell auto-registers every .qml
  # beside shell.qml, including `pragma Singleton` files, by filename.
  xdg.configFile."quickshell/dashboard".source = ./qml;

  systemd.user.services.quickshell-dashboard = {
    Unit = {
      Description = "Quickshell dashboard + notification daemon (SUPER+D)";
      After = ["graphical-session-pre.target"];
      # waybar's custom/notification module reads ~/.cache/dashboard/notify.json
      # once at startup, so this has to have written it first.
      Before = ["waybar.service"];
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
