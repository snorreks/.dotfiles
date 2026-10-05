# The UDP socket is born on the host; only the WireGuard interface moves.
# No host NAT, forwarding, sysctl or firewall policy changes.
{config, pkgs, lib, opts, ...}: let
  cfg = opts.media.torrents;
  backend = lib.head (lib.splitString "/" cfg.vethAddr);
  safeDirectory = path: lib.hasPrefix "/" path && path != "/"
    && !(lib.any (part: builtins.elem part ["" "." ".."]) (lib.tail (lib.splitString "/" path)));
  overlaps = a: b: a == b || lib.hasPrefix (a + "/") b || lib.hasPrefix (b + "/") a;
  package = if cfg.package == null then pkgs.qbittorrent-nox else cfg.package;
  runtime = [pkgs.iproute2 pkgs.iptables pkgs.procps pkgs.coreutils pkgs.python3 pkgs.wireguard-tools pkgs.systemd];
  environment = {
    MEDI_NS = cfg.namespace;
    MEDI_VETH_HOST = cfg.vethHost;
    MEDI_VETH_NS = cfg.veth;
    MEDI_HOST_ADDR = cfg.vethHostAddr;
    MEDI_NS_ADDR = cfg.vethAddr;
    MEDI_GATEWAY = cfg.gateway;
    MEDI_WG_IF = cfg.tunnel.interface;
    MEDI_WEBUI_PORT = toString cfg.webuiPort;
    MEDI_WG_ENDPOINT = cfg.tunnel.endpoint;
    MEDI_TUNNEL_ADDRESS = cfg.tunnel.address;
    MEDI_RESOLVER = cfg.tunnel.resolver;
  };
  setup = "${pkgs.runtimeShell} ${./scripts/netns-up.sh}";
  audit = "${pkgs.runtimeShell} ${./scripts/netns-audit.sh}";
  # Dedicated UID owns the token. A negative owner rule rejects ONLY NEW
  # connections to this backend via this interface; it never accepts traffic
  # or relaxes an existing host OUTPUT policy.
  guard = lib.escapeShellArgs ["-o" cfg.vethHost "-d" "${backend}/32" "-p" "tcp" "--dport" (toString cfg.webuiPort) "-m" "owner" "!" "--uid-owner" "media-webui-proxy" "-m" "conntrack" "--ctstate" "NEW" "-j" "REJECT"];
  clientConfig = pkgs.writeText "qBittorrent.conf" ''
    [LegalNotice]
    Accepted=true
    [Preferences]
    Connection\Interface=${cfg.tunnel.interface}
    Connection\InterfaceName=${cfg.tunnel.interface}
    Downloads\SavePath=${cfg.downloadDir}/
    Downloads\TempPath=${cfg.incompleteDir}/
    Downloads\TempPathEnabled=true
    WebUI\Address=${backend}
    WebUI\Port=${toString cfg.webuiPort}
    [BitTorrent]
    Session\Interface=${cfg.tunnel.interface}
    Session\DefaultSavePath=${cfg.downloadDir}/
    Session\TempPath=${cfg.incompleteDir}/
    Session\TempPathEnabled=true
  '';
