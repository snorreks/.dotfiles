# nixos/tests/media-travel/lib/host-facts.nix
#
# Evaluates the REAL host configurations and reduces them to the facts the
# shell suites assert on.
#
# ── What is asserted, and why it is the DEFAULT configuration ─────────────
# This lane's contract is that every media service is opt-in and that a host
# which has not opted in is bit-for-bit unaffected by the code being here. That
# is an unusual thing to have to prove and an easy thing to break: an import
# that always declares a firewall port, a tmpfiles rule that creates a
# directory, or a systemd unit that starts with no configuration all look
# harmless and are exactly the regressions this file exists to catch.
#
# So these facts are read from the shipping configuration, with nothing forced
# on. A non-empty answer where an empty one is expected is a finding.
#
# The media-ENABLED invariants (what the namespace looks like once someone opts
# in) are covered elsewhere and differently: netns-failclosed.sh drives the
# SHIPPED netns-up.sh and asserts the netfilter calls it makes, and the modules
# themselves refuse the configurations that would be unsafe. See the note in
# run.sh about the forced-enable evaluation being recorded as pending.
#
# Invoked as:
#   nix eval --raw --impure --expr \
#     'builtins.toJSON ((import ./lib/host-facts.nix) "legion")'
host:
let
  flake = builtins.getFlake (toString ../../..);
  c = flake.nixosConfigurations.${host}.config;

  svcs = c.systemd.services;
  have = name: builtins.hasAttr name svcs;

  mediaUnits = [
    "tailscale-serve-jellyfin"
    "tailscale-serve-syncthing"
    "media-netns"
    "media-netns-audit"
    "media-tunnel"
    "media-webui-proxy"
    "media-state-export"
    "qbittorrent"
  ];
in
  {
    # ── The media lane declares NOTHING until it is asked ──────────────────
    mediaUnitsPresent = builtins.filter have mediaUnits;

    # No directory is created and no port is opened by merely importing the
    # module. tmpfiles rules mentioning the media paths are the tell.
    mediaTmpfiles = builtins.filter (r: builtins.match ".*(jellyfin|qbittorrent|syncthing|media).*" r != null)
      (c.systemd.tmpfiles.rules or []);

    # ── The host firewall is untouched ─────────────────────────────────────
    allowedTCPPorts = map toString (c.networking.firewall.allowedTCPPorts or []);
    trustedInterfaces = c.networking.firewall.trustedInterfaces;

    # NixOS' nftables backend declares no OUTPUT policy at all, so "the host
    # OUTPUT policy is unchanged" is checkable as "this lane added no firewall
    # interface and no global port".
    firewallInterfaces = builtins.attrNames (c.networking.firewall.interfaces or {});

    # ── Collie keeps 443 ───────────────────────────────────────────────────
    collieServeUnit = have "tailscale-serve-collie";
    collieServeExec = if have "tailscale-serve-collie" then svcs."tailscale-serve-collie".serviceConfig.ExecStart or "" else "";

    # ── The remote builder (Legion side is trusted-users; GS65 side builds) ─
    buildMachines = map (m: {hostName = m.hostName; sshUser = m.sshUser; protocol = m.protocol;}) (c.nix.buildMachines or []);
    trustedUsers = c.nix.settings.trusted-users;

    # How the builder's PORT is pinned. It cannot live in `hostName`:
    # /etc/nix/machines is whitespace-split, so "-p 2222" there shifts the
    # system/sshKey/maxJobs fields and silently un-advertises the builder.
    nixDaemonSshOpts = c.systemd.services.nix-daemon.environment.NIX_SSHOPTS or "";
    sshdPorts = c.services.openssh.ports;
    pinnedKnownHosts = c.home-manager.users.sonny.home.file.".ssh/known_hosts.travel".text or "";

    # ── The travel laptop ──────────────────────────────────────────────────
    #
    # Observed through the CONFIGURATION rather than through `opts`: `opts` is
    # a module argument and is not reachable from `config`, and re-deriving it
    # here would let the suite disagree with the module about what was asked
    # for. The SSH block and the builder machine string are the two things that
    # actually reach a running system, so they are what gets asserted, and the
    # shell suite does the matching.
    sshExtraConfig = c.home-manager.users.sonny.programs.ssh.extraConfig or "";
  }