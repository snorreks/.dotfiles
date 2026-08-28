{opts, ...}: {
  # Install & Configure Git
  programs.git = {
    enable = true;
    # Sign commits with the SSH key that GitHub already has for this account.
    # (Key must also be registered as an SSH *signing* key on GitHub.)
    signing = {
      format = "ssh";
      key = "/home/sonny/.ssh/github_snorreks.pub";
      signByDefault = true;
    };

    settings = {
      user = {
        name = "${opts.gitUsername}";
        email = "${opts.gitEmail}";
      };

      pull.rebase = false;
      init.defaultBranch = "main";
      credential.helper = "store";
    };
  };
}
