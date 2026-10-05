# Standalone enabled unit evaluation; no runtime secrets or service startup.
{nixpkgsPath ? <nixpkgs>}:
let
  pkgs = import nixpkgsPath {};
  lib = pkgs.lib;
  defaults = import ../../options.nix;
  opts = defaults // {
    media = defaults.media // {
      torrents = defaults.media.torrents // {
        enable = true;
        tunnel = defaults.media.torrents.tunnel // {
          interface = "fixturewg";
          endpoint = "203.0.113.7:51820";
          address = "10.8.0.2/32";
          resolver = "10.8.0.1";
        };
      };
    };
  };
  system = import "${nixpkgsPath}/nixos/lib/eval-config.nix" {
    specialArgs = {inherit opts;};
    modules = [
      ../../config/system/media/torrents.nix
      ({lib, ...}: {
        options.sops.secrets = lib.mkOption {type = lib.types.attrsOf lib.types.anything; default = {};};
        options.agentOps.backup = lib.mkOption {type = lib.types.anything; default = {};};
        config.system.stateVersion = "25.11";
      })
    ];
  };
  units = system.config.systemd.units;
in {
  netns = units."media-netns.service".text;
  audit = units."media-netns-audit.service".text;
  tunnel = units."media-tunnel.service".text;
  client = units."qbittorrent.service".text;
  proxy = units."media-webui-proxy.service".text;
  firewall = system.config.networking.firewall.extraCommands;
}
