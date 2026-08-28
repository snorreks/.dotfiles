# nixos/config/home/swaync.nix
#
# Notification daemon + control center. Replaces mako.nix — mako only ever
# did toast popups, and this setup wants a control-center panel (quick
# toggles, mpris, volume, backlight) behind it, which mako doesn't have.
# Both bind org.freedesktop.Notifications, so they cannot run together —
# mako.nix is deleted in the same change that adds this file.
#
# Styling follows the exact same two-instantiation pattern as waybar (see
# waybar/default.nix's header): `style` below is the static tokyo-night
# baseline (also the launcher's fallback); the matugen-rendered dynamic
# stylesheet lands in ~/.cache/theme/swaync.css and swaync-launch picks it
# up at startup via `-s`. Unlike waybar, swaync has no file-watcher for its
# CSS, so theme-render (theme/default.nix) also calls `swaync-client -rs`
# after every re-render to hot-reload the running daemon.
{
  pkgs,
  lib,
  config,
  ...
}: let
  theme = import ./theme/lib.nix {inherit lib;};

  swaync-launch = pkgs.writeShellScriptBin "swaync-launch" ''
    css="$HOME/.cache/theme/swaync.css"
    [ -f "$css" ] || css="$HOME/.config/swaync/style.css"
    exec ${lib.getExe pkgs.swaynotificationcenter} -s "$css" "$@"
  '';

  powerMode = profile: {
    label =
      {
        performance = "󰓅";
        balanced = "󰌪";
        power-saver = "󰾆";
      }
      .${profile};
    type = "toggle";
    command = "sys-daemon power set ${profile}";
    update-command = "sh -c '[ \"$(powerprofilesctl get 2>/dev/null)\" = ${profile} ] && echo true || echo false'";
  };
in {
  services.swaync = {
    enable = true;
    package = pkgs.swaynotificationcenter;

    settings = {
      positionX = "right";
      positionY = "top";
      layer = "overlay";
      control-center-layer = "top";
      layer-shell = true;
      layer-shell-cover-screen = false;
      cssPriority = "user";
      control-center-margin-top = 6;
      control-center-margin-right = 6;
      control-center-width = 380;
      control-center-height = 640;
      notification-window-width = 380;
      timeout = 6;
      timeout-low = 3;
      timeout-critical = 0;
      fit-to-screen = true;
      relative-timestamps = true;
      hide-on-clear = false;
      hide-on-action = true;
      notification-2fa-action = true;
      notification-grouping = true;
      script-fail-notify = true;

      widgets = ["title" "dnd" "buttons-grid" "mpris" "volume" "backlight" "notifications"];

      widget-config = {
        title = {
          text = "Notifications";
          clear-all-button = true;
          button-text = "Clear All";
        };
        dnd = {
          text = "Do Not Disturb";
        };
        mpris = {
          show-album-art = "when-available";
          blacklist = [];
        };
        volume = {
          label = "󰕾";
        };
        backlight = {
          label = "󰃟";
          # default device is "intel_backlight" — matches this hardware.
        };
        buttons-grid = {
          buttons-per-row = 4;
          actions = [
            {
              label = "󰖩";
              type = "toggle";
              command = "wifi_toggle";
              update-command = "sh -c '[ \"$(nmcli radio wifi)\" = enabled ] && echo true || echo false'";
            }
            {
              label = "󰂯";
              type = "toggle";
              command = "bluetooth_toggle";
              update-command = "sh -c 'rfkill list bluetooth | grep -qi \"soft blocked: yes\" && echo false || echo true'";
            }
            {
              label = "󰀝";
              type = "toggle";
              command = "airplane_mode_toggle";
              update-command = "sh -c '[ -e \"$HOME/.cache/airplane_backup\" ] && echo true || echo false'";
            }
            {
              label = "󰌾";
              type = "toggle";
              # No shell here (swaync spawns argv directly, not via `sh -c`
              # like waybar's on-click) — GLib's async spawn already doesn't
              # block the UI, so no trailing `&` needed either.
              command = "toggle_vpn";
              update-command = "sh -c 'systemctl is-active --quiet wg-quick-wg0.service && echo true || echo false'";
            }
            {
              label = "󰈉";
              type = "toggle";
              command = "toggle_eye_protection";
              update-command = "sh -c 'pgrep -x wlsunset >/dev/null && echo true || echo false'";
            }
            (powerMode "performance")
            (powerMode "balanced")
            (powerMode "power-saver")
          ];
        };
      };
    };

    style = theme.mkSwayncCss config.lib.stylix.colors;
  };

  # Point the systemd unit at the launcher (resolves runtime css at start),
  # same override waybar/default.nix does to its own service.
  systemd.user.services.swaync.Service.ExecStart = lib.mkForce ["${swaync-launch}/bin/swaync-launch"];

  # libnotify (notify-send) doesn't come from the notification daemon
  # itself on any provider — several scripts (toggle_vpn.sh etc.) call it
  # directly and previously depended on mako.nix pulling it in.
  home.packages = [swaync-launch pkgs.libnotify];
}
