# nixos/config/home/waybar/settings.nix
#
# TWO bars, not one.
#
# Waybar creates one bar per output unless `output` says otherwise, and each
# bar instantiates its own copy of every module it lists. For native modules
# that is free. For `custom/*` modules with an `exec` it means one subprocess
# per bar per module — on a 2-monitor session this setup was running two
# `sys-daemon waybar power`, two `light`, two `vpn`, two `tomato`, and two
# Python interpreters each for weather and agenda.
#
# Only ONE of those was actually expensive: `sys-daemon waybar power` was
# independently spinning at ~40% of a core from a self-feeding D-Bus message
# loop (fixed in sys-daemon/src/power.rs — 0% at idle now, measured). power,
# light and vpn are all long-lived-but-idle streams (a handful of bytes on
# actual state changes), so duplicating THEM across bars costs ~nothing.
# Weather/agenda/tomato are Python interpreters — heavier at rest — and
# nothing on a second monitor needs its own copy of the weather.
#
# So: `common` holds every module definition and the full layout, and the two
# bars differ only in `output` and in which modules they lay out. The
# secondary bar gets everything except the Python-backed center-clock trio
# (custom/agenda, custom/weather, custom/tomato) and the single-instance
# status row (custom/notification + tray, which must not visually duplicate —
# two trays would show every SNI icon twice, and the bell's unread count is
# global, not per-screen). Power mode, brightness and VPN all stay.
#
# Group *ids* are reused rather than renamed so both bars share one
# stylesheet: `group/center-clock` simply has different members on each.
#
# ── Why `output` is a positive whitelist, never `["!name"]` ────────────────
# Tried negation first — `output = ["!eDP-1"]` on the secondary bar, meaning
# "every output except the primary". It silently never fires: confirmed live
# by toggling the laptop panel on and off while running `waybar -l debug`.
# With eDP-1 enabled, `output = ["eDP-1"]` gets "Bar configured" instantly,
# every time. With eDP-1 disabled, the negated bar sits forever after "Output
# detection done" for the remaining outputs — no bar, no error, on a totally
# clean environment. Whitelisting eDP-1 by name works; negating it does not.
# So the secondary bar whitelists every OTHER monitor by name instead, built
# from `opts.monitorrule` below — never negation.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  primary = opts.primaryMonitor;

  # Pull the monitor name out of each monitorrule string ("name:^eDP-1$,...")
  # — same format on every host (see options.nix / hosts/*/options.nix).
  monitorNames =
    map (
      rule: builtins.head (builtins.match "name:\\^([^$]+)\\$.*" rule)
    )
    opts.monitorrule;

  secondaryNames = builtins.filter (n: n != primary) monitorNames;

  common = {
    position = "bottom";
    layer = "top";
    # 38, not 36: below the 38px module minimum waybar forces a bar
    # reconfigure on startup. (That reconfigure was once blamed for the
    # duplicated exec modules — it was not the cause. The duplication was one
    # bar per output, which is what the two-bar split above actually fixes.)
    height = 38;
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
      modules = ["tray" "custom/notification"];
    };

    "group/hardware" = {
      orientation = "horizontal";
      modules = ["network" "custom/vpn" "bluetooth" "pulseaudio"];
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
      format = "{} {icon}";
      format-icons = {
        # `none` was an empty string, so a quiet bar showed no bell at all and
        # the pill silently vanished — there was nothing to click to open the
        # panel. Outline bell for quiet, filled for unread.
        notification = "󱅫";
        none = "󰂚";
        "dnd-notification" = "󰂛";
        "dnd-none" = "󰂛";
      };
      return-type = "json";
      # The quickshell dashboard is the notification daemon now (swaync is
      # gone — see dashboard/qml/Notifs.qml). It has no `-swb`-style stream to
      # inherit, so it writes this module's own JSON to a file and raises
      # SIGRTMIN+7; waybar re-runs the exec on that signal. Still fully
      # event-driven: `interval = "once"` means no polling between signals.
      #
      # RTMIN+7 because +8 (toggle_vpn.sh) and +9 (change_brightness.sh) are
      # already spoken for.
      exec = "cat $HOME/.cache/dashboard/notify.json 2>/dev/null";
      interval = "once";
      signal = 7;
      on-click = "qs -c dashboard ipc call dash open notifications";
      on-click-right = "qs -c dashboard ipc call dash dnd";
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
in {
  programs.waybar.settings =
    {
      # Full bar, primary output only. Everything with an `exec` lives here
      # and therefore exists exactly once, no matter how many monitors are
      # attached.
      mainBar =
        common
        // {
          output = [primary];
        };
    }
    # Laptop-only hosts (gs65's monitorrule has just eDP-1) have nothing left
    # to whitelist once primary is excluded — omit the bar entirely rather
    # than pass `output = []`, which waybar would likely read as "no
    # restriction" and duplicate every exec module right back onto eDP-1.
    // lib.optionalAttrs (secondaryNames != []) {
      # Every other output, named explicitly. Same styling, same layout
      # skeleton, native modules only — so attaching a third monitor adds
      # pixels, not processes.
      secondaryBar =
        common
        // {
          output = secondaryNames;

          # Drops custom/agenda, custom/weather and custom/tomato — the three
          # Python-interpreter modules. `group/quick-controls` is NOT
          # overridden here: it inherits `common`'s definition unchanged
          # (custom/powermode, custom/light, battery), so power mode and
          # brightness show on every screen, not just the primary one.
          "group/center-clock" = {
            orientation = "horizontal";
            modules = ["clock"];
          };

          # `group/quick-controls` is likewise NOT overridden — it inherits
          # `common` unchanged (custom/powermode, custom/light, battery).
          #
          # `group/sys-status` (notification bell + tray + VPN) is ALSO left
          # unoverridden, i.e. fully shared with the primary bar. Originally
          # dropped here on the theory that a second tray would duplicate
          # every SNI icon (Discord, qBittorrent, Steam, …) — true, but that
          # theory assumed the primary bar (eDP-1) is always up to show them
          # somewhere. On this machine eDP-1 is routinely OFF (docked/lid
          # closed), and the mainBar output filter means it renders nowhere
          # at all when eDP-1 is disabled — so dropping the tray from the
          # secondary bar made every background app's icon disappear
          # whenever the laptop panel was off, which is most of the time.
          # A tray icon shown on two screens at once is a redundant glance;
          # a tray icon shown on zero screens is a missing one — the second
          # is the actual bug.
          modules-right = [
            "group/sys-status"
            "group/hardware"
            "group/quick-controls"
          ];
        };
    };
}
