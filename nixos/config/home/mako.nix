{pkgs, ...}: {
  home.packages = [pkgs.libnotify];
  services.mako = {
    enable = true;
    settings = {
      # Global settings
      anchor = "top-right";
      "border-radius" = 5;
      "border-size" = 2;
      padding = "20";
      "default-timeout" = 5000;
      layer = "top";
      height = 100;
      width = 300;
      format = "<b>%s</b>\\n%b";

      # Criteria-based settings
      "urgency=low" = {
        "default-timeout" = 3000;
      };
      "urgency=high" = {
        "default-timeout" = 10000;
      };
      "mode=dnd" = {
        invisible = 1;
      };
    };
  };
}
