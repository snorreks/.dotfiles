# nixos/config/system/display-manager.nix
{
  pkgs,
  opts,
  ...
}: {
  # Configure greetd to enable the display manager
  services.greetd = {
    enable = true;
    settings = {
      # Set up the default session to run the defined command as the specified user
      default_session = {
        command = "${pkgs.tuigreet}/bin/tuigreet --asterisks --remember --remember-user-session --time --time-format '%I:%M %p | %a • %h | %F' --cmd mango";
        user = "greeter";
      };
      # Set up the initial session to run the defined command as the specified user
      initial_session = {
        command = "mango";
        user = "${opts.username}";
      };
    };
  };
}
