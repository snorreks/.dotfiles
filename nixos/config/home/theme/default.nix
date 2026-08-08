# nixos/config/home/theme/default.nix
#
# Dynamic wallpaper theming layer.
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
  staticFuzzelColors = pkgs.writeText "theme-fuzzel-colors.ini" (
    theme.renderFuzzelColors (theme.mkFuzzelColors stylixColors)
  );
  staticSwaylock = pkgs.writeText "theme-swaylock.conf" (
    theme.renderSwaylock (theme.mkSwaylockSettings {c = stylixColors; inherit font;})
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

  # ── Matugen template inputs (same mkXxx functions, matugen expressions) ──
  templateStarship = tomlFormat.generate "starship.toml" (
    theme.mkStarshipSettings mp.withHashtag
  );
  templateZed = pkgs.writeText "zed-theme.json" (
    builtins.toJSON (theme.mkZedTheme mp)
  );

  matugen = inputs.matugen.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # mmsg — mango's IPC client (reload_config on the running compositor)
  mmsg = config.wayland.windowManager.mango.package;

  # ── Static writer: populates runtime theme files + config dirs
  #    (rebuild activation + toggle-off)
  theme-apply-static = pkgs.writeShellScriptBin "theme-apply-static" ''
    set -euo pipefail
    mkdir -p ${cacheDir}/yazi "$HOME/.config/zed/themes" "$HOME/.config/vesktop/themes"
    # install -m 644: store files are read-only (444); matugen needs writable outputs
    install -m 644 ${staticWaybarCss} ${cacheDir}/waybar.css
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
  '';

  # ── Runtime renderer: dynamic (matugen image) or static (theme-apply-static)
  theme-render = pkgs.writeShellScriptBin "theme-render" ''
    set -euo pipefail

    THEME_DIR="${cacheDir}"
    MODE_FILE="$THEME_DIR/mode"
    DEFAULT_FILE="$HOME/.dotfiles/wallpapers/.default"

    mode="$(cat "$MODE_FILE" 2>/dev/null || echo static)"
    wall="$(cat "$DEFAULT_FILE" 2>/dev/null || echo "")"

    mkdir -p "$THEME_DIR"

    # 1. Render palette + templates
    if [ "$mode" = "dynamic" ] && [ -n "$wall" ] && [ -f "$wall" ]; then
        # --source-color-index 0: pick the most dominant color non-interactively.
        # On any matugen failure, degrade to the static palette so a rebuild
        # (which runs this via the activation hook) never breaks.
        ${matugen}/bin/matugen image "$wall" -m dark --source-color-index 0 \
            || {
                echo "theme-render: matugen failed, falling back to static palette" >&2
                ${theme-apply-static}/bin/theme-apply-static
            }
    else
        ${theme-apply-static}/bin/theme-apply-static
    fi

    # 2. Apply — waybar needs nothing here: `reload_style_on_change: true`
    #    in the config makes waybar watch the css file (via inotify) and
    #    hot-swap the stylesheet with zero bar teardown. Sending SIGUSR2
    #    would do a full reset (surface rebuild) and SIGUSR1 would TOGGLE
    #    the bar's visibility — both wrong for a color-only change.

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
  '';
in {
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
  xdg.configFile."matugen/templates/fuzzel-colors.ini".text =
    theme.renderFuzzelColors (theme.mkFuzzelColors mp);
  xdg.configFile."matugen/templates/swaylock.conf".text =
    theme.renderSwaylock (theme.mkSwaylockSettings {c = mp; inherit font;});
  xdg.configFile."matugen/templates/starship.toml".source = templateStarship;
  xdg.configFile."matugen/templates/pcmanfm.qss".text = theme.mkPcmanfmQss mp;
  xdg.configFile."matugen/templates/mango-colors.conf".text =
    theme.renderMangoColors (theme.mkMangoColors mp);
  xdg.configFile."matugen/templates/yazi-theme.toml".text = theme.mkYaziTheme mp;
  xdg.configFile."matugen/templates/zed-theme.json".source = templateZed;
  xdg.configFile."matugen/templates/vesktop-theme.css".text = theme.mkVesktopCss mp;

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
      Before = ["waybar.service"];
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
