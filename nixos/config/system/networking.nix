# nixos/config/system/networking.nix
# This file configures network settings, DNS, firewall, and related services.
{
  opts,
  pkgs,
  lib,
  ...
}: {
  # System packages needed for wg-quick DNS management
  environment.systemPackages = with pkgs; [
    openresolv
    wireguard-tools
  ];

  # Passwordless sudo for VPN actions triggered from Waybar (no TTY).
  # Required so toggle_vpn.sh and vpn-connect.sh can start/stop the
  # WireGuard service and copy configs without hanging on a password prompt.
  # Uses /run/current-system/sw/bin/ paths which are stable across rebuilds
  # (unlike Nix store paths which change). Scripts must use these same paths.
  # In networking.nix
  security.sudo.extraRules = [
    {
      users = [opts.username];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl start wg-quick-wg0.service";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop wg-quick-wg0.service";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/wg show wg0 latest-handshakes";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/cp /home/${opts.username}/.vpn/configs/*.conf /etc/nixos/proton-wg.conf";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  # --- VPN START
  # Tailscale now lives in config/system/server.nix (it is infrastructure for
  # reaching the headless host, not an on-demand VPN like the one below).
  #
  # WARNING, on the headless host: never start wg-quick-wg0 remotely. Its
  # kill-switch below REJECTs all output that is not marked for wg0, which
  # includes the tailnet — it would cut the only way back in. autostart is
  # false and it is not wantedBy multi-user.target, so this only happens if
  # someone runs it by hand.

  # This service will manage the connection using your config file
  networking.wg-quick.interfaces.wg0 = {
    # This tells NixOS to use the config file you just created
    configFile = "/etc/nixos/proton-wg.conf";

    # This option defaults to 'true'. Setting it to 'false'
    # prevents the wg-quick-wg0.service from being enabled at boot.
    autostart = false;

    # (Optional but Recommended)
    # Kill-switch: Block all traffic if the VPN is not active.
    # This uses the "AllowedIPs" from your config file.
    postUp = ''
      ${pkgs.iptables}/bin/iptables -I OUTPUT ! -o %i -m mark --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
    '';
    preDown = ''
      ${pkgs.iptables}/bin/iptables -D OUTPUT ! -o %i -m mark --mark $(wg show %i fwmark) -m addrtype ! --dst-type LOCAL -j REJECT
    '';
  };

  # The wg-quick service needs to start after networking is up
  # Commented out since we don't want it enabled by default
  # systemd.services."wg-quick-wg0".wantedBy = ["multi-user.target"];
  # systemd.services."wg-quick-wg0".after = ["network-online.target"];

  # --- VPN END

  # --- Networking Configuration ---
  # All general networking options are consolidated into this single block.

  networking = {
    # Sets the machine's hostname from your central options file.
    hostName = "${opts.hostname}";

    # RECOMMENDATION: Keep IPv6 enabled globally. Disabling it can break modern services.
    # Any application-specific bugs (like with `bun`) should be investigated at the
    # application level, as they are often fixed in newer versions.
    enableIPv6 = true;

    # NetworkManager is essential for laptops that move between different networks.
    networkmanager = {
      enable = true;

      # OPTIMIZATION: Enhance privacy on Wi-Fi by using a random MAC address.
      #
      # Except on a headless host, where it is a liability rather than a
      # privacy win: a fresh MAC on every reconnect means a fresh DHCP lease
      # and potentially a new IP each time, and the machine is joining one
      # trusted network and staying there for months. Pin it so the router
      # (and any reservation on it) sees a stable client.
      wifi.macAddress =
        if opts.headless
        then "permanent"
        else "random";

      # Tell NetworkManager to ignore DNS, as dnscrypt-proxy2 will handle it.
      dns = "none";
    };

    # Point the system's resolver to the local dnscrypt-proxy2 service.
    #
    # On a headless host, append public resolvers behind it. This is a
    # deliberate privacy-for-availability trade and only applies there: with
    # dns = "none" and a loopback-only resolver, dnscrypt-proxy failing to come
    # up after an unattended reboot leaves the machine with NO name resolution
    # at all — including for controlplane.tailscale.com, which is how we get
    # back in. glibc tries these in order, so they are only consulted when the
    # local resolver does not answer; in normal operation nothing changes.
    nameservers =
      ["127.0.0.1" "::1"]
      ++ lib.optionals opts.headless [
        "9.9.9.9" # Quad9
        "1.1.1.1" # Cloudflare
        "2620:fe::fe"
      ];

    # Allows wg-quick to manage /etc/resolv.conf for DNS during VPN connections.
    resolvconf.enable = true;

    # Enable the system firewall.
    firewall = {
      enable = true;
      # "loose" mode prevents the kernel from dropping incoming WireGuard
      # handshake packets that arrive on a different interface than expected.
      # Required for VPNs where traffic may be asymmetric.
      #
      # mkForce because the tailscale module also sets this option (to the same
      # value) whenever useRoutingFeatures includes "client". checkReversePath
      # is not a mergeable type, so two plain definitions would be an eval
      # conflict rather than a no-op.
      checkReversePath = lib.mkForce "loose";

      # 11434 = ollama, 8188 = ComfyUI. Both speak unauthenticated HTTP, so on
      # a headless host they are NOT exposed to the LAN it sits on — that is a
      # family network full of devices we do not control, and anyone on it
      # could otherwise drive the GPU. The services still listen on 0.0.0.0;
      # server.nix trusts tailscale0 instead, so our own machines reach them
      # over the tailnet and nothing else can.
      allowedTCPPorts = lib.optionals (!opts.headless) [11434 8188];
    };
  };

  # --- DNS and Security Services ---

  # Configures a local, encrypted, and secure DNS resolver.
  services.dnscrypt-proxy = {
    enable = true;
    settings = {
      listen_addresses = ["127.0.0.1:53" "[::1]:53"];
      ipv6_servers = true;
      require_dnssec = true;

      # Resolvers used only to look up the encrypted resolvers' own hostnames.
      # Without these, dnscrypt-proxy asks the system resolver — which is
      # itself, via nameservers = 127.0.0.1 — and a cold boot with a stale
      # cache can deadlock into never becoming ready.
      bootstrap_resolvers = ["9.9.9.9:53" "1.1.1.1:53"];
      ignore_system_dns = true;

      # Wait for the network instead of giving up: on an unattended boot the
      # link is frequently not up yet when the service starts.
      netprobe_timeout = 60;

      # A curated list of high-quality, non-logging resolvers with security filtering.
      server_names = [
        "quad9-dnscrypt-ip4-filter-pri" # Security filtering, non-logging, based in Switzerland.
        "nextdns" # Highly configurable, good performance.
        "mullvad-adblock-doh" # Strong privacy, ad-blocking, from a trusted VPN provider.
        "adguard-dns-doh" # Good ad and tracker blocking.
      ];

      # Source list for public resolvers. This is standard.
      sources.public-resolvers = {
        urls = [
          "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
          "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
        ];
        cache_file = "/var/lib/dnscrypt-proxy2/public-resolvers.md";
        minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
      };
    };
  };

  # dnscrypt-proxy is a single point of failure for the whole machine's name
  # resolution (dns = "none" above means nothing else answers). Upstream's unit
  # gives up after the default start-limit burst; on a host we cannot reach a
  # console for, keep retrying forever instead.
  systemd.services.dnscrypt-proxy.serviceConfig = {
    Restart = lib.mkForce "always";
    RestartSec = "10s";
    StartLimitBurst = 0;
  };

  # Enables the OpenSSH server for remote access.
  services.openssh = {
    enable = true;
    # SECURITY NOTE: Ensure this is intentional. If you do not need to SSH *into* this laptop
    # from other devices, it's best practice to keep this disabled (`enable = false;`)
    # to reduce the system's attack surface.
  };
}
