{inputs, ...}: {
  imports = [
    inputs.impermanence.nixosModules.home-manager.impermanence
  ];
  home.persistence."/persist/home" = {
    directories = [
      "Downloads"
      "Music"
      "Pictures"
      "Documents"
      "Videos"
      "Projects"
      "Android"
      ".dotfiles"
      ".thunderbird"
      ".android"
      ".steam"
      # ".npm"
      ".java"
      ".gradle"
      ".bun"
      ".dart"
      ".vscode"
      ".gnupg"
      ".ssh"
      ".nixops"
      {
        directory = ".local/share/Steam";
        method = "symlink";
      }

      ".local/share/keyrings"
      ".local/share/direnv"

      # Browser profiles (survive NixOS updates)
      ".config/zen"
      ".config/BraveSoftware"
      ".mozilla"
    ];
    files = [
      ".nvidia-settings-rc"
    ];
    allowOther = true;
  };
}
