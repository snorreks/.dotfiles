{
  pkgs,
  lib,
  config,
  opts,
  ...
}: {
  # Set root password via sops-nix
  users.users.root.hashedPasswordFile = config.sops.secrets.password.path;

  # ── sudo: what the privileged wrapper is allowed to see ────────────────────
  #
  # `ns-maint confirm` must run as root, so from an SSH session the operator
  # runs `sudo ns-maint confirm <txid>` — and sudo's env_reset (on by default)
  # strips SSH_CONNECTION on the way.
  #
  # That variable is how ns-maint identifies WHO is confirming: it reads the
  # peer's address and port from it and then asks sshd's own journal whether a
  # session from exactly that peer was accepted AFTER the switch was armed. No
  # SSH_CONNECTION means no peer, and the tool refuses rather than guessing.
  #
  # The failure mode is nasty precisely because it is safe: you finish a
  # maintenance transaction, you confirm it, and you get "SSH_CONNECTION is
  # unset, so this is not an SSH session" — from a session that obviously is
  # one. The only ways out are `--assume-new-connection`, which is the flag for
  # "I checked some other way" and therefore the wrong answer for someone who
  # HAS checked, or weakening the check itself. Neither is acceptable.
  #
  # So these three are kept across sudo. They are facts about the session the
  # operator is already in, they are set by sshd before sudo runs, and they
  # grant no capability by themselves: keeping them means the verification can
  # actually happen instead of being bypassed.
  security.sudo.extraConfig = ''
    Defaults env_keep += "SSH_CONNECTION SSH_CLIENT SSH_TTY"
  '';

  security.sudo.extraRules = [
    {
      users = [opts.username]; # Make sure opts.username is correctly defined/passed
      commands = [
        {
          command = "/run/current-system/sw/bin/iptables";
          options = ["NOPASSWD"];
        }
        {
          command = "/etc/profiles/per-user/${opts.username}/bin/kill-switch-cleanup";
          options = ["NOPASSWD"];
        }

        # {
        #   command = "${pkgs.isw}/bin/isw";
        #   options = ["NOPASSWD"]; # Allows running without a password
        # }
      ];
    }
  ];

  # Emergency kill-switch: allow the user to reboot/power-off without a password
  # so `kill-switch --reboot` works during a frozen screen, when no polkit agent
  # is available for interactive authentication.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (
        subject.user == "${opts.username}"
        && (action.id == "org.freedesktop.login1.reboot" ||
            action.id == "org.freedesktop.login1.power-off")
      ) {
        return polkit.Result.YES;
      }
    });
  '';

  # TPM2 settings if you are utilizing TPM hardware
  security.tpm2 = {
    enable = true;
    pkcs11.enable = true; # Only enable if you use TPM for encryption keys
    tctiEnvironment.enable = true; # Context interface for TPM commands
  };

  # For hyprland to work properly
  # security.polkit.enable = true; # Authorization framework for desktop environments

  # Smartcard daemon for Yubikey (PIV, GPG, etc.)
  services.pcscd.enable = true;

  # Basic system security settings
  services.fail2ban.enable = true; # Protect against brute force attacks

  security.rtkit.enable = true;

  # ----- Enable gnome-keyring so zed editor remembers your logins
  # Note this will prompt password for zed and chrome once every boot

  security.pam.services = {
    swaylock = {};
    # for gnome-keyring
    greetd = {
      enableGnomeKeyring = true;
    };
    login.enableGnomeKeyring = true;
  };

  services = {
    gnome.gnome-keyring.enable = true;
  };

  # ---- End of gnome-keyring

  # Make sure gnome-keyring is installed system-wide
  # environment.systemPackages = with pkgs; [
  #   gnome-keyring
  # ];
  # services.gnome.gnome-keyring.enable = true;

  # Firejail for restricting the running environment of untrusted applications
  programs.firejail = {
    enable = true;
    wrappedBinaries = {
      mpv = {
        executable = "${lib.getBin pkgs.mpv}/bin/mpv";
        profile = "${pkgs.firejail}/etc/firejail/mpv.profile";
      };
      imv = {
        executable = "${lib.getBin pkgs.imv}/bin/imv";
        profile = "${pkgs.firejail}/etc/firejail/imv.profile";
      };
      zathura = {
        executable = "${lib.getBin pkgs.zathura}/bin/zathura";
        profile = "${pkgs.firejail}/etc/firejail/zathura.profile";
      };
    };
  };
}
