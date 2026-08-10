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
