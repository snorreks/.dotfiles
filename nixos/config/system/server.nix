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
#
# ── Read `opts.headless`, not the role ───────────────────────────────────────
# Every gate below is `opts.headless`, including the ones that are about the
# role rather than about being remote. `role` is resolved once, in
# nixos/flake.nix, and folded back into this boolean (see nixos/lib/host-policy.nix),
# so there is exactly one switch and no module has to know which of the two it
# is looking at. Anything else is how two answers end up in one configuration.
{
  config,
  pkgs,
  lib,
  opts,
  ...
}: let
  headless = opts.headless;

  # System user lingering: the user manager exists with NOBODY logged in.
  #
  # It used to be gated on opts.mobileAgents.enable, which was a bug waiting to
  # happen rather than an accident: a server with the phone clients turned off
  # had no lingering, so the user manager started at first login and stopped at
  # last logout — and with it everything that manager owns (herdr, Collie, the
  # user units the agent-operations work owns). An always-on box whose whole
  # point is being reachable with nobody sitting at it had a session lifetime
  # policy borrowed from a laptop.
  #
  # The condition is now the union the parallel contract states: agent lifetime
  # is `headless OR mobileAgents.enable`. Note what this is and is not — this
  # makes the manager EXIST. Which units it starts at boot, and whether their
  # credentials are ready, is the agent-operations group's half and is not
  # established by this file alone.
  lingerWanted = headless || opts.mobileAgents.enable;

  # The DNS owner / rescue list, from the same pure function the tests assert.
  dnsPolicy = (import ../../lib/host-policy.nix).dnsPolicy;
  dns = dnsPolicy {headless = opts.headless;};
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
  # and the exit node silently off.
  #
  # It does retry now: systemd increases the delay geometrically from 10s to
  # five minutes over six steps, then repeats at the cap. The old fixed 10s
  # interval meant a node whose uplink came up after an hour had woken the unit 360
  # times first, and each wake is a journal full of "failed to reach
  # controlplane.tailscale.com" noise that hides the real error.
  #
  # `startLimitIntervalSec` is a [UNIT] directive, so it is set there and not
  # under serviceConfig, where systemd would ignore it. That mistake is not
  # hypothetical: it is what dnscrypt-proxy was doing next door, which is why
  # the two are written the same way here.
  systemd.services.tailscaled-set = {
    startLimitIntervalSec = 0;
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
      RestartSteps = 6;
      RestartMaxDelaySec = "300s";
    };
  };

  # ── Convergence, not just retrying ─────────────────────────────────────────
  #
  # tailscaled-set above answers "retry the one command". This answers the
  # question retrying cannot: what if the node authenticated FINE, and the
  # failure was something else — the Serve certificate was not issued yet, the
  # uplink came back an hour later, the flags were never applied because the
  # oneshot gave up at boot?
  #
  # `tailscale-reconcile` observes the node and converges it onto the declared
  # state. It is timer-driven and idempotent, which means every one of these is
  # fixed by itself within a few minutes, with nobody at the machine:
  #
  #   * a cold boot with no uplink — the timer keeps finding BackendState
  #     NeedsLogin, says so, and retries;
  #   * credentials becoming available later — the next tick sees Running and
  #     applies the preferences;
  #   * a Serve mapping that never got written, or was clobbered by something
  #     else — repaired individually, without touching any other mapping;
  #   * the DNS name changing under a stale serveHosts — reported as a failure
  #     with both names, because that is otherwise invisible from a phone.
  #
  # What it will not do is in the script's header and is the important half:
  # no `tailscale up` (that is a login flow, and an unattended one can hang on
  # an interactive prompt forever), no `serve reset` (that erases every mapping,
  # including the Collie HTTPS one and any listener added later), no Funnel, and
  # no reboot. The Collie Serve mapping itself is still declared by
  # config/system/mobile-agents.nix; this only repairs it when it is missing,
  # and never when it is already correct.
  systemd.services.tailscale-reconcile = {
    description = "Converge tailscaled preferences and the private Serve mapping";
    # `path` REPLACES the search path (NixOS re-adds coreutils/findutils/
    # grep/sed/systemd on top, which is why those work and jq has to be named
    # here). The tailscale CLI has to be named too: reconcile.sh drives
    # `tailscale status`/`set`/`serve` by name through NM_TAILSCALE, and without
    # this package on PATH every one of those calls fails with
    # "command not found" — which the script then reports as
    # "BackendState=unknown: the node is not authenticated, run 'tailscale up'"
    # on a node that is perfectly logged in. An unreviewed `tailscale up` on an
    # unattended box can leave it waiting on an interactive auth URL forever, so
    # a PATH that lies about why it failed is not a cosmetic bug.
    path = [
      pkgs.jq
      config.services.tailscale.package
    ];
    after = ["tailscaled.service" "tailscaled-set.service"];
    wants = ["tailscaled.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.runtimeShell} ${./tailscale/reconcile.sh}";
      # The node has to be able to answer at all before this is worth running;
      # a hard bound so a wedged call cannot pile up behind itself.
      TimeoutStartSec = "2min";
    };
    environment = {
      NM_TS_DESIRED_SSH = "true";
      # MagicDNS is off on purpose: Tailscale's resolver would displace
      # dnscrypt-proxy (networking.nix), which on a machine nobody can reach the
      # console of is one more thing that can strand the box.
      NM_TS_ACCEPT_DNS = "false";
      NM_TS_EXIT_NODE = lib.mkDefault (if headless then "true" else "false");
      # Only manage Serve when Collie asked for it — see mobile-agents.nix,
      # which owns that mapping. Zero here means "this node serves no HTTPS",
      # which is the right answer for a host without Collie.
      NM_TS_SERVE_HTTPS_PORT = lib.mkDefault (
        if opts.mobileAgents.enable && opts.mobileAgents.collie.enable then "443" else "0"
      );
      NM_TS_SERVE_TARGET_PORT = lib.mkDefault (
        if opts.mobileAgents.enable && opts.mobileAgents.collie.enable then toString opts.mobileAgents.collie.port else "0"
      );
      NM_TS_SERVE_HOST =
        if opts.mobileAgents.enable && opts.mobileAgents.collie.enable
        then (lib.head (opts.mobileAgents.collie.serveHosts ++ [""]) )
        else "";
    };
  };

  systemd.timers.tailscale-reconcile = {
    description = "Retry tailscale convergence until the node is fully up";
    wantedBy = ["timers.target"];
    timerConfig = {
      # Late enough for the boot-time run to have happened, then every five
      # minutes. Five is a compromise: fast enough that "I rebooted it from the
      # phone and Collie is not there" resolves without me doing anything, slow
      # enough to be invisible in the journal.
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
      # NOT Persistent: replaying yesterday's missed tick would fire a repair
      # job on the wrong state. The timer is a convergence loop, not a
      # catch-up queue.
      Persistent = false;
      Unit = "tailscale-reconcile.service";
    };
  };

  # MagicDNS is off (see --accept-dns above), so peers are resolved from here.
  networking.hosts = opts.tailnetHosts;

  # The tailnet is the trust boundary. Services bound to 0.0.0.0 (ollama, and
  # ComfyUI when it runs) become reachable from our own devices without opening
  # a single port to the LAN the machine happens to sit on — which, in a family
  # house, is a network full of appliances we do not control.
  networking.firewall.trustedInterfaces = ["tailscale0"];

  # ── SSH ────────────────────────────────────────────────────────────────────
  #
  # Three separate keys, deliberately not one list:
  #
  #   sshAuthorizedKeys        the operator (currently also the GitHub key)
  #   remoteBuilder.authorizedKey  the travel laptop, building as the nix daemon
  #   mobileAgents.phoneAuthorizedKey  the phone
  #
  # They were conflated, so "revoke the phone" meant rotating the key that also
  # pushes to Git and logs into both machines. A dedicated key per client is the
  # only thing that makes one revocation not a three-machine outage.
  #
  # None of the private halves live here or in this repository: each client
  # generates its own and only its public half is pasted in. That is why they
  # are `null` rather than generated — see the warning at the bottom.
  # ONE `users.users` definition, holding both the authorized keys and linger.
  #
  # They cannot be two separate definitions — neither `a.b.c = …` next to
  # `a.b = …` nor two `a.b = …` lines is a merge in Nix; the first is "attribute
  # already defined" and the second is the same. The module system merges
  # ACROSS modules, which is why config/system/mobile-agents.nix can add the
  # phone's key to this same set without either of us knowing about the other.
  users.users = lib.mkMerge [
    {
      ${opts.username}.openssh.authorizedKeys.keys =
        opts.sshAuthorizedKeys
        # The builder's key belongs on the BUILDER side regardless of whether
        # this machine is also a client.
        #
        # This used to read `opts.remoteBuilder.enable` alone, which is the
        # enable-switch on the *client* — so the server, the one machine that
        # actually has to accept the key, never added it. A builder configured
        # on both ends and still unable to log in is a genuinely confusing
        # failure, and it looks like a key or firewall problem rather than a
        # condition that was never true on the server.
        ++ lib.optional
          ((opts.remoteBuilder.enable || headless) && opts.remoteBuilder.authorizedKey != null)
          opts.remoteBuilder.authorizedKey;
    }

    # Linger: the user manager exists with NOBODY logged in. Written here
    # rather than in user.nix because the condition is a policy decision and
    # user.nix should not have to know what a server is.
    (lib.mkIf lingerWanted {
      ${opts.username}.linger = true;
    })
  ];

  # Pinned host keys, and why nothing has to be done about them here.
  #
  # The temptation is to write `services.openssh.hostKeys` down to stable paths
  # "so the host key cannot change". It already cannot: nixpkgs' sshd-keygen
  # unit regenerates a host key only when the file is missing or empty
  # (`if ! [ -s "${k.path}" ]`), so /etc/ssh keeps its keys across every rebuild
  # — provided /etc itself survives. That proviso is the whole reason this is
  # written down rather than assumed: `enablePersistence = true` wipes the root
  # subvolume every boot, /etc/ssh/ssh_host_ed25519_key goes with it, and both
  # clients then see a changed host key on the very next boot. That combination
  # is refused below rather than left as a surprise. Impermanence is off on
  # both hosts, and staying that way is what keeps the keys pinned.
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
          sshUser = opts.remoteBuilder.sshUser;
          inherit (opts.remoteBuilder) maxJobs speedFactor sshKey;

          # 🔴 PORT 2222, PINNED, AND DELIBERATELY EXPLICIT.
          #
          # Nix defaults to port 22, and port 22 on this tailnet is Tailscale
          # SSH (`--ssh=true` in the `services.tailscale` block above). Tailscale
          # SSH intercepts port 22 BEFORE the OS sshd sees it and authenticates
          # with a Tailscale identity, bypassing authorized_keys entirely — so a
          # key-based builder aimed at 22 stalls on a Tailscale handshake, or is
          # refused by the tailnet ACL, and reports an error from the wrong layer.
          #
          # 2222 is ordinary OpenSSH (config/system/mobile-agents.nix owns that
          # listener), so the key in authorized_keys above is actually checked.
          # "SSH to the Legion works" is not evidence that the builder works.
          #
          # BARE hostname, deliberately.
          #
          # nixpkgs writes /etc/nix/machines as
          #     <hostName> <system> <sshKey> <maxJobs> <speedFactor> ...
          # and Nix then parses that line by SPLITTING ON WHITESPACE. Putting
          # "-p 2222" in hostName therefore did not add an ssh option: it made
          # the system field "-p", the sshKey field "2222", and every field
          # after it shift by two — so the entry no longer advertised
          # x86_64-linux and the builder was silently skipped for those builds.
          #
          # The port is pinned by NIX_SSHOPTS below, which is Nix's own
          # mechanism for extra ssh arguments (nixpkgs' rebuild tests use it the
          # same way), plus the generated `Host legion / Port 2222` ssh_config.
          hostName = opts.remoteBuilder.hostName;

          # `ssh-ng` is Nix's actual SSH transport. `builtin` speaks no SSH at
          # all and would silently ignore sshOptions above, which turns a port
          # mistake into something that looks like a Nix bug.
          inherit (opts.remoteBuilder) protocol;
          system = "x86_64-linux";
          supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
        }
      ];
    })
  ];

  # ── The port the builder is reached on, for the Nix DAEMON ────────────────
  #
  # The machine entry above can only carry a bare hostname, so the port has to
  # reach Nix another way. NIX_SSHOPTS is that way: Nix prepends it to every ssh
  # it makes, and it only makes ssh to builders.
  #
  # Without it the daemon falls back to port 22, which on this tailnet is
  # Tailscale SSH — it intercepts before the OS sshd and authenticates with a
  # Tailscale identity, so a key-based builder stalls or is refused by the ACL,
  # reporting from the wrong layer entirely.
  systemd.services.nix-daemon.environment = lib.mkIf (opts.remoteBuilder.enable && opts.headless == false) {
    NIX_SSHOPTS = "-p ${toString opts.remoteBuilder.port} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts";
  };

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

  # ── Half-configured remote access is a build warning, never a silent build ──
  #
  # `warnings` is a listOf: ONE assignment per module system. mobile-agents.nix
  # owns the phone/Collie half of this list, so these entries are appended to
  # `warnings` from here rather than starting a second one (which would be an
  # eval conflict, not a merge).
  #
  # Both are the same class of problem: a key that has to be generated on
  # another machine, where a private half cannot honestly be produced here.
  warnings =
    lib.optional (opts.remoteBuilder.enable && opts.remoteBuilder.authorizedKey == null) ''
      server: opts.remoteBuilder.enable is true but
      opts.remoteBuilder.authorizedKey is null, so the only authorized key on
      this host is the operator's. Remote builds will still work — as the
      operator — but "build remotely" and "log in as me" are then the same
      credential. Generate the key on the CLIENT and paste the public half:

        ssh-keygen -t ed25519 -f ~/.ssh/nixbuilder -C nixbuilder
        cat ~/.ssh/nixbuilder.pub
    ''
    ++ lib.optional (headless && opts.enablePersistence) ''
      server: role = "server" with enablePersistence = true. The root subvolume
      is wiped every boot, so /etc/ssh/ssh_host_* is regenerated on the next one
      and every pinned known_hosts entry on your clients stops matching. Keep
      impermanence off on an unattended host, or move the host keys somewhere
      that survives the wipe and pin them explicitly.
    '';
}
