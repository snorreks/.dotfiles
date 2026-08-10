# nixos/config/home/theme/apps/vesktop.nix
#
# vesktop/Vencord theme css — discord CSS variables from the palette.
# Using Discord's own variables keeps it robust against class renames.
{lib}: {
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
      --background-modifier-accent: #${c.base02};
      --background-message-hover: #${c.base02}40;
      --background-nested-floating: #${c.base01};
      --channeltextarea-background: #${c.base02};

      --deprecated-card-bg: #${c.base02};
      --deprecated-card-editable-bg: #${c.base02};
      --activity-card-background: #${c.base02};

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
}
