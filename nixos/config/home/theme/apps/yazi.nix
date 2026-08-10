# nixos/config/home/theme/apps/yazi.nix
#
# yazi theme.toml — TUI file manager.
{lib}: {
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
    progress_label = { fg = "#${c.base00}", bg = "#${c.base0D}" }
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
      { mime = "image/*", fg = "#${c.base0E}" },
      { mime = "video/*", fg = "#${c.base0E}" },
      { mime = "audio/*", fg = "#${c.base0E}" },
      { mime = "text/*", fg = "#${c.base0B}" },
      { is = "dir", fg = "#${c.base0D}" },
      { is = "symlink", fg = "#${c.base0C}" },
      { is = "exec", fg = "#${c.base0A}" },
    ]
  '';
}
