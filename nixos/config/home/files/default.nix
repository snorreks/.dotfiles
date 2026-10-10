{...}: {
  home.file = {
    # Non-secret config files (SSH keys are handled by sops above)

    # 🔴 ~/.ssh/config is NOT here on purpose.
    #
    # It used to be, as `source = ./.ssh/config`, holding the github/gitlab
    # stanzas. That is the SAME attribute path home-manager's ssh module
    # writes, so the two competed for one symlink — and the static file won,
    # which is why the travel aliases in ../travel.nix were in the evaluated
    # config and on disk simultaneously but had no effect. The owner is now
    # ../ssh.nix; modules contribute stanzas through `programs.ssh.extraConfig`
    # instead. See the header there for the full account.
    #
    # known_hosts is likewise not managed here: it grows live as SSH appends
    # newly-trusted hosts, so forcing a repo-tracked snapshot discarded those
    # entries and, once a backup file existed, blocked activation outright.
    # The pins we want (github.com, gitlab.com, the travel server) live in
    # ../../system/ssh.nix instead (/etc/ssh/ssh_known_hosts, checked
    # automatically by OpenSSH — never touches this file).
    ".aws/config" = {
      source = ./.aws/config;
    };
    ".ssh/github_snorreks.pub" = {
      source = ./.ssh/github_snorreks.pub;
    };
  };
}
