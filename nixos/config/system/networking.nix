# nixos/config/system/networking.nix
# This file configures network settings, DNS, firewall, and related services.
{
  opts,
  pkgs,
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
  # services.tailscale.enable = true;

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
      wifi.macAddress = "random";

      # Tell NetworkManager to ignore DNS, as dnscrypt-proxy2 will handle it.
      dns = "none";
    };

    # Point the system's resolver to the local dnscrypt-proxy2 service.
    nameservers = ["127.0.0.1" "::1"];

    # Allows wg-quick to manage /etc/resolv.conf for DNS during VPN connections.
    resolvconf.enable = true;

    # Enable the system firewall.
    firewall = {
      enable = true;
      # "loose" mode prevents the kernel from dropping incoming WireGuard
      # handshake packets that arrive on a different interface than expected.
      # Required for VPNs where traffic may be asymmetric.
      checkReversePath = "loose";
      # NOTE: You can define specific open ports here if needed, for example:
      allowedTCPPorts = [11434 8188];
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

  # Enables the OpenSSH server for remote access.
  services.openssh = {
    enable = true;
    # SECURITY NOTE: Ensure this is intentional. If you do not need to SSH *into* this laptop
    # from other devices, it's best practice to keep this disabled (`enable = false;`)
    # to reduce the system's attack surface.
  };
}
