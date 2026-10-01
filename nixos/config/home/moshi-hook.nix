# nixos/config/home/moshi-hook.nix
#
# Moshi's host daemon, so the agents already running inside herdr are visible
# and steerable from the phone: Inbox events, approvals, Chat View, and the
# diff/browser preview served over a localhost gateway the phone reaches by
# forwarding a port over the same SSH connection.
#
# Gated on opts.mobileAgents.enable (hosts/legion/options.nix). The system half
# is config/system/mobile-agents.nix; the herdr unit is config/home/herdr.nix.
# Full procedure in docs/mobile-agents.md.
#
# ── What this deliberately does NOT do ───────────────────────────────────────
#
# 1. It does not install agent hooks. `moshi-hook install` writes into
#    ~/.claude/settings.json, ~/.pi/agent/extensions/ and
#    ~/.config/opencode/plugins/ — and ~/.claude/settings.json ALREADY carries a
#    herdr-managed SessionStart hook, so an installer run is a merge into live,
#    hand-maintained state. Upstream is careful to leave user-owned hooks alone,
#    but "careful" is not the same as "safe to run on every activation". So
#    installation is a manual step (see below) and nothing here runs it
#    automatically. See the helper at the end of this file.
#
# 2. It does not pair the host, and it holds no token. Pairing is an explicit
#    manual step from the phone; credentials live in ~/.config/moshi/secrets.json
#    at 0600, outside both Git and the Nix store.
#
# 3. It does not self-update. Nix owns the version. Upstream's daemon otherwise
#    polls for new releases every 6 hours and `auto` will `brew upgrade`-style
#    replace the running binary underneath systemd, which on NixOS means the
#    store path and the live binary silently diverge.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = opts.mobileAgents;
  enable = cfg.enable;

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

  # Where Moshi keeps its mutable state and the host secret. Under
  # ~/.local/state rather than the config dir so it is unambiguously runtime
  # data, and so a casual `rm -rf ~/.config/*` cannot take pairing with it.
  # The daemon creates this itself; we only make sure nothing in Git or the
  # store ever holds it.
  stateDir = "${config.xdg.stateHome}/moshi";

  # MOSHI_HERDR_PATH: point the daemon at the SAME herdr the running server was
  # started from.
  #
  # A systemd user service does not inherit PATH from a login shell, so the
  # daemon can resolve neither herdr nor mosh-server and reports "installed, but
  # the moshi-hook daemon cannot find it" — while the phone's own SSH preflight
  # succeeds, because that runs through a shell. That asymmetry is the single
  # most confusing failure in this whole setup, and MOSHI_HERDR_PATH is the
  # documented fix.
  #
  # The value is the STABLE per-user profile symlink, exactly as herdr.nix uses
  # for ExecStart, not a pinned store path. That matters for the same reason it
  # matters there: a flake update that changes herdr's hash must not alter this
  # unit's text, or home-manager restarts the daemon for no reason.
  herdrPath = "/etc/profiles/per-user/${config.home.username}/bin/herdr";
