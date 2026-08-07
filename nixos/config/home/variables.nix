# nixos/config/home/variables.nix
# A safe and minimal set of environment variables to ensure a stable session.
{
  config,
  lib,
  opts,
  ...
}: {
  # Home Manager handles adding these to your PATH automatically.
  home.sessionPath = [
    "$HOME/.dotfiles/bin"
  ];

  home.sessionVariables = {
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

    # Disable G-Sync/VRR to prevent flickering issues.
    __GL_GSYNC_ALLOWED = "0";
    __GL_VRR_ALLOWED = "0";

    # --- User Preferences ---
    EDITOR = opts.defaultEditor;
    BROWSER = opts.defaultBrowser;
    TERMINAL = opts.defaultTerminal;
    XDG_BIN_HOME = lib.mkDefault "$HOME/.local/bin";
    XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";

    # --- Secrets (resolved at shell runtime via sops-nix decrypted files) ---
    # These read from /run/secrets at shell startup — no secrets in the Nix store.
    ANTHROPIC_API_KEY = "$(cat ${config.sops.secrets.ANTHROPIC_API_KEY.path})";
    GOOGLE_AI_API_KEY = "$(cat ${config.sops.secrets.GOOGLE_AI_API_KEY.path})";
    GEMINI_API_KEY = "$(cat ${config.sops.secrets.GOOGLE_AI_API_KEY.path})";
    OPENROUTER_API_KEY = "$(cat ${config.sops.secrets.OPENROUTER_API_KEY.path})";
    SUPABASE_ACCESS_TOKEN = "$(cat ${config.sops.secrets.SUPABASE_ACCESS_TOKEN.path})";
    DEEPSEEK_API_KEY = "$(cat ${config.sops.secrets.DEEPSEEK_API_KEY.path})";
    OPENCODE_API_KEY = "$(cat ${config.sops.secrets.OPENCODE_API_KEY.path})";
    OPENAI_API_KEY = "$(cat ${config.sops.secrets.OPENAI_API_KEY.path})";
    GITHUB_ACCESS_TOKEN = "$(cat ${config.sops.secrets.GITHUB_ACCESS_TOKEN.path})";
    GH_TOKEN = "$(cat ${config.sops.secrets.GITHUB_ACCESS_TOKEN.path})";
    MOONSHOT_API_KEY = "$(cat ${config.sops.secrets.MOONSHOT_API_KEY.path})";
    KIMI_API_KEY = "$(cat ${config.sops.secrets.MOONSHOT_API_KEY.path})";
    CONTEXT7_API_KEY = "$(cat ${config.sops.secrets.CONTEXT7_API_KEY.path})";
    NPM_PRIVATE_TOKEN = "$(cat ${config.sops.secrets.NPM_PRIVATE_TOKEN.path})";
  };
}
