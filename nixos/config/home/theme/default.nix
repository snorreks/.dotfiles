# nixos/config/home/theme/default.nix
#
# Theming entry point: stylix base (palette source, cursor, fonts — see
# ./stylix.nix) + the dynamic wallpaper theming layer below.
#
# Two worlds, one palette source (`./lib.nix`):
#   • Static (default): HM/stylix configs — tokyo-night, exactly today's look.
#   • Dynamic:          matugen extracts base16 colors from the wallpaper and
#                       renders the same configs via templates into
#                       ~/.cache/theme/ (always populated — static writer runs
#                       on every rebuild and whenever dynamic mode is off).
#
# Toggle: theme-toggle on|off (state in ~/.cache/theme/mode)
#   on  → render from wallpaper palette + swap mango colors
#   off → rewrite ~/.cache/theme with the static palette (HM configs stay
#         the fallback baseline everywhere else)
{
  pkgs,
  lib,
  config,
  inputs,
  opts,
  ...
}: let
  theme = import ./lib.nix {inherit lib;};

  font = config.stylix.fonts.monospace.name;
  cacheDir = "/home/${opts.username}/.cache/theme";
  templatesDir = "/home/${opts.username}/.config/matugen/templates";

  stylixColors = config.lib.stylix.colors;
  mp = theme.matugenPalette;

  # ── Static outputs (writeText derivations → copied to ~/.cache/theme) ──
  staticWaybarCss = pkgs.writeText "theme-waybar.css" (theme.mkWaybarCss stylixColors);
  staticDashboardJson = pkgs.writeText "theme-dashboard.json" (builtins.toJSON (theme.mkDashboardTheme stylixColors));
  staticFuzzelColors = pkgs.writeText "theme-fuzzel-colors.ini" (
    theme.renderFuzzelColors (theme.mkFuzzelColors stylixColors)
  );
  staticSwaylock = pkgs.writeText "theme-swaylock.conf" (
    theme.renderSwaylock (theme.mkSwaylockSettings {
      c = stylixColors;
      inherit font;
    })
  );
  tomlFormat = pkgs.formats.toml {};

  staticStarship = tomlFormat.generate "theme-starship.toml" (
    theme.mkStarshipSettings stylixColors.withHashtag
  );
  staticPcmanfmQss = pkgs.writeText "theme-pcmanfm.qss" (theme.mkPcmanfmQss stylixColors);
  staticMangoColors = pkgs.writeText "theme-mango-colors.conf" (
    theme.renderMangoColors (theme.mkMangoColors stylixColors)
  );
  staticYaziTheme = pkgs.writeText "theme-yazi.toml" (theme.mkYaziTheme stylixColors);
  staticZedTheme = pkgs.writeText "theme-zed.json" (
    builtins.toJSON (theme.mkZedTheme stylixColors)
  );
  staticVesktopCss = pkgs.writeText "theme-vesktop.css" (theme.mkVesktopCss stylixColors);
  staticFootColors = pkgs.writeText "theme-foot-colors.ini" (theme.mkFootColors stylixColors);
  staticFootOsc = pkgs.writeText "theme-foot-osc.txt" (theme.mkFootOsc stylixColors);
  staticPyroclearColors = pkgs.writeText "theme-pyroclear-colors.toml" (theme.mkPyroclearColors stylixColors);

  # ── Matugen template inputs (same mkXxx functions, matugen expressions) ──
  templateStarship = tomlFormat.generate "starship.toml" (
    theme.mkStarshipSettings mp.withHashtag
  );
  templateZed = pkgs.writeText "zed-theme.json" (
    builtins.toJSON (theme.mkZedTheme mp)
  );
  templateDashboard = pkgs.writeText "dashboard.json" (
    builtins.toJSON (theme.mkDashboardTheme mp)
  );

  matugen = inputs.matugen.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # mmsg — mango's IPC client (reload_config on the running compositor)
  mmsg = config.wayland.windowManager.mango.package;

  # ── Static writer: populates runtime theme files + config dirs
  #    (rebuild activation + toggle-off)
  theme-apply-static = pkgs.writeShellScriptBin "theme-apply-static" ''
    set -euo pipefail
    # writeShellScriptBin doesn't set PATH; HM activation runs with a minimal
    # environment — declare the tools this script needs explicitly.
    export PATH="${pkgs.coreutils}/bin:$PATH"

    mkdir -p ${cacheDir}/yazi "$HOME/.config/zed/themes" "$HOME/.config/vesktop/themes"
    # install -m 644: store files are read-only (444); matugen needs writable outputs
    install -m 644 ${staticWaybarCss} ${cacheDir}/waybar.css
    install -m 644 ${staticDashboardJson} ${cacheDir}/dashboard.json
    install -m 644 ${staticFuzzelColors} ${cacheDir}/fuzzel-colors.ini
    install -m 644 ${staticSwaylock} ${cacheDir}/swaylock.conf
    install -m 644 ${staticStarship} ${cacheDir}/starship.toml
    install -m 644 ${staticPcmanfmQss} ${cacheDir}/pcmanfm.qss
    install -m 644 ${staticMangoColors} ${cacheDir}/mango-colors.conf

    # yazi: runtime config dir mirrors HM-managed configs + generated theme
    ln -sfn "$HOME/.config/yazi/yazi.toml" ${cacheDir}/yazi/yazi.toml 2>/dev/null || true
    ln -sfn "$HOME/.config/yazi/keymap.toml" ${cacheDir}/yazi/keymap.toml 2>/dev/null || true
    install -m 644 ${staticYaziTheme} ${cacheDir}/yazi/theme.toml

    # zed + vesktop: written to their own (non-HM-managed) config dirs
    install -m 644 ${staticZedTheme} "$HOME/.config/zed/themes/dynamic.json"
    install -m 644 ${staticVesktopCss} "$HOME/.config/vesktop/themes/dynamic.theme.css"

    # foot: colors + OSC recolor payload (no terminal restart needed for OSC)
    install -m 644 ${staticFootColors} ${cacheDir}/foot-colors.ini
    install -m 644 ${staticFootOsc} ${cacheDir}/foot-osc.txt

    # pyroclear: [color] block merged into its config by theme-render
    install -m 644 ${staticPyroclearColors} ${cacheDir}/pyroclear-colors.toml
  '';

  # ── Runtime renderer: dynamic (matugen image) or static (theme-apply-static)
  theme-render = pkgs.writeShellScriptBin "theme-render" ''
    set -euo pipefail
    # writeShellScriptBin doesn't set PATH; HM activation runs with a minimal
    # environment — declare the tools this script needs explicitly (missing
    # awk previously caused exit 127 and failed the whole activation).
    export PATH="${pkgs.gawk}/bin:${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:$PATH"

    THEME_DIR="${cacheDir}"
    MODE_FILE="$THEME_DIR/mode"
    DEFAULT_FILE="$HOME/.dotfiles/wallpapers/.default"

    mode="$(cat "$MODE_FILE" 2>/dev/null || echo static)"
    wall="$(cat "$DEFAULT_FILE" 2>/dev/null || echo "")"

    mkdir -p "$THEME_DIR"

    # 1. Render palette + templates
    if [ "$mode" = "dynamic" ] && [ -n "$wall" ] && [ -f "$wall" ]; then
        # --source-color-index 0: pick the most dominant color non-interactively.
        # --contrast 0.5: matugen's MD3 roles are pinned to fixed HCT tones
        # (on_surface T90, accents T80 — see palette.nix), so contrast is
        # already guaranteed by construction; 0.5 pushes on_surface toward
        # white for extra crispness on arbitrary wallpapers.
        # NOTE: --lightness-dark is NOT used — it was inert for the base16
        # backend and is unnecessary for roles.
        # On any matugen failure, degrade to the static palette so a rebuild
        # (which runs this via the activation hook) never breaks.
        ${matugen}/bin/matugen image "$wall" -m dark --source-color-index 0 --contrast 0.5 \
            || {
                echo "theme-render: matugen failed, falling back to static palette" >&2
                ${theme-apply-static}/bin/theme-apply-static
            }

        # Contrast assertion: roles make the palette readable by construction
        # (see palette.nix), so this should never fire — but if matugen version
        # drift or a new wallpaper ever produces an unreadable palette, bail to
        # static instead of silently shipping invisible text.
        if [ -f "$THEME_DIR/foot-colors.ini" ]; then
            if ! awk '
                function lum(h,   i, c, v) {
                    v = 0
                    for (i = 1; i <= 3; i++) {
                        c = strtonum("0x" substr(h, 2*i-1, 2)) / 255
                        c = (c <= 0.03928) ? c/12.92 : ((c+0.055)/1.055)^2.4
                        v += (i==1 ? 0.2126 : i==2 ? 0.7152 : 0.0722) * c
                    }
                    return v
                }
                function cr(a, b,   r1, r2) {
                    r1 = (lum(a)+0.05) / (lum(b)+0.05)
                    r2 = (lum(b)+0.05) / (lum(a)+0.05)
                    return (r1 > r2) ? r1 : r2
                }
                /^foreground[ =]/ { fg = $NF }
                /^background[ =]/ { bg = $NF }
                /^regular[1-6][ =]/ { reg[n++] = $NF }
                END {
                    if (fg == "" || bg == "" || n < 6) exit 1
                    if (cr(fg, bg) < 4.5) exit 1
                    for (i = 0; i < n; i++) if (cr(reg[i], bg) < 3.5) exit 1
                    exit 0
                }
            ' "$THEME_DIR/foot-colors.ini"; then
                echo "theme-render: rendered palette fails contrast check, falling back to static" >&2
                ${theme-apply-static}/bin/theme-apply-static
            fi
        fi
    else
        ${theme-apply-static}/bin/theme-apply-static
    fi

    # 2. Apply — waybar needs nothing here: `reload_style_on_change: true`
    #    in the config makes waybar watch the css file (via inotify) and
    #    hot-swap the stylesheet with zero bar teardown. Sending SIGUSR2
    #    would do a full reset (surface rebuild) and SIGUSR1 would TOGGLE
    #    the bar's visibility — both wrong for a color-only change.

    # 2b. Apply — the quickshell dashboard needs no nudge at all: its palette
    #     lives in ${cacheDir}/dashboard.json and qml/Theme.qml holds a
    #     watched FileView over it, so the panel and its toasts re-color live.
    #     (swaync used to need an explicit `swaync-client -rs` here; it had no
    #     file watcher. It is gone — see dashboard/qml/Notifs.qml.)

    # 3. Apply — mango (fixed config path, no include: swap the color block)
    mango_config="$HOME/.config/mango/config.conf"
    if [ -f "$mango_config" ] && [ -f "$THEME_DIR/mango-colors.conf" ]; then
        need_reload=0
        color_keys='^(focuscolor|bordercolor|rootcolor|urgentcolor|scratchpadcolor|maximizescreencolor|globalcolor|overlaycolor) = '
        if [ -L "$mango_config" ]; then
            # HM-managed static symlink — only dynamic mode touches it
            if [ "$mode" = "dynamic" ]; then
                tmp="$(mktemp)"
                grep -vE "$color_keys" "$mango_config" > "$tmp" || true
                cat "$THEME_DIR/mango-colors.conf" >> "$tmp"
                rm -f "$mango_config"
                mv "$tmp" "$mango_config"
                need_reload=1
            fi
        else
            # Plain file (leftover from a previous dynamic run) — always regen
            tmp="$(mktemp)"
            grep -vE "$color_keys" "$mango_config" > "$tmp" || true
            cat "$THEME_DIR/mango-colors.conf" >> "$tmp"
            rm -f "$mango_config"
            mv "$tmp" "$mango_config"
            need_reload=1
        fi

        if [ "$need_reload" = "1" ]; then
            sock="$(ls /run/user/$(id -u)/mango-*.sock 2>/dev/null | head -n1 || true)"
            if [ -n "$sock" ]; then
                MANGO_INSTANCE_SIGNATURE="$sock" ${mmsg}/bin/mmsg "dispatch reload_config" >/dev/null 2>&1 || true
            fi
        fi
    fi

    # 4. Apply — pyroclear: merge the theme [color] block into its config.
    #    pyroclear reads config at startup (no live reload), so the next
    #    `pyroclear` run picks it up. Only the [color] section is replaced;
    #    [animation] settings from `pyroclear --settings` are preserved.
    pyroclear_config="$HOME/.config/pyroclear/config.toml"
    if [ -f "$THEME_DIR/pyroclear-colors.toml" ]; then
        mkdir -p "$(dirname "$pyroclear_config")"
        if [ -f "$pyroclear_config" ]; then
            tmp="$(mktemp)"
            # drop the existing [color] section (header + keys), keep the rest
            awk '/^\[color\]/ { skip = 1; next } /^\[/ { skip = 0 } !skip { print }' "$pyroclear_config" > "$tmp"
            cat "$THEME_DIR/pyroclear-colors.toml" >> "$tmp"
            mv "$tmp" "$pyroclear_config"
        else
            # first run: seed from theme colors + pyroclear's defaults
            cat "$THEME_DIR/pyroclear-colors.toml" > "$pyroclear_config"
            printf '\n[animation]\nfps       = 60\nwind      = 0\nheight    = 3\ndirection = false\n' >> "$pyroclear_config"
        fi
    fi
  '';
