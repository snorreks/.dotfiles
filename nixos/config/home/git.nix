{opts, ...}: {
  # Install & Configure Git
  programs.git = {
    enable = true;
    signing.format = null;

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
