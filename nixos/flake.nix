# nixos/flake.nix
{
  description = "Sonny's NixOS Configuration";

  inputs = {
    # TEMP: testing against latest nixos-unstable. If it breaks (e.g. ollama-cuda
    # or an input that can't keep up), restore the pinned rev below and re-run
    # `nix flake lock`.
    # nixpkgs.url = "github:NixOS/nixpkgs/421eebfd0ec7bccd4abe826ce62d7e6e83129493";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
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

    # Wallpaper-derived dynamic theming (runtime color extraction + templates).
    # Follows the pinned nixpkgs so matugen's cargo crates are fetched through
    # static.crates.io: crates.io's api/v1 endpoint now 403s nixpkgs' curl
    # User-Agent, and matugen's own nixpkgs pin predates that fix. The pin
    # already ships matugen >= 4.1, so base16 palette output is unaffected.
    matugen = {
      url = "github:InioX/matugen";
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

    # Terminal multiplexer for AI coding agents — same upstream source as aikami
    herdr = {
      url = "github:ogulcancelik/herdr";
      inputs.nixpkgs.follows = "nixpkgs";

      # herdr pins rust-overlay to 4cdea39, which predates upstream commit
      # 892c035 "treewide: stdenv.is* -> stdenv.hostPlatform.is*" — so building
      # herdr's toolchain emitted two nixpkgs deprecation warnings from
      # rust-overlay's lib/mk-aggregated.nix. herdr itself hasn't bumped its
      # lock, so override the indirect input here and pin it to the fix commit.
      # Drop this override once `nix flake update herdr` pulls a rust-overlay
      # that has it.
      inputs.rust-overlay = {
        url = "github:oxalica/rust-overlay/892c035d7c2ff75acd5da10424a47ab454e1f3dc";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };

    # Terminal fire animation — clear your terminal with ASCII flames
    pyroclear = {
      url = "github:shreyanth-sureshkrishnaa/pyroclear";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Collie — the phone web UI for the SAME herdr workspaces and agents: a
    # PWA served over private Tailscale Serve, gated on a Tailscale identity
    # and paired per device. See docs/mobile-agents.md.
    #
    # PINNED BY TAG, not by branch. A tag is a `chore(release): x.y.z` commit,
    # so moving the binary is the explicit `nix flake update collie`; a branch
    # would move under a plain `nix flake update` and swap the daemon a phone
    # is talking to with no reviewable diff. The rev and narHash that this tag
    # resolved to are both recorded in flake.lock.
    #
    # nixpkgs.follows: upstream pins its own nixpkgs revision for the BUILD
    # ENVIRONMENT (bun, node, tmux, zellij), which we have no use for. Only
    # `packages.<system>.{collie,default}` is consumed, and that derivation is
    # `pkgs.callPackage ./packaging/nix/collie.nix` over a `fetchurl` of the
    # published release tarball — so following our nixpkgs changes which
    # autoPatchelfHook rewrites the ELF interpreter in, and nothing about the
    # payload itself.
    #
    # ⚠ The package WRAPS a published release tarball; it never builds from
    # source (`bun install` needs the network, a Nix derivation has none). Its
    # version comes from `packaging/nix/sources.json` at that tag, and upstream
    # refreshes that file ONE RELEASE LATE: at tag v1.15.3 it still names
    # v1.15.0. So `collie version` under this input reports 1.15.0+<rev>. That
    # is upstream's lag, not a Nix packaging mistake — the manifest and hashes
    # in that file are what prove the payload is the real signed release.
    collie = {
      url = "github:AltanS/collie/v1.15.3";
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
      legion.optsOverrides = import ./hosts/legion/options.nix;
      gs65.optsOverrides = import ./hosts/gs65/options.nix;
    };

    mkPkgs = nixpkgsInput:
      import nixpkgsInput {
        inherit system;
        config = {
          allowUnfree = true;
          nvidia.acceptLicense = true;
        };
        overlays = [
          inputs.nur.overlays.default
          # protonup-ng 0.2.1 can't install the per-arch GE-Proton tarballs.
          (import ./pkgs/protonup-ng-overlay.nix)
        ];
      };

    mkHost = hostKey: hostCfg: enableOllama: let
      # recursiveUpdate, not `//`: a host (or local.nix) overriding a single
      # key of a nested attrset — say `mouse.thumbWheelInvert` — must not drop
      # the rest of that attrset. Lists still replace wholesale, so
      # `monitorrule` keeps its all-or-nothing semantics.
      opts =
        nixpkgs.lib.recursiveUpdate
        (nixpkgs.lib.recursiveUpdate
          (nixpkgs.lib.recursiveUpdate baseOpts hostCfg.optsOverrides)
          localOverrides)
        {inherit enableOllama;};
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
    #   <hostname>       — follows the host's enableOllama (hosts/<host>/options.nix)
    #   <hostname>-fast  — skips ollama-cuda for quick rebuilds (nswitch-fast)
    nixosConfigurations = nixpkgs.lib.foldl' (
      acc: hostKey: let
        hostCfg = hosts.${hostKey};
        mergedOpts = baseOpts // hostCfg.optsOverrides // localOverrides;
        hostname = mergedOpts.hostname;
      in
        acc
        // {
          ${hostname} = mkHost hostKey hostCfg mergedOpts.enableOllama;
          "${hostname}-fast" = mkHost hostKey hostCfg false;
        }
    ) {} (builtins.attrNames hosts);
  };
}
