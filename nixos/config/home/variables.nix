# nixos/config/home/variables.nix
# A safe and minimal set of environment variables to ensure a stable session.
#
# 🔴 SECRETS ARE NOT HERE, AND WERE.
#
# Every credential in env-secrets.nix used to be added to home.sessionVariables
# as `"$(cat /run/secrets/NAME)"`. That is a shell substitution inside the
# profile.d fragment Home Manager generates, which means:
#
#   * a value containing a newline produced a SYNTAX ERROR in every login shell
#     — a PEM key did not merely arrive truncated, it broke the shell;
#   * the value was re-parsed as shell text on every login, on every session,
#     which is a standing invitation for a value to be code;
#   * and it did not run at all when there was nobody logging in — which, with
#     `linger`, is the normal state of this machine. The whole point of boot
#     lifetime is that the agents come up with nobody at the desk, so the one
#     mechanism meant to supply their credentials was the one mechanism that
#     cannot run there.
#
# Credentials now reach a process one of two ways, neither of which is "ambient
# session environment": `secret-env.sh --exec CMD` (values-as-data, via
# execve) or systemd LoadCredential on the specific unit that needs them. See
# config/home/sops.nix and config/home/scripts/scripts/secret-env.sh.
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
      # NOTHING here may force the dGPU globally. This is a hybrid laptop
      # (Intel iGPU renders the desktop; the dGPU is opt-in via PRIME offload),
      # so a session-wide "always NVIDIA" variable is applied to *every* client,
      # including the Intel-side ones that cannot honour it.
      #
      # Deliberately NOT set:
      #   GBM_BACKEND=nvidia-drm    — a pre-495 workaround. On driver 495+ the
      #     NVIDIA GBM backend is discovered on its own, and forcing it makes
      #     Intel-side GBM consumers (Xwayland included, e.g. gamescope's nested
      #     Xwayland) load a backend that cannot allocate on their device.
      #   LIBVA_DRIVER_NAME=nvidia  — routes ALL VA-API through NVDEC, so plain
      #     video playback wakes the 4090. Unset, libva picks iHD on the iGPU
      #     (verified: `vainfo` → "Intel iHD driver") and NVDEC still works for
      #     anything actually running on the dGPU.
      #   VDPAU_DRIVER=nvidia       — same class of problem for VDPAU clients.
      #
      # Per-app overrides are the right tool: `prime-run <app>`, or the
      # __NV_PRIME_RENDER_OFFLOAD / __GLX_VENDOR_LIBRARY_NAME pair in a Steam
      # launch option.

      # Read only by nvidia-vaapi-driver, i.e. only when something explicitly
      # asks for the NVIDIA VA-API backend. Harmless for Intel clients.
      NVD_BACKEND = "direct"; # [20, 26]
      # A common and safe workaround for NVIDIA cursor rendering issues.
      # WLR_NO_HARDWARE_CURSORS = "1";

      # --- User Preferences ---
      EDITOR = opts.defaultEditor;
      BROWSER = opts.defaultBrowser;
      TERMINAL = opts.defaultTerminal;
      XDG_BIN_HOME = lib.mkDefault "$HOME/.local/bin";
      XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";
      PI_HARNESS_CACHE_ENABLED = "0";
      PI_HARNESS_STORMBREAKER_ENABLED = "0";
    };
}
