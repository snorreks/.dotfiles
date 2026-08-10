# nixos/config/home/theme/apps/swaylock.nix
#
# swaylock settings (colors + behavior) — rendered to a runtime config.
{lib}: {
  mkSwaylockSettings = {
    c,
    font,
  }: {
    # ── Behavior & Daemon ───────────────────────────────────────────────
    daemonize = true;
    ignore-empty-password = true;
    show-failed-attempts = true;

    # ── Visual Effects (Frosted Glass Aesthetic) ───────────────────────
    screenshots = true;
    effect-blur = "20x3"; # Deep Gaussian blur
    effect-vignette = "0.4:0.6"; # Subtle dark border gradient
    fade-in = 0.2;

    # ── Clock & Date Styling ─────────────────────────────────────────────
    clock = true;
    timestr = "%H:%M";
    datestr = "%A, %B %d";
    font = font;
    font-size = 24;

    # ── Indicator Geometry & Behavior ──────────────────────────────────
    indicator = true;
    indicator-radius = 110;
    indicator-thickness = 8;
    indicator-idle-visible = false; # Ring pops up only when typing

    # ── Palette Integration (RRGGBB / RRGGBBAA) ─────────────────────────
    # Text Colors
    text-color = "${c.base05}";
    text-clear-color = "${c.base05}";
    text-caps-lock-color = "${c.base0A}";
    text-ver-color = "${c.base0A}";
    text-wrong-color = "${c.base08}";

    # Idle / Neutral Ring & Translucent Center
    ring-color = "${c.base0D}AA"; # Accent (70% opacity)
    inside-color = "${c.base00}B3"; # Dark Base (70% opacity)
    line-color = "00000000"; # Hide border line
    separator-color = "00000000";

    # Keypress & Backspace Visual Highlights
    key-hl-color = "${c.base0B}"; # Green flash on keypress
    bs-hl-color = "${c.base08}"; # Red flash on backspace

    # Verifying Password State
    ring-ver-color = "${c.base0A}"; # Yellow/Peach ring
    inside-ver-color = "${c.base01}B3";

    # Wrong Password / Error State
    ring-wrong-color = "${c.base08}"; # Red error ring
    inside-wrong-color = "${c.base08}33"; # Soft red glow inside

    # Clear & Caps Lock Warning States
    ring-clear-color = "${c.base0C}"; # Cyan ring
    inside-clear-color = "${c.base00}B3";
    ring-caps-lock-color = "${c.base09}"; # Orange caps lock warning
    inside-caps-lock-color = "${c.base00}B3";
  };
}
