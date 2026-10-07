# nixos/config/home/fish/default.nix
{
  pkgs,
  lib,
  opts,
  ...
}: let
  # This host is an always-on box reached only over the tailnet.
  #
  # The distinction matters here and nowhere else: on a desktop you are standing
  # in front of the machine, so `nh os switch` is the right verb and its extra
  # conveniences cost you nothing. On a server the same verb means "update every
  # flake input and apply it, unreviewed, to something nobody is sitting at".
  serverHost = opts.headless;
in {
  home.file = {
    # Copy all function files from ./functions to ~/.config/fish/functions
    ".config/fish/functions" = {
      source = ./functions;
    };

    # ── Project-specific fish shortcuts (auto-sourced by conf.d) ──
    # Shims that source from the project repo — won't error if project absent
    ".config/fish/conf.d/nordclaw.fish".text = ''
      if test -f $HOME/Development/Projects/passion/nordclaw/scripts/direnv/nordclaw.fish
        source $HOME/Development/Projects/passion/nordclaw/scripts/direnv/nordclaw.fish
      end
    '';
    ".config/fish/conf.d/aikami.fish".text = ''
      if test -f $HOME/Development/Projects/passion/aikami/scripts/direnv/aikami.fish
        source $HOME/Development/Projects/passion/aikami/scripts/direnv/aikami.fish
      end
    '';
  };

  programs.pay-respects = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.fish = {
    enable = true;

    # `lib.optionalAttrs` rather than `lib.mkIf`: shellAliases is a plain
    # attrsOf, and mkIf inside a nested attrset is NOT unwrapped by the module
    # system — it would leave the alias defined with the value `false`.
    shellAliases =
      {
        # ls = "lsd";
        l = "ls -l";
        # la = "ls -a";
        # lla = "ls -la";
        # lt = "ls --tree";
        ltt = "ls --tree -d";
        cl = "clear";
        lgit = "lazygit";
        ldocker = "lazydocker";
        conf = "z ~/.config";
        nixos = "z ~/dotfiles/nixos";
        store = "z /nix/store";
        discord = "z ~/.dotfiles/nixos/config/home/discord";

        # ── OS updates ─────────────────────────────────────────────────────────
        #
        # Desktop aliases are unchanged. Server compatibility functions below
        # delegate to nupdate so kernel checks, staging and confirmation have
        # one implementation. Use nupdate/nconfirm for routine updates.
        # ── Garbage collection ─────────────────────────────────────────────────
        #
        # The old value was `nix-collect-garbage -d`. `-d` is "also delete
        # generations", and a deleted generation is a deleted way back: on a box
        # with no operator, "go back to the last known-good system" has to keep
        # working. Retention and generation deletion are now separate decisions,
        # and the second one is made by a human on purpose.
        #
        # On a server this goes through ns-maint gc, which also prints what is
        # currently pinned against collection. It never passes -d.
        nsgc = "sudo nix-collect-garbage";
        # Read-only, so no sudo prompt surprises in the middle of a rebuild.
        nmroots = "ns-maint roots";
        portcheck = "toggle-dev-ports";
        hm = "home-manager switch";
        nau = "sudo nix-channel --add https://nixos.org/channels/nixos-unstable nixos";
        nac = "ani-cli";
        brightnessctl = "brightnessctl -d intel_backlight";
        # Reclaim disk: caches, and a REPORT of what is reclaimable.
        # `dcdeep` additionally drops unused container images (re-pullable, but
        # large) and editor/agent caches. It no longer deletes generations,
        # volumes, worktrees or /tmp entries by age — see disk-cleanup.sh for
        # which of those now need a human and why.
        dclean = "disk-cleanup";
        dcdeep = "disk-cleanup --deep";
        reboot = "systemctl reboot";
        poweroff = "systemctl poweroff";
        # y = "yazi";
        fetch = "fastfetch -l none";
        # ssh alias removed — Foot supports OSC 52 clipboard natively over SSH

        fuck = "f";
        cu = "claude_usage";
        pi-update = "cd $HOME/.pi; and bun run update; and cd -";

        where = "curl -s https://ipinfo.io/json | grep -E '\"ip\":|\"country\":|\"city\":'";

        c = "pyroclear";
      }
      // (lib.optionalAttrs serverHost {
        # ── Server OS updates ────────────────────────────────────────────────
        # These are the guarded fish FUNCTIONS defined in interactiveShellInit
        # below, not aliases — but the alias entries still have to be absent,
        # because fish expands an alias before it looks up a function of the
        # same name. See there for what each one refuses to do.
        nmstatus = "sudo ns-maint status";
        nmabort = "sudo ns-maint abort";
      })
      // (lib.optionalAttrs (!serverHost) {
        # Desktop hosts keep the exact commands they have always had.
        nswitch = "nh os switch ~/.dotfiles/nixos --offline -- --extra-experimental-features flakes --extra-experimental-features nix-command";
        nswitcho = "nh os switch ~/.dotfiles/nixos -- --extra-experimental-features flakes --extra-experimental-features nix-command";
        nswitchu = "nh os switch ~/.dotfiles/nixos --update -- --extra-experimental-features flakes --extra-experimental-features nix-command";
        nswitch-fast = "nh os switch ~/.dotfiles/nixos#(hostname)-fast -- --extra-experimental-features flakes --extra-experimental-features nix-command";
        ngc = "sudo nix-collect-garbage";
      });

    shellAbbrs = {
      ".." = "cd ..";
      "..." = "cd ../..";
      ".3" = "cd ../../..";
      ".4" = "cd ../../../..";
      ".5" = "cd ../../../../..";
      mkdir = "mkdir -p";
      nc = "cd ~/Development/Projects/passion/nordclaw";
      ncw = "cd ~/Development/Projects/passion/nordclaw && taskplane dashboard";
      ncv = "bun moon run :fix --affected; and bun moon run :typecheck --affected";
      ncvt = "bun moon run :fix --affected; and bun moon run :typecheck --affected; and bun moon run :test --affected";
      ncs = "taskplane status";
      piu = "cd $HOME/.pi && bun run update";
    };

    interactiveShellInit = ''
      set fish_greeting # Disable greeting
      ${lib.optionalString serverHost ''        # Build before arming the rollback deadline. Activation runs in a
        # detached system service; the CLI waits for the result, then tells
        # you how to confirm after checking access from another session.
        set -gx NS_SERVER_MODE 1

        # Compatibility names delegate to the same updater. It inspects the
        # kernel before choosing guarded live activation or a staged reboot.
        function nswitch --description 'apply existing configuration offline'
            command nupdate --apply --offline $argv
        end

        function nswitcho --description 'apply existing configuration with network access'
            command nupdate --apply $argv
        end

        function nswitchu --description 'update nixpkgs, or one explicitly named input'
            if test (count $argv) -eq 0
                command nupdate
            else if test (count $argv) -eq 1
                command nupdate --input $argv[1]
            else
                echo 'Usage: nswitchu [input]' >&2
                return 2
            end
        end

        function nswitch-fast --description 'PREPARE the ollama-free output; activation is a separate, explicit step'
            set -l out (hostname)-fast
            echo "nswitch-fast builds the flake output '$out', which is this host" >&2
            echo 'WITHOUT ollama-cuda. That is the only difference from the default' >&2
            echo "output, and it is a real one: activating $out REMOVES ollama" >&2
            echo 'and the models resident in the GPU memory.' >&2
            echo >&2
            echo 'This command only PREPARES it. Nothing is activated, and nothing is' >&2
            echo 'rolled back, until you run ns-maint activate yourself.' >&2
            if not set -q NS_MAINT_ALLOW_FAST
                echo >&2
                echo 'Not doing it. If you have actually weighed that:' >&2
                echo '  set -gx NS_MAINT_ALLOW_FAST 1; nswitch-fast' >&2
                return 1
            end
            sudo ns-maint prepare --output $out --tag $out
        end
      ''}
      if status is-interactive
          # Dynamic theme: prefer the runtime-rendered starship config
          # (wallpaper colors), fall back to the HM-managed static one.
          if test -f "$HOME/.cache/theme/starship.toml"
              set -gx STARSHIP_CONFIG "$HOME/.cache/theme/starship.toml"
          end

          # Dynamic theme: yazi reads config from the runtime dir
          # (HM configs symlinked + theme.toml rendered from the palette).
          if test -d "$HOME/.cache/theme/yazi"
              set -gx YAZI_CONFIG_HOME "$HOME/.cache/theme/yazi"
          end

          # starship init fish | source is owned by home-manager's
          # enableFishIntegration (appended AFTER interactiveShellInit, so the
          # runtime STARSHIP_CONFIG export above still wins).

          # Recolor the running terminal from the dynamic theme (OSC 10/11/4).
          # foot has no live config reload, so emitting the escapes from the
          # prompt hook makes every open terminal follow a wallpaper change on
          # the next prompt (theme-render rewrites foot-osc.txt).
          function _recolor_terminal --on-event fish_prompt
              if test -s "$HOME/.cache/theme/foot-osc.txt"
                  printf '%s' (cat "$HOME/.cache/theme/foot-osc.txt")
              end
          end

          set fish_vi_force_cursor
          set fish_cursor_default block blink
          set fish_cursor_insert line blink
          set fish_cursor_replace_one underscore blink
          set fish_cursor_visual block

          set -gx EDITOR ${opts.defaultEditor}
          set -gx GOOGLE_CLOUD_PROJECT nordclaw-prod
          set -gx GOOGLE_CLOUD_LOCATION europe-west3
          set -gx VOLUME_STEP 5
          set -gx BRIGHTNESS_STEP 5

          set -Ux FZF_DEFAULT_OPTS "\
      --color=bg+:#363a4f,bg:#24273a,spinner:#f4dbd6,hl:#ed8796 \
      --color=fg:#cad3f5,header:#ed8796,info:#c6a0f6,pointer:#f4dbd6 \
      --color=marker:#f4dbd6,fg+:#cad3f5,prompt:#c6a0f6,hl+:#ed8796"

          function fish_user_key_bindings
              fish_default_key_bindings -M insert
              fish_vi_key_bindings --no-erase insert
          end
      end

      zoxide init fish | source
    '';

    plugins = [
      # {
      #   name = "tide";
      #   src = pkgs.fishPlugins.tide.src;
      # }
      {
        name = "autopair";
        src = pkgs.fishPlugins.autopair.src;
      }
      {
        name = "fzf";
        src = pkgs.fishPlugins.fzf.src;
      }
      # {
      #   name = "sponge";
      #   src = pkgs.fishPlugins.sponge.src;
      # }
    ];
  };
}
