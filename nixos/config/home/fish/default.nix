# nixos/config/home/fish/default.nix
{
  pkgs,
  opts,
  ...
}: {
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

    shellAliases = {
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
      # Default offline build — ollama-cuda only if host enables it (options.nix)
      nswitch = "nh os switch ~/.dotfiles/nixos --offline -- --extra-experimental-features flakes --extra-experimental-features nix-command";
      nswitcho = "nh os switch ~/.dotfiles/nixos -- --extra-experimental-features flakes --extra-experimental-features nix-command";
      # Update all flake inputs + switch (ollama-cuda only if host enables it)
      nswitchu = "nh os switch ~/.dotfiles/nixos --update -- --extra-experimental-features flakes --extra-experimental-features nix-command";
      # Fast build WITHOUT ollama-cuda (targets whichever host you're on)
      nswitch-fast = "nh os switch ~/.dotfiles/nixos#(hostname)-fast -- --extra-experimental-features flakes --extra-experimental-features nix-command";
      portcheck = "toggle-dev-ports";
      hm = "home-manager switch";
      nau = "sudo nix-channel --add https://nixos.org/channels/nixos-unstable nixos";
      nsgc = "sudo nix-store --gc";
      ngc = "sudo nix-collect-garbage -d";
      reboot = "systemctl reboot";
      poweroff = "systemctl poweroff";
      # y = "yazi";
      a = "ani-cli";
      brightnessctl = "brightnessctl -d intel_backlight";
      fetch = "fastfetch -l none";
      # ssh alias removed — Foot supports OSC 52 clipboard natively over SSH

      fuck = "f";
      cu = "claude_usage";
      pi-update = "cd $HOME/.pi && bun run update";

      where = "curl -s https://ipinfo.io/json | grep -E '\"ip\":|\"country\":|\"city\":'";

      c = "pyroclear";
    };

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
      # Source sops-nix decrypted secrets into Fish environment
      # Parses POSIX "export KEY=value" format (same file used by ~/.profile & systemd)
      set -l secrets_env "$HOME/.config/sops/secrets-env"
      if test -f "$secrets_env"
        while read -l line
          if string match -q 'export *' -- $line
            set -l kv (string match -r '^export\s+([^=]+)=(.*)\$' -- $line)
            if test (count $kv) -eq 3
              set -l val (string trim -c '"' -- $kv[3])
              set -gx $kv[2] $val
            end
          end
        end < "$secrets_env"
      end

      set fish_greeting # Disable greeting
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