in {
  # One `home.packages` attribute for the whole module (it is a listOf option, so
  # a second one conflicts): the daemon itself below, and the installer helper
  # at the end.
  #
  # Placed on the per-user PATH symlink /etc/profiles/per-user/<user>/bin, which
  # is where Moshi's host probe looks and — verified on this host — is also on
  # the non-interactive SSH PATH. Not /run/current-system/sw/bin, which the
  # probe does not search.
  systemd.user.services.moshi-hook = lib.mkIf enable {
    Unit = {
      Description = "moshi-hook — Moshi agent daemon (inbox, approvals, gateway)";
      Documentation = ["https://getmoshi.app/docs/install-moshi-hook"];

      # herdr first: agents post events over the local socket, so Moshi reports
      # "kind=herdr" plus session/workspace and routes approvals to the right
      # pane. sops second, so the daemon and the agents it describes share one
      # set of credentials.
      After = ["herdr.service" "sops-import-environment.service"];
      Wants = ["herdr.service" "sops-import-environment.service"];

      # Not PartOf/Requires, for the same reason herdr-contract-resume is not:
      # Moshi must not be able to hold herdr's own startup, and herdr must not
      # take Moshi down with it.
    };

    Service = {
      Type = "simple";

      # `serve` in the foreground; systemd owns its lifetime, so the daemon
      # survives logout exactly like herdr does (see linger in
      # config/system/mobile-agents.nix).
      ExecStart = "${moshiHook}/bin/moshi-hook serve";

      # One list, not three separate `Environment =` attributes: this is an
      # attribute of type listOf, so a second assignment is a conflict, not an
      # append.
      #
      # 🔴 Nothing secret goes in here — only paths and a loopback address. The
      # sops credentials reach the daemon (and the agents) through the user
      # manager environment, which sops-import-environment.service populates
      # before this unit starts.
      Environment = [
        # Keep the gateway on loopback. It proxies diffs and dev-server previews
        # and answers approval requests; binding it to 0.0.0.0 would publish all
        # of that to every interface on the machine. Moshi reaches it by SSH
        # forwarding (AllowTcpForwarding in mobile-agents.nix), not by
        # connecting directly, so loopback is sufficient and correct.
        "MOSHI_HOOK_GATEWAY_LISTEN=127.0.0.1:24543"

        # Absolute path, no PATH lookup. See the herdrPath note above.
        "MOSHI_HERDR_PATH=${herdrPath}"

        # A systemd user service inherits no PATH from a login shell, so the
        # daemon can resolve neither herdr nor mosh-server and reports
        # "installed, but the moshi-hook daemon cannot find it" — while the
        # phone's own SSH preflight succeeds, because that DOES go through a
        # shell. That asymmetry is the most confusing failure in this setup.
        #
        # /run/current-system/sw/bin is where programs.mosh puts mosh-server,
        # and it is also on the non-interactive SSH PATH (verified), so the
        # phone's mosh bootstrap finds it too.
        #
        # 🔴 No stable symlink points at the bounded mosh wrapper, so a mosh
        # bump needs `systemctl --user restart moshi-hook` and the phone
        # reconnected. Noted in docs/mobile-agents.md rather than hidden.
        # herdr, which must never restart, deliberately uses its stable path.
        "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin"
      ];

      Restart = "on-failure";
      RestartSec = 5;

      # The daemon takes a single-instance file lock under its state dir and
      # exits if another instance holds it. Under systemd that is a clean,
      # expected non-crash, so treat a locked-out start as success rather than
      # letting it spin.
      SuccessExitStatus = "0 1";

      WorkingDirectory = "%h";
    };

    # Start at boot via the user manager (linger), not at graphical login:
    # Moshi is only useful when nobody is at the desk.
    Install.WantedBy = ["default.target"];
  };

  # ── Settings ───────────────────────────────────────────────────────────────
  #
  # Nothing is applied here, on purpose. `moshi-hook set` writes
  # ~/.config/moshi/config.toml, a file the daemon owns, so calling it from Nix
  # means an activation-time side effect that fights the daemon for one file —
  # and running it in the unit would do it on every start.
  #
  # Almost every default is already right for a Nix host. The one that is not is
  # 🔴 auto-update: `ask` merely reports, but `auto` downloads a new release and
  # restarts the daemon in place, replacing a Nix-owned binary with something
  # outside the store. Turn it off once, by hand:
  #
  #   moshi-hook set auto-update off
  #
  # Everything else stays the operator's call via `moshi-hook set <key> <value>`;
  # see docs/mobile-agents.md.

  # ── Agent-hook installer ───────────────────────────────────────────────────
  #
  # A narrowly scoped, idempotent wrapper rather than `moshi-hook install` run
  # bare or on every activation.
  #
  # Why not run it in the unit: `install` mutates ~/.claude/settings.json,
  # which on this host already holds a herdr-managed SessionStart hook, and
  # ~/.pi/agent/extensions/herdr-agent-state.ts, which herdr owns and
  # overwrites on reinstall. A silent activation-time edit to files another
  # system unit manages is precisely how you get a duplicated notification path
  # and a mysteriously reset hook.
  #
  # Why a wrapper at all: `moshi-hook install` is already careful to leave
  # user-owned entries alone, so the wrapper's job is not to reimplement it. It
  # is to (a) back up the files it is about to touch, (b) restore them on
  # failure, and (c) be safe to re-run — so the operator can iterate on hook
  # setup without hand-managing backups.
  #
  # Deliberately NOT run by any activation path. Invoke it by hand.
  home.packages = lib.mkIf enable [
    moshiHook
    (
      pkgs.writeShellApplication {
        name = "moshi-agent-hooks";
        runtimeInputs = [moshiHook pkgs.coreutils pkgs.gnugrep];
        text = ''
          # Install Moshi's agent hooks for exactly the agents present on this
          # host, after backing up every file it will touch.
          #
          # Idempotent: safe to re-run. Restores the backup if the install
          # fails partway, so a half-written settings.json is not left behind.

          set -euo pipefail

          # Which agents are actually present. Only these get wired:
          # writing hooks for an agent that is not installed just creates
          # config nobody reads.
          agents=()
          [ -d "$HOME/.claude" ] && agents+=(claude)
          [ -d "$HOME/.config/opencode" ] && agents+=(opencode)
          [ -d "$HOME/.pi/agent" ] && agents+=(pi)

          if [ "''${#agents[@]}" -eq 0 ]; then
            echo "moshi-agent-hooks: none of claude/opencode/pi found; nothing to do" >&2
            exit 0
          fi

          echo "moshi-agent-hooks: agents: ''${agents[*]}"

          # Exactly the paths upstream documents for those agents, taken
          # before anything is touched. Explicit, not globbed: a wildcard
          # over ~/.claude would sweep up megabytes of session history.
          targets=()
          for agent in "''${agents[@]}"; do
            case "$agent" in
              claude) targets+=("$HOME/.claude/settings.json") ;;
              opencode) targets+=("$HOME/.config/opencode/plugins/moshi-hooks.ts") ;;
              pi) targets+=("$HOME/.pi/agent/extensions/moshi-hooks.ts") ;;
            esac
          done

          backup_dir="$HOME/.local/state/moshi/hook-backups/$(date -u +%Y%m%dT%H%M%SZ)"
          mkdir -p "$backup_dir"
          chmod 700 "$backup_dir"

          backed_up=()
          for f in "''${targets[@]}"; do
            if [ -e "$f" ]; then
              mkdir -p "$backup_dir/$(dirname "$f")"
              cp -a "$f" "$backup_dir/$f"
              backed_up+=("$f")
            fi
          done

          if [ "''${#backed_up[@]}" -gt 0 ]; then
            echo "moshi-agent-hooks: backed up ''${#backed_up[@]} file(s) to $backup_dir"
          else
            echo "moshi-agent-hooks: no existing hook files; nothing to back up"
          fi

          target_csv="$(IFS=,; echo "''${agents[*]}")"

          if ${moshiHook}/bin/moshi-hook install --target "$target_csv"; then
            echo
            echo "moshi-agent-hooks: done. Verify with:  moshi-hook doctor"
            echo "Existing hooks are merged, not replaced."
            echo "Undo everything Moshi added with:  moshi-hook uninstall"
          else
            echo "moshi-agent-hooks: install FAILED; restoring backup" >&2
            for f in "''${backed_up[@]}"; do
              cp -a "$backup_dir/$f" "$f"
            done
            exit 1
          fi
        '';
      }
    )
  ];
}
