# nixos/config/home/sops.nix
{
  config,
  inputs,
  pkgs,
  ...
}: let
  protonServers = import ./vpn/proton-servers.nix;

  mkVpnTemplate = server: {
    name = "vpn-${server.name}.conf";
    value = {
      path = "${config.home.homeDirectory}/.vpn/configs/${server.name}.conf";
      mode = "0600";
      content = ''
        # ${server.label}
        [Interface]
        PrivateKey = ${config.sops.placeholder.PROTON_VPN_PRIVATE_KEY}
        Address = 10.2.0.2/32, 2a07:b944::2:2/128
        DNS = 10.2.0.1, 2a07:b944::2:1

        [Peer]
        PublicKey = ${server.pubkey}
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = ${server.endpoint}
        PersistentKeepalive = 25
      '';
    };
  };
in {
  imports = [
    inputs.sops-nix.homeManagerModules.sops
  ];

  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets.yaml;

    # Declare all secrets used in templates
    secrets = {
      # API keys
      ANTHROPIC_API_KEY = {};
      GOOGLE_AI_API_KEY = {};
      OPENROUTER_API_KEY = {};
      SUPABASE_ACCESS_TOKEN = {};
      DEEPSEEK_API_KEY = {};
      OPENCODE_API_KEY = {};
      OPENAI_API_KEY = {};
      GITHUB_ACCESS_TOKEN = {};
      MOONSHOT_API_KEY = {};
      CONTEXT7_API_KEY = {};
      NPM_PRIVATE_TOKEN = {};

      # Proton VPN WireGuard private key
      PROTON_VPN_PRIVATE_KEY = {};

      # File-based secrets
      "github_ssh_key" = {
        path = "${config.home.homeDirectory}/.ssh/github_snorreks";
        mode = "0600";
      };
      "aws_credentials" = {
        path = "${config.home.homeDirectory}/.aws/credentials";
        mode = "0600";
      };
    };

    templates =
      {
        "secrets-env" = {
          path = "${config.home.homeDirectory}/.config/sops/secrets-env";
          content = ''
            export ANTHROPIC_API_KEY="${config.sops.placeholder.ANTHROPIC_API_KEY}"
            export GOOGLE_AI_API_KEY="${config.sops.placeholder.GOOGLE_AI_API_KEY}"
            export GEMINI_API_KEY="${config.sops.placeholder.GOOGLE_AI_API_KEY}"
            export OPENROUTER_API_KEY="${config.sops.placeholder.OPENROUTER_API_KEY}"
            export SUPABASE_ACCESS_TOKEN="${config.sops.placeholder.SUPABASE_ACCESS_TOKEN}"
            export DEEPSEEK_API_KEY="${config.sops.placeholder.DEEPSEEK_API_KEY}"
            export OPENCODE_API_KEY="${config.sops.placeholder.OPENCODE_API_KEY}"
            export OPENAI_API_KEY="${config.sops.placeholder.OPENAI_API_KEY}"
            export GITHUB_ACCESS_TOKEN="${config.sops.placeholder.GITHUB_ACCESS_TOKEN}"
            export GH_TOKEN="${config.sops.placeholder.GITHUB_ACCESS_TOKEN}"
            export MOONSHOT_API_KEY="${config.sops.placeholder.MOONSHOT_API_KEY}"
            export KIMI_API_KEY="${config.sops.placeholder.MOONSHOT_API_KEY}"
            export CONTEXT7_API_KEY="${config.sops.placeholder.CONTEXT7_API_KEY}"
            export NPM_PRIVATE_TOKEN="${config.sops.placeholder.NPM_PRIVATE_TOKEN}"
          '';
        };

        "nix-access-tokens".content = ''
          access-tokens = github.com=${config.sops.placeholder.GITHUB_ACCESS_TOKEN}
        '';
      }
      // (builtins.listToAttrs (map mkVpnTemplate protonServers));
  };

  nix.extraOptions = ''
    !include ${config.sops.templates."nix-access-tokens".path}
  '';

  systemd.user.services.sops-import-environment = {
    Unit = {
      Description = "Import SOPS decrypted secrets into systemd user environment";
      After = ["sops-nix.service"];
    };
    Install = {
      WantedBy = ["default.target"];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c 'if [ -f ~/.config/sops/secrets-env ]; then set -a; source ~/.config/sops/secrets-env; systemctl --user import-environment; fi'";
    };
  };

  home.file.".profile".text = ''
    if [ -f "$HOME/.config/sops/secrets-env" ]; then
      . "$HOME/.config/sops/secrets-env"
    fi
  '';
}
