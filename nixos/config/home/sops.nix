# nixos/config/home/sops.nix
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  protonServers = import ./vpn/proton-servers.nix;
  envSecrets = import ./env-secrets.nix;

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

    # Declare all secrets used in templates.
    # Simple string secrets come from env-secrets.nix (see add_env_secret);
    # file-based / one-off secrets are declared here directly.
    secrets =
      (builtins.listToAttrs (map (s: {
          name = s.name;
          value = {};
        })
        envSecrets))
      // {
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

        # base64 tar.gz of Thunderbird account/auth files (prefs.js, logins,
        # OpenPGP keys, address book) — NOT the mail store. See
        # backup_thunderbird_profile / restore_thunderbird_profile.
        "thunderbird_profile_bundle" = {
          path = "${config.home.homeDirectory}/.config/sops/thunderbird-profile-bundle.b64";
          mode = "0600";
        };
      };

    templates =
      {
        # Honours `sessionVariable = false` the same way variables.nix does.
        # Without that guard a secret marked "don't expose" still landed in the
        # environment of every process: this file is sourced by ~/.profile, by
        # fish's interactiveShellInit, and by sops-import-environment.service
        # (which `systemctl --user import-environment`s it into the whole user
        # session). ANTHROPIC_API_KEY leaking that way made the Claude Agent SDK
        # bill a $0-credit console account instead of the Pro OAuth token.
        "secrets-env" = {
          path = "${config.home.homeDirectory}/.config/sops/secrets-env";
          content =
            lib.concatMapStrings (
              s:
                if s.sessionVariable or true
                then
                  lib.concatMapStrings (
                    varName: ''
                      export ${varName}="${config.sops.placeholder.${s.name}}"
                    ''
                  ) ([s.name] ++ (s.aliases or []))
                else ""
            )
            envSecrets;
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
