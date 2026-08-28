# nixos/config/home/packages.nix
#
# This file defines all user-specific packages installed via Home Manager.
# Packages are organized into categories for clarity and maintainability.
{
  inputs,
  pkgs,
  ...
}: let
  # --- Package Categories ---
  # We define lists for each category of packages here.
  cli-essentials = with pkgs; [
    gh # GitHub CLI
    git # Version control system
    bitwarden-cli # Bitwarden CLI (bw) — for sops-nix bootstrap on new machines
    sops # CLI for editing/encrypting secrets.yaml — used by add_env_secret
    # jujutsu # Jujutsu (jj) — modern, Git-compatible VCS
    # jjui # Terminal UI for Jujutsu
    curl # Tool for transferring data with URLs
    wget # Another tool for non-interactive network downloads
    jq # Command-line JSON processor
    google-cloud-sdk # Google Cloud CLI (gcloud, gsutil, bq)
    xdg-utils # Utilities for desktop integration (xdg-open, etc.)
    openssl # Cryptography and SSL/TLS Toolkit
    libarchive # For the `bsdtar` command to handle various archive formats
    file # Determine file type
    # ----------------------
  ];

  terminal-enhancements = with pkgs; [
    # herdr lives in ./herdr.nix — the package and its systemd user service
    # belong together (see the comment there on why it must not be a shell job).
    zoxide # A smarter `cd` command that learns your habits
    bluetuith # Bluetooth TUI manager
    stow # Symlink farm manager, useful for dotfiles
    fd # A simple, fast, and user-friendly `find` alternative
    ripgrep # A line-oriented search tool that recursively searches for a regex pattern
    fzf # A general-purpose command-line fuzzy finder
    entr # Run arbitrary commands when files change
    tomato-c # A simple Pomodoro timer for your terminal
    inputs.pyroclear.packages.${pkgs.stdenv.hostPlatform.system}.default # Terminal fire animation (pyroclear)
  ];

  system-monitoring = with pkgs; [
    lm_sensors # For monitoring CPU temperatures and fan speeds
    acpi # For querying battery status and thermal information
    powertop # Diagnose issues with power consumption and power management
    psmisc # Provides `killall` and other process management tools
    man-pages # The system's manual pages
    fastfetch # A neofetch-like tool for fetching system information, but faster
    perf # The profiler for the running kernel.
    # evhz # A tool for monitoring CPU frequency and power consumption
  ];

  development-langs = with pkgs; [
    # C/C++ Build Toolchain (often required by other dev tools like neovim plugins)
    gcc
    gnumake

    # Primary runtime for all passion projects (direnv handles per-project versions)
    bun
  ];

  development-tools = with pkgs; [
    # Nix
    alejandra
    nixd # Nix language server

    go
    rustc

    # Tools
    appimage-run # For running .AppImage files
  ];

  fonts = with pkgs; [
    nerd-fonts.jetbrains-mono # Primary font for terminals and editors
  ];

  llm-agents = with inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}; [
    # --- Core AI Coding Agents ---
    gemini-cli # Brings the power of Gemini directly into your terminal
    # qwen-code # Command-line workflow for Qwen3-Coder models
    # goose-cli # Local, extensible, open-source AI agent
    # letta-code # Memory-first agent that evolves across sessions
    jules # Asynchronous coding agent from Google
    pi # A terminal-based coding agent with multi-model support

    # --- Sandboxing & Security ---
    sandbox-runtime # Enforces filesystem and network restrictions
    opencode
    # --- Spec-Driven Development Workflow ---
    openspec # Framework for spec-driven AI development
    backlog-md # Manages project collaboration via plain-text markdown

    # --- Utilities ---
    rtk # CLI proxy that reduces LLM token consumption by 60-90%

    # --- Claude Ecosystem (Routed) ---
    claude-code
    # claude-code-router
    # claudebox # Sandboxed environment specifically for Claude

    # --- Workflow & Spec Management ---
    vibe-kanban
    cc-sdd

    # --- Browser Automation ---
    agent-browser # Headless browser automation CLI for AI agents (Vercel)

    # --- Usage Tracking ---
    ccusage # Token usage tracker for pi sessions

    # --- Code Review ---
    coderabbit-cli
    # paseo-desktop
    # zeroclaw # Fast, small, and fully autonomous AI assistant infrastructure
  ];

  gui-applications = with pkgs; [
    # System & Productivity
    lxmenu-data # Application menu entries for pcmanfm
    file-roller # Archive extraction GUI
    libreoffice-fresh
    hunspell # Spell checker backend for LibreOffice
    hunspellDicts.en_US
    hunspellDicts.nb_NO
    gparted # Partition editor
    qalculate-gtk # Powerful and easy to use desktop calculator
    pwvucontrol # volume control applet for PipeWire
    qbittorrent
    errands
    solaar # Logitech mouse configuration (MX Master 3S)
    slack
    thunderbird
    google-chrome
    telegram-desktop
    whatsapp-electron
    # calibre # uncomment once the bug is fixed
  ];

  media-tools = with pkgs; [
    playerctl # Control media players from command line / keybinds
    yt-dlp # Download video from youtube and other places
    ffmpeg # The cornerstone of video and audio conversion
    imagemagick # Command-line image manipulation suite
    gimp # Powerful image editor
    imv # A simple and scriptable image viewer for Wayland
    inputs.curd.packages.${pkgs.stdenv.hostPlatform.system}.default # Command-line anime streaming
  ];

  wayland-utilities = with pkgs; [
    # Wallpaper & Compositor
    awww # Animated wallpaper daemon (formerly swww)
    wlrctl # Miscellaneous wlroots utilities
    wayland
    glib

    # Disk Automounting
    udiskie

    # Screenshot & Screen Recording Stack
    grim # The base screenshot tool for wlroots
    slurp # For selecting a region on screen
    satty # Screenshot annotation tool (bound to keybinds — see README)
    wayfreeze # Freeze screen before capture
    wf-recorder # Screen recorder for wlroots (bound to keybinds — see README)
  ];

  gaming = with pkgs; [
    # lutris
    bubblewrap # Required by Proton 11+ (Steam Linux Runtime pressure-vessel sandbox)
    protonup-ng # For managing custom Proton-GE versions
    protontricks
    cabextract
    gamescope # Micro-compositor from Valve for games
    winetricks # Helper script to install runtime libraries for Wine
    mangohud # Vulkan and OpenGL overlay for monitoring FPS, temperatures, CPU/GPU load and more
    shadps4 # PlayStation 4 emulator for Linux
    prismlauncher # Minecraft launcher
    # System wine conflicts with Proton. Use Proton/Proton-GE for all Windows games.
    # (wineWow64Packages.staging.override {
    #   waylandSupport = true;
    # })
  ];

  hardware-and-gpu = with pkgs; [
    # GPU monitoring tool that works well with both NVIDIA and AMD
    nvtopPackages.nvidia

    libva-utils
    brightnessctl # Control backlight brightness from CLI
  ];
in {
  # MangoHud overlay config (used by the bloodborne fish function)
  xdg.configFile."MangoHud/MangoHud.conf".text = ''
    # MangoHud config for shadPS4 / Bloodborne
    # Toggle overlay with Shift+F12 (default)

    # --- Performance monitoring ---
    fps
    frametime
    gpu_stats
    gpu_temp
    gpu_power
    gpu_core_clock
    gpu_mem_clock
    cpu_stats
    cpu_temp
    cpu_power
    ram
    vram
    engine_version
    vulkan_driver
    # --- Presentation ---
    position=top-left
    font_size=20
    background_alpha=0.4
    # --- Behavior ---
    toggle_hud=Shift_R+F12
    fps_limit=0
    vsync=0
  '';

  # The final list of packages is a concatenation of all the categories defined above.
  # This makes it easy to add/remove packages from their logical group.
  home.packages =
    cli-essentials
    ++ terminal-enhancements
    ++ system-monitoring
    ++ development-langs
    ++ development-tools
    ++ fonts
    ++ gui-applications
    ++ media-tools
    ++ wayland-utilities
    ++ gaming
    ++ hardware-and-gpu
    ++ llm-agents;
}
