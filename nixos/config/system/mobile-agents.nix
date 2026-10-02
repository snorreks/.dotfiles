# nixos/config/system/mobile-agents.nix
#
# The system-level half of the phone→herdr setup: a second sshd listener for
# Moshi's key authentication, and mosh bounded to a small UDP range.
#
# Gated on opts.mobileAgents.enable, which hosts/legion/options.nix sets. The
# counterpart on the user side is config/home/moshi-hook.nix, and the third
# piece is the WantedBy target in config/home/herdr.nix. Read docs/mobile-agents.md
# before enabling it.
#
# ── Why a second port instead of 22 ──────────────────────────────────────────
# server.nix already runs `--ssh=true`, and Tailscale SSH answers on tailnet
# port 22 BEFORE the OS sshd sees the connection — it authenticates with a
# Tailscale identity and bypasses authorized_keys entirely. Moshi authenticates
# with a key file and checks the public key on the host, so against a
# Tailscale-SSH hijacked port 22 it stalls ~60s and then reports a misleading
# auth error even though the key is authorized and the host is perfectly
# reachable. (Upstream documents this exact failure and calls Tailscale SSH
# incompatible with key auth; it also breaks the mosh bootstrap, because mosh
# needs a real sshd to run `mosh-server new` through.)
#
# So port 2222 is ordinary OpenSSH and 22 is left completely untouched as the
# recovery path. Nothing about Tailscale SSH changes.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = opts.mobileAgents;

  moshiHook = import ../../pkgs/moshi-hook.nix {
    inherit
      (pkgs)
      lib
      stdenvNoCC
      fetchurl
      symlinkJoin
      writeShellScriptBin
      ;
    mosh = pkgs.mosh;
    portRange = cfg.moshPortRange;
  };
