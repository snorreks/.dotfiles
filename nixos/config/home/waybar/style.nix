# nixos/config/home/waybar/style.nix
{config, ...}: let
  c = config.lib.stylix.colors;
in {
  programs.waybar.style = ''
    * {
        border: none;
        border-radius: 0px;
        font-family: "JetBrainsMono Nerd Font", sans-serif;
        font-weight: bold;
        font-size: 11px;
        min-height: 0px;
    }

    window#waybar {
        background: transparent;
    }

    tooltip {
        background: #${c.base00};
        color: #${c.base05};
        border-radius: 8px;
        border: 1px solid rgba(255, 255, 255, 0.08);
        padding: 6px 10px;
    }

    /* ── Transparent Main Containers ──────────────────────────────────── */
    .modules-left,
    .modules-center,
    .modules-right,
    #window-info {
        background: transparent;
        margin: 0;
        padding: 0;
    }

    /* ── Sub-Pill Floating Cards ─────────────────────────────────────── */
    #custom-power,
    #launcher-bar,
    #center-clock,
    #sys-status,
    #hardware,
    #quick-controls,
    #workspaces {
        background: rgba(26, 27, 38, 0.85);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 10px;
        padding: 2px 8px;
        margin: 3px 4px;
    }

    /* ── Active Window Title Pill ─────────────────────────────────────── */
    #window {
        background: rgba(26, 27, 38, 0.85);
        border: 1px solid rgba(255, 255, 255, 0.08);
        color: #${c.base0D};
        padding: 2px 10px;
        margin: 3px 4px;
        border-radius: 10px;
        font-style: italic;
    }

    window#waybar.empty #window,
    #window.empty {
        background: transparent;
        border: none;
        margin: 0px;
        padding: 0px;
    }

    /* ── Power Button Pill ───────────────────────────────────────────── */
    #custom-power {
        font-size: 15px;
        color: #${c.base08};
        padding: 0 8px;
    }
    #custom-power:hover {
        color: #${c.base0D};
    }

    /* ── Menu ────────────────────────────────────────────────────────── */
    #custom-menu {
        font-size: 15px;
        color: #${c.base05};
        padding: 0 4px;
    }
    #custom-menu:hover {
        color: #${c.base0D};
    }

    /* ── Hardware Pill Spacing ───────────────────────────────────────── */
    #network {
        color: #${c.base05};
        font-size: 13px;
        padding: 0 4px;
        margin-right: 6px;
    }

    #bluetooth {
        color: #${c.base05};
        font-size: 12px;
        padding: 0 4px;
        margin-right: 6px;
    }

    #pulseaudio {
        color: #${c.base05};
        font-size: 12px;
        padding: 0 4px;
    }

    /* ── Quick Controls Pill ─────────────────────────────────────────── */
    #custom-light {
        color: #${c.base05};
        font-size: 12px;
        padding: 0 4px;
        margin-right: 6px;
    }

    #battery {
        color: #${c.base05};
        font-size: 12px;
        padding: 0 4px;
    }

    /* ── General Status Icons Vertical Alignment ──────────────────────── */
    #clock,
    #tray,
    #custom-vpn,
    #custom-tomato {
        color: #${c.base05};
        background: transparent;
        padding: 0 5px;
        font-size: 12px;
    }

    /* ── Keyframes for Pulsing Loading Animation ─────────────────────── */
    @keyframes vpn-pulse {
        0% {
            opacity: 0.2;
        }
        50% {
            opacity: 1.0;
        }
        100% {
            opacity: 0.2;
        }
    }

    /* ── VPN Status Colors & Animation ───────────────────────────────── */
    #custom-vpn {
      padding: 0 6px;
      margin: 0 2px;
      border-radius: 8px;
      transition: all 0.2s ease-in-out;
    }

    /* Connected -> Shield Check (Stylix Green) */
    #custom-vpn.vpn-on {
      color: #${c.base0B};
    }

    /* Loading -> Pulsing Icon (Stylix Yellow) */
    #custom-vpn.vpn-loading {
      color: #${c.base0A};
      animation-name: vpn-pulse;
      animation-duration: 1.2s;
      animation-timing-function: ease-in-out;
      animation-iteration-count: infinite;
    }

    /* Disconnected -> Shield Off (Stylix Gray) */
    #custom-vpn.vpn-off {
      color: #${c.base04};
    }

    /* Error -> Alert Icon (Stylix Red) */
    #custom-vpn.vpn-failed {
      color: #${c.base08};
    }

    /* ── Eye Protection State Colors ─────────────────────────────────── */
    #custom-light.eye-on {
        color: #${c.base0B};
    }
    #custom-light.eye-forced {
        color: #${c.base0A};
    }
    #custom-light.eye-off {
        color: #${c.base05};
    }

    /* ── Dev Ports Status (sys-daemon) ───────────────────────────────── */
    #custom-dev-ports {
        color: #${c.base04};
        padding: 0 6px;
        margin: 0 2px;
        border-radius: 8px;
        transition: all 0.2s ease-in-out;
    }
    #custom-dev-ports.dev-active {
        color: #${c.base0B};
    }
    #custom-dev-ports.dev-idle {
        color: #${c.base04};
    }
    /* Dashboard stopped — dimmed so it reads as "off", not broken */
    #custom-dev-ports.dev-off {
        color: #${c.base03};
        opacity: 0.6;
    }

    /* ── Tomato Timer (sys-daemon) ───────────────────────────────────── */
    #custom-tomato.tomato-active {
        color: #${c.base0A};
    }
    #custom-tomato.tomato-idle {
        color: #${c.base04};
    }

    /* ── MPRIS Music ─────────────────────────────────────────────────── */
    #mpris {
        color: #${c.base05};
        background: transparent;
        padding: 0 6px;
        margin: 0 2px;
        border-radius: 8px;
        font-size: 12px;
    }
    #mpris.playing {
        color: #${c.base0B};
    }
    #mpris.paused {
        color: #${c.base04};
    }
  '';
}
