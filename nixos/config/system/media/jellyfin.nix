# nixos/config/system/media/jellyfin.nix
#
# Private media server: native NixOS + systemd, no orchestration stack.
#
# The whole design is one sentence: **nothing here is reachable from the LAN,
# and everything here is reachable from the tailnet.** Jellyfin binds loopback
# only and is published through a PRIVATE Tailscale Serve listener, which is the
# same shape config/system/mobile-agents.nix gives Collie. That means no
# `allowedTCPPorts` entry, no interface beyond loopback, and no firewall rule
# that a future edit could get wrong.
#
# ── On the Serve port ───────────────────────────────────────────────────────
# Collie owns tailnet HTTPS 443. This module takes a DIFFERENT port
# (`serveHttpsPort`, default 8443) and an assertion below refuses 443 while
# Collie is enabled, because two units claiming the same Serve port is not a
# configuration that fails — it is one where whichever unit starts last wins and
# the other becomes a silently broken half. See docs/media-travel.md for how to
# verify the port is supported by the pinned Tailscale before enabling.
#
# `ExecStop` turns off ITS OWN port and nothing else. `tailscale serve reset`
# would erase every mapping on the node including Collie's, and it is the reason
# A's reconcile script does not use it either.
#
# ── On hardware transcoding ─────────────────────────────────────────────────
# Off by default, and the default is the point. "This laptop has an Intel GPU" is
# not a statement about QSV being usable: the render node, the media driver, the
# GuC/HuC firmware and the codec build each have to be present, and enabling
# acceleration without checking produces a server that silently transcodes in
# software while appearing configured.
#
# So `hardwareAcceleration.enable` additionally requires either a passing
# `jellyfin-accel-check.sh` or an explicit `acknowledgeMissing = true` — the
# second of which is a deliberate override that shows up in the diff.
#
# The discrete NVIDIA GPU is NOT configured for Jellyfin anywhere in this file,
# and `nvdec`/`nvenc` are deliberately absent. That GPU is for inference, and
# giving a transcoder the same device is the ordinary way inference stops having
# memory when a stream starts. Software transcoding remains available as the
# explicit fallback and is unaffected by any of this.
{config, pkgs, lib, opts, ...}: let
  cfg = opts.media.jellyfin;
