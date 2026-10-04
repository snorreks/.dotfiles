# nixos/config/system/media/syncthing.nix
#
# OPTIONAL. Off by default, and off on both hosts as shipped — nothing here
# starts until somebody deliberately selects folders to synchronise.
#
# ── What synchronisation is not ─────────────────────────────────────────────
# 🔴 SYNCTHING IS NOT A BACKUP, and the two behave differently in the way that
# hurts:
#
#   restic        a snapshot at a point in time; deleting a file does not
#                 delete yesterday's copy.
#   syncthing     a live mirror; deleting a file DELETES IT ON THE OTHER
#                 DEVICE, immediately and permanently.
#
# So a file removed from the travel laptop — because it was renamed, because a
# half-finished edit was reverted, because an agent tidied a directory — is gone
# from the server's copy too. Restic remains the backup for everything in this
# file. See docs/media-travel.md § "Sync is not backup".
#
# ── The exclusion list is the security control here ─────────────────────────
# The folder list is opt-in and short. The EXCLUSIONS below are not: they are
# unconditional, and they exist because the failure mode of getting them wrong
# is publishing a secret to a second device, or corrupting a database that was
# open while it was copied.
#
# `.git` and `worktrees/` — a synchronised git directory produces two
# repositories that disagree, and a worktree's metadata is meaningless on
# another machine. Not excluded, this corrupts uncommitted work, which is
# exactly the work restic exists to protect.
#
# SQLite databases (`*.db`, `-journal`, `-wal`) — the canonical unsafe-sync
# case: a half-copied database is structurally valid and semantically wrong, and
# both ends then believe it. Media state is exported properly by media-state.sh
# and backed up by restic; it is not mirrored.
#
# agent runtime state (`.pi/`, `sessions/`, `herdr`) — a live session database
# synchronised while two agents are writing to it is a corrupted session store on
# both machines, and duplicating an in-flight agent session onto a second host is
# the two-devices-running-one-agent failure.
#
# key material and decrypted environments (`.ssh/`, `*.age`, `*.key`, `.env`,
# `credentials`) — a synchronised private key is a private key on another
# device. "It is on my own tailnet" is not a property that makes that
# acceptable; the key does not need to be useful to anyone else to be a
# liability if that device is lost.
#
# tailscale state (`/var/lib/tailscale`) — this is the node's identity. Two
# devices sharing one node key is a tailnet incident, not a sync.
{config, pkgs, lib, opts, ...}: let
  cfg = opts.media.syncthing;
