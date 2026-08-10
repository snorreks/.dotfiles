# nixos/config/system/ssh.nix
#
# Pins host keys for the git hosts we always trust into
# /etc/ssh/ssh_known_hosts (checked automatically by OpenSSH's default
# GlobalKnownHostsFile — no ssh_config changes needed).
#
# Deliberately NOT home-manager's `home.file ".ssh/known_hosts"`: that file
# also grows live (SSH appends new host keys on first connect to anything),
# so declaring it wholesale meant every rebuild tried to back up the live
# file before overwriting it with the stale repo copy — silently discarding
# newly-learned hosts, and permanently blocking activation once a previous
# `.backup` was left behind (home-manager refuses to clobber an existing
# backup). Pinning just the hosts we actually care about here means the
# per-user known_hosts file is never touched by home-manager again.
{...}: {
  programs.ssh.knownHosts = {
    "github.com-ed25519" = {
      hostNames = ["github.com"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    };
    "github.com-rsa" = {
      hostNames = ["github.com"];
      publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
    };
    "github.com-ecdsa" = {
      hostNames = ["github.com"];
      publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
    };
    "gitlab.com" = {
      hostNames = ["gitlab.com"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
    };
  };
}
