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
  # Autoloadable even in a bare pane of an already-running server: do not
  # depend on that pane having run the new interactiveShellInit/shellInit.
  # Other launchers can opt in with a real executable; no global PATH shim.
  childLauncher = pkgs.writeTextDir "__ns_agent_exec.fish" ''
      function __ns_agent_exec --description 'ready credentials scoped to one actual child'
          set -l loader "$HOME/.config/agent-ops/secret-env"
          if set -q SECRET_ENV
              set loader "$SECRET_ENV"
          end
          command "$loader" --ready --exec $argv
          return $status
      end
    '';
in {
  home.file = {
    # Copy all function files from ./functions to ~/.config/fish/functions
    ".config/fish/functions" = {
      source = pkgs.symlinkJoin {
        name = "fish-functions";
        paths = [./functions childLauncher];
      };
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
        # On a DESKTOP host these are unchanged: `nh os switch` against the flake,
        # exactly as before. On a headless host they are NOT emitted at all — fish
        # resolves an alias before a function of the same name, so leaving the
        # alias in place here would silently win over the guarded functions
        # defined further down. The server variants are deliberately explicit
        # about which of the four operations they perform (build / activate /
        # update inputs / stage a reboot) rather than collapsing them into one
        # word that does all four.
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
      # ── Credentials: values as data, never as sourced text ────────────────
      #
      # 🔴 The parser that used to live here is GONE, along with the template it
      # read. It was:
      #
      #     set -l kv (string match -r '^export\s+([^=]+)=(.*)\$' -- $line)
      #
      # `\$` inside fish single quotes is a backslash followed by a dollar, so
      # the pattern demanded that every secret line END with a literal "$" — it
      # matched essentially nothing, and nothing noticed because ~/.profile was
      # sourcing the same broken template. It also could not have worked: the
      # template was line-oriented (`while read -l line`), so a multiline value
      # would have been truncated, and `string trim -c '"'` would have eaten a
      # legitimate quote from the end of a value.
      #
      # What replaces it never parses a value at all. `ns-secrets` reads the
      # decrypted files as bytes and sets them as fish VARIABLES, which is fish's
      # own representation and cannot be re-parsed as code:
      #
      #   ns-secrets                       # load ready credentials into this shell
      #   ns-secrets check                 # readiness, no values
      #   ns-secrets run <cmd> [args...]   # strict: require all session keys
      # For OAuth/local-friendly selection: secret-env --ready --exec <cmd>.
      # For an explicitly required API key: secret-env --name KEY --exec <cmd>.
      #   ns-secrets exec <cmd>            # replace this shell with cmd + creds
      #
      # Nothing here is automatic. A credential arrives when a process asks for
      # it by name, which is what "scoped to the intended agent processes"
      # means in practice — as opposed to `systemctl --user import-environment`,
      # which put all of them into all of them.
      set -gx SECRET_ENV "$HOME/.config/agent-ops/secret-env"
      set -gx SECRET_ENV_MANIFEST "$HOME/.config/agent-ops/secrets.manifest"
      # Path lookup, aliases and byte handling belong to the loader alone.

      function ns-secrets --description 'load SOPS credentials as data, or check/scope them'
          if test (count $argv) -eq 0
              # Explicit convenience action only; skip unready credentials.
              # NUL records preserve embedded/trailing newlines and include
              # aliases. Split only the first '='; never source/eval values.
              for name in (command $SECRET_ENV --list)
                  command $SECRET_ENV --name "$name" --check >/dev/null 2>&1; or continue
                  command $SECRET_ENV --name "$name" --format=nul | while read --null -l pair
                      set -l fields (string split --max 1 '=' -- "$pair")
                      set -gx "$fields[1]" "$fields[2]"
                  end
              end
              return 0
          end
          switch $argv[1]
              case check
                  command $SECRET_ENV --check $argv[2..-1]
                  return $status
              case run
                  # Scoped: only this child process sees the values.
                  if test (count $argv) -lt 2
                      echo 'ns-secrets run: give me a command' >&2
                      return 2
                  end
                  command $SECRET_ENV --exec $argv[2..-1]
                  return $status
              case exec
                  shift
                  command $SECRET_ENV --exec $argv
                  return $status
              case '*'
                  echo "ns-secrets: unknown subcommand '$argv[1]' (check|run|exec)" >&2
                  return 2
          end
      end

      # Readiness only, never values, and never fatal: a credential that is not
      # decrypted yet must not stop an interactive shell from opening. Agents
      # that need one ask for it by name and get a clear refusal instead.
      if status is-interactive
          if not command $SECRET_ENV --check >/dev/null 2>&1
              set -g __ns_secrets_unready 1
          end
      end

      set fish_greeting # Disable greeting
      ${lib.optionalString serverHost ''        # ── Server OS updates ───────────────────────────────────────────────
        #
        # On a host nobody is sitting at, the desktop one-liners
        # (`nh os switch [--update]`, `nh os switch #host-fast`) hide three
        # decisions that must not be made implicitly:
        #
        #   1. "--update" moves EVERY flake input. Unreviewed, on the machine
        #      that is your only way in.
        #   2. "switch" activates. The old nswitch-safe armed a dead-man timer
        #      BEFORE building and rolled back with `systemctl reboot`, so a slow
        #      build rebooted the server and a failed activation was assumed to
        #      have changed nothing. See config/system/maintenance.nix.
        #   3. '#host-fast' is not a faster host, it is a host WITHOUT
        #      ollama-cuda. Activating it removes Ollama from the running
        #      system, including the models resident in the 4090's VRAM.
        #
        # So each verb here names exactly one step. Nothing here reboots; the
        # only reboot is `ns-maint reboot --yes`, a separate command on purpose.
        #
        # Published so the emergency scripts can tell they are on an unattended
        # host without having to be told on the command line while the machine
        # is already misbehaving. kill-switch.sh reads it (management processes
        # and their descendants are never targets, bare shared runtimes are not
        # either); kill-switch-cleanup.sh reads it (dropping the page cache and
        # cycling swap make a remote box briefly LESS responsive, so it refuses).
        set -gx NS_SERVER_MODE 1

        # NOTE on quoting: the messages below use single-quoted fish strings.
        # Double quotes work too, but every backslash would then have to be
        # doubled to survive both Nix and fish, which is exactly where this went
        # wrong once already.
        function nswitch --description 'build, then activate the OS as a guarded no-reboot transaction'
            if test (count $argv) -gt 0
                echo 'nswitch: no arguments on this host.' >&2
                echo '         build only:   ns-maint prepare' >&2
                echo '         activate:     ns-maint activate' >&2
                return 1
            end
            # Build first, offline from what is already fetched. This step arms
            # nothing: there is no deadline that can fire during it, so however
            # long it takes, the result is zero activation and zero rollback.
            sudo ns-maint prepare --offline; or return $status
            # Only now arm the deadline and hand activation to a system service.
            sudo ns-maint activate --timeout 20m
        end

        function nswitcho --description 'same as nswitch, but allows fetching from the network'
            sudo ns-maint prepare; or return $status
            sudo ns-maint activate --timeout 20m
        end

        function nswitchu --description 'update exactly ONE named flake input, then build and activate'
            if test (count $argv) -eq 0
                echo 'nswitchu no longer means "--update every input and switch".' >&2
                echo 'It means "update the one input you are about to review".' >&2
                echo >&2
                echo '  nswitchu nixpkgs        # update that input, rebuild, activate' >&2
                echo >&2
                echo 'It rewrites nixos/flake.lock, so review that diff before you' >&2
                echo 'confirm the transaction. Moving the whole input set in one' >&2
                echo 'unreviewed step is the failure this host cannot recover from.' >&2
                return 1
            end
            sudo ns-maint prepare --update-input $argv[1]; or return $status
            sudo ns-maint activate --timeout 20m
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