in {
  # The account. Gated with everything else, because defining it unconditionally
  # would create a system user on machines with Syncthing switched off — and an
  # unconfigured user account is an account, just an inert one.
  #
  # It is in `media` so Syncthing can read the selected folders, and nothing
  # more: not in `wheel`, not the operator, no shell.
  users.users.syncthing = lib.mkIf cfg.enable {
    isSystemUser = true;
    group = "syncthing";
    extraGroups = ["media"];
    description = "Syncthing, optional selective folder synchronisation";
  };
  users.groups.syncthing = lib.mkIf cfg.enable {};

  services.syncthing = lib.mkIf cfg.enable {
    enable = true;
    package = pkgs.syncthing;
    dataDir = cfg.dataDir;
    user = "syncthing";
    group = "syncthing";

    # System service, so it is bounded like every other media workload and
    # survives the operator not being logged in. A Syncthing that only runs
    # while somebody is sitting at the machine is not synchronising anything.
    systemService = true;

    # GUI on loopback, reached over the same private Serve pattern as Jellyfin
    # and Collie. Not on the LAN, not on the tailnet directly, and never with
    # Funnel: the Syncthing GUI can add devices and read file listings for every
    # synchronised folder, which makes it an unusually valuable target.
    guiAddress = "127.0.0.1";

    # 🔴 nixpkgs opens 8384 (GUI), 22000 (discovery) and 21027 (relay) by
    # default when this is true. Every one of those would publish the admin UI
    # and the peer protocol to the LAN. See the openDefaultPorts description.
    openDefaultPorts = false;
  };

  systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    "d ${cfg.dataDir} 0700 syncthing syncthing -"
  ];

  systemd.services.tailscale-serve-syncthing = lib.mkIf cfg.enable {
    description = "Syncthing admin on the node's private Tailscale HTTPS endpoint";
    after = ["tailscaled.service" "tailscaled-set.service"];
    wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.escapeShellArgs [
        (lib.getExe config.services.tailscale.package)
        "serve"
        "--bg"
        "--https=${toString cfg.serveHttpsPort}"
        "http://127.0.0.1:${toString cfg.guiPort}"
      ];
      # This port only. Never `serve reset`.
      ExecStop = lib.escapeShellArgs [
        (lib.getExe config.services.tailscale.package)
        "serve"
        "--https=${toString cfg.serveHttpsPort}"
        "off"
      ];
    };
  };

  # ── What may be synchronised, and what may never be ──────────────────────
  environment.etc."syncthing/media-ignore.rules".text = ''
    # Generated by nixos/config/system/media/syncthing.nix.
    #
    # 🔴 THESE EXCLUSIONS ARE NOT A DEFAULT PROFILE TO TURN OFF. They are the
    # reason this service is safe to enable at all. A folder added without
    # reading this file is a folder that can publish a private key.

    # Version control and its worktrees.
    .git/
    .gitignore
    worktrees/

    # Live databases. Media state is exported (media-state.sh) and backed up by
    # restic; it is never mirrored.
    *.db
    *.db-journal
    *.db-wal
    *.sqlite
    *.sqlite3

    # Agent runtime state: two agents writing one synchronised session store
    # corrupts both.
    .pi/
    sessions/
    herdr/
    .claude/

    # Key material and decrypted environments.
    .ssh/
    *.age
    *.agekey
    *.key
    *.pem
    # OpenSSH private keys by their conventional names, matched OUTSIDE .ssh/
    # as well. A key that has been moved to a working directory is still a key,
    # and `.ssh/` alone only protects the copy that never leaves home.
    id_rsa
    id_dsa
    id_ecdsa
    id_ed25519
    id_ed25519_sk
    id_ecdsa_sk
    *.pubkey
    .env
    .env.*
    credentials
    secrets.yaml
    *.sops.yaml

    # Tailscale node identity.
    tailscaled.state
    .tailscale/

    # Build and store artefacts.
    result
    result-*
    node_modules/
    .direnv/
  '';

  assertions = lib.optionals cfg.enable [
    {
      assertion = !lib.any (f: f == "/" || f == "" || f == "$HOME") cfg.folders;
      message = ''
        media: opts.media.syncthing.folders contains a whole-home or whole-root
        entry. Select specific directories; a home-directory folder would pull
        every .ssh key and decrypted environment through the exclusions above
        by accident of what is new.
      '';
    }

    {
      assertion = !lib.any (f: lib.hasPrefix "/var/lib/tailscale" f) cfg.folders;
      message = ''
        media: opts.media.syncthing.folders must not include Tailscale state.
        Synchronising it puts one node identity on two devices.
      '';
    }

    {
      assertion = cfg.serveHttpsPort != 443
        || !(opts.mobileAgents.collie.enable);
      message = ''
        media: Syncthing's Serve port is 443 and Collie owns it. Give Syncthing
        its own port (default ${toString (cfg.serveHttpsPort + 8440)}).
      '';
    }
  ];

  warnings =
    lib.optional (cfg.enable && cfg.folders == []) ''
      media: Syncthing is enabled with no folders selected. It will run, hold a
      device identity and a GUI credential, and synchronise nothing. Either add
      folders or turn it off.
    ''
    ++ lib.optional cfg.enable ''
      media: Syncthing is enabled. Remember that synchronisation PROPAGATES
      DELETION — a file removed on the travel laptop is removed on the server.
      Restic is the backup; see docs/media-travel.md § "Sync is not backup".
    '';

  agentOps.backup = lib.mkIf (cfg.enable && opts.agentOps.backup.enable) {
    sources = [{paths = [cfg.dataDir];}];
  };
}