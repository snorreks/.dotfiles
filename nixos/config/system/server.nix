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
{
  pkgs,
  lib,
  opts,
  ...
}: let
  headless = opts.headless;

  # Revert to a known generation and reboot into it. Split out of the deadman
  # switch below so it can also be fired by hand from a rescue session.
  rollbackTo = pkgs.writeShellApplication {
    name = "nixos-rollback-to";
    runtimeInputs = [pkgs.nix pkgs.systemd];
    text = ''
      gen="''${1:?usage: nixos-rollback-to <generation-number>}"
      echo "nixos-rollback-to: reverting to generation $gen, then rebooting"
      nix-env -p /nix/var/nix/profiles/system --switch-generation "$gen"
      # `boot`, not `switch`: the whole reason we are here is that the running
      # generation may have broken networking, and switch-to-configuration
      # switch would try to reconfigure it live. Write the bootloader entry and
      # let a clean boot sort it out.
      /nix/var/nix/profiles/system/bin/switch-to-configuration boot
      systemctl reboot
    '';
  };

  # Dead-man's switch around a rebuild.
  #
  # An autonomous "is the internet up?" watchdog was the obvious alternative
  # and is worse: it cannot tell a config mistake from the parents' ISP having
  # a bad afternoon, so it reboots the box for things a rollback will not fix.
  # This arms only across the window where *we* changed something, which is
  # when the risk actually exists.
  safeSwitch = pkgs.writeShellApplication {
    name = "nswitch-safe";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.systemd pkgs.nh];
    text = ''
      timeout="''${ROLLBACK_TIMEOUT:-20min}"

      # A rebuild killed halfway by a dropped SSH session is its own failure
      # mode, and the one most likely to happen on hotel wifi.
      if [ -z "''${TMUX:-}''${ZELLIJ:-}''${STY:-}" ]; then
        echo "nswitch-safe: not inside tmux/zellij — a dropped connection would" >&2
        echo "              kill the rebuild mid-flight. Start a multiplexer first," >&2
        echo "              or set ALLOW_NO_MUX=1 if you really are at the machine." >&2
        [ -n "''${ALLOW_NO_MUX:-}" ] || exit 1
      fi

      link=$(readlink /nix/var/nix/profiles/system)
      gen=''${link#system-}
      gen=''${gen%-link}
      if ! printf '%s' "$gen" | grep -qE '^[0-9]+$'; then
        echo "nswitch-safe: cannot parse a generation number out of '$link'" >&2
        exit 1
      fi

      echo "nswitch-safe: current generation is $gen"
      echo "nswitch-safe: arming rollback — unless 'nswitch-confirm' runs within"
      echo "              $timeout, this machine reverts to generation $gen and reboots."

      # A transient *system* unit, so it outlives the SSH session that armed it
      # — which is the entire point.
      sudo systemd-run --collect --quiet \
        --unit=nixos-deadman \
        --on-active="$timeout" \
        --description="Unconfirmed rebuild rollback to generation $gen" \
        ${lib.getExe rollbackTo} "$gen"

      rc=0
      nh os switch "${opts.flakeDir}" "$@" || rc=$?

      if [ "$rc" -ne 0 ]; then
        echo
        echo "nswitch-safe: rebuild FAILED (exit $rc). No new generation was created," >&2
        echo "              so nothing needs reverting — disarming." >&2
        ${lib.getExe confirmSwitch}
        exit "$rc"
      fi

      echo
      echo "nswitch-safe: rebuild applied. Verify you can still reach this host"
      echo "              (open a SECOND ssh session — do not trust this one),"
      echo "              then run: nswitch-confirm"
    '';
  };

  confirmSwitch = pkgs.writeShellApplication {
    name = "nswitch-confirm";
    runtimeInputs = [pkgs.systemd];
    text = ''
      if systemctl is-active --quiet nixos-deadman.timer; then
        sudo systemctl stop nixos-deadman.timer
        sudo systemctl reset-failed nixos-deadman.timer nixos-deadman.service 2>/dev/null || true
        echo "nswitch-confirm: rollback disarmed — this generation is now permanent."
      else
        echo "nswitch-confirm: no armed rollback; nothing to confirm."
      fi
    '';
  };
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
    safeSwitch
    confirmSwitch
    rollbackTo
    # Reaching a remote rebuild that survives a dropped connection is the whole
    # workflow; make sure the multiplexer nswitch-safe insists on is present
    # even on a host whose home-manager session never starts.
    pkgs.tmux
  ];
}
