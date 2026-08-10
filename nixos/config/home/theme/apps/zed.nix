# nixos/config/home/theme/apps/zed.nix
#
# zed theme (zed v0.1.0 theme schema, dark) — base16 → zed style map.
{lib}: {
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
}
