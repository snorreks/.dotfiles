# nixos/config/home/waybar/settings.nix
{pkgs, ...}: {
  programs.waybar.settings.mainBar = {
    position = "bottom";
    layer = "top";
    height = 36;
    exclusive = true;
    passthrough = false;
    gtk-layer-shell = true;

    # ── Modular Group Layouts ──────────────────────────────────────────
    modules-left = [
      "custom/power"
      "group/window-info"
      "group/launcher-bar"
      "mpris"
    ];

    modules-center = [
      "group/center-clock"
    ];

    modules-right = [
      "group/sys-status"
      "group/hardware"
      "group/quick-controls"
    ];

    # ── Group Definitions ──────────────────────────────────────────────
    "group/window-info" = {
      orientation = "horizontal";
      modules = ["mango/workspaces" "mango/window"];
    };

    "group/launcher-bar" = {
      orientation = "horizontal";
      modules = ["custom/menu" "wlr/taskbar"];
    };

    "group/center-clock" = {
      orientation = "horizontal";
      modules = ["clock" "custom/tomato"];
    };

    "group/sys-status" = {
      orientation = "horizontal";
      modules = ["tray" "custom/vpn" "custom/dev-ports"];
    };

    "group/hardware" = {
      orientation = "horizontal";
      modules = ["network" "bluetooth" "pulseaudio"];
    };

    "group/quick-controls" = {
      orientation = "horizontal";
      modules = ["custom/light" "battery"];
    };

    # ── Left Modules ──────────────────────────────────────────────────
    "custom/power" = {
      format = "";
      tooltip = true;
      tooltip-format = "Power Menu";
      on-click = "wlogout";
    };

    "custom/menu" = {
      format = "󰍉";
      tooltip = true;
      tooltip-format = "󰍉 App Launcher | 󰆊 Wallpaper | 󰆓 Clipboard";
      on-click = "fuzzel-drun";
      on-click-middle = "fuzzel-clipboard";
      on-click-right = "wallpaper-picker";
    };

    "wlr/taskbar" = {
      format = "{icon}";
      icon-size = 18;
      spacing = 2;
      tooltip-format = "{title}";
      on-click = "activate";
      on-click-middle = "close";
      ignore-list = ["Alacritty"];
      app_ids-mapping = {
        firefoxdeveloperedition = "firefox-developer-edition";
      };
    };

    "mango/workspaces" = {
      format = "{icon}";
      hide-empty = true;
      on-click = "activate";
      on-click-right = "toggle";
      overview-label = "OVERVIEW";
      all-outputs = false;
    };

    "mango/window" = {
      format = "{}";
      icon-size = 20;
      max-length = 25;
    };

    # ── Center Modules ────────────────────────────────────────────────
    "clock" = {
      format = "󰥔 {:%I:%M %p}";
      tooltip-format = "<tt>{calendar}</tt>";
      calendar = {
        mode = "month";
        mode-mon-col = 3;
        on-scroll = 1;
        on-click-right = "mode";
        format = {
          months = "<span color='#89b4fa'><b>{}</b></span>";
          weekdays = "<span color='#f9e2af'><b>{}</b></span>";
          today = "<span color='#f38ba8'><b>{}</b></span>";
        };
      };
    };

    "custom/tomato" = {
      format = "{}";
      # Pomodoro state streamed from the daemon (watches tomato's time.log).
      exec = "sys-daemon waybar tomato";
      return-type = "json";
      restart-interval = 10;
      hide-empty-text = true;
      tooltip = true;
    };

    # ── Music (native MPRIS via D-Bus — no polling) ─────────────────────
    "mpris" = {
      format = "{player_icon} {artist} - {title}";
      format-paused = "{status_icon} <i>{artist} - {title}</i>";
      player-icons = {
        default = "▶";
        spotify = "";
      };
      status-icons = {
        paused = "⏸";
      };
      tooltip-format = "Album: {album}\nArtist: {artist}\nLength: {length}";
      max-length = 42;
      on-click = "playerctl play-pause";
      on-scroll-up = "playerctl next";
      on-scroll-down = "playerctl previous";
      # side wheel / horizontal scroll → skip tracks
      on-scroll-left = "playerctl previous";
      on-scroll-right = "playerctl next";
    };

    # ── Right Modules ─────────────────────────────────────────────────
    "tray" = {
      icon-size = 18;
      spacing = 6;
    };

    "custom/vpn" = {
      format = "{}";
      # Event-driven stream from the Rust daemon (systemd D-Bus subscription) —
      # no interval polling, no script spawns. Waybar reads each JSON line.
      exec = "sys-daemon waybar vpn";
      return-type = "json";
      restart-interval = 10;
      on-click = "toggle_vpn &"; # & so Waybar updates asynchronously
      on-click-right = "toggle_vpn --rotate &";
    };

    "custom/dev-ports" = {
      format = "{}";
      # Port state streamed from the daemon's /proc/net/tcp watcher. Shows a
      # dim 🔌 when the dashboard is stopped — click to toggle it on/off.
      exec = "sys-daemon waybar ports";
      return-type = "json";
      restart-interval = 10;
      tooltip = true;
      on-click = "toggle-dev-ports";
      on-click-middle = "xdg-open http://localhost:3333";
    };

    "network" = {
      format-wifi = "󰤨";
      format-ethernet = "󰈀";
      format-disconnected = "󰤭";
      tooltip-format = "Network: <b>{essid}</b>\nSignal: <b>{signaldBm}dBm ({signalStrength}%)</b>\nIP: <b>{ipaddr}</b>";
      tooltip-format-disconnected = "Disconnected";
      interval = 3;
    };

    "bluetooth" = {
      format = "";
      format-connected = " {device_battery_percentage}%";
      tooltip-format = "{controller_alias}\t{controller_address}\n\n{num_connections} connected";
      tooltip-format-connected = "{controller_alias}\t{controller_address}\n\n{num_connections} connected\n\n{device_enumerate}";
      tooltip-format-enumerate-connected = "{device_alias}\t{device_address}";
      tooltip-format-enumerate-connected-battery = "{device_alias}\t{device_address}\t({device_battery_percentage}%)";
      on-click = "${pkgs.lib.getExe pkgs.foot} --title=bluetuith-popup --window-size-chars=80x24 bluetuith";
    };

    "pulseaudio" = {
      format = "{icon} {volume}%";
      format-muted = "󰝟";
      format-icons = {
        headphone = "";
        hands-free = "";
        headset = "";
        phone = "";
        portable = "";
        car = "";
        default = ["󰕿" "󰖀" "󰕾"];
      };
      on-click = "pwvucontrol -t 3";
      on-click-middle = "wpctl set-mute @DEFAULT_SINK@ toggle";
      tooltip-format = "{icon} {desc} // {volume}%";
      # vertical wheel: ±1% · side wheel (horizontal): ±2%
      on-scroll-up = "wpctl set-volume @DEFAULT_SINK@ 1%+";
      on-scroll-down = "wpctl set-volume @DEFAULT_SINK@ 1%-";
      on-scroll-left = "wpctl set-volume @DEFAULT_SINK@ 2%+";
      on-scroll-right = "wpctl set-volume @DEFAULT_SINK@ 2%-";
    };

    "custom/light" = {
      format = "{}";
      # Brightness/eye-protection streamed from the daemon (sysfs + /proc reads).
      exec = "sys-daemon waybar light";
      return-type = "json";
      restart-interval = 10;
      smooth-scrolling-threshold = 6;
      on-scroll-up = "change_brightness up";
      on-scroll-down = "change_brightness down";
      on-click = "toggle_eye_protection";
      on-click-middle = "force_eye_protection";
    };

    "battery" = {
      format = "{icon} {capacity}%";
      format-charging = "󰂄 {capacity}%";
      format-plugged = "󰚥 {capacity}%";
      format-icons = ["󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹"];
      interval = 30;
    };
  };
}
