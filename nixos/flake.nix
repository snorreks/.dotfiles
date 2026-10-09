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
    # ⚠ THE PINNED TAG IS NOT THE VERSION YOU GET. The package WRAPS a
    # published release tarball; it never builds from source (`bun install` needs
    # the network, a Nix derivation has none). Its version comes from
    # `packaging/nix/sources.json` AT THAT TAG, and upstream writes that file
    # from the PREVIOUS release's manifest — so it trails by one at every tag:
    # v1.15.3 names v1.15.0, v1.16.2 names v1.16.1, v1.18.1 names v1.17.2.
    #
    # So `collie version` reporting 1.15.0 under the v1.15.3 pin is ACCURATE:
    # the derivation really does fetch the v1.15.0 tarball, and the hashes in
    # that file are what prove the payload is the genuine signed release. This
    # is upstream's release ordering, not a Nix packaging mistake — and only
    # upstream can close it. Judge a bump by the PAYLOAD, not by the tag.
    #
    # To move it: `collie-bump <version>`, which rewrites this line, locks, and
    # prints both numbers. See docs/mobile-agents.md §2.
    collie = {
      url = "github:AltanS/collie/v1.15.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {nixpkgs, ...} @ inputs: let
    system = "x86_64-linux";
    baseOpts = import ./options.nix;

    # The server/travel ROLE policy: which role a host is in, which settings
    # contradict which role, how a private override file is scoped to one
    # host, and the DNS owner + its rescue list. Pure and builtins-only so
    # that lib/host-policy.nix can be asserted directly by
    # nixos/tests/server-foundation/role-policy.sh without evaluating a host —
    # see that file's header for why that constraint is the point.
    hostPolicy = import ./lib/host-policy.nix;

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
    #
    # Scoped BY HOST, not applied to everything: see hostPolicy.selectHostOverrides
    # for the accepted shapes and docs/headless-server.md § "Private overrides
    # and the build source" for the part that is easy to get wrong — a
    # gitignored file is invisible to a `flake:` reference unless the tree is
    # read by path, so an override that "works" locally can silently not exist
    # in the copy nix actually evaluates.
    localOverrides =
      if builtins.pathExists ./local.nix
      then import ./local.nix
      else null;

    # Per-host overrides: hostname, GPU bus IDs, monitor defaults, etc.
    # The host's own hardware + any host-only extra modules live in
    # ./hosts/<key>/default.nix.
    hosts = {
      legion.optsOverrides = import ./hosts/legion/options.nix;
      gs65.optsOverrides = import ./hosts/gs65/options.nix;
    };

    # The ONE place a host's options are resolved.
    #
    # Order matters and is not negotiable:
    #
    #   base             nixos/options.nix — every default, and the only place
    #                    the headless COMPATIBILITY boolean is defined
    #   host overrides   hosts/<key>/options.nix — checked in, per host
    #   private          local.nix, scoped to this host only (gitignored)
    #   role resolution  the server/travel role, folded back into `headless` so
    #                    every module still reads ONE boolean
    #
    # Everything else — the output's display name, the -fast variant — reads
    # the answer from here rather than re-merging the inputs a second time.
    resolveHostOpts =
      {
        hostKey,
        hostCfg,
        # null = follow whatever the host (or its private override) declared,
        # which is the default variant. Explicitly false = the `-fast` variant,
        # which skips the CUDA build.
        enableOllama ? null
      }:
      let
        selected = hostPolicy.selectHostOverrides {
          local = localOverrides;
          inherit hostKey;
        };
        # recursiveUpdate, not `//`: a host (or local.nix) overriding a single
        # key of a nested attrset — say `mouse.thumbWheelInvert` — must not
        # drop the rest of that attrset. Lists still replace wholesale, so
        # `monitorrule` keeps its all-or-nothing semantics.
        merged = nixpkgs.lib.recursiveUpdate (nixpkgs.lib.recursiveUpdate baseOpts hostCfg.optsOverrides) selected.overrides;
        withOllama = merged // {
          enableOllama = if enableOllama == null then merged.enableOllama else enableOllama;
        };

        diagnostics = hostPolicy.policyDiagnostics {
          role = withOllama.role or null;
          headless = withOllama.headless;
          batteryChargeLimit = withOllama.batteryChargeLimit;
          mobileAgents = withOllama.mobileAgents;
        };

        # Refuse a contradictory configuration AT EVALUATION. Not an
        # `assertions` entry: those fire at build time, one at a time, and a
        # role that contradicts the boolean is a mistake in the inputs rather
        # than a build failure. Failing here means every command that touches
        # this host explains it, and nothing half-builds first.
        #
        # Every problem is reported at once, because fixing them one rebuild at
        # a time on a machine you may only reach remotely is a bad use of a day.
        opts =
          if diagnostics.problems != [] then
            throw ''
              hostPolicy: ${hostKey} declares a contradictory configuration:

              ${builtins.concatStringsSep "\n" diagnostics.problems}
            ''
          else
            # Fold the RESOLVED role back into the effective boolean. This is
            # the compatibility contract other work depends on: `opts.headless`
            # is still a boolean and still means "this host is reached only
            # remotely", it is just now derived from the role when a role is
            # set — so a host promoted to a server by editing one line gets
            # every headless behaviour instead of having to remember a second.
            withOllama // {
              role = diagnostics.role;
              headless = diagnostics.effectiveHeadless;
            };
      in
      {
        inherit opts;
        shape = selected.shape;
        warnings =
          (if selected.warning != null then [selected.warning] else [])
          ++ diagnostics.warnings;
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
      resolved = resolveHostOpts {
        inherit hostKey hostCfg enableOllama;
      };
      opts = resolved.opts;

      # One line per observation, printed once per evaluation, and only when
      # there is something to say. A warning nobody can act on trains people to
      # ignore warnings; these all name the file to edit and the value to put
      # in it.
      #
      # `builtins.trace`, not the `warnings` option: that option is a listOf and
      # config/system/mobile-agents.nix already assigns it, so a second
      # assignment here would be an eval conflict rather than an append. The
      # two belong to different halves of the policy — module-level warnings
      # come from the mobile layer, these from role resolution.
      policyWarnings =
        if resolved.warnings == [] then
          []
        else
          ["private override shape is ${resolved.shape}."] ++ resolved.warnings;
    in
      builtins.trace (builtins.concatStringsSep "" (map (w: "hostPolicy (${hostKey}): ${w}\n") policyWarnings))
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
        # The SAME resolution mkHost uses. It used to be a second, different
        # merge (`//`, and it merged the flat local.nix on top of everything),
        # so the name of the output and the options the output was built from
        # could disagree — and a role, a host-scoped private override or a
        # warning is exactly the sort of thing a second merge drops.
        mergedOpts = (resolveHostOpts {
          inherit hostKey hostCfg;
          enableOllama = hostCfg.optsOverrides.enableOllama or baseOpts.enableOllama;
        }).opts;
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

    # The facts live in the STORE, not in $TMPDIR.
    #
    # Writing them to "$TMPDIR/host-facts.env" made them a sibling of every
    # suite's `mktemp -d "$TMPDIR/agent-ops-test.XXXXXX"`, and one suite's
    # cleanup removed the file the check had been handed — which surfaced as
    # "the Legion unit facts are available" failing on a file that had been
    # created successfully a moment earlier. A store path cannot collide with
    # anything a test does.
    agentOperationsFacts =
      nixpkgs.legacyPackages.${system}.writeText "agent-ops-host-facts" (
        "# Generated by nixos/flake.nix. Read-only facts about the REAL Legion.
"
        + nixpkgs.lib.concatStringsSep "\n" (
          nixpkgs.lib.mapAttrsToList (
            # ONE level of JSON encoding. The reader is
            # nixos/tests/agent-operations/agent-lifetime.sh, which strips a
            # wrapping pair of quotes and then unescapes the inner ones — one
            # decode pass.
            #
            # Encoding TWICE needs two passes, and the second is easy to forget:
            # every comparison then silently runs against the still-escaped text
            # and reports a mismatch that looks like a configuration bug.
            name: value: "HOST_FACT_${name}=${builtins.toJSON value}"
          )
          agentOperationsUnitFacts
        )
        + "\n"
      );


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
      # Build the real HM config, not just its drvPath: Mango's -p validator
      # catches upstream keyword changes only when this derivation is built.
      mango-config = let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = nixpkgs.lib;
        homes = map (host: allHosts.${host}.config.home-manager.users.sonny) ["legion" "gs65"];
      in pkgs.runCommand "mango-config-check" {nativeBuildInputs = [pkgs.bash pkgs.gnugrep];} ''
        ${lib.concatMapStringsSep "\n" (hm: ''
          test "$(grep -c '^exec_once = ' ${hm.xdg.configFile."mango/config.conf".source})" = 1
          if grep -Eq '^(exec-once|borderpx|gappih|gappiv|gappoh|gappov|monitorrule|tagrule|windowrule|focuscolor|bordercolor) *=' \
            ${hm.xdg.configFile."mango/config.conf".source}; then
            echo "obsolete Mango configuration keyword" >&2
            exit 1
          fi
          bash -n ${hm.xdg.configFile."mango/autostart.sh".source}
          grep -q 'dbus-update-activation-environment --systemd --all' ${hm.xdg.configFile."mango/autostart.sh".source}
          grep -q 'start mango-session.target' ${hm.xdg.configFile."mango/autostart.sh".source}
        '') homes}
        touch "$out"
      '';

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
            nixpkgs.legacyPackages.${system}.jq
            # `nix` for tests/server-foundation/role-policy.sh, which evaluates
            # nixos/lib/host-policy.nix directly with `nix eval --file`. That is
            # a plain local evaluation — no flake, no store, no network — which
            # is exactly why the policy was written as a builtins-only module,
            # and why this suite can run in here at all.
            nixpkgs.legacyPackages.${system}.nix
            nixpkgs.legacyPackages.${system}.jq
            # python3 binds the throwaway unix sockets tests/gui-session.sh
            # needs, so the launcher's `-S` session checks run against real
            # socket paths instead of skipping themselves. Without it every
            # launch assertion failed on a missing command rather than on the
            # behaviour under test.
            nixpkgs.legacyPackages.${system}.python3
            nixpkgs.legacyPackages.${system}.shellcheck
            nixpkgs.legacyPackages.${system}.util-linux
            nixpkgs.legacyPackages.${system}.which
          ];
          src = ./.;

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

          # NM_REQUIRE_ALL=0 says a skip is acceptable here, and
          # NM_SKIP_HOST_EVAL=1 says WHICH one and why, rather than silently
          # omitting it: host-eval.sh evaluates four real flake configurations,
          # and an evaluation inside a build sandbox cannot reach the flake's
          # inputs. Nesting that is not something to depend on.
          #
          # It is not forgotten. `bash nixos/tests/run.sh` outside a sandbox runs
          # it and FAILS if it does not pass, because there NM_REQUIRE_ALL
          # defaults to 1. So the host evaluation is run directly:
          #
          #   bash nixos/tests/server-foundation/host-eval.sh
          #
          # and nixos/tests/README.md says the same.
          export NM_REQUIRE_ALL=0
          export NM_SKIP_HOST_EVAL=1
          # This output owns maintenance and foundation only. The full registry
          # also needs agent/media tools and Cargo, with separate check closures
          # below; invoking it here silently skipped or failed unrelated lanes.
          shellcheck -x -P "$src/tests" "$src/config/system/maintenance/ns-maint.sh" "$src/config/home/updates/nupdate.sh" "$src/config/home/gui-session/ns-gui.sh" "$src/tests/ns-maint-transaction.sh" "$src/tests/nupdate-workflow.sh" "$src/tests/gui-session.sh"
          for suite in ns-maint-transaction.sh nupdate-workflow.sh gui-session.sh kill-switch-targets.sh disk-cleanup-safety.sh \
            server-foundation/role-policy.sh server-foundation/boot-health.sh \
            server-foundation/tailscale-reconcile.sh server-foundation/ssh-confirm.sh; do
            bash "$src/tests/$suite"
          done
          printf '%s\n' 'SKIP: full host evaluation is run outside the build sandbox'

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
            nixpkgs.legacyPackages.${system}.fish
            nixpkgs.legacyPackages.${system}.git
            nixpkgs.legacyPackages.${system}.gnugrep
            nixpkgs.legacyPackages.${system}.nix
            # python3 parses `nix eval --json` in agent-lifetime.sh. Without it
            # the JSON assertions silently compared against an empty string.
            nixpkgs.legacyPackages.${system}.python3
            # jq is a RUNTIME dependency of ns-agent-health and
            # herdr-daemon-check, not just of the tests: they build their JSON
            # with it. Without it in the closure the health suite runs against a
            # script that cannot emit a payload, and the failure reads as "the
            # heartbeat never fired".
            nixpkgs.legacyPackages.${system}.jq
            nixpkgs.legacyPackages.${system}.shellcheck
            nixpkgs.legacyPackages.${system}.sqlite
            nixpkgs.legacyPackages.${system}.restic
            nixpkgs.legacyPackages.${system}.systemd
            nixpkgs.legacyPackages.${system}.util-linux
            nixpkgs.legacyPackages.${system}.which
          ];
          src = ./.;

        }
        ''
          runHook preInstall

          # runCommand's builder runs in an empty directory with $src pointing at
          # the copied flake source; every path below is relative to $src.
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          # No facts are written here: they come from the store path below, so
          # there is nothing for a test's cleanup to delete.
          AGENT_OPS_NIXPKGS="${nixpkgs}" AGENT_OPS_HOST_FACTS="${agentOperationsFacts}" \
            bash "$src/tests/agent-operations/run.sh"

          touch "$out"
          runHook postInstall
        '';

      # The media-travel lane: private media, a namespace-confined qBittorrent,
      # the travel workflow. A SEPARATE output, for the same reason
      # agent-operations is one — the lanes were developed independently and
      # each has to stay runnable on its own.
      #
      # sqlite and jq are runtime inputs rather than optional extras:
      # state-restore.sh creates a REAL database and checks that a corrupt one is
      # refused, and host-isolation.sh parses evaluated host configurations.
      # A suite that quietly skipped the only test proving a media backup can be
      # verified would be worse than having no such test.
      media-travel =
        nixpkgs.legacyPackages.${system}.runCommand
        "media-travel"
        {
          nativeBuildInputs = [
            nixpkgs.legacyPackages.${system}.bash
            nixpkgs.legacyPackages.${system}.coreutils
            nixpkgs.legacyPackages.${system}.findutils
            nixpkgs.legacyPackages.${system}.git
            nixpkgs.legacyPackages.${system}.gnugrep
            nixpkgs.legacyPackages.${system}.jq
            nixpkgs.legacyPackages.${system}.nix
            nixpkgs.legacyPackages.${system}.python3
            nixpkgs.legacyPackages.${system}.shellcheck
            nixpkgs.legacyPackages.${system}.sqlite
            nixpkgs.legacyPackages.${system}.util-linux
            nixpkgs.legacyPackages.${system}.which
          ];
          src = ./.;

        }
        ''
          runHook preInstall

          # runCommand's builder runs in an empty directory with $src pointing
          # at the copied flake source; every path below is relative to $src.
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          # A skip is acceptable here and WHICH one it is says why: the two
          # host-evaluation suites evaluate real flake configurations, and an
          # evaluation inside a build sandbox cannot reach the flake's inputs.
          # Outside a sandbox, `bash nixos/tests/media-travel/run.sh` runs them
          # and FAILS if they do not pass, because NM_REQUIRE_ALL defaults to 1.
          export NM_REQUIRE_ALL=0
          export NM_SKIP_MEDIA_HOST_EVAL=1
          bash "$src/tests/media-travel/run.sh"

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

      # ── repo-contracts ──────────────────────────────────────────────────
      #
      # Registration only. Host construction above this point is untouched: no
      # `mkHost` change, no import change, no option change. This adds one
      # output so the checks this lane owns can be asked for by name, the same
      # way each other lane has its own output.
      #
      # What is in it:
      #   * tests/check-registry.sh  — the registry verifies itself: discovery,
      #                                 failure propagation, and that a suite
      #                                 which did not run never reads as passed.
      #   * tests/update-dotfiles-scope.sh — the fish function's refusals,
      #                                 against throwaway git fixtures.
      #   * cargo test for sys-daemon — the dashboard's HTTP admission rules and
      #                                 the process-kill safety rules.
      #
      # `cargo` and `rustc` come from the pinned nixpkgs, not from the host, so
      # this build does not depend on whatever toolchain the contributor
      # happens to have. The vendored crate sources are fetched through
      # `cargoLock`, exactly as package.nix already does for the daemon itself.
      repo-contracts =
        let
          inherit (nixpkgs.legacyPackages.${system}) runCommand;
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.rustPlatform.buildRustPackage
        {
          pname = "repo-contracts-tests";
          version = "0.1.0";
          # The fileset is rooted at the CRATE, not at ./ — buildRustPackage
          # expects Cargo.lock at the source root, so a fileset rooted higher
          # up lands it at config/home/sys-daemon/Cargo.lock and the build
          # fails in cargoSetupPostPatchHook.
          src = pkgs.lib.fileset.toSource {
            root = ./config/home/sys-daemon;
            fileset = pkgs.lib.fileset.unions [
              ./config/home/sys-daemon/Cargo.toml
              ./config/home/sys-daemon/Cargo.lock
              ./config/home/sys-daemon/ports.json
              ./config/home/sys-daemon/src
              ./config/home/sys-daemon/tests
            ];
          };
          cargoLock.lockFile = ./config/home/sys-daemon/Cargo.lock;
          # Only the Rust half. The shell suites run in the `repo-contracts`
          # check below; `doCheck` here would run them a second time.
          doCheck = false;
          # buildRustPackage wants to build something. There is no binary in
          # this crate — it is the library plus its tests — so the default
          # cargo build is satisfied by the library and the tests are run
          # explicitly.
          # The tests are RUN, not merely compiled.
          #
          # An earlier revision of this used `cargo test --no-run --tests`,
          # which compiles every test and executes none of them. The check
          # passed, green, having verified nothing — the exact failure this
          # lane exists to prevent, committed inside the check that exists to
          # detect it. If this ever stops executing the tests again, the
          # output of this step must not contain "test result:".
          buildPhase = ''
            runHook preBuild
            cargo test --offline -- --test-threads=1
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            touch "$out"
            runHook postInstall
          '';
          meta = {
            description = "sys-daemon HTTP admission and process-kill safety tests";
          };
        };

      # The shell half of the same lane: the registry's own tests and the
      # update_dotfiles scope tests. Kept separate from the Rust half so a
      # contributor can run `nix build .#checks.…repo-contracts-shells` in
      # seconds without building a Rust toolchain, and so a failure in one is
      # not confused with a failure in the other.
      repo-contracts-shells =
        nixpkgs.legacyPackages.${system}.runCommand
        "repo-contracts-shells"
        {
          nativeBuildInputs = [
            nixpkgs.legacyPackages.${system}.bash
            nixpkgs.legacyPackages.${system}.coreutils
            nixpkgs.legacyPackages.${system}.findutils
            nixpkgs.legacyPackages.${system}.git
            nixpkgs.legacyPackages.${system}.gnugrep
            # fish, because the function under test is a fish function and
            # check-registry.sh drives the real `run.sh`.
            nixpkgs.legacyPackages.${system}.fish
            nixpkgs.legacyPackages.${system}.shellcheck
          ];
          src = ./.;
        }
        ''
          runHook preInstall

          # Both suites build throwaway git repositories under HOME and must
          # never reach the builder's real one. update-dotfiles-scope.sh also
          # refuses to run against $HOME/.dotfiles outright, which is what
          # stops a broken path in it from driving the operator's real repo.
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"

          export NM_REQUIRE_ALL=0

          # Repo-wide lint, discovered by shebang rather than by a maintained
          # list. The list is what used to drift: every PR that added a script
          # had to remember to add it here, and the ones that did not simply
          # were not linted.
          echo "--- shellcheck (repo-wide, new findings only) ---"
          lint_failed=0
          current="$(
            cd "$src" || exit 1
            find . -name '*.sh' -type f | sort | while IFS= read -r f; do
              # "$f" is relative ("./config/..."), so shellcheck reports that
              # same relative path and it lines up with the baseline. Passing
              # "$src/$f" instead makes shellcheck report the store path, which
              # matches nothing in the baseline and turns every finding into a
              # "new" one.
              shellcheck -x -P "$src/tests" -S style "$f" -f gcc 2>/dev/null || true
            done | sed 's|^\./||' | sort -u
          )"
          baseline="$src/tests/shellcheck-baseline.txt"
          if [ -f "$baseline" ]; then
            # grep -Fxv -f, not `comm`. `comm` requires both inputs sorted in
            # the SAME collation, and inside the build sandbox the two sorts
            # do not agree, so every baseline line came back as "new". This
            # comparison does not care about ordering or locale at all.
            new_findings="$(printf '%s\n' "$current" | grep -Fxv -f "$baseline" || true)"
          else
            new_findings="$current"
          fi
          if [ -n "$new_findings" ]; then
            echo "shellcheck: findings not in the baseline:" >&2
            printf '%s\n' "$new_findings" | sed 's/^/    /' >&2
            lint_failed=1
          else
            echo "    ok   no new shellcheck findings"
          fi

          echo "--- fish syntax ---"
          while IFS= read -r f; do
            rel="''${f#"$src/"}"
            if fish -n "$f"; then
              echo "    ok   $rel"
            else
              echo "    FAIL $rel"
              lint_failed=1
            fi
          done < <(find "$src" -name '*.fish' -type f | sort)
          if [ "$lint_failed" -ne 0 ]; then
            echo "repo-contracts-shells: lint failed" >&2
            exit 1
          fi

          bash "$src/tests/check-registry.sh"
          bash "$src/tests/update-dotfiles-scope.sh"

          touch "$out"
          runHook postInstall
        '';
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
