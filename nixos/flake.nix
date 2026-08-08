# nixos/flake.nix
{
  description = "Sonny's NixOS Configuration";

  inputs = {
    # Temporarily pinned to working rev (ollama-cuda build broken on latest head).
    # Revert to nixos-unstable once fixed upstream.
    nixpkgs.url = "github:NixOS/nixpkgs/421eebfd0ec7bccd4abe826ce62d7e6e83129493";
    nur.url = "github:nix-community/NUR";

    llm-agents.url = "github:numtide/llm-agents.nix";
    curd = {
      url = "github:Wraient/curd";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      # url = "github:the-argus/spicetify-nix";

      inputs.nixpkgs.follows = "nixpkgs";
    };

    stylix = {
      url = "github:danth/stylix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mangowm = {
      url = "github:mangowm/mango";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    alejandra = {
      url = "github:kamadorueda/alejandra";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    impermanence.url = "github:nix-community/impermanence";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {nixpkgs, ...} @ inputs: let
    system = "x86_64-linux";
    baseOpts = import ./options.nix;

    # Optional, gitignored, machine-local overrides — never committed, since
    # they're for one-off personal tweaks (e.g. "externals unplugged today")
    # rather than checked-in host differences. Copy local.nix.example to
    # local.nix to use it.
    localOverrides =
      if builtins.pathExists ./local.nix
      then import ./local.nix
      else {};

    # Per-host overrides: hostname, GPU bus IDs, monitor defaults, etc.
    # The host's own hardware + any host-only extra modules live in
    # ./hosts/<key>/default.nix.
    hosts = {
      legion.optsOverrides = {};
      gs65.optsOverrides = import ./hosts/gs65/options.nix;
    };

    mkPkgs = nixpkgsInput:
      import nixpkgsInput {
        inherit system;
        config = {
          allowUnfree = true;
          nvidia.acceptLicense = true;
        };
        overlays = [inputs.nur.overlays.default];
      };

    mkHost = hostKey: hostCfg: enableOllama: let
      opts = baseOpts // hostCfg.optsOverrides // localOverrides // {inherit enableOllama;};
    in
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs system opts;};
        modules = [
          ./system.nix
          ./hosts/${hostKey}
          inputs.mangowm.nixosModules.mango
          inputs.sops-nix.nixosModules.sops
          inputs.home-manager.nixosModules.home-manager
          inputs.impermanence.nixosModules.impermanence
          inputs.disko.nixosModules.disko
          {
            home-manager = {
              backupFileExtension = "backup";
              useUserPackages = true;
              useGlobalPkgs = false; # Opt to use NUR overlay instead
              sharedModules = [
                inputs.mangowm.hmModules.mango
              ];
              extraSpecialArgs = {
                inherit inputs opts;
                # TODO: unify with the nixosSystem-level pkgs (see system.nix)
                # instead of constructing a second one here.
                pkgs = mkPkgs inputs.nixpkgs;
              };
              users.${opts.username} = import ./config/home;
            };
          }
          {
            sops = {
              age.keyFile = "/home/${opts.username}/.config/sops/age/keys.txt";
              defaultSopsFile = ./secrets.yaml;
              secrets = {
                password = {
                  neededForUsers = true;
                };
              };
            };
          }
        ];
      };
  in {
    formatter.${system} = inputs.alejandra.defaultPackage.${system};

    # Builds two flake outputs per host:
    #   <hostname>       — default build, ollama-cuda included
    #   <hostname>-fast  — skips ollama-cuda for quick rebuilds (nswitch-fast)
    nixosConfigurations = nixpkgs.lib.foldl' (
      acc: hostKey: let
        hostCfg = hosts.${hostKey};
        hostname = (baseOpts // hostCfg.optsOverrides // localOverrides).hostname;
      in
        acc
        // {
          ${hostname} = mkHost hostKey hostCfg true;
          "${hostname}-fast" = mkHost hostKey hostCfg false;
        }
    ) {} (builtins.attrNames hosts);
  };
}