in lib.mkIf cfg.enable {
  users.users.qbittorrent = {isSystemUser = true; group = "qbittorrent"; extraGroups = ["media"];};
  users.groups.qbittorrent = {};
  users.groups.media = {};
  users.users.media-webui-proxy = {isSystemUser = true; group = "media-webui-proxy";};
  users.groups.media-webui-proxy = {};
  networking.firewall.extraCommands = ''
    iptables -w -C OUTPUT ${guard} 2>/dev/null || iptables -w -I OUTPUT 1 ${guard}
  '';
  networking.firewall.extraStopCommands = ''
    iptables -w -D OUTPUT ${guard} 2>/dev/null || true
  '';
  sops.secrets.MEDIA_WG_CONFIG = {
    path = cfg.tunnel.configSecretPath;
    restartUnits = ["media-tunnel.service"];
  };
  sops.secrets.MEDIA_WEBUI_TOKEN = {
    path = cfg.proxyTokenSecretPath;
    restartUnits = ["media-webui-proxy.service"];
  };
  systemd.tmpfiles.rules = [
    "d ${cfg.incompleteDir} 0750 qbittorrent media -"
    "d ${cfg.downloadDir} 0750 qbittorrent media -"
    "d ${cfg.stateDir} 0700 qbittorrent qbittorrent -"
    "d ${cfg.configDir} 0700 qbittorrent qbittorrent -"
    "d ${cfg.configDir}/qBittorrent 0700 qbittorrent qbittorrent -"
  ];
  systemd.services.media-netns = {
    description = "Fail-closed torrent namespace (management-only veth)";
    wantedBy = ["multi-user.target"];
    before = ["media-netns-audit.service" "media-tunnel.service" "qbittorrent.service"];
    after = ["network-pre.target" "firewall.service"];
    requires = ["firewall.service"];
    path = runtime;
    inherit environment;
    serviceConfig = {Type = "oneshot"; RemainAfterExit = true; ExecStart = setup; TimeoutStartSec = "30s";};
  };
  systemd.services.media-netns-audit = {
    description = "Verify exact namespace filter allowlist";
    after = ["media-netns.service"];
    requires = ["media-netns.service"];
    bindsTo = ["media-netns.service"];
    partOf = ["media-netns.service"];
    before = ["media-tunnel.service" "qbittorrent.service"];
    path = runtime;
    inherit environment;
    serviceConfig = {Type = "oneshot"; RemainAfterExit = true; ExecStart = audit;};
  };
  # A separate non-remaining oneshot can run periodically. Starting the cached
  # startup-audit unit again would not re-execute its successful ExecStart.
  systemd.services.media-netns-watchdog = {
    description = "Stop only torrent services if namespace/owner guard drifts";
    after = ["media-netns.service" "firewall.service"];
    requires = ["media-netns.service"];
    path = runtime;
    inherit environment;
    script = ''
      if ! timeout 10 ${audit} || ! iptables -w 2 -C OUTPUT ${guard}; then
        systemctl stop qbittorrent.service media-tunnel.service
        exit 1
      fi
    '';
    serviceConfig = {Type = "oneshot"; TimeoutStartSec = "35s";};
  };
  systemd.timers.media-netns-watchdog = {
    wantedBy = ["timers.target"];
    timerConfig = {OnBootSec = "3min"; OnUnitActiveSec = "1min"; Persistent = false;};
  };
  systemd.services.media-tunnel = {
    description = "Host-born WireGuard UDP socket, namespace tunnel interface";
    wantedBy = ["multi-user.target"];
    after = ["media-netns-audit.service" "network-online.target"];
    requires = ["media-netns-audit.service"];
    bindsTo = ["media-netns.service"];
    partOf = ["media-netns.service"];
    before = ["qbittorrent.service"];
    path = runtime;
    inherit environment;
    unitConfig.AssertPathExists = cfg.tunnel.configSecretPath;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      LoadCredential = "wg.conf:${config.sops.secrets.MEDIA_WG_CONFIG.path}";
      ExecStartPre = audit;
      ExecStart = "${setup} tunnel-up";
      ExecStop = "${setup} tunnel-down";
      ExecStartPost = lib.optional (cfg.uploadLimitKbit != null)
        "${pkgs.iproute2}/bin/ip netns exec ${cfg.namespace} ${pkgs.iproute2}/bin/tc qdisc replace dev ${cfg.tunnel.interface} root tbf rate ${toString cfg.uploadLimitKbit}kbit latency 400ms burst 64kb";
      TimeoutStartSec = "30s";
    };
  };
  systemd.services.qbittorrent = {
    description = "Headless qBittorrent confined to the tunnel namespace";
    wantedBy = ["multi-user.target"];
    after = ["media-tunnel.service" "media-netns-audit.service"];
    requires = ["media-tunnel.service" "media-netns-audit.service"];
    bindsTo = ["media-netns.service" "media-tunnel.service"];
    partOf = ["media-netns.service" "media-tunnel.service"];
    unitConfig = {
      AssertPathIsDirectory = [cfg.incompleteDir cfg.downloadDir cfg.stateDir cfg.configDir];
      StartLimitIntervalSec = 0;
    };
    path = runtime;
    inherit environment;
    # Preserve password/resume data but re-pin security-sensitive settings.
    preStart = ''
      python3 - ${clientConfig} ${lib.escapeShellArg "${cfg.configDir}/qBittorrent/qBittorrent.conf"} <<'PY'
      import configparser, os, sys
      def parser():
          value = configparser.RawConfigParser(strict=False)
          value.optionxform = str
          return value
      desired, current = parser(), parser()
      desired.read(sys.argv[1])
      current.read(sys.argv[2])
      for section in desired.sections():
          if not current.has_section(section):
              current.add_section(section)
          for key, value in desired.items(section):
              current.set(section, key, value)
      temporary = sys.argv[2] + '.new'
      with open(temporary, 'w') as output:
          current.write(output, space_around_delimiters=False)
      os.chmod(temporary, 0o600)
      os.replace(temporary, sys.argv[2])
      PY
    '';
    serviceConfig = {
      Type = "simple";
      Slice = "system-mediaWorkload.slice";
      User = "qbittorrent";
      Group = "qbittorrent";
      # Prepare user-writable configuration as qbittorrent, never as root.
      # '+' audits with full privileges before the sandboxed
      # process starts; RestrictNamespaces otherwise blocks ip netns exec.
      ExecStartPre = ["+${audit}"];
      WorkingDirectory = cfg.stateDir;
      NetworkNamespacePath = "/run/netns/${cfg.namespace}";
      BindReadOnlyPaths = ["/etc/netns/${cfg.namespace}/resolv.conf:/etc/resolv.conf"];
      Environment = ["XDG_CONFIG_HOME=${cfg.configDir}" "XDG_DATA_HOME=${cfg.stateDir}" "HOME=${cfg.stateDir}"];
      ExecStart = lib.escapeShellArgs ["${package}/bin/qbittorrent-nox" "--webui-port=${toString cfg.webuiPort}"];
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [cfg.stateDir cfg.configDir cfg.incompleteDir cfg.downloadDir];
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      RestrictNamespaces = true;
      LockPersonality = true;
      MemoryMax = cfg.resources.memoryMax;
      CPUQuota = cfg.resources.cpuQuota;
    };
  };
  systemd.services.media-webui-proxy = {
    description = "Token-gated loopback WebUI proxy";
    wantedBy = ["multi-user.target"];
    after = ["qbittorrent.service" "firewall.service"];
    requires = ["firewall.service"];
    wants = ["qbittorrent.service"];
    environment = {
      MEDI_PROXY_LISTEN_HOST = "127.0.0.1";
      MEDI_PROXY_LISTEN_PORT = toString cfg.proxyPort;
      MEDI_PROXY_BACKEND_HOST = backend;
      MEDI_PROXY_BACKEND_PORT = toString cfg.webuiPort;
      MEDI_PROXY_TOKEN_FILE = "%d/proxy-token";
    };
    unitConfig.AssertPathExists = cfg.proxyTokenSecretPath;
    serviceConfig = {
      User = "media-webui-proxy";
      LoadCredential = "proxy-token:${config.sops.secrets.MEDIA_WEBUI_TOKEN.path}";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/webui-proxy.py}";
      Restart = "on-failure";
      IPAddressAllow = ["localhost" backend];
      IPAddressDeny = "any";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      MemoryMax = "256M";
    };
  };
  assertions = [
    {
      assertion = cfg.tunnel.address != "" && cfg.tunnel.resolver != "" && cfg.tunnel.endpoint != "";
      message = "media.torrents requires explicit IPv4 tunnel address, resolver and pinned endpoint";
    }
    {
      assertion = lib.all (name: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]{0,14}" name != null)
        [cfg.namespace cfg.vethHost cfg.veth cfg.tunnel.interface];
      message = "media.torrents requires safe namespace/interface names (max 15 characters)";
    }
    {
      assertion = builtins.isInt cfg.proxyPort && cfg.proxyPort > 0 && cfg.proxyPort <= 65535
        && !(builtins.elem cfg.proxyPort [22 2222 443]);
      message = "media.torrents.proxyPort must be a valid port that does not claim SSH or tailnet HTTPS";
    }
    {
      assertion = lib.all safeDirectory [cfg.stateDir cfg.configDir cfg.downloadDir cfg.incompleteDir opts.media.jellyfin.libraryDir]
        && !lib.any (path: overlaps path opts.media.jellyfin.libraryDir) [cfg.downloadDir cfg.incompleteDir];
      message = "media.torrents requires canonical absolute non-root directories; downloads/incomplete must not overlap the served library";
    }
  ];
  # media/default.nix registers only the quiesced export tree. Never register
  # live profile directories or an untyped { paths = ...; } backup source.
}
