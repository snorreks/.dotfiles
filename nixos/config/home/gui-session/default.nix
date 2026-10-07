{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  launcher = pkgs.callPackage ./package.nix {
    mango = config.wayland.windowManager.mango.package;
  };
in {
  # Desktop hosts retain their existing app launch behavior.
  home.packages = lib.optionals opts.headless [launcher];
}
