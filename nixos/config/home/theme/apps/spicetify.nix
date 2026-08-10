# nixos/config/home/theme/apps/spicetify.nix
#
# spicetify custom color scheme — build-time only (spicetify patches the
# store Spotify asar, so it can never be runtime-dynamic). Colors follow
# the static baseline palette; spicetify-nix generates color.ini.
{lib}: {
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
}
