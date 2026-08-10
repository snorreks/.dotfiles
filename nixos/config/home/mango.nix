# nixos/config/home/mango.nix
{
  pkgs,
  lib,
  opts,
  config,
  ...
}: let
  _ = lib.getExe;
  c = config.lib.stylix.colors;
  theme = import ./theme/lib.nix {inherit lib;};
in {
  wayland.windowManager.mango = {
    enable = true;

    systemd = {
      enable = true;
      variables = ["--all"];
    };

    # ── Autostart ─────────────────────────────────────────────────────────
    autostart_sh = ''
      # 0. Sync Wayland environment with D-Bus/Systemd (CRITICAL for XDG Portals)
      dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE
      systemctl --user restart xdg-desktop-portal &

      # 1. Background Daemons (Notifications & Wallpapers)
      # wall-change restores the saved default wallpaper (see wall-change.sh)
      wall-change &

      # 3. Declarative Silent Apps
      ${_ pkgs.thunderbird} &
      ${_ pkgs.solaar} --window=hide &
    '';

    # ── Settings ──────────────────────────────────────────────────────────
    # Colors are NOT here — they live in `extraConfig` below (single source:
    # theme/lib.nix `mkMangoColors`), so the dynamic theme renderer can swap
    # them at runtime via ~/.cache/theme/mango-colors.conf + mmsg reload.
    settings = {
      # ── Window Appearance & Geometry ───────────────────────────────
      border_radius = 8;
      borderpx = 1; # Slightly thicker border for accent pop
      no_border_when_single = 1;

      # ── Window Gaps (Padding Around Windows) ─────────────────────────
      # Inner Gaps (spacing between adjacent tiled windows)
      gappih = 2; # Horizontal inner gap
      gappiv = 2; # Vertical inner gap

      # Outer Gaps (spacing between windows and screen edges/Waybar)
      gappoh = 4; # Horizontal outer gap
      gappov = 4; # Vertical outer gap

      # Smart Gaps: Automatically removes gaps when only 1 window is visible
      smartgaps = 1;

      # Try syncobj_enable=1 in your mango settings block as a separate experiment from the gamescope fixes above — mango's own docs note it fixes flicker/hangs in some Electron/game surfaces, though it's occasionally the opposite problem on other GPUs, so test it both ways:
      syncobj_enable = 1;

      # Opacity & Eye-Candy
      focused_opacity = 0.98;
      unfocused_opacity = 0.92;

      # ── Animations ────────────────────────────────────────────────────
      animations = 1;
      animation_type_open = "zoom";
      layer_animations = 0; # Keep disabled for performance

      blur = 1;
      blur_layer = 0;
      blur_optimized = 1; # Cache wallpaper blur background
      blur_params_radius = 3; # Low kernel size = fast execution
      blur_params_num_passes = 1; # 1 pass cuts GPU load by ~60% vs 3 passes
      shadows = 0; # Keep off for smooth high-Hz rendering

      # ── Keyboard & Input ──────────────────────────────────────────────
      xkb_rules_layout = "us,no";
      numlockon = 1;

      # Mouse & Focus
      sloppyfocus = 1;
      focus_on_activate = 1;
      drag_tile_to_tile = 1; # 0 make file drag-and-drop lag less across windows

      # Mouse Profile (Flat)
      mouse_natural_scrolling = 0;
      mouse_accel_profile = 1;
      mouse_accel_speed = 1.0;

      # Trackpad Profile
      disable_while_typing = 1;
      tap_to_click = 1;
      trackpad_natural_scrolling = 1;
      trackpad_accel_profile = 1;
      trackpad_accel_speed = 1.0;

      # ── Layout Settings ───────────────────────────────────────────────
      circle_layout = "tile,vertical_tile";
      new_is_master = 1;
      default_mfact = 0.55;

      # ── Monitor Rules ─────────────────────────────────────────────────
      # Per-host rules from opts.monitorrule (default: laptop-only; see
      # hosts/legion/options.nix for the 3-monitor desktop setup).
      # rr:0 = normal (0°), rr:1 = 90° rotation (portrait)
      monitorrule = opts.monitorrule;

      # ── Tag Layout Rules ──────────────────────────────────────────────
      tagrule = [
        "id:1,monitor_name:HDMI-A-1,layout_name:tile"
        "id:2,monitor_name:eDP-1,layout_name:tile"
        "id:3,monitor_name:DP-1,layout_name:tile"
        "id:4,layout_name:tile"
        "id:5,layout_name:tile"
        "id:6,layout_name:tile"
        "id:7,layout_name:tile"
        "id:8,layout_name:tile"
        "id:9,layout_name:tile"
      ];

      # ── Window Rules ──────────────────────────────────────────────────
      windowrule = [
        # Floating Rules
        "appid:pwvucontrol,isfloating:1,width:700,height:450"
        "appid:SoundWireServer,isfloating:1,tags:5,isopensilent:1"
        "title:^float_${opts.defaultTerminal}$,isfloating:1,width:950,height:600"
        # PiP: open silently (auto-PiP on tab switch no longer steals focus),
        # still clickable/interactive and minimizable once focused
        "title:^Picture-in-Picture$,isfloating:1,isglobal:1,isnoborder:1,isopensilent:1,istagsilent:1"

        # Bluetooth TUI popup
        "title:^bluetuith-popup$,isfloating:1"

        # Game & Wine Helper Floating Matches
        "title:^.*[.][eE][xX][eE]$,isfloating:1"
        "appid:^regsvr32$,isfloating:1"
        "appid:transmission,isfloating:1"
        "appid:^\.sameboy-wrapped$,isfloating:1"
        "title:^Firefox — Sharing Indicator$,isfloating:1"
        "appid:file_progress,isfloating:1"
        "appid:confirm,isfloating:1"
        "appid:dialog,isfloating:1"
        "appid:download,isfloating:1"
        "appid:notification,isfloating:1"
        "appid:error,isfloating:1"
        "appid:confirmreset,isfloating:1"
        "title:^Open File$,isfloating:1"
        "title:^branchdialog$,isfloating:1"
        "title:^Confirm to replace files$,isfloating:1"
        "title:^File Operation Progress$,isfloating:1"

        # Steam Popups & Dialogs (Properties, Settings, Friends, etc.)
        "appid:steam,isglobal:1"
        "title:^Steam$,isglobal:1"
        "title:^.*[-—] Properties$,isfloating:1,isglobal:1"
        "title:^Steam - Settings$,isfloating:1,isglobal:1"
        "title:^Steam.*News$,isglobal:1"

        # Opacity Tweaks (Set focused & unfocused EQUAL for pcmanfm-qt to eliminate drag lag)
        "appid:^pcmanfm-qt$,focused_opacity:1.0,unfocused_opacity:1.0"
        "appid:^pcmanfm$,focused_opacity:1.0,unfocused_opacity:1.0"
        "appid:^${opts.defaultFileManager}$,focused_opacity:1.0,unfocused_opacity:1.0"
        "appid:zen,focused_opacity:0.95,unfocused_opacity:0.88"
        "appid:zed,focused_opacity:0.96,unfocused_opacity:0.92"

        # Media & Canvas Opacity Overrides (Always Solid)
        "title:^.*imv.*$,focused_opacity:1.0,unfocused_opacity:1.0"
        "title:^.*mpv.*$,focused_opacity:1.0,unfocused_opacity:1.0"
        "appid:aseprite,focused_opacity:1.0,unfocused_opacity:1.0"
        "appid:unity,focused_opacity:1.0,unfocused_opacity:1.0"

        # Declarative background / silent apps
        "appid:thunderbird,tags:9,isopensilent:1"
        "appid:discord,tags:4,isopensilent:1"
      ];

      # ── Keybindings ───────────────────────────────────────────────────
      bind = [
        # System & Window Controls
        "SUPER,r,reload_config"
        "SUPER,q,killclient"
        "SUPER+SHIFT,q,killclient, force"
        "SUPER,space,togglefloating"
        "ALT,backslash,togglefloating"
        "SUPER,Escape,spawn,swaylock-runtime"
        "SUPER+SHIFT,Escape,spawn,shutdown-script"
        "SUPER+SHIFT,Delete,spawn,kill-switch --light"
        "SUPER+CTRL+SHIFT,code:119,spawn,kill-switch --full"
        "SUPER+CTRL+ALT,code:119,spawn,kill-switch --reboot"
        "SUPER,k,spawn,toggle_keyboard"

        # Terminals & Launchers
        "CTRL+SHIFT,Delete,spawn,foot-clear-scrollback"
        "SUPER,Return,spawn,${opts.defaultTerminal}"
        "CTRL,Return,spawn_shell,FISH_NO_GREETING=1 ${opts.defaultTerminal} --title=float_${opts.defaultTerminal}"
        "SUPER+SHIFT,Return,spawn,${opts.defaultTerminal}-big"
        "SUPER,c,spawn_shell,wlrctl toplevel focus app_id:zed || ${opts.defaultEditor} &"
        "SUPER,x,spawn,${opts.defaultBrowser}"
        "SUPER,h,spawn,hs-skip"

        # Applications & Tools
        "SUPER,F1,spawn,show-keybinds"
        "SUPER,e,spawn,${opts.defaultFileManager}"
        "SUPER,y,spawn,${opts.defaultTerminal} yazi"
        "SUPER,m,spawn,spotify"
        "SUPER,a,spawn,fuzzel-drun"
        "SUPER,v,spawn,fuzzel-clipboard"
        "SUPER,w,spawn,wallpaper-picker"
        "SUPER+SHIFT,b,spawn,pkill -SIGUSR1 .waybar-wrapped"

        # Declarative App Launches
        "SUPER+SHIFT,d,spawn,discord"
        "SUPER,s,restore_minimized"
        "SUPER+SHIFT,s,minimized"
        "SUPER+SHIFT,F2,spawn,SoundWireServer"

        # Bluetooth Popup
        "SUPER,b,spawn,${opts.defaultTerminal} --title=bluetuith-popup --window-size-chars=80x24 bluetuith"

        # Fullscreen / Layout Toggles
        "SUPER,f,togglemaximizescreen"
        "SUPER+SHIFT,f,togglefullscreen"
        "ALT,f,togglefakefullscreen"
        "SUPER,n,exchange_stack_client,next"
        "SUPER,j,switch_layout"

        # Screen Share / Monitor Rotations
        "SUPER+SHIFT,r,spawn,wlr-randr --output DP-1 --transform normal"
        "SUPER+SHIFT+ALT,r,spawn,wlr-randr --output DP-1 --transform 90"

        # Screen Capture
        "SUPER,Print,spawn,screenshot-area"
        "SUPER+SHIFT,Print,spawn,screenshot-annotate"
        "NONE,Print,spawn,screenshot-clipboard"
        "CTRL,Print,spawn,screenshot-output"
        "SUPER+CTRL,Print,spawn,screenshot-freeze"
        "SUPER+ALT,Print,spawn,screenshot-gif-start"

        # Window Focus Navigation
        "ALT,Left,focusdir,left"
        "ALT,Right,focusdir,right"
        "ALT,Up,focusdir,up"
        "ALT,Down,focusdir,down"

        # Swap Windows
        "SUPER+SHIFT,Up,exchange_client,up"
        "SUPER+SHIFT,Down,exchange_client,down"
        "SUPER+SHIFT,Left,exchange_client,left"
        "SUPER+SHIFT,Right,exchange_client,right"

        # Move Window by Pixels (floating)
        "CTRL+SHIFT,Up,movewin,+0,-50"
        "CTRL+SHIFT,Down,movewin,+0,+50"
        "CTRL+SHIFT,Left,movewin,-50,+0"
        "CTRL+SHIFT,Right,movewin,+50,+0"

        # Resize Window
        "CTRL+ALT,Up,resizewin,+0,-50"
        "CTRL+ALT,Down,resizewin,+0,+50"
        "CTRL+ALT,Left,resizewin,-50,+0"
        "CTRL+ALT,Right,resizewin,+50,+0"

        # Tag Switching
        "SUPER,1,view,1,0"
        "SUPER,2,view,2,0"
        "SUPER,3,view,3,0"
        "SUPER,4,view,4,0"
        "SUPER,5,view,5,0"
        "SUPER,6,view,6,0"
        "SUPER,7,view,7,0"
        "SUPER,8,view,8,0"
        "SUPER,9,view,9,0"

        # Tag Navigation
        "SUPER,Left,viewtoleft,0"
        "SUPER,Right,viewtoright,0"

        # Monitor Navigation
        "SUPER+CTRL,Left,focusmon,left"
        "SUPER+CTRL,Right,focusmon,right"

        # Move Window to Adjacent Monitor
        "SUPER+ALT,Left,tagmon,left,1"
        "SUPER+ALT,Right,tagmon,right,1"

        # Move Window to Tag & Follow
        "SUPER+ALT,1,tag,1,0"
        "SUPER+ALT,2,tag,2,0"
        "SUPER+ALT,3,tag,3,0"
        "SUPER+ALT,4,tag,4,0"
        "SUPER+ALT,5,tag,5,0"
        "SUPER+ALT,6,tag,6,0"
        "SUPER+ALT,7,tag,7,0"
        "SUPER+ALT,8,tag,8,0"
        "SUPER+ALT,9,tag,9,0"

        # Move Window to Tag Silently
        "CTRL+SUPER,Left,tagtoleft,0"
        "CTRL+SUPER,Right,tagtoright,0"

        # Dropdown Scratchpad Terminal
        "ALT,z,toggle_named_scratchpad,${opts.defaultTerminal}-scratchpad,none,${opts.defaultTerminal} --app-id=${opts.defaultTerminal}-scratchpad"

        # Audio / Media Keys
        "NONE,XF86AudioRaiseVolume,spawn,wpctl set-volume @DEFAULT_SINK@ 2%+"
        "NONE,XF86AudioLowerVolume,spawn,wpctl set-volume @DEFAULT_SINK@ 2%-"
        "NONE,XF86AudioMute,spawn,wpctl set-mute @DEFAULT_SINK@ toggle"
        "SHIFT,XF86AudioMute,spawn,wpctl set-mute @DEFAULT_SOURCE@ toggle"
        "NONE,XF86AudioNext,spawn,playerctl next"
        "NONE,XF86AudioPrev,spawn,playerctl previous"
        "NONE,XF86AudioPlay,spawn,playerctl play-pause"

        # Hardware Brightness
        "NONE,XF86MonBrightnessUp,spawn,brightnessctl s +2%"
        "SHIFT,XF86MonBrightnessUp,spawn,brightnessctl s 100%"
        "NONE,XF86MonBrightnessDown,spawn,brightnessctl s 2%-"
        "SHIFT,XF86MonBrightnessDown,spawn,brightnessctl s 1%"
      ];

      # ── Mouse Bindings ────────────────────────────────────────────────
      mousebind = [
        "SUPER,btn_left,moveresize,curmove"
        "SUPER,btn_right,moveresize,curresize"
      ];

      # ── Axis Bindings ─────────────────────────────────────────────────
      axisbind = [
        "SUPER,UP,viewtoleft_have_client"
        "SUPER,DOWN,viewtoright_have_client"
        "SUPER+CTRL,UP,focusmon,left"
        "SUPER+CTRL,DOWN,focusmon,right"
        "ALT,UP,spawn,brightnessctl s +2%"
        "ALT,DOWN,spawn,brightnessctl s 2%-"
      ];
    };

    # Static WM colors (tokyo-night) — appended after settings. The dynamic
    # renderer strips and re-appends this block from ~/.cache/theme/mango-colors.conf.
    extraConfig = theme.renderMangoColors (theme.mkMangoColors c);
  };
}
