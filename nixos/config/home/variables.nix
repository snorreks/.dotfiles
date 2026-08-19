# nixos/config/home/variables.nix
# A safe and minimal set of environment variables to ensure a stable session.
{
  config,
  lib,
  opts,
  ...
}: let
  envSecrets = import ./env-secrets.nix;

  # Secrets read from /run/secrets at shell startup — no secrets in the Nix store.
  secretSessionVariables = builtins.listToAttrs (
    lib.concatMap (
      s:
        if s.sessionVariable or true
        then
          map (varName: {
            name = varName;
            value = "$(cat ${config.sops.secrets.${s.name}.path})";
          }) ([s.name] ++ (s.aliases or []))
        else []
    )
    envSecrets
  );
in {
  # Home Manager handles adding these to your PATH automatically.
  home.sessionPath = [
    "$HOME/.dotfiles/bin"
  ];

  home.sessionVariables =
    {
      # --- Essential Wayland & Toolkit Flags ---
      # These are the standard, non-controversial settings to make apps use Wayland.
      NIXOS_OZONE_WL = "1";
      GDK_BACKEND = "wayland,x11";
      QT_QPA_PLATFORM = "wayland;xcb";
      # Hint Firefox to use its native Wayland backend.
      MOZ_ENABLE_WAYLAND = "1";
      # Disable the RDD sandbox in Firefox to allow the VA-API driver to work.
      # This has security implications but is currently necessary.
      MOZ_DISABLE_RDD_SANDBOX = "1"; # [26, 28]
      SDL_VIDEODRIVER = "wayland,x11";
      _JAVA_AWT_WM_NONEREPARENTING = "1";

      # --- Session Information ---
      # This correctly identifies your session to applications.
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "mango";
      XDG_SESSION_DESKTOP = "mango";
      # mango's own wiki explicitly calls out NVIDIA + atomic modesetting as a source of exactly this kind of buffer/sync failure. Set it system-wide via environment.sessionVariables in your NixOS config, reboot (it needs to be set before mango starts):
      # WLR_DRM_NO_ATOMIC = "1";

      # --- NVIDIA Driver Configuration ---
      # These are the correct settings for using the NVIDIA proprietary driver.
      GBM_BACKEND = "nvidia-drm";
      LIBVA_DRIVER_NAME = "nvidia";
      VDPAU_DRIVER = "nvidia";
      # Instruct the nvidia-vaapi-driver to use the 'direct' backend.
      # This is required for modern NVIDIA drivers.
      NVD_BACKEND = "direct"; # [20, 26]
      # A common and safe workaround for NVIDIA cursor rendering issues.
      # WLR_NO_HARDWARE_CURSORS = "1";

      # --- User Preferences ---
      EDITOR = opts.defaultEditor;
      BROWSER = opts.defaultBrowser;
      TERMINAL = opts.defaultTerminal;
      XDG_BIN_HOME = lib.mkDefault "$HOME/.local/bin";
      XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";
    }
    // secretSessionVariables;
}
