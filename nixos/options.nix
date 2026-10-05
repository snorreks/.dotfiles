# nixos/options.nix
# 'rec' allows variables to reference each other inside this set
rec {
  username = "sonny";
  hostname = "legion";

  # User Variables
  deviceName = "nvme0n1";
  gitUsername = "snorreks";
  defaultBrowser = "zen";
  defaultEditor = "zeditor";
  defaultFileManager = "pcmanfm";
  defaultTerminal = "foot";
  gitEmail = "snorrekstrand@hotmail.com";
  flakeDir = "/home/${username}/.dotfiles/nixos";
  intelBusId = "0:2:0"; # Use the correct Bus ID for your Intel GPU
  nvidiaBusId = "1:0:0"; # Use the correct Bus ID for your NVIDIA GPU

  # Location Coordinates (e.g. Oslo / Southern Norway)
  latitude = "59.91";
  longitude = "10.75";

  # --- Monitor Configuration ---

  # Per-host mango `monitorrule` (list of rule strings). The default is
  # laptop-only; hosts override the whole list in hosts/<host>/options.nix
  # (see hosts/legion/options.nix for the 3-monitor desktop setup).
  # rr:0 = normal (0°), rr:1 = 90° rotation (portrait)
  monitorrule = [
    "name:^eDP-1$,width:2560,height:1600,refresh:240,x:0,y:0,scale:1,rr:0,vrr:1"
  ];

  # The output that carries the "full" status bar.
  #
  # Waybar instantiates every module once PER BAR, and it creates one bar per
  # output unless told otherwise — so on a 2-monitor session the custom exec
  # modules were running twice: two `sys-daemon waybar power`, two `light`,
  # two `vpn`, two `tomato`, and two Python interpreters each for weather and
  # agenda, all from one waybar process.
  #
  # waybar/settings.nix therefore splits the bar in two: the full module set
  # on this output, and a secondary bar everywhere else carrying only the
  # native modules (workspaces, taskbar, clock, network, audio, battery),
  # which cost no processes at all. See the header there.
  #
  # eDP-1 on both hosts: it is the one output guaranteed to exist, and it is
  # also Quickshell.screens[0], so the dashboard panel and the full bar stay
  # on the same screen.
  primaryMonitor = "eDP-1";

  # ── Logitech mouse (MX Master 3S) ──
  # Applied declaratively by config/home/mouse.nix via `solaar config` — the
  # Solaar GUI/tray is NOT required for these to take effect. `settings` keys
  # are Solaar setting names; run `solaar config 1` to list what this device
  # supports. Hosts can override individual keys (overrides merge recursively).
  mouse = {
    enable = true;
    # Device selector: a device number (1..6), serial, or name substring.
    device = "MX Master 3S";
    # Run the tray applet too (battery indicator only — not needed for settings).
    tray = true;
    # Bind the thumb wheel to volume in mango (see config/home/mango.nix).
    # NOTE: this consumes horizontal scroll globally — see the comment there.
    thumbWheelVolume = true;
    # Invert the thumb wheel's left/right direction in mango's axisbinds.
    # The same physical flick yields opposite REL_HWHEEL signs depending on how
    # the mouse is paired: over the Bolt receiver hid-logitech-hidpp translates
    # HID++ feature 0x2150, over Bluetooth LE the kernel reads the device's own
    # AC-Pan usage — and the two disagree. Set per host to match how that host
    # pairs (legion = Bolt receiver, gs65 = Bluetooth). Done here rather than
    # via the Solaar `thumb-scroll-invert` setting so it holds even when
    # mouse-apply has not run — power-cycling the mouse produces no hidraw
    # event, see config/system/mouse.nix.
    thumbWheelInvert = false;
    settings = {
      dpi = 4000;
      # Wheel stays ratcheted; switches to freespin above this speed.
      smart-shift = 10;
      scroll-ratchet = "Ratcheted";
      thumb-scroll-invert = "False";
      hires-smooth-invert = "False";
    };
  };

  # ── Large / slow-to-build packages ──
  # Ollama-cuda is included by default.
  # Use nswitch-fast (or build sonny-laptop-fast) to skip it for quick rebuilds.
  enableOllama = true;

  # ── Role: what KIND of machine is this? ────────────────────────────────────
  # "desktop" or "server", set per host in hosts/<host>/options.nix, or null to
  # inherit `headless` (below). See lib/host-policy.nix for the resolution and
  # for which combinations are refused outright.
  #
  #   desktop  a machine somebody sits at. Suspends when the lid shuts, lid
  #            and idle behave like a laptop, LAN service ports open, no exit
  #            node, no user lingering. The travel laptop (gs65) is this.
  #
  #   server   a machine that stays behind and is only reached remotely.
  #            Suspend removed as a possibility rather than left unscheduled,
  #            lid/power/hibernate keys ignored, system user LINGERING on so the
  #            user manager exists with nobody logged in, LAN service ports
  #            closed in favour of the tailnet, exit node advertised, and the
  #            host-wide Proton VPN kill-switch structurally absent — that
  #            kill-switch REJECTs all output that is not marked for wg0, which
  #            includes the tailnet, so on an unattended host it is not a
  #            setting to be careful with, it is a way to lock yourself out.
  #
  # A server is still a usable desktop: walk up to it, log in at tuigreet, and
  # you get mango. Nothing is uninstalled; the point is only that nothing
  # starts one unattended.
  role = null;

  # ── Headless / server mode (compatibility boolean) ─────────────────────────
  # The EFFECTIVE answer to "is this host reached only remotely?", and the
  # boolean every module reads. `headless` is kept as an input, not the switch:
  #
  #   role = null   -> headless decides, exactly as before
  #   role = "server" -> headless becomes true, whatever it said
  #   role = "desktop" + headless = true -> REFUSED at evaluation
  #
  # So a host promoted to a server edits one line, and code written against
  # `opts.headless` (including the agent-operations work in this repository)
  # keeps working unchanged. What it turns on: no desktop autologin, sleep
  # disabled outright, Wi-Fi MAC pinned, LAN service ports closed (the tailnet
  # reaches them instead) and SSH restricted to the keys below. See
  # docs/headless-server.md.
  headless = false;

  # ── Boot health blessing (opt-in) ───────────────────────────────────────────
  # Boot counting with a LOCAL pass/fail gate. See config/system/boot.nix for
  # what "local" excludes (everything that needs the internet) and why this is
  # off until it has been tried.
  bootHealth = {
    # OFF by default, deliberately. It needs a reboot to observe working, and
    # a reboot on the server is a scheduled, attended event — see
    # docs/headless-server.md § "Testing the boot blessing".
    enable = false;

    # Boot attempts a freshly staged entry is given before systemd-boot treats
    # it as bad and falls back to the previous entry. nixpkgs' own default.
    tries = 3;

    # Units that must be healthy before this boot is blessed. Deliberately a
    # short, explicit list rather than `systemctl --failed`: a failed unit
    # because the hotel wifi is down is exactly what must NOT cost you the
    # good entry you are currently running on.
    criticalUnits = [
      "local-fs.target"
      "systemd-modules-load.service"
    ];
  };

  # ── Per-host ACPI / graphics quirks ─────────────────────────────────────────
  # These were one shared kernelParameters list for both machines, which is a
  # list — so a value either applies to every host or to none, and "off on the
  # travel laptop, on for the server" was not expressible. Per host now.
  #
  # Values are NOT changed from what both hosts ran before; only their scope is.
  # See config/system/kernel.nix for the evidence behind the GuC comment and
  # for why acpi_call is off by default.
  acpi = {
    # Load the acpi_call module (needed by some vendor fan/battery tools).
    # It was loaded on both hosts unconditionally; nothing in this
    # configuration calls it, so it is opt-in per host.
    acpiCall = false;

    # acpi_osi=... kernel parameter, or null to omit it. It tells the firmware
    # to expose Linux-specific ACPI interfaces.
    acpiOsi = "Linux";

    # i915.enable_guc=... kernel parameter, or null to omit it.
    #
    # DEFAULT null here: on the current kernel this parameter TAINTS the kernel
    # (see the evidence in config/system/kernel.nix) while achieving nothing.
    # Set it to 2 to restore the old behaviour on a kernel where it is wanted.
    i915Guc = null;
  };

  # ── Shared NTFS volume ─────────────────────────────────────────────────────
  # /mnt/shared is the Windows dual-boot volume. Mounting it is OFF by default
  # on both hosts, for the same reason the Proton VPN is excluded on a server:
  # it is a dependency that can fail in ways nothing else can fix.
  #
  # NTFS3 with `rw` on a volume Windows has hibernated (Fast Startup) is a way
  # to corrupt it, and the fix — disabling hibernation from Windows, or
  # remounting read-only — is something you need a keyboard and a booted
  # Windows for. An unattended box that cannot reach it must not be writing
  # there. Nothing server-critical reads or writes this path: all state and
  # media roots are native Linux filesystems. See docs/headless-server.md.
  mountShared = false;

  # ── Battery charge threshold ──
  # Percentage to stop charging at, or null to leave the firmware alone.
  # Holding a pack at 100% is what actually ages it: 80 is the usual
  # daily-driver compromise, 60 the right number for a machine that will sit
  # plugged in and idle for months. Not every laptop exposes a writable
  # threshold — see config/system/battery.nix for the fallback chain.
  batteryChargeLimit = null;

  # ── SSH ──
  # Public keys allowed to log in as ${username}, on every host. Declared here
  # rather than left to a hand-edited ~/.ssh/authorized_keys so a headless host
  # can turn password auth off with no chance of locking us out.
  #
  # This is currently the same key pair used for GitHub (private half lives in
  # sops as github_ssh_key, so it is already on every host). A dedicated key is
  # tidier if you ever want to revoke one without the other — generate it, add
  # the public half here, rebuild.
  sshAuthorizedKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBXMenhf8rjYurnVkAPn6obO4bQGjKhrLQjsb/9apiy1 github_snorreks"
  ];

  # ── Tailnet ──
  # Static /etc/hosts entries for tailnet peers. MagicDNS is deliberately NOT
  # accepted (Tailscale's resolver would displace dnscrypt-proxy — see
  # config/system/networking.nix), so peers get named here instead. Fill in
  # once the node is up: `tailscale ip -4 legion`.
  #   tailnetHosts = {"100.x.y.z" = ["legion"];};
  tailnetHosts = {};

  # ── Nix remote builds ──
  # Offload builds from this host to a beefier one over the tailnet. Enable on
  # the *client* (the weak laptop); the builder side only needs headless = true,
  # which is what adds ${username} to nix's trusted-users. Requires a one-time
  # key exchange — see docs/headless-server.md.
  remoteBuilder = {
    enable = false;
    hostName = "legion";

    # 🔴 PORT 2222, NOT 22. This is the single most important field here.
    #
    # config/system/server.nix starts tailscaled with `--ssh=true`, and
    # Tailscale SSH answers on tailnet port 22 BEFORE the OS sshd sees the
    # connection — authenticating with a Tailscale identity and bypassing
    # authorized_keys entirely. Nix's distributed builder authenticates with a
    # KEY FILE, so against port 22 it stalls on the Tailscale handshake or is
    # refused by the tailnet ACL, and the useful error is not on the nix side.
    # Port 2222 is ordinary OpenSSH (config/system/mobile-agents.nix owns that
    # listener), so the builder key in authorized_keys is actually checked.
    #
    # 22 and 2222 are NOT interchangeable here. "ssh works to that host" is not
    # evidence that the builder works.
    port = 2222;

    # The account the builder logs in as. It does not have to be the operator:
    # a dedicated account is what makes revoking build access a one-line change
    # instead of rotating the key that also pushes to Git and logs in to both
    # machines.
    #
    # 🔴 Whatever account this names is in nix's trusted-users (server.nix), and
    # trusted-users can drive the daemon, which is root-equivalent. A dedicated
    # account does not make that unprivileged — it makes the privilege explicit
    # and separately revocable. It is deliberately NOT given blanket NOPASSWD
    # sudo to imitate a narrower boundary.
    sshUser = username;

    # Nix's actual SSH transport. `ssh-ng` is the modern one; `builtin` speaks no
    # SSH at all and would silently ignore every option above, which is the
    # failure mode that makes a port mistake look like a Nix bug.
    protocol = "ssh-ng";

    # Root's private key: nix runs distributed builds as the daemon user.
    sshKey = "/root/.ssh/id_nixbuilder";

    # 🔴 THE BUILDER CLIENT'S PUBLIC KEY GOES HERE on the BUILDER host (or in
    # local.nix, scoped to it). Without it, the only authorized key is the
    # operator's GitHub key below — which means "remote build" and "log in as
    # sonny" are the same credential, so revoking the phone or the builder
    # means rotating the key you also use for Git.
    #
    # Generate ON THE CLIENT, never here:
    #   ssh-keygen -t ed25519 -f ~/.ssh/nixbuilder -C nixbuilder
    #   cat ~/.ssh/nixbuilder.pub
    #
    # Null rather than empty: an empty list would be indistinguishable from a
    # configured key set, and config/system/server.nix turns null into a build
    # warning naming the key to paste.
    authorizedKey = null;

    maxJobs = 8;
    speedFactor = 4;
  };

  # ── Impermanence ──
  # Wipe the root subvolume every boot: imports config/system/persistence.nix
  # and mounts the /persist subvolume (see hosts/gs65/hardware.nix). Off by
  # default — hosts opt in explicitly with enablePersistence = true in
  # hosts/<host>/options.nix. See docs/impermanence-migration.md.
  enablePersistence = false;

  # ── Mobile agents (phone → herdr) ───────────────────────────────────────────
  # Reach the host from an Android phone and drive the SAME persistent herdr
  # workspaces and pi / Claude Code / OpenCode agents the desktop uses — not a
  # second stack, not a tmux-inside-herdr.
  #
  # THREE layers, deliberately separable, because "remote access" and "which
  # app is it driven from" are independent decisions and conflating them is how
  # you end up with a phone that cannot get in at all:
  #
  #   enable        SHARED INFRASTRUCTURE. The second sshd listener, the phone
  #                 key, bounded mosh, `linger`, and the herdr WantedBy change
  #                 that starts the server at boot. This is what "reachable from
  #                 a phone" means, and it is what every client below rides on.
  #
  #   collie.enable Collie PWA over private Tailscale Serve + HTTPS. Needs
  #                 NOTHING from sshd/mosh at all — it is a browser talking to
  #                 tailscaled. The primary Android interface.
  #
  #   moshi.enable  moshi-hook daemon + Chat View gateway over SSH port
  #                 forwarding. Now OPTIONAL, so turning Moshi off does not turn
  #                 remote access off with it.
  #
  # Disabling the last two leaves the first intact on purpose: port 2222, mosh,
  # linger and boot-time herdr keep working, so Termux remains a working
  # fallback and there is never a generation in which the phone has no way in.
  #
  # Per-host opt-in, exactly like headless. Off by default;
  # hosts/legion/options.nix turns it on. Deliberately independent of headless:
  # the Legion stays a normal three-monitor desktop that merely also answers on
  # the tailnet.
  #
  # Enabling it touches, in one place each: config/system/mobile-agents.nix
  # (sshd mobile port + bounded mosh + the Tailscale Serve mapping),
  # config/home/collie.nix (the Collie bridge), config/home/moshi-hook.nix (the
  # Moshi daemon), and the WantedBy target in config/home/herdr.nix. Read
  # docs/mobile-agents.md before flipping anything — pairing is a manual step,
  # and the phone's public key has to be filled in below.
  mobileAgents = {
    enable = false;

    # The mobile sshd listener. NOT 22, and that is the whole point.
    #
    # `services.tailscale.extraSetFlags` carries --ssh=true, and Tailscale SSH
    # answers on tailnet port 22 *before* the OS sshd ever sees the connection,
    # authenticating with a Tailscale identity and bypassing authorized_keys
    # entirely. A phone client that authenticates with a key FILE — Moshi, or
    # Termux's plain `ssh` — stalls ~60s against that and then fails with a
    # misleading auth error. Port 2222 is ordinary OpenSSH, so the phone's key
    # is actually checked, while 22 stays exactly as it is as the recovery
    # path.
    #
    # Collie does not use this port at all: it is a browser over Tailscale
    # Serve. 2222 is here for the SSH/Mosh fallback and for Moshi.
    sshPort = 2222;

    # 🔴 THE PHONE'S PUBLIC KEY GOES HERE (or in nixos/local.nix, which is
    # gitignored and merged over the top of this file by flake.nix).
    #
    # Generate it ON THE PHONE — Moshi Settings → the key row → generate, or in
    # Termux `ssh-keygen -t ed25519 -f ~/.ssh/phone -C phone`, then
    # `cat ~/.ssh/phone.pub`. Never create it here and never copy a host
    # private key down to the phone: the point is that the phone holds the only
    # copy of its own key and the host only ever sees the public half.
    #
    # Left null so a fresh clone still evaluates; mobile-agents.nix turns that
    # into a build warning rather than a hard failure, so you can land this
    # first and add the real key in a second, smaller commit.
    phoneAuthorizedKey = null;

    # mosh's UDP port range. Bounded rather than mosh's 60000-61000 default so
    # the tailnet ACL and the host firewall both carry a short, auditable list.
    #
    # ⚠ This does NOT restrict the server by itself. NixOS's programs.mosh has
    # no allocation-range option — it only offers openFirewall, which opens
    # 60000-61000 on *every* interface. mobile-agents.nix therefore turns
    # openFirewall off and ships a mosh-server wrapper that passes `-p
    # 60000:60010`, which is the only thing that actually bounds it. Change both
    # ends together or mosh will silently fall back to SSH.
    moshPortRange = {
      from = 60000;
      to = 60010;
    };

    # mosh-server. mosh is a convenience, not the transport everything depends
    # on: with this off, port 2222 alone is a complete, working SSH setup, and
    # Collie needs neither. See docs/mobile-agents.md for why this is a
    # separate switch.
    mosh = {
      enable = true;
    };

    # ── Collie (primary Android interface) ────────────────────────────────────
    # A PWA served from this host's own loopback port through PRIVATE Tailscale
    # Serve — HTTPS on tailnet :443, no Funnel, nothing on the public internet.
    # Nix owns both the unit and the Serve mapping; see config/home/collie.nix
    # and config/system/mobile-agents.nix.
    collie = {
      enable = false;

      # Loopback port the bridge listens on. Tailscale Serve proxies
      # https://<host> → http://127.0.0.1:<port>. Not a firewall exposure:
      # 127.0.0.1 is not reachable from any other interface, and Collie
      # refuses a non-loopback bind without an explicit opt-out.
      port = 8787;

      # 🔴 REQUIRED when collie.enable — the tailnet login allowed to drive
      # the agents, emitted as COLLIE_TRUSTED_USER.
      #
      # Exactly the string Tailscale puts in the `Tailscale-User-Login`
      # header: your tailnet email, lowercase, NO trailing dot. Check it with
      #   tailscale debug prefs | jq -r '.Config.UserProfile.LoginName'
      #
      # This is the outer of two independent gates. It answers "is this the
      # operator?" and fails CLOSED: a request that arrives with no
      # Tailscale-User-Login header at all is rejected, rather than trusted
      # because it came from somewhere. Set it to null and the whole Collie
      # stack is refused at build time (a Home Manager assertion), because an
      # unset gate is the one configuration nobody means to ship.
      trustedUser = null;

      # The tailnet DNS name this host is published under, e.g.
      # "legion.tailf24d02.ts.net". Two jobs, both load-bearing:
      #
      #   * it is what Tailscale Serve serves the machine as, so it belongs in
      #     the Serve mapping (config/system/mobile-agents.nix);
      #   * it becomes COLLIE_PUBLIC_HOSTS, the Host-header allowlist. Collie's
      #     Host gate is fail-closed and Collie itself does NOT discover the
      #     name here — `collie start` does that and injects it, and we do not
      #     run `collie start`. Omit it and every non-loopback request is
      #     refused with "host not allowed".
      #
      # One entry is enough; a list because a machine can have more than one
      # (a custom domain in front of Serve, an added .ts.net name).
      serveHosts = [];
    };

    # ── Moshi (optional, secondary) ───────────────────────────────────────────
    # Kept because it still works and because it is the documented fallback
    # while Collie is being evaluated. Nothing in the shared infrastructure
    # above depends on it, and nothing in Collie does.
    moshi = {
      # When true, adds config/home/moshi-hook.nix: the daemon, the Chat View
      # gateway on 127.0.0.1:<gatewayPort>, and the `moshi-agent-hooks`
      # installer. Turning this off removes the unit and leaves port 2222,
      # mosh, linger, boot-time herdr and Collie untouched.
      #
      # 🔴 It defaults to true, i.e. the behaviour legion already had before
      # Collie existed. hosts/legion/options.nix turns it off explicitly when
      # Collie is the only client you want, so the switch is visible in the
      # host diff rather than something you have to go looking for.
      enable = true;

      # Moshi's loopback gateway, reached from the phone by SSH port-forwarding
      # over the 2222 session. Not a listening port on any interface; the sshd
      # Match block for sshPort carries AllowTcpForwarding for exactly this.
      gatewayPort = 24543;
    };
  };

  # ── Private media and isolated downloads ─────────────────────────────────
  #
  # Everything here is OFF by default, and off on both hosts as shipped. An
  # import changes nothing until somebody asks for it, which is the property
  # that makes it safe to land this before the machine has been provisioned.
  #
  # Three services, three separate switches, deliberately: Jellyfin is a server
  # you watch things on, the torrent namespace is a security boundary, and
  # Syncthing is an optional convenience that propagates deletions. Turning one
  # on must never imply the other two.
  media = {
    # ── Jellyfin ─────────────────────────────────────────────────────────
    jellyfin = {
      enable = false;

      # Native Linux paths only. /mnt/shared (the Windows NTFS volume,
      # opts.mountShared) is refused by an assertion below rather than merely
      # discouraged: an unattended server writing to a hibernated Windows
      # filesystem corrupts it, and repairing that needs a keyboard.
      dataDir = "/var/lib/jellyfin";
      configDir = "/etc/jellyfin";
      libraryDir = "/srv/media/library";
      downloadDir = "/srv/media/download";

      # Loopback port. NOT opened in the firewall — Jellyfin binds 127.0.0.1
      # only and is published through a private Tailscale Serve listener, which
      # is why no allowedTCPPorts entry exists anywhere for it.
      port = 8096;

      # Tailnet HTTPS port for Jellyfin. MUST differ from 443: Collie owns 443
      # (config/system/mobile-agents.nix) and two units writing the same Serve
      # port is a race where the loser is silently broken.
      #
      # 8443 is Tailscale Serve's alternate HTTPS port. VERIFY IT against the
      # pinned Tailscale before enabling — see docs/media-travel.md § "Checking
      # the Serve port".
      serveHttpsPort = 8443;

      # Jellyfin's first-run setup wizard creates the administrator account, and
      # until one exists ANY tailnet device can reach it and claim it. This flag
      # does not create an account or check for one; it records that the wizard
      # was completed, and false produces a build warning saying so.
      setupCompleted = false;

      hardwareAcceleration = {
        # OFF until jellyfin-accel-check passes on this machine. See
        # jellyfin.nix for why "it has an Intel GPU" is not sufficient.
        enable = false;

        # Overrides the check's verdict deliberately. Present so that a machine
        # where acceleration does not work has to say so in the diff.
        acknowledgeMissing = false;

        # "vaapi" or "qsv". "nvenc" is REFUSED by assertion — the discrete GPU
        # is for inference in this configuration.
        type = "vaapi";
      };
    };

    # ── Isolated downloads ───────────────────────────────────────────────
    torrents = {
      enable = false;

      package = null; # null -> pkgs.qbittorrent-nox

      # The namespace everything is confined to. Named rather than generated so
      # that `ip netns list` and the audit script agree without configuration.
      namespace = "medtns";

      vethHost = "mthost";
      veth = "mtns0";

      # 10.77.0.0/30 — a /30 because exactly two endpoints exist and a wider
      # range would be address space nothing has a reason to be in.
      vethHostAddr = "10.77.0.1/30";
      vethAddr = "10.77.0.2/30";
      gateway = "10.77.0.1";

      # qBittorrent's WebUI, INSIDE the namespace. Reachable only through the
      # host's loopback proxy. Not 8080: a well-known admin port is the wrong
      # thing to be reachable at, even by accident.
      webuiPort = 18080;

      # The host-side proxy. Loopback only, token-gated, and it refuses to bind
      # anything else at start-up.
      proxyPort = 18081;

      stateDir = "/var/lib/qbittorrent";
      configDir = "/var/lib/qbittorrent-config";
      incompleteDir = "/srv/media/incomplete";
      downloadDir = "/srv/media/download";

      tunnel = {
        interface = "wg0";
        # Nonsecret IPv4 CIDR and numeric resolver inside the provider tunnel.
        # wg strip intentionally omits these; empty values refuse startup.
        address = "";
        resolver = "";

        # NUMERIC IP:PORT, REQUIRED AND VALIDATED. Pin the peer instead of
        # allowing DNS to change endpoint selection. The encrypted UDP socket
        # uses host routing; the namespace has no plaintext bootstrap route.
        # Empty means not configured and namespace setup refuses to proceed.
        endpoint = "";

        # Where the `wg-quick strip` output lives in sops-nix. There is no
        # default: generating a keypair here would put a private key in a git
        # repository, and defaulting to something plausible is how a real
        # credential ends up committed.
        configSecretPath = "/run/agenix/media-wg-config";
      };

      # sops-nix paths for the two runtime credentials. Generated once by hand;
      # no defaults, for the same reason as configSecretPath.
      proxyTokenSecretPath = "/run/agenix/media-webui-token";

      # 🔴 NULL MEANS UNBOUNDED SEEDING. Measure the home upstream, reserve
      # headroom for management, and set a number. 20–30%% of measured upstream
      # is the documented starting point, not a recommendation.
      uploadLimitKbit = null;

      resources = {
        memoryMax = "2G";
        cpuQuota = 200;
      };
    };

    # ── Optional selective synchronisation ───────────────────────────────
    #
    # 🔴 SYNCHRONISATION PROPAGATES DELETION. Restic remains the backup for
    # everything here. See docs/media-travel.md § "Sync is not backup".
    syncthing = {
      enable = false;

      package = null; # null -> pkgs.syncthing
      dataDir = "/var/lib/syncthing";
      guiPort = 8384;

      # A DIFFERENT Serve port from both Collie (443) and Jellyfin (8443). Two
      # units writing one Serve port is a race, not a conflict error.
      serveHttpsPort = 8444;

      # Deliberately EMPTY by default. An empty list means "nothing is
      # synchronised", which is safe; a default of "$HOME" would mean a private
      # key and a decrypted environment reach a second device.
      folders = [];
    };
  };

  # ── Travel laptop workflow ───────────────────────────────────────────────
  #
  # The GS65 half: SSH aliases, native herdr remote attachment, and the remote
  # builder. Deliberately host-scoped — the Legion must not gain travel
  # helpers, and the GS65 must not inherit server policy. See
  # config/home/travel.nix.
  travel = {
    enable = false;

    # Host-key-pinned aliases for the Legion. Two, because they are genuinely
    # different services:
    #
    #   legion        ordinary OpenSSH on 2222. Key authentication. This is the
    #                 one the Nix builder uses and the one to reach for.
    #   legion-tailscale
    #                 Tailscale SSH on 22. A Tailscale IDENTITY, not a key, so
    #                 it works from a device with no private key — which is also
    #                 why it cannot be used for key-based automation.
    serverHost = "legion";
    sshPort = 2222;
    tailscalePort = 22;

    # Filled in by the operator from the server's own /etc/ssh/ssh_host_*.pub.
    # Empty rather than fabricated: a wrong pin is worse than no pin, because a
    # wrong pin is a host key change the operator will be told to "just accept".
    serverHostKey = "";
    serverHostKeyType = "ssh-ed25519";

    # herdr remote attachment. Native `herdr --remote`, no wrapper that replaces
    # or upgrades anything on the server.
    herdrRemote = {
      enable = false;
      label = "legion";
    };
  };
}