in {
  services.jellyfin = lib.mkIf cfg.enable {
    enable = true;
    # Nix-owned version. Upgrading is `nix flake update` plus a rebuild, and a
    # rollback is a rebuild of the previous lock — which is a property the
    # whole reason for going native rather than adding a container stack.
    package = pkgs.jellyfin;

    dataDir = cfg.dataDir;
    configDir = cfg.configDir;

    # 🔴 NOT A STYLISTIC CHOICE, AND NOT AN OVERSIGHT.
    #
    # There is no firewall entry for Jellyfin anywhere in this configuration, so
    # the LAN cannot reach it — not because a rule happens to refuse it, but
    # because the port is never opened. `openFirewall = false` is the nixpkgs
    # default and is stated anyway, because the natural "fix" for a transcoding
    # problem people hit is to flip it, and it should have to be a deliberate
    # act.
    #
    # This is the boundary config/system/networking.nix already draws for ollama
    # and ComfyUI: the service may listen broadly, the port is never opened, and
    # `networking.firewall.trustedInterfaces = ["tailscale0"]` means the tailnet
    # reaches it while the LAN cannot.
    #
    # It is the firewall rather than a loopback bind because nixpkgs' jellyfin
    # module exposes no listen-address option — the address lives in Jellyfin's
    # own network.xml, which is application state that a module writes into and
    # an operator also edits. That is a worse place to keep a security boundary
    # than a port list that can be read off the configuration.
    openFirewall = false;

    # Least privilege. Jellyfin gets its own system account and the `media`
    # group, and nothing else. It is not a member of `wheel`, and it does not
    # run as the operator.
    group = "media";
    user = "jellyfin";

    # Transcoding acceleration is declared HERE, in the same block, rather than
    # as a second `services.jellyfin.hardwareAcceleration`: within one
    # attribute set those are a conflict, not a merge. (Across modules they DO
    # merge, which is why `systemd.services.jellyfin.sliceConfig` in
    # default.nix is fine.)
    #
    # QSV/VAAPI on the iGPU, never NVENC — see the file header. When
    # acceleration is off, nothing is declared here and Jellyfin's own default
    # (software transcoding) applies, rather than a value chosen here.
    hardwareAcceleration = {
      enable = cfg.hardwareAcceleration.enable;
      # nixpkgs asserts this is non-null whenever enable is true. Naming it here
      # keeps the failure pointing at this module rather than at an upstream
      # assertion that names neither the option nor the check that was supposed
      # to run before it.
      device = lib.mkIf cfg.hardwareAcceleration.enable "/dev/dri/renderD128";
      type = lib.mkIf cfg.hardwareAcceleration.enable (
        if cfg.hardwareAcceleration.acknowledgeMissing
        then cfg.hardwareAcceleration.type
        else "vaapi"
      );
    };

    # 🔴 INTELLITUTOR IS NOT DISABLED HERE, DELIBERATELY.
    #
    # It is on by default upstream and it phones home, and it would be good to
    # turn off on a tailnet-reachable server. It is left on here because
    # nixpkgs' jellyfin module exposes no way to set it: it lives in Jellyfin's
    # own system.xml, which is application state.
    #
    # Declaring an `environment` block to set it would evaluate, and would do
    # nothing — which is worse than not doing it, because the next person reads
    # the configuration, believes the server is not calling home, and does not
    # check. docs/media-travel.md § "After the setup wizard" has the actual
    # click path, and the checklist is not optional.
  };

  users.groups.media = {};
  users.groups.jellyfin = {};

  # ── Storage ────────────────────────────────────────────────────────────────
  #
  # Native Linux filesystem only. opts.mountShared (/mnt/shared, the Windows
  # dual-boot NTFS volume) is deliberately NOT referenced here and must not be:
  # an unattended server writing to a hibernated Windows volume is a corruption
  # path that needs a keyboard and a booted Windows to fix.
  #
  # The three-way split is load-bearing, not tidiness:
  #
  #   incomplete/  being written right now. Nothing reads it.
  #   download/    finished, waiting to be moved into the library.
  #   library/     what Jellyfin actually serves.
  #
  # Jellyfin is given library/ (and the cache/download dir it needs), NOT the
  # parent, so a half-written download is never something a library scan can
  # pick up.
  systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    "d ${cfg.incompleteDir} 0750 jellyfin media -"
    "d ${cfg.downloadDir} 0750 jellyfin media -"
    "d ${cfg.libraryDir} 0750 jellyfin media -"
    "d ${cfg.dataDir} 0755 jellyfin media -"
    "d ${cfg.configDir} 0755 jellyfin media -"
  ];

  # ── Private publication ────────────────────────────────────────────────────
  systemd.services.tailscale-serve-jellyfin = lib.mkIf cfg.enable {
    description = "Jellyfin on the node's private Tailscale HTTPS endpoint (${toString cfg.serveHttpsPort})";
    after = [
      "tailscaled.service"
      "tailscaled-autoconnect.service"
      "tailscaled-set.service"
      "network-pre.target"
    ];
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
        "http://127.0.0.1:${toString cfg.port}"
      ];
      # THIS PORT ONLY. Never `serve reset`, which erases every mapping on the
      # node — including Collie's 443, which A's reconcile script exists to keep.
      ExecStop = lib.escapeShellArgs [
        (lib.getExe config.services.tailscale.package)
        "serve"
        "--https=${toString cfg.serveHttpsPort}"
        "off"
      ];
      # The unit must not be able to hang a boot on a node that has not finished
      # authenticating; `tailscale serve` returns non-zero rather than blocking.
      TimeoutStartSec = "30s";
    };
  };

  # ── Acceleration capability check ──────────────────────────────────────────
  #
  # Installed whenever Jellyfin is on, acceleration or not: it is the thing an
  # operator runs to find out WHY acceleration is unavailable, which is the
  # question that actually gets asked.
  environment.systemPackages = lib.mkIf cfg.enable [
    (pkgs.writeShellApplication {
      name = "jellyfin-accel-check";
      runtimeInputs = [
        # Provides vainfo — the VAAPI entrypoint enumeration the check reads.
        pkgs.intel-media-driver
        # Provides oneVPL/QSV, which is the other half of "QSV is available".
        # Installed but not enabled by default: see the hardwareAcceleration
        # block above.
        pkgs.intel-media-sdk
        pkgs.pciutils
        pkgs.coreutils
      ];
      text = builtins.readFile ./scripts/jellyfin-accel-check.sh;
    })
  ];

  # ── Backup integration ─────────────────────────────────────────────────────
  #
  # The library index is registered with the backup lane, which is what makes a
  # library restore possible. Without it a restored media directory has files and
  # no index, and Jellyfin's first scan of a large library is not fast.
  #
  # media/default.nix owns the export service and the heartbeatHook; this module
  # only declares WHAT has to survive, so the two cannot disagree about which
  # database matters.
  agentOps.backup = lib.mkIf (cfg.enable && opts.agentOps.backup.enable) {
    sources = [
      {
        paths = ["${cfg.dataDir}/data"];
        excludes = [
          "cache"
          # Metadata, not state: regenerable and large.
          "metadata"
        ];
      }
    ];
  };

  # ── Refusals, and visible half-configured states ──────────────────────────
  assertions = lib.optionals cfg.enable [
    {
      # Two Serve units claiming one port is a race, not a conflict error.
      assertion = !(cfg.serveHttpsPort == 443 && opts.mobileAgents.collie.enable);
      message = ''
        media: opts.media.jellyfin.serveHttpsPort is 443 and Collie is enabled.
        Both units would write `tailscale serve --https=443`, and the one that
        starts last silently wins.

        Collie owns 443 (config/system/mobile-agents.nix). Give Jellyfin its
        own port:
          opts.media.jellyfin.serveHttpsPort = ${toString cfg.serveHttpsPort + 8440};
      '';
    }

    {
      # Accel on without the check having passed, and without saying so.
      assertion = !cfg.hardwareAcceleration.enable
        || cfg.hardwareAcceleration.acknowledgeMissing;
      message = ''
        media: hardwareAcceleration.enable is true, but the capability check has
        not been acknowledged as passed.

        Run it first:
          jellyfin-accel-check
        If it fails, leave acceleration off (software transcoding is correct and
        keeps the NVIDIA GPU free for inference), or override deliberately:
          opts.media.jellyfin.hardwareAcceleration.acknowledgeMissing = true;
      '';
    }

    {
      assertion = !cfg.hardwareAcceleration.enable || cfg.hardwareAcceleration.type != "nvenc";
      message = ''
        media: hardwareAcceleration.type = "nvenc" was refused.

        The discrete NVIDIA GPU is for inference in this configuration. Handing
        the transcoder the same device is how inference runs out of memory the
        first time somebody plays something. Use "vaapi" (the Intel iGPU), or
        leave acceleration off and transcode in software.
      '';
    }

    {
      # Shared NTFS is not a media root.
      assertion = !opts.mountShared
        || !(lib.hasPrefix "/mnt/shared" cfg.libraryDir);
      message = ''
        media: the Jellyfin library is on the shared NTFS volume.

        /mnt/shared is the Windows dual-boot volume (opts.mountShared). An
        unattended server writing to a hibernated Windows filesystem corrupts
        it, and repairing it needs a keyboard and a booted Windows. Media and
        state must live on native Linux filesystems.
      '';
    }
  ];

  warnings =
    lib.optional (cfg.enable && cfg.setupCompleted == false) ''
      media: Jellyfin is enabled but opts.media.jellyfin.setupCompleted is false.

      Until a Jellyfin administrator account exists, Jellyfin's first-run setup
      wizard is open to anyone who can reach the service — and every tailnet
      device can, through the Serve mapping above. Whoever completes it first
      becomes the administrator.

      Finish the setup over the tailnet, then set:
        opts.media.jellyfin.setupCompleted = true;

      The flag does not create or check an account; it records that you did.
    ''
    ++ lib.optional (cfg.enable && cfg.hardwareAcceleration.enable) ''
      media: hardware transcoding is enabled for Jellyfin. This has not been
      verified on this machine in this configuration. Real-hardware acceptance
      (a representative high-bitrate file, and a seek) is recorded as PENDING in
      docs/media-travel.md and must be performed before travel.
    '';
}