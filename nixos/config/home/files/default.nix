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
    # known_hosts is intentionally NOT managed here — it grows live as SSH
    # itself appends newly-trusted hosts, so forcing it to a repo-tracked
    # snapshot on every rebuild silently discarded those entries and,
    # once a home-manager backup file existed, blocked activation outright.
    # The hosts we actually want pinned (github.com, gitlab.com) live in
    # ../../system/ssh.nix instead (/etc/ssh/ssh_known_hosts, checked
    # automatically by OpenSSH — never touches this file).
  };
}
