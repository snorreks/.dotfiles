{...}: {
  home.file = {
    # Non-secret config files (SSH keys are handled by sops above)
    ".aws/config" = {
      source = ./.aws/config;
    };
    ".ssh/config" = {
      source = ./.ssh/config;
    };
    ".ssh/github_snorreks.pub" = {
      source = ./.ssh/github_snorreks.pub;
    };
    ".ssh/known_hosts" = {
      source = ./.ssh/known_hosts;
    };
  };
}
