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
}
