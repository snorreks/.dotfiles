function bloodborne
    # ── shadPS4 / Bloodborne launcher (optimized) ─────────────────────
    # 1. PrimeRun-style PRIME offload: force the discrete NVIDIA GPU
    #    (RTX 4090) instead of the Intel iGPU on this hybrid laptop.
    set -lx __NV_PRIME_RENDER_OFFLOAD 1
    set -lx __VK_LAYER_NV_optimus NVIDIA_only
    set -lx __GLX_VENDOR_LIBRARY_NAME nvidia

    # 2. MangoHud overlay (Shift+F12 to toggle) + GameMode performance
    #    (performance governor, renice, NVIDIA powermizer — see gaming.nix).
    gamemoderun appimage-run ~/Games/bloodborne.AppImage
end
