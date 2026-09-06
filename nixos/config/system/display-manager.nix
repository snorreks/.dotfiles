# nixos/config/system/display-manager.nix
{
  pkgs,
  lib,
  opts,
  ...
}: {
  # Configure greetd to enable the display manager
  services.greetd = {
    enable = true;
    settings =
      {
        # Set up the default session to run the defined command as the specified user
        default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --asterisks --remember --remember-user-session --time --time-format '%I:%M %p | %a • %h | %F' --cmd mango";
          user = "greeter";
        };
      }
      # Autologin straight into mango. Dropped on a headless host: the desktop
      # stays fully installed and one tuigreet login away for whenever we are
      # physically at the machine, but nothing starts a mango session for an
      # empty room. That removes a compositor, waybar, quickshell, swayidle,
      # mako and the nm-applet that is already known to crash (services.nix)
      # from a box whose failure mode is "somebody has to drive to the
      # basement" — and it frees the RAM they were holding for models.
      // lib.optionalAttrs (!opts.headless) {
        # Set up the initial session to run the defined command as the specified user
        initial_session = {
          command = "mango";
          user = "${opts.username}";
        };
      };
  };
}
