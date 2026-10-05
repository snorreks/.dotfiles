# nixos/config/home/theme/apps/mango.nix
#
# mango WM colors — the only consumer that cannot point elsewhere (mango
# reads a fixed path with no include), so these lines are swapped in/out
# of ~/.config/mango/config.conf at runtime.
{lib}: {
  mkMangoColors = c: {
    focus_color = "0x${c.base0D}FF"; # Primary Accent
    border_color = "0x${c.base02}FF"; # Dark Border / Surface
    root_color = "0x${c.base00}FF"; # Wallpaper Background
    urgent_color = "0x${c.base08}FF"; # Urgent / Error (Red)
    scratchpad_color = "0x${c.base0C}FF"; # Scratchpad (Cyan)
    maximized_screen_color = "0x${c.base0B}FF"; # Maximized (Green)
    global_color = "0x${c.base0E}FF"; # Global Windows (Purple/Mauve)
    overlay_color = "0x${c.base0A}FF"; # Overlay (Yellow)
  };
}
