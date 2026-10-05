# Metadata only: real NixOS option types and module merging, no system build,
# activation, credentials or network. Evaluated by backup-restore.sh outside a
# Nix build sandbox (inside one, the nested evaluation is explicitly skipped).
#
# Proves, against the REAL backup + state-manifest + media modules:
#   * media/syncthing integration paths are APPENDED (additionalSources) to the
#     manifest default AND to an operator-selected `sources` list, never
#     replacing either;
#   * the union is deduplicated;
#   * cfg.stateDir reaches every backup unit as AGENT_OPS_STATE_DIR and is the
#     directory the generated quiesce table lives in (no /backup suffix);
#   * the unsupported ioMaxConcurrent setting is gone from options and config.
{nixpkgs ? <nixpkgs>}: let
  base = import ../../options.nix;
  opts = base // {
    media = base.media // {
      jellyfin = base.media.jellyfin // {enable = true;};
      syncthing = base.media.syncthing // {enable = true;};
    };
  };
  stateDir = "/var/lib/custom-backup";
  evaluate = extra:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      system = "x86_64-linux";
      specialArgs = {inherit opts;};
      modules = [
        ../../config/system/agent-ops/state-manifest.nix
        ../../config/system/agent-ops/backup.nix
        ../../config/system/media
        ({lib, ...}: {
          # External credential provider's typed interface; no secret material.
          options.sops.secrets = lib.mkOption {
            default = {};
            type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
              options.path = lib.mkOption {
                type = lib.types.str;
                default = "/run/secrets/${name}";
              };
            }));
          };
          config = {
            agentOps.backup.enable = true;
            agentOps.backup.stateDir = stateDir;
            # Boilerplate so the generic NixOS assertions hold; never built.
            fileSystems."/" = {device = "none"; fsType = "tmpfs";};
            boot.loader.grub.enable = false;
            system.stateVersion = "25.11";
          };
        })
        extra
      ];
    }).config;

  config = evaluate {};
  exportDir = "/var/lib/agent-ops/media-exports";
  selected = evaluate {agentOps.backup.sources = ["/operator/selected" exportDir];};

  conf = c: c.environment.etc."agent-ops/backup.conf".text;
  lines = c: builtins.filter builtins.isString (builtins.split "\n" (conf c));
  value = key: c: let
    prefix = "${key}=";
    n = builtins.stringLength prefix;
  in
    builtins.fromJSON (builtins.substring n (-1)
      (builtins.head (builtins.filter (l: builtins.substring 0 n l == prefix) (lines c))));
  paths = value "sources";

  core = map (entry: entry.path) (builtins.filter (entry:
    !(entry.excludeFromBackup or false))
  config.agentOps.state.manifest);
  integrations = [exportDir opts.media.syncthing.dataDir opts.media.jellyfin.configDir];
  hasAll = wanted: actual: builtins.all (path: builtins.elem path actual) wanted;
  noDuplicates = xs: builtins.length xs == builtins.length (builtins.attrNames
    (builtins.listToAttrs (map (x: {name = x; value = true;}) xs)));
  units = ["agent-ops-backup" "agent-ops-backup-retention" "agent-ops-backup-verify"];
  failed = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
in
  assert core != [];
  assert hasAll (core ++ integrations) (paths config);
  assert noDuplicates (paths config);
  assert hasAll (["/operator/selected"] ++ integrations) (paths selected);
  assert !(hasAll core (paths selected));
  assert builtins.length (paths selected) == 4;
  assert config.systemd.services.media-state-export.environment.MEDI_JELLYFIN_DB == "${opts.media.jellyfin.dataDir}/data/jellyfin.db";
  assert builtins.all (unit: config.systemd.services.${unit}.environment.AGENT_OPS_STATE_DIR == stateDir) units;
  assert value "quiesceFile" config == "${stateDir}/quiesce.conf";
  assert builtins.match ".*ioMaxConcurrent.*" (conf config) == null;
  assert !(config.agentOps.backup ? ioMaxConcurrent);
  assert failed config == [];
  assert failed selected == []; {
    sources = paths config;
    operatorSources = paths selected;
    stateDir = config.systemd.services.agent-ops-backup.environment.AGENT_OPS_STATE_DIR;
  }
