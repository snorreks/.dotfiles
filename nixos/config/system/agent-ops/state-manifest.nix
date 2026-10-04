# nixos/config/system/agent-ops/state-manifest.nix
#
# The inventory of what on this host is worth losing.
#
# ── Why a manifest and not a list in the backup module ────────────────────────
# Backups, health reporting and the future persistence allowlist all need the
# same answer to "where does this machine's irreplaceable state actually live",
# and they were each going to answer it separately and slightly differently. So
# it is answered once, here, and everything else reads it.
#
# The inventory is of REAL paths on this repository's hosts, checked against
# this machine, not a template. Several entries would not have been thought of:
#
#   * the herdr SESSION lives in ~/.config/herdr/session.json — without it a
#     restore comes back with no workspaces, which is the same as no agents;
#   * Collie's PAIRING is in ~/.local/state/collie and its VAPID key in
#     ~/.config/collie/.env. Restoring the config directory without the state
#     directory leaves a paired-everywhere-again bridge that pushes nothing,
#     because the subscription keys moved;
#   * ~/.config/sops/age/keys.txt is the age identity that decrypts every other
#     secret on this machine. It is the highest-value file here and the one
#     most likely to be forgotten, because it is not itself a sops secret;
#   * ns-maint's record is in /var/lib/nixos/maintenance, and a restore must
#     NOT carry an armed transaction from the backed-up host onto this one.
#
# ── Why persistence is still OFF ─────────────────────────────────────────────
# options.enablePersistence is false on both hosts and this lane does not turn
# it on. Turning it on is a real, separate decision with real risk (an
# allowlist that misses one directory means an upgrade that silently keeps an
# old file forever). What this file provides is the corrected, reviewed list
# that decision should be made against later — see the `persistenceHints`
# option, which is documentation rendered into the module's output and asserted
# against the backup sources, not an activation of anything.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  home = "/home/${opts.username}";

  # Each entry says what the path is, why it matters, and — deliberately — how
  # sensitive it is. `sensitive` paths are still backed up (an encrypted
  # repository is the right place for a private key) but they are never printed
  # in a health report and never included in a non-encrypted scratch restore.
  entries = [
    {
      path = "${home}/.config/herdr";
      what = "herdr workspaces, panes and session.json — the agent layout";
      why = "without session.json a restart comes back with no workspaces at all";
      sensitive = false;
    }
    {
      path = "${home}/.local/state/herdr";
      what = "herdr plugin and agent-detection state";
      why = "rebuilt on first run; cheap to restore, but its absence causes a rescan storm";
      sensitive = false;
    }
    {
      path = "${home}/.config/collie";
      what = "Collie VAPID keypair (.env)";
      why = "losing it re-subscribes every phone and stops every push notification";
      sensitive = true;
    }
    {
      path = "${home}/.local/state/collie";
      what = "Collie device pairing credentials";
      why = "the pairing a phone is trusted by; config without state re-prompts and re-trusts";
      sensitive = true;
    }
    {
      path = "${home}/.config/moshi";
      what = "Moshi client configuration (when mobileAgents.moshi is on)";
      why = "chat history and gateway settings";
      sensitive = true;
    }
    {
      path = "${home}/.pi";
      what = "pi agent configuration, prompts and local model links";
      why = "the agents' own setup, not just their panes";
      sensitive = false;
    }
    {
      path = "${home}/.config/sops/age/keys.txt";
      what = "THE AGE IDENTITY that decrypts secrets.yaml";
      why = "losing this makes every encrypted secret on this host unrecoverable, and it is not itself a sops secret so nothing else will restore it";
      sensitive = true;
    }
    {
      path = "${home}/.config/sops";
      what = "decrypted-at-rest sops material not covered elsewhere";
      why = "see the age identity above; also the thunderbird profile bundle";
      sensitive = true;
    }
    {
      path = "${home}/.ssh";
      what = "client keys and known_hosts";
      why = "sshAuthedKeys in options.nix covers LOGIN, not outbound client keys";
      sensitive = true;
    }
    {
      path = "${home}/.aws";
      what = "AWS credentials file";
      why = "an sops secret, but the *consumers* (scripts, agents) reference the path";
      sensitive = true;
    }
    {
      path = "${home}/Development/Projects";
      what = "every checkout, including worktrees and UNCOMMITTED work";
      why = "restic archives what is on disk; a worktree with unstaged changes is in .git as objects but the dirty index is not recoverable from them";
      sensitive = false;
    }
    {
      path = "/var/lib/nixos/maintenance";
      what = "ns-maint transaction record and its GC roots";
      why = "EXCLUDE the pending transaction from a restore: an armed record carried onto another host would arm a deadline for a change that never happened here";
      sensitive = false;
      excludeFromBackup = true;
    }
  ];
in {
  options.agentOps.state = {
    manifest = lib.mkOption {
      # A LIST, because `entries` is a list of per-path records. Declaring
      # `lib.types.attrs` here fails the type check the moment anything reads
      # `config.agentOps.state.manifest` — which backup.nix does — so enabling
      # backup could never have evaluated.
      type = lib.types.listOf lib.types.attrs;
      readOnly = true;
      default = entries;
      description = "The reviewed inventory of state worth backing up. Read by backup.nix and health.nix.";
    };

    persistenceHints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = map (e: "${e.path}  # ${e.what}") entries;
      readOnly = true;
      description = ''
        The manifest rendered as comments, for whoever eventually turns
        environment.persistence on. Not applied: options.enablePersistence is
        false on both hosts and this lane does not change that.
      '';
    };
  };

  config = {
    # A static, reviewable file. Not a runCommand: a generated shell script that
    # interpolates every entry is a place for an entry's path to be re-parsed as
    # shell, and this file is documentation that has to be readable in `git diff`
    # as text.
    environment.etc."agent-ops/state-manifest.txt".text = ''
      # Generated by nixos/config/system/agent-ops/state-manifest.nix.
      #
      # What is worth keeping on this host. Review this BEFORE enabling
      # environment.persistence: options.enablePersistence is false on both hosts
      # and this lane does not change that. See docs/agent-operations.md,
      # "What is worth keeping".

      ${lib.concatMapStringsSep "\n\n" (
          e: ''
            ${e.path}
              what:       ${e.what}
              why:        ${e.why}
              sensitive:  ${
              if e.sensitive
              then "yes — in an encrypted repo, never in a health report"
              else "no"
            }
            ${lib.optionalString (e.excludeFromBackup or false) "excludeFromBackup: yes — ${e.why}"}
          ''
        )
        entries}
    '';
  };
}
