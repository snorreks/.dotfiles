# nixos/config/home/ssh.nix
#
# THE SINGLE OWNER of ~/.ssh/config.
#
# 🔴 WHY THIS FILE EXISTS AT ALL — two bugs, one symptom.
#
# The travel aliases in ./travel.nix were correct in the evaluated config the
# whole time: `Host legion` with `Port 2222` and the pinned host key was in
# `programs.ssh.extraConfig`, and `~/.ssh/known_hosts.travel` was deployed
# correctly. None of it was ever written to disk, and the failure was silent.
#
#   1. `programs.ssh.enable` was never set to true. travel.nix declared
#      `extraConfig`, but home-manager's ssh module does nothing at all unless
#      `enable` is true, so the value was inert on BOTH hosts.
#
#   2. `config/home/files/default.nix` ALSO declared `home.file.".ssh/config"`,
#      with the github/gitlab stanzas as a static file. That is the SAME
#      attribute path home-manager's ssh module writes, so the two were in
#      direct competition for one symlink.
#
# Bug 1 is what HID bug 2 from failing loudly. With `enable = false`, the
# `mkIf` around home-manager's definition evaluates the attribute away, so the
# two `home.file` definitions never collide and evaluation succeeds — the
# static file simply wins. Turn `enable` on without removing the static
# definition and the build now fails with a duplicate-attribute error on
# `.ssh/config`, which is the correct outcome and the reason both changes have
# to land together.
#
# RULE, stated so the next change does not reintroduce this: exactly ONE thing
# may write ~/.ssh/config. Modules contribute stanzas by extending
# `programs.ssh.extraConfig`, which merges as a list; nobody adds a second
# `home.file.".ssh/config"`.
#
# known_hosts is deliberately still NOT managed per-user. That file grows live
# as SSH learns hosts, so declaring it wholesale meant every rebuild tried to
# back up the live file and overwrite it with a stale repo copy — discarding
# learned hosts, and blocking activation outright once a leftover `.backup`
# existed. The pins we actually want (github.com, gitlab.com, the travel
# server) live in ../../system/ssh.nix, which writes /etc/ssh/ssh_known_hosts
# and is checked through OpenSSH's default GlobalKnownHostsFile.
{...}: {
  programs.ssh = {
    # Owned here rather than in travel.nix, because these stanzas are wanted on
    # every host, while the travel aliases are wanted only where
    # opts.travel.enable is true.
    enable = true;

    # 🔴 THIS IS THE WHOLE POINT OF THE FILE, and it is load-bearing.
    #
    # `enableDefaultConfig = false` stops home-manager emitting its own block of
    # ssh defaults — and that block was silently overriding everything we set.
    #
    # ssh_config takes the FIRST value it finds for a keyword, and home-manager
    # writes its defaults at the TOP of the file, before any extraConfig. So
    # every keyword it happens to default was already decided, and whatever
    # extraConfig said afterwards was discarded. Measured, on this machine,
    # before this line existed:
    #
    #     4:  ControlMaster no          ← home-manager, wins
    #     6:  ControlPersist no         ← home-manager, wins
    #     10:  ServerAliveInterval 0     ← home-manager, wins
    #     24:      ServerAliveInterval 30 ← travel.nix, never read
    #     $ ssh -G legion | grep serveraliveinterval
    #     serveraliveinterval 0
    #
    # That last line is the important one: ServerAliveInterval 0 means NO
    # keepalives at all, so a tailnet link that goes quiet — rather than being
    # closed — leaves an interactive session hanging forever instead of being
    # detected and dropped. The travel comment in travel.nix about noticing a
    # quiet link "quickly" was describing behaviour that did not exist.
    #
    # It cannot be fixed through the typed options instead: every
    # programs.ssh.serverAliveInterval / controlMaster / userKnownHostsFile in
    # this home-manager version fails with
    #     Renaming error: option `programs.ssh.settings.*.<X>' does not exist.
    # so the options that would win the shadowing are themselves unusable. Owning
    # the whole file is the only remaining route, and it also means the values
    # written below are the values ssh actually reads.
    enableDefaultConfig = false;

    # Required, and intentionally EMPTY.
    #
    # home-manager asserts that `settings."*"` is declared whenever extraConfig
    # is set with enableDefaultConfig = false, so this must exist — but it does
    # not need to contain anything. An empty global block means ssh's own
    # compiled-in defaults apply (TCPKeepAlive yes, HashKnownHosts yes, …), and
    # every value that matters is stated per-host in extraConfig below, where it
    # is visible next to the thing it affects.
    settings."*" = {};

    # The git hosts. The private half is installed by sops and the public half
    # by ./files/default.nix; both are already unconditional, and
    # ./git.nix already points `programs.git.signing.key` at this identity, so
    # the host entry belongs on every host too.
    extraConfig = ''
      # Generated by nixos/config/home/ssh.nix
      #
      # No `UserKnownHostsFile` here on purpose. travel.nix emits the one that
      # applies, because only it knows whether the pin was provisioned — and with
      # enableDefaultConfig = false the first line now WINS, so a second one here
      # would quietly shadow it, which is the same bug in a new place.

      Host github.com
          HostName github.com
          User git
          IdentityFile ~/.ssh/github_snorreks
          AddKeysToAgent yes

      Host gitlab.com
          HostName gitlab.com
          User git
          IdentityFile ~/.ssh/github_snorreks
          AddKeysToAgent yes
    '';
  };
}
