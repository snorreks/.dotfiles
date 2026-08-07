# nixos/config/home/waybar/default.nix
{pkgs, ...}: {
  imports = [
    ./settings.nix
    ./style.nix
  ];

  programs.waybar = {
    enable = true;

    # Use standard pre-compiled binary from binary cache (no long builds)
    package = pkgs.waybar;

    # Let systemd manage starting, logging, and restarting Waybar on crashes
    systemd = {
      enable = true;
      targets = ["graphical-session.target"];
    };
  };
}
