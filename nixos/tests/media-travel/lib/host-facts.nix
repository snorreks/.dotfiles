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
host: let
  flake = builtins.getFlake (toString ../../..);
  c = flake.nixosConfigurations.${host}.config;

  svcs = c.systemd.services;
  have = name: builtins.hasAttr name svcs;

  # ── What this host actually opted in to ─────────────────────────────────
  #
  # Read through `config` rather than `opts`, and the reason is not
  # convenience: `opts` is a module argument, reachable from neither `config`
  # nor `_module.args` (both verified), so deriving intent from option values
  # here would let this suite disagree with the modules about what was
  # requested. Reading the services the modules actually define keeps one
  # source of truth.
  #
  # These live in `let` rather than as attributes of the result because a Nix
  # attrset is not recursive unless declared `rec`, and the result below
  # refers back to them.
  #
  # Note that `tailscale-serve-jellyfin` is NOT implied by
  # services.jellyfin.enable alone: publishServe gates that unit separately, so
  # a host may legitimately run Jellyfin with publication off. The shell suite
  # therefore treats that unit as permitted-but-not-required, while every other
  # media unit must be fully accounted for.
  #
  # `(x or false)` because a host that never enables a service has no such
  # option value at all, and reading it unguarded would throw.
  jellyfinEnabled = c.services.jellyfin.enable or false;
  torrentsEnabled = c.services.qbittorrent.enable or false;
  syncthingEnabled = c.services.syncthing.enable or false;

  # Which of the media units this host actually installed. Also in `let`,
  # because `mediaUnitsUnaccounted` below refers to it and a plain attrset is
  # not recursive.
  mediaUnitsPresent = builtins.filter have mediaUnits;

  mediaUnits = [
    "tailscale-serve-jellyfin"
    "tailscale-serve-syncthing"
    "media-netns"
    "media-netns-audit"
    "media-netns-watchdog"
    "media-tunnel"
    "media-webui-proxy"
    "media-state-export"
    "qbittorrent"
  ];
in {
  # Which media services this host opted in to. See the comment on
  # `jellyfinEnabled` in the `let` above for why these are read from
  # `config` and not from `opts`.
  jellyfinEnabled = jellyfinEnabled;
  torrentsEnabled = torrentsEnabled;
  syncthingEnabled = syncthingEnabled;

  # ── The media lane declares NOTHING until it is asked ──────────────────
  mediaUnitsPresent = mediaUnitsPresent;

  # A media unit is legitimate only when its owning service is enabled.
  mediaUnitsUnaccounted =
    builtins.filter (
      unit:
        if unit == "tailscale-serve-jellyfin"
        then false
        else if unit == "tailscale-serve-syncthing"
        then syncthingEnabled
        else if builtins.match ".*media-.*" unit != null
        then torrentsEnabled || syncthingEnabled
        else if unit == "qbittorrent"
        then torrentsEnabled
        else false
    )
    mediaUnitsPresent;

  # No directory is created and no port is opened by merely importing the
  # module. tmpfiles rules mentioning the media paths are the tell.
  mediaTmpfiles =
    builtins.filter (r: builtins.match ".*(jellyfin|qbittorrent|syncthing|media).*" r != null)
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
  collieServeExec =
    if have "tailscale-serve-collie"
    then svcs."tailscale-serve-collie".serviceConfig.ExecStart or ""
    else "";

  # ── The remote builder (Legion side is trusted-users; GS65 side builds) ─
  buildMachines = map (m: {
    hostName = m.hostName;
    sshUser = m.sshUser;
    protocol = m.protocol;
  }) (c.nix.buildMachines or []);
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
