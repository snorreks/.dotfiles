# nixos/config/home/theme/lib.nix
#
# Single source of truth for every color-bearing config.
#
# Every `mkXxx` below is a pure function of a palette attrset with the same
# shape as `config.lib.stylix.colors`:
#
#   { base00 = "1a1b26"; ...; base0F = "f7768e";
#     withHashtag = { base00 = "#1a1b26"; ... } }
#
# Each function is instantiated TWICE — once per consumer:
#
#   1. `config.lib.stylix.colors`        → static HM config (tokyo-night,
#                                          the fallback baseline, unchanged)
#   2. `matugenPalette` (template exprs) → matugen template file rendered at
#                                          runtime from the wallpaper's colors
#
# Because both instantiations are literally the same Nix expression, drift
# between the static and dynamic themes is structurally impossible.
{
  lib,
}: let
  # matugen base16 template expressions (lowercase names — official matugen
  # keyword form: `{{ base16.base0d.dark.hex_stripped }}`).
  mkExpr = fmt: n: "{{ base16.${lib.toLower n}.dark.${fmt} }}";

  # Palettes ---------------------------------------------------------------
  base16Names = [
    "base00"
    "base01"
    "base02"
    "base03"
    "base04"
    "base05"
    "base06"
    "base07"
    "base08"
    "base09"
    "base0A"
    "base0B"
    "base0C"
    "base0D"
    "base0E"
    "base0F"
  ];

  # Palette whose values are matugen template expressions. Feed this to the
  # mkXxx functions to get a template file (still valid text, with {{…}}
  # placeholders embedded).
  matugenPalette =
    (lib.genAttrs base16Names (mkExpr "hex_stripped"))
    // {
      withHashtag = lib.genAttrs base16Names (mkExpr "hex");
    };

  # Config renderers (target formats) ---------------------------------------
  # swaylock: `key=value`, booleans as bare keys, false omitted
  renderSwaylock = settings:
    lib.concatStringsSep "\n" (
      lib.filter (s: s != null) (
        lib.mapAttrsToList (k: v:
          if v == true
          then k
          else if v == false
          then null
          else "${k}=${toString v}")
        settings
      )
    );

  # fuzzel: ini `key=value` inside a [colors] section
  renderFuzzelColors = colors:
    "[colors]\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${v}") colors
    );

  # mango: `key = value` lines (mango's own format, spaces around =)
  renderMangoColors = colors:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k} = ${v}") colors
    );

  # ── App configs ─────────────────────────────────────────────────────────

  # waybar CSS (static rules + palette). The hardcoded tokyo-night pill
  # background rgba(26,27,38,0.85) becomes the palette base00 at 0.85 alpha
  # (GTK CSS alpha() — 8-digit hex is not supported by waybar's GTK parser).
  mkWaybarCss = c: ''
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
        background: alpha(#${c.base00}, 0.85);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 10px;
        padding: 2px 8px;
        margin: 3px 4px;
    }

    /* ── Active Window Title Pill ─────────────────────────────────────── */
    #window {
        background: alpha(#${c.base00}, 0.85);
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

    /* Connected -> Shield Check (Palette Green) */
    #custom-vpn.vpn-on {
      color: #${c.base0B};
    }

    /* Loading -> Pulsing Icon (Palette Yellow) */
    #custom-vpn.vpn-loading {
      color: #${c.base0A};
      animation-name: vpn-pulse;
      animation-duration: 1.2s;
      animation-timing-function: ease-in-out;
      animation-iteration-count: infinite;
    }

    /* Disconnected -> Shield Off (Palette Gray) */
    #custom-vpn.vpn-off {
      color: #${c.base04};
    }

    /* Error -> Alert Icon (Palette Red) */
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

  # fuzzel colors — rendered into a tiny include file that overrides the
  # static fuzzel.ini (fuzzel supports `include=` with its own section scope).
  mkFuzzelColors = c: {
    background = "${c.base00}dd"; # 87% opacity for MangoWM blur
    text = "${c.base05}ff";
    prompt = "${c.base07}ff";
    placeholder = "${c.base04}ff";
    input = "${c.base05}ff";
    match = "${c.base0D}ff"; # Highlighted search matches
    selection = "${c.base02}ff"; # Selected pill background
    selection-text = "${c.base05}ff";
    selection-match = "${c.base0D}ff";
    counter = "${c.base04}ff"; # Match stats text color
    border = "${c.base0D}ff"; # Accent border
  };

  # swaylock settings (colors + behavior) — rendered to a runtime config.
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

  # mango WM colors — the only consumer that cannot point elsewhere (mango
  # reads a fixed path with no include), so these lines are swapped in/out
  # of ~/.config/mango/config.conf at runtime.
  mkMangoColors = c: {
    focuscolor = "0x${c.base0D}FF"; # Primary Accent
    bordercolor = "0x${c.base02}FF"; # Dark Border / Surface
    rootcolor = "0x${c.base00}FF"; # Wallpaper Background
    urgentcolor = "0x${c.base08}FF"; # Urgent / Error (Red)
    scratchpadcolor = "0x${c.base0C}FF"; # Scratchpad (Cyan)
    maximizescreencolor = "0x${c.base0B}FF"; # Maximized (Green)
    globalcolor = "0x${c.base0E}FF"; # Global Windows (Purple/Mauve)
    overlaycolor = "0x${c.base0A}FF"; # Overlay (Yellow)
  };

  # starship prompt — takes the withHashtag palette (starship styles use
  # `#rrggbb`).
  mkStarshipSettings = wh: {
    # ── Prompt Layout ───────────────────────────────────────────────────
    format = lib.concatStrings [
      "$os"
      "$directory"
      "$git_branch"
      "$git_status"
      "$nix_shell"
      "$rust"
      "$golang"
      "$nodejs"
      "$bun"
      "$python"
      "$c"
      "$package"
      "$status"
      "$line_break"
      "$character"
    ];

    right_format = "$cmd_duration $time";

    # ── OS Symbol ───────────────────────────────────────────────────────
    os = {
      disabled = false;
      symbols.NixOS = " ";
      style = "bold ${wh.base0D}"; # Blue
      format = "[$symbol]($style)";
    };

    # ── Directory Segment (Pill style) ──────────────────────────────────
    directory = {
      style = "bg:${wh.base01} fg:${wh.base0E} bold"; # Base background + Purple text
      format = " [](${wh.base01})[$path]($style)[$read_only]($read_only_style)[](${wh.base01}) ";
      truncation_length = 3;
      truncation_symbol = "…/";
      read_only = " 󰌾";
      read_only_style = "bg:${wh.base01} fg:${wh.base08} bold";
      substitutions = {
        "Documents" = "󰈙 ";
        "Downloads" = " ";
        "Music" = " ";
        "Pictures" = " ";
        "Development" = "󰲋 ";
        "Projects" = "󰲋 ";
        "~" = "󰋜 ";
      };
    };

    # ── Git Branch & Status ─────────────────────────────────────────────
    git_branch = {
      symbol = " ";
      style = "bold ${wh.base0C}"; # Cyan
      format = "on [$symbol$branch]($style) ";
    };

    git_status = {
      style = "bold ${wh.base08}"; # Red
      format = "([$all_status$ahead_behind]($style) )";
      conflicted = "󰞇 ";
      ahead = "⇡\${count}";
      behind = "⇣\${count}";
      diverged = "⇕⇡\${ahead_count}⇣\${behind_count}";
      untracked = "󰞋 ";
      stashed = "📦 ";
      modified = "📝 ";
      staged = "[+\${count}](bold ${wh.base0B}) "; # Green
      renamed = "󰁕 ";
      deleted = "🗑 ";
    };

    # ── Nix Shell Status Badge ──────────────────────────────────────────
    nix_shell = {
      symbol = " ";
      style = "bold ${wh.base0D}"; # Blue
      format = "via [](${wh.base02})[$symbol$state(\\($name\\))](${wh.base0D} bg:${wh.base02} bold)[](${wh.base02}) ";
      impure_msg = "[impure](bold ${wh.base0A} bg:${wh.base02})";
      pure_msg = "[pure](bold ${wh.base0B} bg:${wh.base02})";
      unknown_msg = "";
    };

    # ── Exit Status Module ──────────────────────────────────────────────
    status = {
      disabled = false;
      symbol = "✘ ";
      style = "bold ${wh.base08}";
      format = "[$symbol$status]($style) ";
    };

    # ── Language Runtimes ───────────────────────────────────────────────
    rust = {
      symbol = " ";
      style = "bold ${wh.base09}"; # Orange
      format = "[$symbol($version)]($style) ";
    };

    nodejs = {
      symbol = "󰎙 ";
      style = "bold ${wh.base0B}"; # Green
      format = "[$symbol($version)]($style) ";
    };

    bun = {
      symbol = "🧅 ";
      style = "bold ${wh.base0F}"; # Peach / Accent
      format = "[$symbol($version)]($style) ";
    };

    python = {
      symbol = " ";
      style = "bold ${wh.base0A}"; # Yellow
      format = "[$symbol$pyenv_prefix($version)(\\($virtualenv\\))]($style) ";
    };

    golang = {
      symbol = " ";
      style = "bold ${wh.base0C}"; # Cyan
      format = "[$symbol($version)]($style) ";
    };

    c = {
      symbol = " ";
      style = "bold ${wh.base0D}"; # Blue
      format = "[$symbol($version)]($style) ";
    };

    package = {
      symbol = "󰏗 ";
      style = "dimmed ${wh.base05}";
      format = "is [$symbol$version]($style) ";
    };

    # ── Right Side: Duration & Time Capsules ────────────────────────────
    cmd_duration = {
      min_time = 2000;
      format = "[](${wh.base02})[󰔚 $duration](bg:${wh.base02} fg:${wh.base0A} bold)[](${wh.base02}) ";
    };

    time = {
      disabled = false;
      time_format = "%R";
      format = "[](${wh.base02})[󰥔 $time](bg:${wh.base02} fg:${wh.base05})[](${wh.base02})";
    };

    # ── Prompt Character / Cursor ───────────────────────────────────────
    character = {
      success_symbol = "[❯](bold ${wh.base0D})";
      error_symbol = "[❯](bold ${wh.base08})";
      vimcmd_symbol = "[❮](bold ${wh.base0B})";
    };

    # ── Disable Unused Modules ──────────────────────────────────────────
    aws.disabled = true;
    gcloud.disabled = true;
    openstack.disabled = true;
    azure.disabled = true;
  };

  # pcmanfm-qt QSS stylesheet — full Fusion styling from the palette.
  mkPcmanfmQss = c: ''    /* Global Base Styling for all Qt Widgets */
    QWidget {
      background-color: #${c.base00};
      color: #${c.base05};
    }

    /* Main Window & View Background */
    QMainWindow, QDialog, Fm--MainView, Fm--FolderView {
      background-color: #${c.base00};
      color: #${c.base05};
    }

    /* Menu Bar at the very top */
    QMenuBar {
      background-color: #${c.base00};
      color: #${c.base05};
      border-bottom: 1px solid #${c.base01};
    }

    QMenuBar::item {
      background-color: transparent;
      color: #${c.base05};
      padding: 4px 8px;
      border-radius: 4px;
    }

    QMenuBar::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Toolbars & Path / Breadcrumbs */
    QToolBar {
      background-color: #${c.base01};
      border-bottom: 1px solid #${c.base02};
      spacing: 4px;
      padding: 2px;
    }

    QToolButton {
      background-color: transparent;
      color: #${c.base05};
      border: 1px solid transparent;
      border-radius: 4px;
      padding: 3px 6px;
    }

    QToolButton:hover {
      background-color: #${c.base02};
      border: 1px solid #${c.base02};
    }

    QToolButton:checked, QToolButton:pressed {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Dropdowns / ComboBoxes (e.g., View Mode Selector) */
    QComboBox {
      background-color: #${c.base00};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 4px;
      padding: 3px 8px;
    }

    QComboBox:hover {
      border: 1px solid #${c.base0D};
    }

    QComboBox::drop-down {
      border: none;
    }

    QComboBox QAbstractItemView {
      background-color: #${c.base01};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      selection-background-color: #${c.base02};
      selection-color: #${c.base0D};
    }

    /* Tab Bar */
    QTabBar {
      background-color: #${c.base01};
    }

    QTabBar::tab {
      background-color: #${c.base01};
      color: #${c.base04};
      padding: 6px 12px;
      border-top-left-radius: 4px;
      border-top-right-radius: 4px;
      margin-right: 2px;
    }

    QTabBar::tab:selected {
      background-color: #${c.base00};
      color: #${c.base05};
      border-bottom: 2px solid #${c.base0D};
    }

    QTabBar::tab:hover:!selected {
      background-color: #${c.base02};
    }

    /* Location Bar Input */
    QLineEdit {
      background-color: #${c.base00};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 6px;
      padding: 4px 8px;
      selection-background-color: #${c.base0D};
    }

    QLineEdit:focus {
      border: 1px solid #${c.base0D};
    }

    /* Side Pane (Places / Bookmarks / Devices) */
    Fm--SidePane, QDockWidget {
      background-color: #${c.base01};
      color: #${c.base05};
      border-right: 1px solid #${c.base02};
    }

    /* File List & Icon Grid View */
    QTreeView, QListView, QColumnView {
      background-color: #${c.base00};
      color: #${c.base05};
      border: none;
    }

    QTreeView::item:selected, QListView::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
      border-radius: 4px;
    }

    QHeaderView::section {
      background-color: #${c.base01};
      color: #${c.base05};
      padding: 4px;
      border: none;
      border-right: 1px solid #${c.base02};
      border-bottom: 1px solid #${c.base02};
    }

    /* Right-Click Context Menus */
    QMenu {
      background-color: #${c.base01};
      color: #${c.base05};
      border: 1px solid #${c.base02};
      border-radius: 8px;
      padding: 4px;
    }

    QMenu::item {
      padding: 6px 20px 6px 10px;
      border-radius: 4px;
    }

    QMenu::item:selected {
      background-color: #${c.base02};
      color: #${c.base0D};
    }

    /* Scrollbars */
    QScrollBar:vertical, QScrollBar:horizontal {
      background: #${c.base00};
      width: 8px;
      height: 8px;
      border: none;
    }

    QScrollBar::handle:vertical, QScrollBar::handle:horizontal {
      background: #${c.base02};
      border-radius: 4px;
      min-height: 20px;
    }

    /* Status Bar at Bottom */
    QStatusBar {
      background-color: #${c.base01};
      color: #${c.base05};
      border-top: 1px solid #${c.base02};
    }
  '';

  # ── yazi theme.toml — TUI file manager ───────────────────────────────────
  mkYaziTheme = c: ''
    [manager]
    cwd = { fg = "#${c.base0D}" }
    hovered = { reversed = true }
    preview_hovered = { underline = true }
    find_keyword = { fg = "#${c.base0A}", italic = true }
    find_position = { fg = "#${c.base0E}" }
    marker_copied = { fg = "#${c.base0B}" }
    marker_cut = { fg = "#${c.base08}" }
    marker_selected = { fg = "#${c.base0D}" }
    marker_marked = { fg = "#${c.base0C}" }
    tab_active = { fg = "#${c.base08}" }
    tab_inactive = { fg = "#${c.base0D}" }
    count_copied = { fg = "#${c.base00}", bg = "#${c.base0B}" }
    count_cut = { fg = "#${c.base00}", bg = "#${c.base08}" }
    count_selected = { fg = "#${c.base00}", bg = "#${c.base0D}" }
    count_marked = { fg = "#${c.base00}", bg = "#${c.base0C}" }
    border_symbol = "│"
    border_style = { fg = "#${c.base0D}" }

    [status]
    separator_open = ""
    separator_close = ""
    mode_normal = { fg = "#${c.base00}", bg = "#${c.base0D}" }
    mode_select = { fg = "#${c.base00}", bg = "#${c.base0C}" }
    mode_unset = { fg = "#${c.base00}", bg = "#${c.base0A}" }
    progress_label = { fg = "#${c.base05}", bg = "#${c.base0D}" }
    progress_normal = { fg = "#${c.base00}", bg = "#${c.base0D}" }
    progress_error = { fg = "#${c.base00}", bg = "#${c.base08}" }
    permissions_t = { fg = "#${c.base05}" }
    permissions_r = { fg = "#${c.base0A}" }
    permissions_w = { fg = "#${c.base08}" }
    permissions_x = { fg = "#${c.base0D}" }

    [input]
    border = { fg = "#${c.base0D}" }
    title = {}
    value = {}

    [confirm]
    border = { fg = "#${c.base08}" }
    title = { fg = "#${c.base08}" }
    content = { fg = "#${c.base08}" }
    list = { fg = "#${c.base08}" }
    yes = { fg = "#${c.base0B}" }
    no = { fg = "#${c.base08}" }

    [completion]
    border = { fg = "#${c.base0D}" }
    active = { fg = "#${c.base00}", bg = "#${c.base0D}" }
    inactive = {}

    [tasks]
    border = { fg = "#${c.base0D}" }
    title = { fg = "#${c.base0D}" }
    hovered = { underline = true }

    [which]
    cols = 4
    mask = { bg = "#${c.base00}" }
    cand = { fg = "#${c.base0D}" }
    rest = { fg = "#${c.base05}" }
    separator = "→"
    separator_style = { fg = "#${c.base05}" }

    [filetype]
    rules = [
      { mime = "image/*", fg = "#${c.base0E}" }
      { mime = "video/*", fg = "#${c.base0E}" }
      { mime = "audio/*", fg = "#${c.base0E}" }
      { mime = "text/*", fg = "#${c.base0B}" }
      { is = "dir", fg = "#${c.base0D}" }
      { is = "symlink", fg = "#${c.base0C}" }
      { is = "exec", fg = "#${c.base0A}" }
    ]
  '';

  # ── zed theme (zed v0.1.0 theme schema, dark) — base16 → zed style map ──
  mkZedTheme = c: {
    "$schema" = "https://zed.dev/schema/themes/v0.1.0.json";
    name = "Dynamic";
    appearance = "dark";
    style = {
      background = "#${c.base00}";
      foreground = "#${c.base05}";
      border = "#${c.base02}";
      accent = "#${c.base0D}";
      selection = "#${c.base02}";

      "editor.background" = "#${c.base00}";
      "editor.foreground" = "#${c.base05}";
      "editor.active_line.background" = "#${c.base01}80";
      "editor.gutter.background" = "#${c.base00}";
      "editor.gutter.active_line_number" = "#${c.base0D}";
      "editor.gutter.line_number" = "#${c.base03}";

      "panel.background" = "#${c.base01}";
      "panel.border" = "#${c.base02}";
      "status_bar.background" = "#${c.base01}";
      "title_bar.background" = "#${c.base01}";
      "tab_bar.background" = "#${c.base01}";
      "tab.active_background" = "#${c.base00}";
      "tab.inactive_background" = "#${c.base01}";

      "syntax" = {
        keyword = "#${c.base0E}";
        string = "#${c.base0B}";
        comment = "#${c.base03}";
        function = "#${c.base0D}";
        number = "#${c.base09}";
        type = "#${c.base0A}";
        variable = "#${c.base05}";
        constant = "#${c.base08}";
        operator = "#${c.base0C}";
        tag = "#${c.base08}";
        punctuation = "#${c.base05}";
        label = "#${c.base0C}";
        link = "#${c.base0C}";
        embedded = "#${c.base07}";
        error = "#${c.base08}";
        warning = "#${c.base0A}";
        info = "#${c.base0D}";
        hint = "#${c.base03}";
      };
    };
  };

  # ── vesktop/Vencord theme css — discord CSS variables from the palette.
  #    Using Discord's own variables keeps it robust against class renames.
  mkVesktopCss = c: ''
    /**
     * @name Dynamic
     * @description Palette-generated Discord theme (wallpaper-aware)
     */
    .theme-dark {
      --background-primary: #${c.base00};
      --background-secondary: #${c.base01};
      --background-secondary-alt: #${c.base02};
      --background-tertiary: #${c.base01};
      --background-floating: #${c.base01};
      --background-modifier-hover: #${c.base02}80;
      --background-modifier-active: #${c.base02};
      --background-modifier-selected: #${c.base02};
      --channeltextarea-background: #${c.base02};

      --brand-experiment: #${c.base0D};
      --brand-experiment-600: #${c.base0D};
      --brand-experiment-560: #${c.base0D};
      --brand-experiment-500: #${c.base0D};
      --brand-experiment-430: #${c.base0D};
      --brand-experiment-400: #${c.base0D};
      --brand-experiment-360: #${c.base0D};
      --brand-experiment-300: #${c.base0D};
      --brand-experiment-200: #${c.base0D};
      --brand-experiment-100: #${c.base0D};

      --text-normal: #${c.base05};
      --text-muted: #${c.base04};
      --text-link: #${c.base0D};
      --text-positive: #${c.base0B};
      --text-danger: #${c.base08};
      --header-primary: #${c.base05};
      --header-secondary: #${c.base04};

      --interactive-normal: #${c.base05};
      --interactive-hover: #${c.base07};
      --interactive-active: #${c.base07};
      --interactive-muted: #${c.base04};

      --scrollbar-thin-thumb: #${c.base02};
      --scrollbar-auto-thumb: #${c.base02};
      --scrollbar-auto-track: #${c.base01};
      --input-background: #${c.base02};
      --input-placeholder-text: #${c.base04};

      --modal-background: #${c.base01};
      --elevation-low: 0 1px 0 #${c.base02};
      --elevation-high: 0 8px 16px #${c.base00};
    }
  '';

  # ── spicetify custom color scheme — build-time only (spicetify patches
  #    the store Spotify asar, so it can never be runtime-dynamic). Colors
  #    follow the static baseline palette; spicetify-nix generates color.ini.
  mkSpicetifyColorScheme = c: {
    text = c.base05;
    subtext = c.base04;
    main = c.base00;
    sidebar = c.base01;
    player = c.base01;
    card = c.base02;
    shadow = c.base00;
    "selected-row" = c.base02;
    button = c.base0D;
    "button-active" = c.base0D;
    "button-disabled" = c.base03;
    "tab-active" = c.base0D;
    notification = c.base01;
    "notification-error" = c.base08;
    misc = c.base00;
  };
in {
  inherit
    matugenPalette
    renderSwaylock
    renderFuzzelColors
    renderMangoColors
    mkWaybarCss
    mkFuzzelColors
    mkSwaylockSettings
    mkMangoColors
    mkStarshipSettings
    mkPcmanfmQss
    mkYaziTheme
    mkZedTheme
    mkVesktopCss
    mkSpicetifyColorScheme
    ;
}
