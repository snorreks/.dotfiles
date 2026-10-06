{
  lib,
  opts,
  pkgs,
  ...
}: let
  updater = pkgs.writeShellApplication {
    name = "nupdate";
    runtimeInputs = [pkgs.coreutils pkgs.inetutils pkgs.jq pkgs.nix pkgs.nh pkgs.openssh];
    text =
      ''
        export NU_HOST=${lib.escapeShellArg opts.hostname}
        export NU_IS_SERVER=${
          if opts.headless
          then "1"
          else "0"
        }
        export NU_FLAKE=${lib.escapeShellArg opts.flakeDir}
        export NU_REMOTE_ALIAS=${lib.escapeShellArg "${opts.travel.serverHost}-tailscale"}
        export NU_REMOTE_UPDATE=${lib.escapeShellArg "/etc/profiles/per-user/${opts.username}/bin/nupdate"}
        export NU_MAINT=/run/current-system/sw/bin/ns-maint
        export NU_BOOTED_SYSTEM=/run/booted-system
      ''
      + builtins.readFile ./nupdate.sh;
  };
  confirm = pkgs.writeShellApplication {
    name = "nconfirm";
    text = ''
      exec ${lib.getExe updater} --confirm "$@"
    '';
  };
in {
  home.packages = [updater confirm];
}
