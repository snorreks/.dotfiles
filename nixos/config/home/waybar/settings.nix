# nixos/config/home/waybar/settings.nix
{pkgs, ...}: {
  programs.waybar.settings.mainBar = {
    position = "bottom";
    layer = "top";
    height = 38; # was 36 — below the 38px module minimum, forcing a bar reconfigure that leaked a duplicate generation of every custom exec module
    exclusive = true;
    passthrough = false;
    gtk-layer-shell = true;

    # Hot-swap the stylesheet on file change (file watcher, no bar teardown).
    # Lets wallpaper re-themes apply without SIGUSR2/SIGUSR1.
    reload_style_on_change = true;

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
      modules = ["ext/workspaces"];
    };

    "group/launcher-bar" = {
      orientation = "horizontal";
      modules = ["custom/menu" "wlr/taskbar"];
    };

    "group/center-clock" = {
      orientation = "horizontal";
      modules = ["custom/agenda" "clock" "custom/weather" "custom/tomato"];
    };

    "group/sys-status" = {
      orientation = "horizontal";
      modules = ["custom/notification" "tray" "custom/vpn"];
    };

    "group/hardware" = {
      orientation = "horizontal";
      modules = ["network" "bluetooth" "pulseaudio"];
    };

    "group/quick-controls" = {
      orientation = "horizontal";
      modules = ["custom/powermode" "custom/light" "battery"];
    };

    # ── Left Modules ──────────────────────────────────────────────────
    "custom/power" = {
      # 󰐥 = nf-md-power. The old glyph (nf-fa-power_off) is patched into Nerd Fonts
      # with a different vertical origin than the Material Design block that every other
      # icon in this bar uses, so it rendered high in the line box while its neighbours
      # sat centered — that is the "not centered" bug.
      format = "󰐥";
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

    # Mango is dwl-derived: workspaces come over the generic ext-workspace-v1
    # protocol. There is no "mango/workspaces" waybar module — that name was a
    # leftover guess that waybar silently no-op'd (logged as "Unknown module").
    #
    # waybar's "dwl/window" module (for the active window title) was tried
    # here too, but its constructor calls into a dwl-ipc-unstable-v1 global
    # mango doesn't advertise — waybar dereferences the null proxy and
    # SIGSEGVs on startup. Left out until either waybar or mango closes that
    # gap; window title just isn't shown right now.
    "ext/workspaces" = {
      format = "{name}";
      ignore-hidden = true;
      all-outputs = false;
      sort-by-id = true;
      on-click = "activate";
    };

    "dwl/window" = {
      format = "{title}";
      max-length = 25;
    };

    # ── Center Modules ────────────────────────────────────────────────
    # The center pill reads left→right as "what's next / what time / what's it
    # like outside": agenda, clock, weather, pomodoro. The agenda and weather
    # halves are streaming JSON modules (waybar/modules.nix), so nothing here
    # polls on a timer.

    "custom/agenda" = {
      format = "{}";
      # Google Calendar (secret iCal URL from sops) → next event.
      # Hidden entirely when nothing is coming up, so the pill stays quiet.
      exec = "waybar-agenda";
      return-type = "json";
      restart-interval = 30;
      hide-empty-text = true;
      tooltip = true;
      max-length = 44;
      on-click = "calendar-open";
      on-click-right = "waybar-agenda --refresh";
    };

    "clock" = {
      format = "󰥔 {:%H:%M}";
      # Line 1 spells the date out (the grid alone makes you count columns),
      # line 2 is the calendar in a monospace face so the columns line up.
      tooltip-format = "<big>{:%A %d %B %Y}</big>\n<tt>{calendar}</tt>";
      calendar = {
        mode = "month";
        mode-mon-col = 3;
        # ISO 8601: Monday-first weeks and real week numbers — the way dates
        # are written here, and what "uke 34" in a Norwegian calendar means.
        iso8601 = true;
        weeks-pos = "left";
        on-scroll = 1;
        format = {
          months = "<span color='#89b4fa'><b>{}</b></span>";
          weekdays = "<span color='#f9e2af'><b>{}</b></span>";
          weeks = "<span color='#94e2d5'><i>{}</i></span>";
          today = "<span color='#f38ba8'><b><u>{}</u></b></span>";
        };
      };
      # Left click opens Thunderbird's calendar tab; the calendar's own
      # navigation lives on the other buttons (right click toggles the
      # month/year grid, scroll walks months).
      on-click = "calendar-open";
      actions = {
        on-click-right = "mode";
        on-scroll-up = "shift_up";
        on-scroll-down = "shift_down";
      };
    };

    "custom/weather" = {
      format = "{}";
      # OpenWeatherMap (coordinates from nixos/options.nix, key from sops).
      # Tooltip carries the 3-hourly window and the next few days.
      exec = "waybar-weather";
      return-type = "json";
      restart-interval = 30;
      tooltip = true;
      on-click = "waybar-weather --open";
      on-click-right = "waybar-weather --refresh";
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
      # Pango markup: artist stays full-weight (short, scannable), title is
      # deliberately dimmed. Previously the entire 42-char string competed
      # for attention at 1.12:1 contrast.
      format = "{player_icon} {artist}  <span alpha='62%'>{title}</span>";
      format-paused = "{status_icon} <span alpha='70%'>{artist}  {title}</span>";
      format-stopped = "";
      player-icons = {
        default = "󰐐";
        spotify = "󰓇";
        firefox = "󰈹";
        mpv = "󰐐";
      };
      status-icons = {
        paused = "󰏤";
        playing = "󰐐";
        stopped = "󰓛";
      };
      tooltip-format = "Album: {album}\nArtist: {artist}\nLength: {length}";
      # The old ▶ / ⏸ are Unicode geometric/misc-technical characters, not
      # Nerd Font glyphs — they fell back to a different face at a different weight
      # and size, the same class of problem as the old power button.
      max-length = 46;
      ellipsize = "end";
      on-click = "playerctl play-pause";
      on-scroll-up = "playerctl next";
      on-scroll-down = "playerctl previous";
      # side wheel / horizontal scroll → skip tracks
      on-scroll-left = "playerctl previous";
      on-scroll-right = "playerctl next";
    };

    # ── Right Modules ─────────────────────────────────────────────────

    "custom/powermode" = {
      format = "{}";
      # Event-driven stream from the Rust daemon (PPD D-Bus subscription) —
      # no interval polling, no script spawns. Waybar reads each JSON line.
      exec = "sys-daemon waybar power";
      return-type = "json";
      restart-interval = 10;
      on-click = "sys-daemon power cycle";
      on-click-right = "sys-daemon power set performance";
      on-scroll-up = "sys-daemon power set performance";
      on-scroll-down = "sys-daemon power set power-saver";
    };

    "custom/notification" = {
      # swaync's own event stream — not sys-daemon, it already pushes JSON
      # on every add/close with no polling of its own.
      format = "{} {icon}";
      format-icons = {
        notification = "󱅫";
        none = "";
        dnd-notification = "";
        dnd-none = "󰂛";
        inhibited-notification = "";
        inhibited-none = "";
        dnd-inhibited-notification = "";
        dnd-inhibited-none = "";
      };
      # No exec-if guard: swaync.nix unconditionally installs swaync-client
      # on this machine, unlike the portable dotfiles this module config
      # pattern is usually copied from.
      return-type = "json";
      exec = "swaync-client -swb";
      # sleep first: clicking waybar while the panel is opening/closing races
      # swaync's own animation and can otherwise re-toggle mid-transition.
      on-click = "sleep 0.1 && swaync-client -t -sw";
      on-click-right = "sleep 0.1 && swaync-client -d -sw";
      escape = true;
    };

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
      # tooltip was previously unset → waybar defaulted to showing the raw
      # text; make it explicit so the pill can stay terse.
      tooltip = true;
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
