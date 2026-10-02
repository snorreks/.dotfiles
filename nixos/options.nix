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

  # ── Headless / server mode ──
  # Turns a host into an always-on box that is only ever reached remotely: no
  # desktop autologin, sleep disabled outright, Wi-Fi MAC pinned, LAN service
  # ports closed (the tailnet reaches them instead) and SSH restricted to the
  # keys below.
  #
  # Nothing is *uninstalled* — walk up to the machine, log in at tuigreet and
  # you get the normal mango desktop. The point is only that nothing starts one
  # unattended. See docs/headless-server.md.
  headless = false;

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
    # Root's private key: nix runs distributed builds as the daemon user.
    sshKey = "/root/.ssh/id_nixbuilder";
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
}
