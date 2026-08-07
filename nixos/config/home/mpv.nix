{...}: {
  programs.mpv = {
    enable = true;
    config = {
      hwdec = "auto-safe";
      vo = "gpu";
      profile = "gpu-hq";
      sub-auto = "all";
      gpu-context = "wayland";
    };
  };
}
