# nixos/config/system/networking.nix
# This file configures network settings, DNS, firewall, and related services.
{
  opts,
  pkgs,
  lib,
  ...
}: let
  # The DNS owner and its rescue list are decided in ONE place, together, so
  # the list and the cap on how much of it is used cannot drift apart:
  # nixos/lib/host-policy.nix (dnsPolicy). Read its header for why the cap
  # matters — it is not a style preference, it is the difference between a
  # rescue path existing and being silently discarded.
  #
  # Imported rather than passed through specialArgs: it is a pure function of
  # two booleans, and a second import path for it would only create a second
  # thing that could be edited without the test noticing.
  dnsPolicy = (import ../../lib/host-policy.nix).dnsPolicy;
  dns = dnsPolicy {headless = opts.headless;};
in {
  # System packages needed for wg-quick DNS management
  environment.systemPackages = with pkgs; [
    openresolv
    wireguard-tools

    # Herdr's agent-state hooks are shell scripts that shell out to python3 —
    # ~/.claude/hooks/herdr-agent-state.sh and the per-agent equivalents. The
    # guard on that is `command -v python3 >/dev/null || exit 0`, which is why
    # this failure is invisible: without python3 the hook EXITS 0 while doing
    # nothing, so herdr never learns which pane an agent session belongs to and
    # `collie doctor` is the only thing that reports it (`error: hook-python3`).
    #
    # SYSTEM-WIDE, not home.packages, and that is the load-bearing choice: an
    # agent's hook runs inside a herdr pane, and panes inherit the server's
    # environment. herdr starts at boot under the lingering user manager with no
    # login session behind it, so /run/current-system/sw/bin is the only PATH
    # that is reliably present. The desktop PATH also has it after a rebuild,
    # but the boot-time one would not.
    python3
  ];

  # ── Passwordless sudo for VPN actions (desktop hosts only) ──────────────────
  #
  # Required so toggle_vpn.sh and vpn-connect.sh can start/stop the WireGuard
  # service and copy configs without hanging on a password prompt. Uses
  # /run/current-system/sw/bin/ paths, which are stable across rebuilds (unlike
  # Nix store paths, which change). Scripts must use these same paths.
  #
  # 🔴 STRUCTURALLY ABSENT ON A SERVER, and that is the whole point. These four
  # rules are a remote-code-shaped privilege: any process running as
  # ${opts.username} can write an arbitrary WireGuard config to
  # /etc/nixos/proton-wg.conf and then start the interface that reads it. On a
  # machine whose only ingress is the tailnet, "the process you reached over
  # SSH" is exactly the thing an attacker would be, and handing it NOPASSWD on
  # the tunnel that also carries the tailnet is a privilege boundary made of
  # paper.
  #
  # On a server role the mutating toggles are therefore not merely discouraged
  # — there is nothing to call. config/home/scripts/scripts/kill-switch.sh and
  # the Waybar VPN control call these commands through sudo; with no rule they
  # fail with "sudo: a password is required", which is a visible, correct
  # outcome. The Proton kill-switch below is gone for the same reason and with a
  # sharper edge: its postUp REJECTs every packet not marked for wg0, the
  # tailnet included, so on an unattended host starting it is a lockout with a
  # five-second fuse.
  #
  # If a server role ever does need the tunnel, the answer is a per-host opt-in
  # that has been thought about — not this default becoming true again.
  security.sudo.extraRules =
    lib.optional (!opts.headless) {
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
    };

  # --- VPN START
  # Tailscale now lives in config/system/server.nix (it is infrastructure for
  # reaching the headless host, not an on-demand VPN like the one below).
  #
  # WARNING, on the headless host: never start wg-quick-wg0 remotely. Its
  # kill-switch below REJECTs all output that is not marked for wg0, which
  # includes the tailnet — it would cut the only way back in. autostart is
  # false and it is not wantedBy multi-user.target, so this only happens if
  # someone runs it by hand.

  # This service will manage the connection using your config file.
  #
  # 🔴 Desktop hosts only. On a server role the interface does not exist at all
  # — see the sudo rules above for the reasoning. This is a structural
  # exclusion, not a documented convention: a config file left behind in
  # /etc/nixos, a stray `systemctl start`, or a Waybar click all hit the same
  # wall, which is a missing unit rather than a policy somebody has to remember.
  networking.wg-quick.interfaces.wg0 = lib.mkIf (!opts.headless) {
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
    # ── One DNS owner, and a rescue list that is not silently truncated ────────
    # `nameservers` and `resolvconf.extraOptions.maxnames` are computed together
    # in dnsPolicy and come from the same function, because the two have to
    # agree: resolv.conf(5) caps how many nameservers a resolver will consult
    # (MAXNS), everything past the cap is DISCARDED rather than ignored, and
    # openresolv — which NixOS installs here — applies a default of its own.
    # This file used to list five nameservers and set no cap at all, so the
    # three public rescue addresses were truncated away by the very mechanism
    # meant to use them: on the host where losing dnscrypt-proxy means losing
    # name resolution entirely, including for controlplane.tailscale.com, the
    # fallback was not there. `maxnames` is now the length of the list, always.
    #
    # The rescue addresses are NUMERIC on purpose. A resolver address that is a
    # hostname depends on DNS working to be reachable, which is exactly the
    # condition the rescue exists for. They are plain UDP-on-53 resolvers, not
    # DoH and not anything encrypted, so this is availability, not privacy:
    # dnscrypt-proxy is the privacy half and is asked first every time.
    #
    # They apply to a server role only. A travel laptop on hotel wifi is better
    # off not sending every lookup to a public resolver the moment its local
    # cache misses.
    nameservers = dns.nameservers;

    # Allows wg-quick to manage /etc/resolv.conf for DNS during VPN connections.
    resolvconf.enable = true;

    # The cap, stated. `maxnames N` goes into the `options` line of
    # /etc/resolv.conf, where glibc reads it — which is why this is a
    # resolv.conf OPTION and not an openresolv.conf setting: the number that
    # matters is the one the libc actually uses.
    resolvconf.extraOptions = [
      "maxnames ${toString dns.maxnames}"
    ];

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
  # resolution (dns = "none" above means nothing else answers). Keep retrying
  # forever rather than giving up after a burst.
  #
  # 🔴 StartLimitBurst used to be set HERE, under serviceConfig, where it does
  # nothing. StartLimitIntervalSec and StartLimitBurst are [UNIT] directives:
  # systemd does not read them from [Service], so that line was silently inert
  # and the unit kept systemd's default of 5 starts in 10s — which a resolver
  # that takes longer to fail than that will blow through on a cold boot, and
  # then the machine has no DNS at all until something restarts it. unitConfig is
  # where nixpkgs' own modules put them for the same reason.
  #
  # The delay is bounded rather than instant so a resolver that is waiting on a
  # link which has not come up yet does not spin: the sequence is 5s, 10s, 20s,
  # 40s … capped at two minutes, forever.
  systemd.services.dnscrypt-proxy = {
    # [Unit], as it must be. See above: this used to be a StartLimitBurst under
    # serviceConfig, which systemd does not read there, so it was never in
    # effect. 0 = rate limiting off, which is what "keep retrying forever"
    # actually means; the backoff below is what keeps that from spinning.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = "5s";
      RestartSteps = 5;
      RestartStepSec = "5s";
      RestartMaxDelaySec = "120s";
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
