# nixos/config/home/collie.nix
#
# Collie's bridge as a declarative Home Manager user service: a phone web UI
# for the SAME persistent herdr workspaces and pi / Claude Code / OpenCode
# agents the desktop already runs. Not a second stack — the phone is a second
# client of the one herdr server.
#
# Gated on opts.mobileAgents.enable AND opts.mobileAgents.collie.enable. The
# shared mobile infrastructure (2222 sshd, phone key, bounded mosh, linger) is
# config/system/mobile-agents.nix, which is where the Tailscale Serve mapping in
# front of this lives. The herdr unit is config/home/herdr.nix. Full procedure,
# pairing and rollback in docs/mobile-agents.md.
#
# ── Ownership: one owner per thing, and Nix is it ───────────────────────────
#
# Upstream's own reference unit (systemd/collie.service) exists for a binary or
# Homebrew install, where `collie start` GENERATES
# ~/.config/systemd/user/collie.service and a `tailscale serve` mapping, and
# then supervises both. Under Nix that is two owners for the same two facts, and
# both facts are already in this repository:
#
#   the unit            → systemd.user.services.collie, below
#   the front door      → systemd.services.tailscale-serve-collie, in mobile-agents.nix
#
# So this module runs `collie _exec-bridge`, the "everything it needs is on its
# own command line" entry point, which upstream documents as exactly what a
# supervisor-managed install should use. It never runs `tailscale serve` and
# never writes a unit. `collie start` / `collie restart` / `collie stop` /
# `collie uninstall` are therefore OFF LIMITS here — each of them writes the
# unit and/or the Serve mapping that Nix owns. Restart with
# `systemctl --user restart collie`, and read state with `collie status`,
# `collie url`, `collie logs`, `collie doctor`.
#
# `collie update` is a non-issue rather than a promise: a Nix store path is
# read-only and outside $HOME, which is one of the three shapes Collie reads as
# a PACKAGED install (ADR 0035), so it refuses to replace its own files and
# names the package manager instead. Verified: `collie update --check` on this
# derivation reports "updates come from your package manager". Verified, not
# assumed.
#
# ── What this deliberately does NOT do ───────────────────────────────────────
#
# 1. It does not publish anything. The bridge binds 127.0.0.1 (upstream's
#    default, and it refuses a non-loopback bind without an explicit opt-out we
#    do not set), and Tailscale Serve proxies it. Nothing is opened in
#    networking.firewall, nothing is added to allowedTCPPorts, and the port is
#    not reachable from the LAN.
#
# 2. It holds no secret. COLLIE_TRUSTED_USER is an identity, not a credential.
#    The VAPID keypair lives in ~/.config/collie/.env at mode 600 and pairing
#    credentials live in ~/.local/state/collie/ — both written by Collie's own
#    commands, both outside Git and outside the Nix store. Nothing here reads,
#    generates, templates or links them.
#
# 3. It does not install agent hooks. `collie hooks install claude` merges into
#    ~/.claude/settings.json, which already carries a herdr-managed
#    SessionStart hook. Manual, and documented.
{
  inputs,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = opts.mobileAgents.collie;
  enable = opts.mobileAgents.enable && cfg.enable;

  # The pinned flake package. Wraps the upstream release tarball; see the
  # `collie` input comment in flake.nix for why it reports 1.15.0 at tag
  # v1.15.3.
  #
  # `inputs` is a specialArg threaded through flake.nix (home-manager
  # extraSpecialArgs), the same one herdr.nix resolves herdr from.
  collie = inputs.collie.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # `getExe'` rather than `getExe`: coreutils has no meta.mainProgram, so the
  # latter guesses and nixpkgs warns on every evaluation.
  mkdir = lib.getExe' pkgs.coreutils "mkdir";
  chmod = lib.getExe' pkgs.coreutils "chmod";
in {
  # ── Fail closed on the identity gate ───────────────────────────────────────
  #
  # COLLIE_TRUSTED_USER is checked only when it is non-empty, and empty means
  # "any tailnet device that reaches the bridge gets full write access" — a
  # warning in the log, not an error. A missing identity in a config file is
  # almost always an oversight, and it is the one oversight in this whole setup
  # whose failure mode is silent and total. So: refuse to build instead.
  #
  # Reject both null and the empty string: either would leave the gate unset.
  assertions = [
    {
      assertion = !cfg.enable || (cfg.trustedUser != null && cfg.trustedUser != "");
      message = ''
        opts.mobileAgents.collie.trustedUser is null or empty, so Collie would run with
        NO identity gate: every tailnet device that can reach the Serve URL gets
        full write access to your agents' panes.

        Find your tailnet login and put it in nixos/hosts/<host>/options.nix (or
        nixos/local.nix):

          tailscale debug prefs | jq -r '.UserProfile.LoginName'

        The value is the lowercase email with NO trailing dot — exactly what
        Tailscale puts in the Tailscale-User-Login header.
      '';
    }
    {
      assertion = !cfg.enable || cfg.serveHosts != [];
      message = ''
        opts.mobileAgents.collie.serveHosts is empty. Collie's Host-header
        gate is fail-closed and it does not discover the tailnet name on its own
        (`collie start` injects that; Nix owns the unit here, so nothing
        injects it). Without this every non-loopback request is refused with
        "host not allowed" and the phone sees an empty page.

        Set it to this machine's MagicDNS name:

          tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'
      '';
    }
  ];

  # ── The service ────────────────────────────────────────────────────────────
  systemd.user.services.collie = lib.mkIf (enable && cfg.trustedUser != null) {
    Unit = {
      Description = "collie — phone web UI for the herdr agents, over Tailscale Serve";
      Documentation = [
        "https://github.com/AltanS/collie"
        "https://github.com/AltanS/collie/blob/main/docs/install.md"
      ];

      # Upstream's reference unit. Never give up restarting: a phone-only
      # operator has no console to run `systemctl reset-failed` on, so an
      # exhausted start limit is a permanently dead front door.
      StartLimitIntervalSec = 0;

      # herdr first: Collie discovers the panes through that socket, and a
      # bridge that starts before it finds an empty machine and shows the phone
      # a blank dashboard until the next poll.
      #
      # sops second, so Collie and the agents it describes share one set of
      # credentials — Collie shells out to git for its Changes view, and the
      # agents' own credentials come from the same environment.
      #
      # 🔴 Wants, never Requires/PartOf. Collie must not be able to hold herdr's
      # startup, and — the reason that is worth a comment in a file about a
      # phone — herdr must not take Collie down with it. Nothing here may ever
      # be able to restart the server holding your live agents.
      After = ["herdr.service" "sops-import-environment.service"];
      Wants = ["herdr.service" "sops-import-environment.service"];
    };

    Service = {
      Type = "simple";

      # `_exec-bridge` runs the bridge in the foreground and nothing else: no
      # unit generation, no `tailscale serve`, no pidfile ownership record. It
      # is the entry point for installs whose supervisor already owns those two
      # things, which is what Nix is here.
      ExecStart = "${collie}/bin/collie _exec-bridge";

      # The config dir has to exist before the bridge reads .env from it, and
      # `collie push-keys` needs somewhere to write. It is created here rather
      # than declared through `xdg.configFile` on purpose: Home Manager
      # manages a declared directory COMPLETELY and would prune the .env as an
      # undeclared file. An ExecStartPre mkdir has no such authority — it
      # creates the directory and never touches what is inside it.
      #
      # One list, not two `ExecStartPre` attributes: the option is a listOf,
      # so a second assignment is a conflict rather than an append.
      #
      # `-p` so this is idempotent: systemd runs ExecStartPre on every start,
      # and the directory already exists after the first one.
      #
      # Owner-only, matching what Collie itself expects of a directory holding
      # COLLIE_VAPID_PRIVATE.
      ExecStartPre = [
        "${mkdir} -p %h/.config/collie %h/.local/state/collie"
        "${chmod} 700 %h/.config/collie %h/.local/state/collie"
      ];

      # PATHS AND ONE IDENTITY. Nothing secret.
      #
      # The generated unit is world-readable (systemd reads it as any user,
      # and upstream's own reference unit notes the same), so a Web Push signing
      # key must never be baked into an `Environment=` line — which is why
      # upstream parses the mode-600 .env inside the process instead. The
      # EnvironmentFile below is the same file the operator's own `collie
      # push-keys` writes, and it is the only path that carries a secret.
      Environment = [
        # herdr is the default and the only backend this setup uses; named
        # explicitly so a future upstream default change cannot silently move
        # the phone to a multiplexer that is not running.
        "COLLIE_MUX=herdr"

        # The socket the RUNNING server listens on — herdr.service's, i.e. the
        # same one the desktop's own herdr client uses. Absolute, no PATH
        # lookup, and not a store path: herdr.nix deliberately starts the server
        # from the stable per-user profile symlink so a herdr bump does not
        # rewrite herdr.service. Naming a store path here would put that churn
        # back, in the unit that must not move.
        "HERDR_SOCKET_PATH=%h/.config/herdr/herdr.sock"

        # Loopback only. Collie's default, stated so the value is visible.
        "COLLIE_PORT=${toString cfg.port}"

        # Where .env and config.toml live. Matches upstream's own last-resort
        # default, stated for the same reason: it is the path `collie pair`,
        # `collie push-keys` and `collie doctor` resolve on the CLI side too, so
        # the operator and the daemon cannot disagree about where the pairing
        # credential was written.
        "HERDR_PLUGIN_CONFIG_DIR=%h/.config/collie"

        # The install root, which must hold web/dist and herdr-plugin.toml.
        # Normally derived from argv0 — and it IS derived correctly here, since
        # the flake package keeps upstream's $out/lib/collie + $out/bin/collie
        # symlink layout — but stated explicitly so the unit does not depend on
        # that layout staying put.
        "COLLIE_PLUGIN_ROOT=${collie}/lib/collie"

        # COLLIE_TRUSTED_USER: the outer gate. tailscaled (not Collie) puts the
        # `Tailscale-User-Login` header on requests that arrive through Serve,
        # and Collie rejects a mismatch — and rejects an ABSENT header, because
        # this gate fails closed. That last part is why COLLIE_SKIP_SERVE is
        # deliberately NOT set: Collie disables the identity check entirely when
        # it believes no Serve is in front, and `tailscale-serve-collie` in
        # mobile-agents.nix is exactly a Serve in front, whatever Collie
        # believes. Leaving it unset buys fail-closed enforcement; the cost is
        # that `collie status` cannot see the Serve mapping, since it only
        # reports what it would publish itself. Both are documented in
        # docs/mobile-agents.md.
        "COLLIE_TRUSTED_USER=${cfg.trustedUser}"

        # The Host-header allowlist, one entry per serveHosts. Fail-closed, and
        # the reason it is set explicitly is in options.nix: nothing injects
        # COLLIE_TAILSCALE_HOSTS when `collie start` is not the thing starting
        # the service.
        "COLLIE_PUBLIC_HOSTS=${lib.concatStringsSep "," cfg.serveHosts}"
      ];

      # The operator's own file. Leading '-': a missing .env is a startup
      # warning-free no-op, because Web Push is optional and Collie is fully
      # usable without it.
      EnvironmentFile = "-%h/.config/collie/.env";

      Restart = "on-failure";
      RestartSec = 5;

      # Upstream's hardening, kept identical rather than improved. The bridge is
      # remote shell access into panes running live agents.
      NoNewPrivileges = true;
      PrivateTmp = true;

      # 🔴 ProtectSystem is deliberately NOT set, for the reason upstream gives:
      # the only write path is the env-driven state dir, which a Herdr session
      # can point anywhere, so it cannot be enumerated as a static ReadWritePaths.
      # Inventing a narrower sandbox here would be a guess about where a
      # third party may be told to write.

      WorkingDirectory = "%h";
    };

    # Start at boot via the lingering user manager (linger is in
    # config/system/mobile-agents.nix), not at graphical login: Collie is only
    # useful when nobody is at the desk.
    Install.WantedBy = ["default.target"];
  };

  # ── The binary on PATH ─────────────────────────────────────────────────────
  #
  # `useUserPackages = true` in flake.nix puts home.packages on the per-user
  # profile symlink /etc/profiles/per-user/<user>/bin — the same place herdr and
  # moshi-hook live, which is what makes `collie pair`, `collie push-keys` and
  # `collie doctor` work in a plain shell.
  #
  # home.packages is a listOf option, so this is the ONE home.packages for the
  # whole module.
  home.packages = lib.mkIf enable [collie];
}
