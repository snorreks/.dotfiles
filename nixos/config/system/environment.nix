# nixos/config/system/environment.nix
#
# This file sets system-wide environment variables for all users and sessions.
# It's used to configure hardware acceleration, Wayland integration, and other
# core system behaviors.
{pkgs, ...}: {
  environment = {
    # System-wide session variables for Wayland/Hyprland.
    # Required for screen sharing and portal backends to detect the compositor.
    variables = {
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "mango";
      NIXOS_OZONE_WL = "1";
    };
  };
}