in {
  imports = [
    ./stylix.nix
  ];

  home.packages = [
    matugen
    theme-apply-static
    theme-render
  ];

  # ── Matugen config (templates → ~/.cache/theme; wallpaper handled by awww) ──
  xdg.configFile."matugen/config.toml".text = ''
    [config]
    version_check = false
    caching = true

    [config.wallpaper]
    # Wallpaper is applied by wall-change.sh (awww) — matugen only renders.
    set = false
    command = "awww img {{ image }}"

    [templates.waybar]
    input_path = "${templatesDir}/waybar.css"
    output_path = "${cacheDir}/waybar.css"

    [templates.dashboard]
    input_path = "${templatesDir}/dashboard.json"
    output_path = "${cacheDir}/dashboard.json"

    [templates.fuzzel_colors]
    input_path = "${templatesDir}/fuzzel-colors.ini"
    output_path = "${cacheDir}/fuzzel-colors.ini"

    [templates.swaylock]
    input_path = "${templatesDir}/swaylock.conf"
    output_path = "${cacheDir}/swaylock.conf"

    [templates.starship]
    input_path = "${templatesDir}/starship.toml"
    output_path = "${cacheDir}/starship.toml"

    [templates.pcmanfm]
    input_path = "${templatesDir}/pcmanfm.qss"
    output_path = "${cacheDir}/pcmanfm.qss"

    [templates.mango_colors]
    input_path = "${templatesDir}/mango-colors.conf"
    output_path = "${cacheDir}/mango-colors.conf"

    [templates.yazi]
    input_path = "${templatesDir}/yazi-theme.toml"
    output_path = "${cacheDir}/yazi/theme.toml"

    [templates.zed]
    input_path = "${templatesDir}/zed-theme.json"
    output_path = "/home/${opts.username}/.config/zed/themes/dynamic.json"

    [templates.vesktop]
    input_path = "${templatesDir}/vesktop-theme.css"
    output_path = "/home/${opts.username}/.config/vesktop/themes/dynamic.theme.css"

    [templates.foot]
    input_path = "${templatesDir}/foot-colors.ini"
    output_path = "${cacheDir}/foot-colors.ini"

    [templates.foot_osc]
    input_path = "${templatesDir}/foot-osc.txt"
    output_path = "${cacheDir}/foot-osc.txt"

    [templates.pyroclear]
    input_path = "${templatesDir}/pyroclear-colors.toml"
    output_path = "${cacheDir}/pyroclear-colors.toml"
  '';

  # Scheme-check config for wallpaper-add (extract + cache, render nothing)
  xdg.configFile."matugen/check.toml".text = ''
    [config]
    version_check = false
    caching = true

    [config.wallpaper]
    set = false
    command = "awww img {{ image }}"

    # Scheme-check only: no templates are rendered here
    [templates]
  '';

  # ── Matugen template inputs (HM-managed, read-only — inputs, not outputs) ──
  xdg.configFile."matugen/templates/waybar.css".text = theme.mkWaybarCss mp;
  xdg.configFile."matugen/templates/dashboard.json".source = templateDashboard;
  xdg.configFile."matugen/templates/fuzzel-colors.ini".text =
    theme.renderFuzzelColors (theme.mkFuzzelColors mp);
  xdg.configFile."matugen/templates/swaylock.conf".text = theme.renderSwaylock (theme.mkSwaylockSettings {
    c = mp;
    inherit font;
  });
  xdg.configFile."matugen/templates/starship.toml".source = templateStarship;
  xdg.configFile."matugen/templates/pcmanfm.qss".text = theme.mkPcmanfmQss mp;
  xdg.configFile."matugen/templates/mango-colors.conf".text =
    theme.renderMangoColors (theme.mkMangoColors mp);
  xdg.configFile."matugen/templates/yazi-theme.toml".text = theme.mkYaziTheme mp;
  xdg.configFile."matugen/templates/zed-theme.json".source = templateZed;
  xdg.configFile."matugen/templates/vesktop-theme.css".text = theme.mkVesktopCss mp;
  xdg.configFile."matugen/templates/foot-colors.ini".text = theme.mkFootColors mp;
  xdg.configFile."matugen/templates/foot-osc.txt".text = theme.mkFootOsc mp;
  xdg.configFile."matugen/templates/pyroclear-colors.toml".text = theme.mkPyroclearColors mp;

  # ── Always-populate ~/.cache/theme on rebuild (kills the first-boot race:
  #    waybar starts via systemd before any wallpaper change). Runs the full
  #    renderer so a rebuild respects the current mode (dynamic → matugen,
  #    static → theme-apply-static) instead of always resetting to static.
  home.activation.themeRender = lib.hm.dag.entryAfter ["writeBoundary"] ''
    ${theme-render}/bin/theme-render
  '';

  # Dynamic mode replaces mango's HM symlink with a plain file (mango has no
  # include directive — the color block is swapped in/out of config.conf).
  # Rebuilds must clobber that plain file back to the static symlink, i.e.
  # "rebuild restores the static tokyo-night baseline".
  xdg.configFile."mango/config.conf".force = true;

  # ── Render at session start, ordered before waybar ──
  systemd.user.services.theme-render = {
    Unit = {
      Description = "Render dynamic theme from the active wallpaper";
      After = ["graphical-session-pre.target"];
      Before = ["waybar.service" "quickshell-dashboard.service"];
      PartOf = ["graphical-session.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${theme-render}/bin/theme-render";
    };
    Install = {
      WantedBy = ["graphical-session.target"];
    };
  };
}
