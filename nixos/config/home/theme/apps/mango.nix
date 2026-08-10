# nixos/config/home/theme/apps/mango.nix
#
# mango WM colors — the only consumer that cannot point elsewhere (mango
# reads a fixed path with no include), so these lines are swapped in/out
# of ~/.config/mango/config.conf at runtime.
{lib}: {
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
}