in {
  # ── The mobile sshd listener ───────────────────────────────────────────────
  #
  # 🔴 22 IS SPELLED OUT HERE ON PURPOSE. `services.openssh.ports` is a plain
  # listOf option, NOT a list that merges with its default — assigning to it
  # REPLACES the default [22] wholesale. An earlier version of this file wrote
  # just `[cfg.sshPort]`, and the result was that the activated system listened on
  # 2222 and NOTHING ELSE: the desktop sshd lost port 22 entirely and the only
  # remaining way in was Tailscale SSH, which was simultaneously logged out.
  # Every `ssh -p 22` failed with "Connection refused".
  #
  # So both ports are always listed together. If you ever change one, change
  # both, and verify with:
  #   sshd -T | grep -i ^port          # must show BOTH 22 and 2222
  #   ss -tln | grep -E ':22 |:2222 '  # must show BOTH listening
  #
  # Belt and braces: `networking.firewall.allowedTCPPorts = [ 22 ]` below also
  # keeps 22 open, but a firewall rule does not help if sshd is not listening.
  services.openssh.ports = lib.mkIf cfg.enable [22 cfg.sshPort];

  # The OS sshd binds this port on all interfaces, so the listener itself is not
  # the access control — the firewall below is. `openFirewall = false` is the
  # load-bearing line: the sshd module defaults it to TRUE, which would add
  # every port in `ports` to allowedTCPPorts, publishing 2222 on the LAN and the
  # WAN. We open 22 explicitly (unchanged from today) and never 2222.
  services.openssh.openFirewall = lib.mkIf cfg.enable false;
  networking.firewall.allowedTCPPorts = lib.mkIf cfg.enable [22];

  # 🔴🔴 The string below is interpolated into an UNQUOTED heredoc by the
  # sshd module:
  #
  #   sshconf = pkgs.runCommand "sshd.conf-final" { } ''
  #     cat ${configFile} - >$out <<EOL
  #     ${cfg.extraConfig}
  #     EOL
  #   '';
  #
  # Note `<<EOL`, not `<<'EOL'`. The shell therefore performs parameter
  # expansion, command substitution and backslash processing on this text.
  #
  # So: NO backticks, and be careful with $ and \. A comment here reading
  # "global `yes` on a desktop host" makes the shell run `yes`, which never
  # returns: the build hangs for a minute and is then killed by the OOM killer,
  # which surfaces as the deeply misleading
  #
  #   error: Cannot build '…-sshd.conf-final.drv'.
  #     Reason: builder failed with exit code 137.
  #
  # on the config that has nothing to do with sshd at all. That is not a
  # hypothetical — it is exactly how this branch broke the first rebuild, and it
  # cost a confusing debugging session because the log tail shows only this
  # innocent-looking block. Plain prose, no shell metacharacters.
  #
  # $(...) and ${...} are equally unsafe; `lib.sshConf` does not need any of
  # them here, which is why none appear below.

  # `Match LocalPort` scopes the hardening to 2222 alone. Verified against this
  # host's OpenSSH 10.5p1 with `sshd -T -C ...lport=…`: port 22 keeps
  # PasswordAuthentication/KbdInteractiveAuthentication yes and
  # PermitRootLogin prohibit-password (today's live values, untouched), while
  # 2222 resolves to no / no / no. That is the whole point of a Match block
  # rather than global `settings` — hardening the port the phone uses must not
  # lock anyone out of the port that rescues the box.
  services.openssh.extraConfig = lib.mkIf cfg.enable ''
    # 🔴 Read the heredoc warning above before adding any text here. The
    # rendered text must contain no backticks, dollar signs or backslashes.
    Match LocalPort ${toString cfg.sshPort}
      # Key-only. PasswordAuthentication and KbdInteractiveAuthentication are
      # globally enabled on a desktop host (server.nix only pins them off when
      # headless = true, and the Legion is not headless), so a phone-facing
      # listener would otherwise be a password-guessable one.
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PermitRootLogin no
      # Forwarding is REQUIRED: Moshi reaches the moshi-hook gateway on
      # 127.0.0.1:24543 by forwarding a local port over this same SSH
      # connection. Without it the Inbox, Chat View, and the diff/browser
      # preview all fail while the terminal itself looks fine.
      AllowTcpForwarding yes
      # Agent forwarding is deliberately OFF. It is unnecessary — the host
      # already has the Git and model credentials the agents need, in
      # authorized_keys and the sops environment — and it would put a
      # phone-held key in reach of anything that lands in a shell here. It also
      # would not work over the mosh transport the phone actually uses, since
      # mosh cannot carry SSH channels.
      AllowAgentForwarding no
      # No X11, no sftp subsystem shenanigans needed; leave the rest inherited.
  '';

  # ── The phone's key ────────────────────────────────────────────────────────
  #
  # A dedicated key, separate from sshAuthorizedKeys, so revoking the phone
  # does not mean rotating the desktop/GitHub key. `null` is the pre-key state
  # and must not silently become an empty-but-valid-looking setup.
  #
  # `users.users.<name>` is a submodule that rejects a SECOND definition of the
  # same attribute, and config/system/user.nix already defines this user — so
  # these merge into that existing definition via mkMerge rather than being
  # written as two more top-level `users.users.…` attributes.
  users.users = lib.mkMerge [
    (lib.mkIf (cfg.enable && cfg.phoneAuthorizedKey != null) {
      ${opts.username}.openssh.authorizedKeys.keys = [cfg.phoneAuthorizedKey];
    })
    (lib.mkIf cfg.enable {
      ${opts.username}.linger = true;
    })
  ];

  warnings = lib.optional (cfg.enable && cfg.phoneAuthorizedKey == null) ''
    mobile-agents: opts.mobileAgents.enable is true but phoneAuthorizedKey is
    null, so port ${toString cfg.sshPort} has NO key authorized and the phone
    cannot log in. Generate the key on the phone and set
    opts.mobileAgents.phoneAuthorizedKey (options.nix, or nixos/local.nix).
  '';

  # ── mosh ───────────────────────────────────────────────────────────────────
  #
  # openFirewall = false is not optional. The module's own default opens
  # 60000-61000 on every interface and does nothing to constrain the server.
  programs.mosh = lib.mkIf (cfg.enable && cfg.mosh.enable) {
    enable = true;
    openFirewall = false;

    # Our wrapper: real mosh plus a `mosh-server` that pins `-p 60000:60010`.
    package = moshiHook.moshBounded;

    # libutempter installs a setgid wrapper binary system-wide so mosh can
    # write /var/run/utmp, which is what makes `who` list mosh sessions. We do
    # not need that here, and a setgid root-group wrapper is not something to
    # add to a desktop for a phone convenience.
    withUtempter = false;
  };

  # UDP is not opened at all. tailscale0 is already in
  # networking.firewall.trustedInterfaces (server.nix), and trusted interfaces
  # accept inbound traffic unconditionally — which is exactly the "reachable
  # from the tailnet, invisible on the LAN" property we want, and it is how
  # SSH and Ollama already work on this host. Adding an explicit
  # allowedUDPPortRanges entry would instead open the range on wlan0/eth0 too.
  #
  # 🔴 This is host firewalling only. It is NOT a substitute for tailnet access
  # policy: a peer that can reach this host over the tailnet still has to be
  # permitted by the Tailscale ACL for TCP 2222 and the UDP range, or it will be
  # refused before the host firewall is consulted. See docs/mobile-agents.md for
  # the grants to add — trusting tailscale0 here does nothing for that.
  #
  # ── Linger, and why it is here rather than in user.nix ──────────────────────
  #
  # Without lingering the user manager starts at first login and stops at last
  # logout, so herdr — whose entire job is surviving the session that started
  # it — would be dead whenever nobody is logged in. That is the difference
  # between "reachable from the phone" and "reachable only while sitting at the
  # desk". Set in the mkMerge above because it is gated on the mobile flag; nixpkgs'
  # `null` default leaves lingering unmanaged, and we only ever opt IN.
}
