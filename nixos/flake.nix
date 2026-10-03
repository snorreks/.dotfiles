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

    # The maintenance transaction package, built once and reused by both the
    # host configurations and the tests, so the thing the VM test boots is the
    # same derivation the Legion installs.
    nsMaintPackage =
      inputs.nixpkgs.legacyPackages.${system}.callPackage
      ./config/system/maintenance/package.nix {};

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
    # Builds two flake outputs per host:
    #   <hostname>       — follows the host's enableOllama (hosts/<host>/options.nix)
    #   <hostname>-fast  — skips ollama-cuda for quick rebuilds (nswitch-fast)
    #
    # Bound in `let`, not inside the returned attrset, so `checks` below can
    # READ the evaluated host configuration. Inside one attrset,
    # `nixosConfigurations` is a sibling attribute name, not a binding in scope.
    allHosts = nixpkgs.lib.foldl' (
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
    # The unit facts the lane's tests assert against are computed HERE, by
    # the flake, on the machine that runs `nix build` — not by a nested
    # `nix eval` inside the check. A nested `nix eval` of this flake cannot
    # work from inside a build: it needs the network to resolve the flake's
    # inputs, and it needs the store the host's Nix is already using. Baking
    # the facts in means the check compares the GENERATED UNIT against the
    # RULE without re-implementing either of them.
    agentOperationsUnitFacts = let
      hm = allHosts.legion.config.home-manager.users.sonny;
      svc = hm.systemd.user.services;
      # Home Manager's systemd unit options are typed `unspecified`, so a
      # single Wants/After can still be a bare STRING here rather than a
      # one-element list. Normalised, or this fails on a correct unit.
      asList = xs:
        if builtins.isList xs
        then xs
        else [xs];
      # builtins.toJSON rather than hand-quoted concatenation: the manual
      # version was three separate quoting bugs waiting to happen.
      jsonList = xs: builtins.toJSON (asList xs);
    in {
      herdrWantedBy = jsonList svc.herdr.Install.WantedBy;
      herdrAfter = jsonList svc.herdr.Unit.After;
      herdrWants = jsonList svc.herdr.Unit.Wants;
      herdrLoadCredential = toString (builtins.length svc.herdr.Service.LoadCredential);
      resumeSuccess = svc.herdr-resume.Service.SuccessExitStatus;
      resumeWantedBy = jsonList svc.herdr-resume.Install.WantedBy;
      hasImportEnvironment =
        if svc ? sops-import-environment
        then "true"
        else "false";
      sessionSecretVars = jsonList (
        builtins.filter (n: builtins.match ".*(API_KEY|ACCESS_TOKEN|PASSWORD).*" n != null)
        (builtins.attrNames hm.home.sessionVariables)
      );
    };
  in {
    formatter.${system} = inputs.alejandra.defaultPackage.${system};

    # Builds two flake outputs per host:
    #   <hostname>       — follows the host's enableOllama (hosts/<host>/options.nix)
    #   <hostname>-fast  — skips ollama-cuda for quick rebuilds (nswitch-fast)
    nixosConfigurations = allHosts;

    # ── checks ──────────────────────────────────────────────────────────────
    #
    # One entry point, `nix/tests/run.sh`, that a developer can also run by
    # hand, wrapped here so `nix flake check` runs it. Deliberately narrow: the
    # shell suites this PR adds, plus a shellcheck pass over exactly the files
    # this PR touched. A repository-wide lint, a secret scan and a CI workflow
    # belong to the repo-contracts PR; adding them here would mean every
    # sequential PR carries the noise of the last one.
    checks.${system} = {
      maintenance-contracts =
        nixpkgs.legacyPackages.${system}.runCommand
        "maintenance-contracts"
        {
          nativeBuildInputs = [
            nixpkgs.legacyPackages.${system}.bash
            nixpkgs.legacyPackages.${system}.coreutils
            nixpkgs.legacyPackages.${system}.findutils
            nixpkgs.legacyPackages.${system}.git
            nixpkgs.legacyPackages.${system}.gnugrep
            nixpkgs.legacyPackages.${system}.shellcheck
            nixpkgs.legacyPackages.${system}.util-linux
            nixpkgs.legacyPackages.${system}.which
          ];
          src = ./.;

          # NOT SANDBOXED, deliberately, and the reason is worth stating
          # because "unsandboxed check" normally reads as a red flag.
          #
          # agent-lifetime.sh evaluates Nix inside the check: the (headless ×
          # mobileAgents) matrix, and the generated herdr unit for the real
          # Legion. A nested `nix eval` inside a chrooted builder cannot see
          # /nix/store at all — it builds a private chroot store under $HOME and
          # then fails to read the flake, which is indistinguishable from "the
          # lifetime rule is broken". The alternatives were worse:
          #
          #   * drop the evaluation and assert on the module's source text,
          #     which tests the comment rather than the rule;
          #   * keep the evaluation out of `checks`, where it would then never
          #     run in CI at all.
          #
          # What this check runs is the repository's own bash, on disposable
          # fixtures under a temporary directory. It builds nothing, installs
          # nothing and writes nothing outside $TMPDIR.
          __noChroot = true;
        }
        ''
          runHook preInstall

          # runCommand's builder does NOT unpack `src` — it runs in an empty
          # directory with $src pointing at the copied flake source. Referencing
          # tests/run.sh relative to the cwd is why this check reported
          # "No such file or directory" the first time.
          #
          # HOME must be set and writable: the cleanup suite builds disposable
          # git worktrees under it and must not touch the builder's real one.
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          bash "$src/tests/run.sh"

          touch "$out"
          runHook postInstall
        '';

      # The agent-operations lane (agent-operations PR): credential loading,
      # agent lifetime, daemon-closure pinning, health redaction and a real
      # restic backup/restore. A SEPARATE output from maintenance-contracts,
      # not an addition to it, because the lanes are developed in parallel and
      # each has to be runnable on its own before any of them merge.
      #
      # restic and sqlite are in nativeBuildInputs rather than skipped: the
      # backup suite creates a REAL disposable repository and restores from it.
      # A shell suite that silently SKIPs the only test that proves a backup can
      # be restored is worse than having no such test.
      agent-operations =
        nixpkgs.legacyPackages.${system}.runCommand
        "agent-operations"
        {
          nativeBuildInputs = [
            nixpkgs.legacyPackages.${system}.bash
            nixpkgs.legacyPackages.${system}.coreutils
            nixpkgs.legacyPackages.${system}.findutils
            nixpkgs.legacyPackages.${system}.git
            nixpkgs.legacyPackages.${system}.gnugrep
            nixpkgs.legacyPackages.${system}.nix
            # python3 parses `nix eval --json` in agent-lifetime.sh. Without it
            # the JSON assertions silently compared against an empty string.
            nixpkgs.legacyPackages.${system}.python3
            nixpkgs.legacyPackages.${system}.shellcheck
            nixpkgs.legacyPackages.${system}.sqlite
            nixpkgs.legacyPackages.${system}.restic
            nixpkgs.legacyPackages.${system}.util-linux
            nixpkgs.legacyPackages.${system}.which
          ];
          src = ./.;

          # NOT SANDBOXED, deliberately, and the reason is worth stating
          # because "unsandboxed check" normally reads as a red flag.
          #
          # agent-lifetime.sh evaluates Nix inside the check: the (headless ×
          # mobileAgents) matrix. A nested `nix eval` inside a chrooted builder
          # cannot see /nix/store at all — it builds a private chroot store under
          # $HOME and then fails, which is indistinguishable from "the lifetime
          # rule is broken". The alternatives were worse: dropping the evaluation
          # and asserting on the module's source text (which tests the comment
          # rather than the rule), or keeping the evaluation out of `checks`,
          # where it would never run in CI at all.
          #
          # What this check runs is the repository's own bash against disposable
          # fixtures under a temporary directory. It builds nothing, installs
          # nothing, and writes nothing outside $TMPDIR.
          __noChroot = true;
        }
        ''
          runHook preInstall

          # runCommand's builder runs in an empty directory with $src pointing at
          # the copied flake source; every path below is relative to $src.
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          # Into $TMPDIR, not into $src: $src is a read-only store copy, and
          # writing into it fails with "Permission denied" on a line that looks
          # like the test cannot find its own data.
          cat > "$TMPDIR/host-facts.env" <<'FACTERMS'
          # Generated by nixos/flake.nix. Values evaluated from the REAL Legion
          # configuration on the machine that built this check.
          ${nixpkgs.lib.concatStringsSep "\n" (
            nixpkgs.lib.mapAttrsToList (name: value: "HOST_FACT_${name}=${value}") agentOperationsUnitFacts
          )}
          FACTERMS

          AGENT_OPS_HOST_FACTS="$TMPDIR/host-facts.env" \
            bash "$src/tests/agent-operations/run.sh"

          touch "$out"
          runHook postInstall
        '';

      # A real NixOS boot, with the real systemd units, a real root-owned state
      # directory and a real timer driving `ns-maint tick`. Needs KVM and builds
      # a whole system, so it is a SEPARATE check rather than part of the fast
      # one — `nix flake check` runs both, but a contributor running
      # `nix build .#checks.x86_64-linux.maintenance-contracts` gets the seconds
      # one and does not silently wait on a VM.
      #
      # Not added to `checks` automatically: a missing /dev/kvm would fail the
      # flake check on machines that cannot run it. It is a normal output, named
      # so it can be asked for explicitly:
      #   nix build .#maintenance-vm
    };

    # The VM test, exposed as a top-level output.
    maintenanceVm = import ./tests/maintenance-vm.nix {
      inherit system;
      pkgs = nixpkgs.legacyPackages.${system};
      maintenanceModule = ./config/system/maintenance.nix;
      maintenancePackage = nsMaintPackage;
      testDir = ./.;
    };
  };
}
