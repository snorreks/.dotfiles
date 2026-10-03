# nixos/config/system/server.nix
#
# Everything needed to run a host as an always-on machine that is only ever
# reached remotely, plus the tailnet plumbing every host needs in order to
# reach it. Gated on opts.headless; see docs/headless-server.md for the
# one-time steps that cannot be expressed declaratively (BIOS, tailnet login).
#
# The guiding constraint: when this box is in a basement on another continent,
# the only recovery path that does not involve talking a parent through a boot
# menu is "it came back up on its own". So every choice here favours coming
# back over being clever.
#
# The update/rollback workflow used to live here too, as `nswitch-safe`. It is
# gone: it armed its dead-man timer before building and rolled back by
# rebooting, which on a remote host means a slow build kills the server and a
# half-applied activation gets declared safe. Its replacement is the explicit,
# reboot-free transaction in config/system/maintenance.nix (ns-maint), and
# docs/headless-server.md describes the operator side of it.
{
  pkgs,
  lib,
  opts,
  ...
}: let
  headless = opts.headless;
in {
  # ── Tailnet ────────────────────────────────────────────────────────────────
  # On every host, not just the server: this is how the travel laptop reaches
  # the basement at all. Tailscale dials out, so the parents' router, its NAT,
  # CGNAT and any number of wifi resets are all irrelevant — there is nothing
  # to port-forward and nothing to keep working.
  services.tailscale = {
    enable = true;
    openFirewall = true;

    # "server" turns on IP forwarding, needed to advertise an exit node.
    # "client" is what lets this host route its traffic *through* one.
    useRoutingFeatures =
      if headless
      then "server"
      else "client";

    # Applied by the tailscaled-set unit on every boot, so these survive
    # re-authentication and do not depend on remembering a `tailscale up`
    # incantation.
    #
    # --ssh is the important one: it is a second, independent way in that does
    # not depend on the openssh key material below being right. If one path
    # breaks, the other still works.
    #
    # --accept-dns=false is not optional here. Tailscale's resolver would take
    # over /etc/resolv.conf and displace dnscrypt-proxy (networking.nix), which
    # is both a privacy regression and — on a machine nobody can reach the
    # console of — an extra thing that can strand the box. Peers are named via
    # opts.tailnetHosts instead.
    extraSetFlags =
      [
        "--ssh=true"
        "--accept-dns=false"
      ]
      ++ lib.optionals headless [
        # A Norwegian exit node: useful for banking and geo-locked services
        # from abroad. Advertising it costs nothing until it is selected, but
        # it must still be approved once in the Tailscale admin console.
        "--advertise-exit-node=true"
      ];
  };

  # tailscaled-set is a plain oneshot upstream, so if it runs before the node
  # has finished authenticating it fails and never tries again — leaving SSH
  # and the exit node silently off. Retry until it takes.
  systemd.services.tailscaled-set.serviceConfig = {
    Restart = "on-failure";
    RestartSec = "10s";
  };

  # MagicDNS is off (see --accept-dns above), so peers are resolved from here.
  networking.hosts = opts.tailnetHosts;

  # The tailnet is the trust boundary. Services bound to 0.0.0.0 (ollama, and
  # ComfyUI when it runs) become reachable from our own devices without opening
  # a single port to the LAN the machine happens to sit on — which, in a family
  # house, is a network full of appliances we do not control.
  networking.firewall.trustedInterfaces = ["tailscale0"];

  # ── SSH ────────────────────────────────────────────────────────────────────
  users.users.${opts.username}.openssh.authorizedKeys.keys = opts.sshAuthorizedKeys;

  services.openssh.settings = lib.mkIf headless {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };

  # ── Never sleep ────────────────────────────────────────────────────────────
  # config/home/idle.nix documents, at length, that resume-from-suspend on this
  # NVIDIA + mango combination broke badly enough to need a hard power-off,
  # twice. That is survivable at a desk and terminal on another continent, so
  # on a headless host suspend is removed as a possibility rather than merely
  # left unscheduled: masking the targets means even a stray `systemctl
  # suspend`, or some helpful desktop component, cannot reach it.
  systemd.targets = lib.mkIf headless {
    sleep.enable = false;
    suspend.enable = false;
    hibernate.enable = false;
    "hybrid-sleep".enable = false;
  };

  services.logind.settings.Login = lib.mkIf headless {
    # The lid will be shut in a basement; on battery the default is "suspend".
    HandleLidSwitch = lib.mkForce "ignore";
    HandleLidSwitchDocked = lib.mkForce "ignore";
    HandleLidSwitchExternalPower = lib.mkForce "ignore";
    # Nobody is at the keyboard, but a cat, a cleaner or a nudged laptop is a
    # perfectly ordinary way to hit a power button.
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    IdleAction = "ignore";
  };

  # ── Remote builds ──────────────────────────────────────────────────────────
  nix = lib.mkMerge [
    # Builder side: the nix daemon will not accept build requests over ssh-ng
    # from a user it does not trust.
    (lib.mkIf headless {
      settings.trusted-users = [opts.username];
    })

    # Client side: send builds to the big machine instead of grinding through
    # them on the travel laptop. builders-use-substitutes lets the builder pull
    # dependencies from the binary caches itself, rather than making us fetch
    # them over a hotel connection and push them across the tailnet.
    (lib.mkIf opts.remoteBuilder.enable {
      distributedBuilds = true;
      settings.builders-use-substitutes = true;
      buildMachines = [
        {
          inherit (opts.remoteBuilder) hostName maxJobs speedFactor sshKey;
          sshUser = opts.username;
          protocol = "ssh-ng";
          system = "x86_64-linux";
          supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        }
      ];
    })
  ];

  environment.systemPackages = [
    # A long remote build still wants a multiplexer to live in — not because
    # anything requires one any more, but because watching a build scroll for an
    # hour in a bare SSH session is how people lose the output they needed.
    #
    # The maintenance transaction itself deliberately does NOT depend on this:
    # activation runs in a system service, so a dropped connection can no longer
    # kill a rebuild half-way, which is the failure mode the old wrapper's
    # multiplexer check existed to prevent. The workflow moved to
    # config/system/maintenance.nix (ns-maint); see docs/headless-server.md.
    pkgs.tmux
  ];
}
