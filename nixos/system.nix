# nixos/system.nix
{
  inputs,
  pkgs,
  opts,
  ...
}: {
  nixpkgs = {
    overlays = [
      inputs.nur.overlays.default # NUR overlay
    ];
    config = {
      allowUnfree = true; # Allow unfree packages
      nvidia.acceptLicense = true; # Accept the Nvidia license
    };
  };

  # The per-machine host module (hardware + any host-only extras, e.g.
  # gs65's fan control) is added by flake.nix, not hardcoded here.
  imports = [
    ./config/system
  ];
  # Optimization settings and garbage collection automation
  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = "experimental-features = nix-command flakes";
    optimise = {
      automatic = true;
    };
    channel.enable = false; # remove nix-channel related tools & configs, we use flakes instead.
    settings = {
      allowed-users = ["${opts.username}"];
      warn-dirty = false;
      sandbox = "relaxed";
      # Manual optimise storage: nix-store --optimise
      # https://nixos.org/manual/nix/stable/command-ref/conf-file.html#conf-auto-optimise-store
      auto-optimise-store = true;
      max-jobs = "auto";
      cores = 0;
      experimental-features = ["nix-command" "flakes"];
      substituters = [
        "https://cache.numtide.com"
      ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "ryan4yin.cachix.org-1:Gbk27ZU5AYpGS9i3ssoLlwdvMIh0NxG0w8it/cv9kbU="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        # "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      ];
    };
  };

  programs.nh = {
    enable = true;
    clean.enable = true;
    clean.extraArgs = "--keep-since 4d --keep 3";
    flake = "${opts.flakeDir}";
  };

  powerManagement.cpuFreqGovernor = "schedutil";

  system = {
    stateVersion = "25.05";
    # Scheduled auto upgrade system (this is only for system upgrades,
    # if you want to upgrade cargo\npm\pip global packages, docker containers or different part of the system
    # or get really full system upgrade, use `topgrade` CLI utility manually instead.
    # I recommend running `topgrade` once a week or at least once a month)
    autoUpgrade = {
      enable = false; # Disabled to prevent large downloads on restricted connections
      operation = "switch";
      flake = "${opts.flakeDir}";
      flags = ["--update-input" "nixpkgs" "--commit-lock-file"];
      dates = "weekly";
    };
  };
}
