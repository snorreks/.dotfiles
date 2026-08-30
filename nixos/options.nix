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
  # supports. Hosts override the whole `mouse` attrset (shallow merge).
  mouse = {
    enable = true;
    # Device selector: a device number (1..6), serial, or name substring.
    device = "MX Master 3S";
    # Run the tray applet too (battery indicator only — not needed for settings).
    tray = true;
    # Bind the thumb wheel to volume in mango (see config/home/mango.nix).
    # NOTE: this consumes horizontal scroll globally — see the comment there.
    thumbWheelVolume = true;
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

  # ── Impermanence ──
  # Wipe the root subvolume every boot: imports config/system/persistence.nix
  # and mounts the /persist subvolume (see hosts/gs65/hardware.nix). Off by
  # default — hosts opt in explicitly with enablePersistence = true in
  # hosts/<host>/options.nix. See docs/impermanence-migration.md.
  enablePersistence = false;
}
