# Evaluate the actual folder guard, without starting services or reading state.
{nixpkgsPath ? <nixpkgs>}:
let
  pkgs = import nixpkgsPath {};
  lib = pkgs.lib;
  defaults = import ../../options.nix;
  accepts = folder: let
    opts = lib.recursiveUpdate defaults {
      media.syncthing = {enable = true; folders = [folder];};
    };
    system = import "${nixpkgsPath}/nixos/lib/eval-config.nix" {
      specialArgs = {inherit opts;};
      modules = [
        ../../config/system/media/syncthing.nix
        ({lib, ...}: {
          options.agentOps.backup.enable = lib.mkOption {type = lib.types.bool; default = false;};
          options.agentOps.backup.sources = lib.mkOption {type = lib.types.listOf lib.types.path; default = [];};
          options.agentOps.backup.additionalSources = lib.mkOption {type = lib.types.listOf lib.types.path; default = [];};
          config.users.users.${opts.username} = {isNormalUser = true; home = "/home/${opts.username}";};
          config.system.stateVersion = "25.11";
        })
      ];
    };
    # Do not force messages from unrelated native assertions: some diagnostics
    # refer to values that exist only when their corresponding check fails.
    definitions = lib.filter (d: d.file == toString ../../config/system/media/syncthing.nix)
      system.options.assertions.definitionsWithLocations;
    checks = lib.filter (a: lib.hasInfix "whole-home" a.message)
      (lib.concatMap (d: d.value) definitions);
  in checks != [] && lib.all (a: a.assertion) checks;
  home = "/home/${defaults.username}";
in {
  approved = accepts "${home}/projects/notes";
  configRoot = accepts "${home}/.config/herdr";
  configParent = accepts "${home}/.config";
  configChild = accepts "${home}/.config/herdr/session";
  stateRoot = accepts "${home}/.local/state/herdr";
  stateParent = accepts "${home}/.local/state";
  stateChild = accepts "${home}/.local/state/herdr/agents";
}
