# nixos/config/system/media/torrents.nix
#
# qBittorrent, unprivileged, inside a dedicated network namespace whose only
# way out is a WireGuard tunnel.
#
# ── The one rule this file must never break ────────────────────────────────
# 🔴 NOTHING HERE TOUCHES THE HOST'S OUTPUT POLICY. Not one rule, not one
# chain, not one interface.
#
# The existing wg-quick kill-switch in config/system/networking.nix is the
# cautionary example and it is why that file structurally omits it on a server:
# an OUTPUT rule that rejects everything not marked for the tunnel rejects the
# TAILNET as well, and the tailnet is the only way back into a box in a
# basement. Copying that shape here, even scoped "just for qBittorrent", either
# does nothing (if applied in the host namespace) or locks the machine out (if
# applied outside it).
#
# Isolation here comes from a network NAMESPACE. Every rule that restricts
# egress is installed inside `medtns` and cannot be reached from the host's own
# tables. The host gets exactly one new thing: an interface-scoped INPUT
# allowance on the veth, so the loopback proxy can reach the WebUI. INPUT only.
# `networking.firewall.trustedInterfaces` and every OUTPUT policy on this host
# are exactly as they were before this module existed.
#
# ── Fail closed, which is a property not a feature ─────────────────────────
# The tunnel disappearing must stop downloads. It must NOT stop SSH, tailscaled,
# Collie, herdr or Jellyfin — and because none of those are in the namespace,
# that is structural rather than something the ordering of unit dependencies
# has to be trusted to get right.
#
# Inside the namespace the policy is DROP and the tunnel is allowed by NAME.
# While the tunnel is absent that rule matches nothing and everything falls
# through to DROP. There is no window in which an absent tunnel is a permissive
# tunnel, and no ordering in which the client can start before the rules exist:
# `media-netns.service` is `Before=` the tunnel and the client, and is
# `RequiredBy=` both, so a namespace that failed to come up means neither runs.
{config, pkgs, lib, opts, ...}: let
  cfg = opts.media.torrents;

  netnsEnv = {
    MEDI_NS = cfg.namespace;
    MEDI_VETH_HOST = cfg.vethHost;
    MEDI_VETH_NS = cfg.veth;
    MEDI_HOST_ADDR = "${cfg.vethHostAddr}";
    MEDI_NS_ADDR = "${cfg.vethAddr}";
    MEDI_GATEWAY = cfg.gateway;
    MEDI_WG_IF = cfg.tunnel.interface;
    MEDI_WEBUI_PORT = toString cfg.webuiPort;
    # 🔴 NUMERIC, and required. See netns-up.sh: a hostname endpoint would need a
    # DNS query to leave through the veth before the tunnel exists, which is the
    # exact leak the namespace is built to prevent.
    MEDI_WG_ENDPOINT = "${cfg.tunnel.endpoint}";
  };

  # Upload shaping. A token bucket on the tunnel interface inside the namespace,
  # rather than a number in qBittorrent's own settings — qBittorrent's limit is
  # mutable state that a UI change can raise, and this one cannot.
  tcUnit = lib.optionalAttrs (cfg.uploadLimitKbit != null) ''
    ${pkgs.iproute2}/bin/tc qdisc add dev ${cfg.tunnel.interface} root tbf \
      rate ${toString cfg.uploadLimitKbit}kbit \
      latency 400ms burst 64kb
  '';
