{
  pkgs,
  lib,
  config,
  opts,
  ...
}: {
  # Set root password via sops-nix
  users.users.root.hashedPasswordFile = config.sops.secrets.password.path;

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
