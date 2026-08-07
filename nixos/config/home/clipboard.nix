# nixos/config/home/clipboard.nix
{pkgs, ...}: {
  home.packages = with pkgs; [
    cliphist # Clipboard history manager
    wl-clipboard # Provides `wl-copy` and `wl-paste`
    wl-clip-persist # Keep selection in memory after app closes
  ];
  # NEW — clipboard stack as proper, singleton, auto-restarting services
  systemd.user.services = {
    cliphist-clipboard = {
      Unit = {
        Description = "cliphist watcher (clipboard selection)";
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
    cliphist-primary = {
      Unit = {
        Description = "cliphist watcher (primary selection)";
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --primary --type text --watch ${pkgs.cliphist}/bin/cliphist store";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
    wl-clip-persist = {
      Unit = {
        Description = "Keep clipboard content alive after source app closes";
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
      };
      Service = {
        ExecStart = "${pkgs.wl-clip-persist}/bin/wl-clip-persist --clipboard both";
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