in {
  # ── Accounts ──────────────────────────────────────────────────────────────
  #
  # Two distinct accounts, for two distinct jobs:
  #
  #   qbittorrent  owns nothing except the client. Cannot read the media
  #                library's read-only export, cannot read anything of the
  #                operator's, and is not in any group that would let it.
  #   media         read/write on the media tree, which is what Jellyfin and
  #                the namespace need to share.
  users.users.qbittorrent = {
    isSystemUser = true;
    group = "qbittorrent";
    description = "qBittorrent, confined to the media network namespace";
    extraGroups = ["media"];
  };
  users.groups.qbittorrent = {};
  users.groups.media = {};

  # ── Host-side ingress, scoped to the veth and nothing else ────────────────
  #
  # The ONLY firewall change on the host. It is an INPUT rule, it is attached to
  # one interface that exists solely for this purpose, and it exists because
  # qBittorrent's WebUI has to be reachable by SOMETHING on the host.
  #
  # mthost is deliberately NOT in networking.firewall.trustedInterfaces: that
  # list accepts everything unconditionally, and this interface carries traffic
  # to an unauthenticated-by-default admin UI. One narrow port beats blanket
  # trust.
  networking.firewall.interfaces = lib.mkIf cfg.enable {
    ${cfg.vethHost} = {
      allowedTCPPorts = [cfg.webuiPort];
      # Nothing may be routed THROUGH this host from the namespace. The
      # namespace has no route and this forbids it being granted one.
      log = false;
    };
  };

  # ── Runtime provider credentials ──────────────────────────────────────────
  #
  # The WireGuard configuration is a SYSTEMD CREDENTIAL, not an environment
  # variable and not a file in /etc. Three reasons, in order of how much they
  # matter:
  #
  #   * it is never in the Nix store, so it is not readable by every account on
  #     the machine and not visible in `nix-store -q --references`;
  #   * it is readable only by the service that was given it, so it does not
  #     leak into the qBittorrent process — which is the one process here that
  #     processes untrusted input from the internet;
  #   * it is decrypted at run time by sops-nix, so a rebuild does not require
  #     the secret to be present at eval time and a machine that has not been
  #     provisioned yet still evaluates.
  #
  # `sops.requiredSecrets` is the point at which the difference shows: with it,
  # activation on a machine that was never provisioned FAILS LOUDLY rather than
  # starting a tunnel unit with no configuration, which would look like a
  # working service that silently never connects.
  sops.secrets = lib.mkIf cfg.enable {
    MEDIA_WG_CONFIG = {
      # 🔴 Generated ONCE, by hand, on a machine that is already configured for
      # the provider: `wg-quick strip <iface>` writes it. There is no default
      # and no `null` fallback, because a private key in a git repository is a
      # credential in history and a plausible-looking default path is how one
      # ends up committed.
      path = cfg.tunnel.configSecretPath;
      # Same convention as config/system/agent-ops/backup.nix: the credential is
      # wired to the unit that consumes it.
      restartUnits = ["media-tunnel.service"];
    };

    # The loopback WebUI proxy's token. Same reasoning as the tunnel config
    # above, and with an extra reason: qBittorrent's WebUI is unauthenticated
    # until a password is set, which is exactly what a freshly-provisioned
    # instance and a restored-from-backup config both look like.
    MEDIA_WEBUI_TOKEN = {
      path = cfg.proxyTokenSecretPath;
      restartUnits = ["media-webui-proxy.service"];
    };
  };

  # ── Storage ───────────────────────────────────────────────────────────────
  #
  # Three directories, three purposes, three owners-of-concern:
  #
  #   incomplete/  qBittorrent writes, Jellyfin never reads
  #   download/    qBittorrent writes, Jellyfin never reads
  #   library/     Jellyfin serves; qBittorrent does NOT write here
  #
  # The last one is the point. Letting the client write into the served library
  # means a partially-written file is a file Jellyfin will try to open, and
  # "move to library when complete" is a separate, visible step rather than an
  # accident of directory permissions.
  systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    "d ${cfg.incompleteDir} 0750 qbittorrent media -"
    "d ${cfg.downloadDir} 0750 qbittorrent media -"
    "d ${cfg.libraryDir} 0750 media jellyfin -"
  ];

  # ── 1. The namespace ──────────────────────────────────────────────────────
  systemd.services.media-netns = lib.mkIf cfg.enable {
    description = "Create the media network namespace and its deny-by-default egress policy";
    after = ["network-pre.target"];
    before = ["media-tunnel.service" "qbittorrent.service"];
    wantedBy = ["multi-user.target"];
    unitConfig.DefaultDependencies = false;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = netnsEnv;
      ExecStart = "${pkgs.runtimeShell} ${./scripts/netns-up.sh}";
      # The namespace is the security boundary; if it takes longer than this
      # something is wrong, and a half-built namespace must not linger.
      TimeoutStartSec = "30s";
    };

    # RequiredBy, not Wants: if the namespace cannot be built there is no tunnel
    # and no client, and that has to be a failure rather than a service that
    # starts and quietly does nothing.
    requiredBy = ["media-tunnel.service" "qbittorrent.service"];
  };

  # ── 2. The tunnel, INSIDE the namespace ───────────────────────────────────
  #
  # Root, because bringing up a WireGuard interface needs CAP_NET_ADMIN — but
  # confined to the namespace by NetworkNamespacePath, so it has no authority
  # over the host's interfaces at all. Splitting it out of the client is what
  # lets the client itself run unprivileged.
  systemd.services.media-tunnel = lib.mkIf cfg.enable {
    description = "WireGuard tunnel inside the media namespace";
    after = ["media-netns.service"];
    requires = ["media-netns.service"];
    partOf = ["media-netns.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      NetworkNamespacePath = "/run/netns/${cfg.namespace}";
      # AssertPathExists on the CREDENTIAL, so a machine that was never
      # provisioned fails this unit loudly instead of starting a tunnel that
      # quietly never connects. sops-nix resolves the path at build time whether
      # or not the file exists, so the check has to live here.
      AssertPathExists = [
        "${cfg.tunnel.configSecretPath}"
        "${cfg.proxyTokenSecretPath}"
      ];
      LoadCredential = "wg.conf:${config.sops.secrets.MEDIA_WG_CONFIG.path}";
      Environment = netnsEnv;
      # wg-quick wants the config on disk, and $CREDENTIALS_DIRECTORY is
      # private to this service and per-invocation. The copy is into
      # PrivateTmp, so it never lands on a world-readable filesystem.
      ExecStartPre = "${pkgs.coreutils}/bin/install -m 0600 %d/wg.conf /tmp/wg-media.conf";
      ExecStart = lib.escapeShellArgs [
        "${pkgs.wireguard-tools}/bin/wg-quick"
        "up"
        "/tmp/wg-media.conf"
      ];
      ExecStop = "${pkgs.wireguard-tools}/bin/wg-quick down /tmp/wg-media.conf";
      # Removes the copied config. Without this the private key outlives the
      # service in a tmpfs that anything on the host can read.
      ExecStopPost = "${pkgs.coreutils}/bin/sh -c 'rm -f /tmp/wg-media.conf'";
      # Shaping is applied here rather than in qBittorrent's settings because
      # the tunnel is where the limit belongs: it applies to every client
      # configuration and cannot be raised from a web UI.
      ExecStartPost = lib.mkIf (cfg.uploadLimitKbit != null) pkgs.runtimeShell + '' -c ${tcUnit}'';
      PrivateTmp = true;
      TimeoutStartSec = "30s";
    };
  };

  # ── 3. Prove the namespace is closed before anything runs in it ──────────
  #
  # A oneshot that reads back the installed policy and FAILS if it is not what
  # was asked for. `media-tunnel` and `qbittorrent` both require it, so a
  # namespace that came up permissive does not get a client in it — the check
  # is a gate, not a report.
  systemd.services.media-netns-audit = lib.mkIf cfg.enable {
    description = "Assert the media namespace is fail-closed";
    after = ["media-netns.service"];
    requires = ["media-netns.service"];
    before = ["qbittorrent.service"];
    partOf = ["media-netns.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = netnsEnv;
      ExecStart = "${pkgs.runtimeShell} ${./scripts/netns-audit.sh}";
      TimeoutStartSec = "30s";
    };
  };

  # ── 4. The client ─────────────────────────────────────────────────────────
  #
  # Unprivileged, in the namespace, and BOUND TO THE TUNNEL.
  #
  # The binding is defence in depth and is described as such in netns-up.sh's
  # header: it covers the paths that go through this socket, and it is not what
  # stops a leak — the namespace's DROP policy is. What the binding usefully
  # adds is that a misconfiguration of the firewall still cannot let this
  # specific process out, and that it is visibly wrong in `ss` output rather
  # than invisible.
  systemd.services.qbittorrent = lib.mkIf cfg.enable {
    description = "qBittorrent (unprivileged, confined to the media namespace)";
    after = ["media-netns-audit.service"];
    requires = ["media-netns-audit.service"];
    partOf = ["media-netns.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = "qbittorrent";
      Group = "qbittorrent";
      WorkingDirectory = cfg.incompleteDir;
      NetworkNamespacePath = "/run/netns/${cfg.namespace}";
      # No new privileges, no ambient capabilities: the client needs none, and
      # the tunnel's CAP_NET_ADMIN lives in a different unit for that reason.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [cfg.incompleteDir cfg.downloadDir cfg.stateDir];
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryMax = cfg.resources.memoryMax;
      CPUQuota = cfg.resources.cpuQuota;

      # Fails the unit rather than skipping it when a media directory is absent,
      # because "skipped" and "failed" look alike in `systemctl list-units` and
      # the difference decides whether anything is running with no media volume.
      AssertPathIsDirectory = [cfg.incompleteDir cfg.downloadDir];

      ExecStart = lib.escapeShellArgs [
        (lib.getExe cfg.package)
        # Bound to the tunnel. Fails to connect when the tunnel is absent,
        # which is the correct behaviour: no tunnel, no downloads.
        "--interface"
        cfg.tunnel.interface
        "--webui-port=${toString cfg.webuiPort}"
      ];
      ExecStopPost = "${pkgs.coreutils}/bin/rm -rf ${cfg.stateDir}";
      Restart = "on-failure";
      RestartSec = "10s";
      # Startup order matters: network (the namespace) before the client.
      StartLimitIntervalSec = 0;
    };
  };

  # ── 5. The one way in, from loopback only ─────────────────────────────────
  #
  # A browser cannot speak WireGuard, so the WebUI has to be reachable — and it
  # is reachable from exactly one place: 127.0.0.1 on this host. The script
  # refuses to bind anything else at start-up rather than trusting the
  # environment, and it requires a token from a systemd credential before it will
  # serve a single request.
  #
  # Runs as the OPERATOR, not as root and not as qbittorrent: it is a management
  # surface and belongs in the management class. It holds a credential and
  # nothing else, and it can reach the namespace and the host's own loopback and
  # nothing beyond.
  systemd.services.media-webui-proxy = lib.mkIf cfg.enable {
    description = "Authenticated loopback-only proxy to the namespace WebUI";
    after = ["qbittorrent.service"];
    wants = ["qbittorrent.service"];
    wantedBy = ["multi-user.target"];

    serviceConfig = {
      Type = "simple";
      User = opts.username;
      LoadCredential = "proxy-token:${config.sops.secrets.MEDIA_WEBUI_TOKEN.path}";
      Environment = {
        MEDI_PROXY_LISTEN_HOST = "127.0.0.1";
        MEDI_PROXY_LISTEN_PORT = toString cfg.proxyPort;
        MEDI_PROXY_BACKEND_HOST = cfg.vethAddr;
        MEDI_PROXY_BACKEND_PORT = toString cfg.webuiPort;
        # %d is the private, per-service credential directory.
        MEDI_PROXY_TOKEN_FILE = "%d/proxy-token";
      };
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/webui-proxy.py}";
      Restart = "on-failure";
      RestartSec = "5s";
      # Loopback is a socket, not a firewall rule, so this needs no host
      # firewall entry and no trustedInterfaces change.
      IPAddressAllow = "localhost";
      IPAddressDeny = "any";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryMax = "256M";
    };
  };


  # `AssertPathIsDirectory` makes the unit FAIL rather than skip. A skipped unit
  # and a failed unit look identical in `systemctl list-units` at a glance, and
  # the difference decides whether anything is running in a namespace with no
  # media volume mounted. It is written inside the qBittorrent unit above
  # rather than as a second `systemd.services.qbittorrent` — two definitions of
  # one attribute is "already defined", not a merge.

  # ── Refusals ──────────────────────────────────────────────────────────────
  assertions = [
    {
      # A name that is not numeric cannot be validated by netns-up.sh, which
      # is the only thing standing between a hostname and a bootstrap leak.
      assertion = !cfg.enable || lib.hasInfix "." cfg.tunnel.endpoint;
      message = ''
        media: opts.media.torrents.tunnel.endpoint = "${cfg.tunnel.endpoint}"
        does not look like NUMERIC-IP:PORT.

        The endpoint is pinned numerically on purpose: a hostname would need a
        DNS query to leave the namespace through the veth before the tunnel
        exists, which is precisely the leak the namespace prevents.

        Resolve it on the host once and paste the result:
          getent ahosts <provider-host> | head -1
      '';
    }

    {
      # 8080 is qBittorrent's own default and a famously scanned port. It is not
      # reachable from outside here, but keeping the default invites someone
      # later to "fix" reachability by opening it.
      assertion = cfg.webuiPort != 8080 || cfg.proxyPort != 8080;
      message = ''
        media: the WebUI or proxy port is qBittorrent's default 8080. Pick
        something else; a well-known admin port is the wrong thing to be
        reachable at, even by accident.
      '';
    }

    {
      assertion = !cfg.enable || opts.media.jellyfin.enable
        || cfg.downloadDir != opts.media.jellyfin.libraryDir;
      message = ''
        media: the torrent download directory is the Jellyfin library directory.

        These must be different directories. A file still being written into the
        download directory would then be a file Jellyfin tries to open, and the
        failure appears inside Jellyfin as an unreadable item rather than as the
        storage mistake it is.
      '';
    }
  ];

  warnings =
    lib.optional (cfg.enable && cfg.uploadLimitKbit == null) ''
      media: opts.media.torrents.uploadLimitKbit is null, so there is NO upload
      cap on the tunnel.

      Seeding is unlimited, which competes directly with everything else this
      machine is for — remote builds, SSH, and streaming over the tailnet. A
      full upstream turns the tailnet into a symptom rather than a cause.

      Measure the home upstream from where you will actually be (docs/media-travel.md
      § "Measuring bandwidth"), reserve headroom for management, and set a
      value. 20–30%% of measured upstream is the starting point, not a
      recommendation.
    ''
    ++ lib.optional (cfg.enable && opts.headless && cfg.proxyPort != 0) ''
      media: the torrent WebUI proxy is enabled on a SERVER host. It binds
      127.0.0.1 only and is token-gated, but anything on this host that can read
      ${cfg.stateDir} or the systemd credential directory can reach it. That is
      a deliberate widening of what "local" means on a machine reached only over
      SSH.
    '';

  # ── Operational visibility ────────────────────────────────────────────────
  #
  # Reuses the backup lane's sources list so a qBittorrent library survives a
  # restore; the export itself is media/default.nix's, because the export has to
  # outlive the run to be verifiable.
  agentOps.backup = lib.mkIf (cfg.enable && opts.agentOps.backup.enable) {
    sources = [{paths = [cfg.stateDir];}];
  };
}