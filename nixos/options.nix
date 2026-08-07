# nixos/options.nix
# 'rec' allows variables to reference each other inside this set
rec {
  username = "sonny";
  hostname = "sonny-laptop";

  # User Variables
  deviceName = "nvme0n1";
  gitUsername = "snorreks";
  defaultBrowser = "zen";
  defaultEditor = "zeditor";
  defaultFileManager = "pcmanfm";
  defaultTerminal = "foot";
  gitEmail = "snorrekstrand@hotmail.com";
  theme = "atelier-cave";
  flakeDir = "/home/${username}/.dotfiles/nixos";
  intelBusId = "0:2:0"; # Use the correct Bus ID for your Intel GPU
  nvidiaBusId = "1:0:0"; # Use the correct Bus ID for your NVIDIA GPU

  # Location Coordinates (e.g. Oslo / Southern Norway)
  latitude = "59.91";
  longitude = "10.75";

  # --- Monitor Configuration ---

  # Set to TRUE for 3-monitor setup (Left-Center-Right).
  # Set to FALSE for Laptop only.
  enableExternalMonitors = true; # Keep true to use external monitors

  # 1. Laptop Monitor (eDP-1)
  # Always enabled at 0,0
  mainMonitor = "eDP-1,2560x1600@60,0x0,1,vrr,1";

  # 2. HDMI Monitor (ViewSonic VG272U V - Right of laptop)
  hdmiMonitor = "HDMI-A-1,1920x1080@60,2560x0,1,vrr,1";

  # 3. USBC Monitor (ASUS DP-1 - Far right, vertical)
  # transform,1 = 90 degree rotation (vertical)
  usbcMonitor = "DP-1,1920x1080@60,4480x0,1,transform,1,vrr,1";

  # ── Large / slow-to-build packages ──
  # Ollama-cuda is included by default.
  # Use nswitch-fast (or build sonny-laptop-fast) to skip it for quick rebuilds.
  enableOllama = true;
}
