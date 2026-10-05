# nixos/config/system/agent-ops/health.nix
#
# One private, redacted answer to "is this box fine?".
#
# ── What this is not ────────────────────────────────────────────────────────
# Not a monitoring service, not a dashboard, and not anything with an account.
# It is a single bounded script that answers one question and exits with a
# status, readable by an operator over SSH, from the sys-daemon, or — only if
# the operator configures it — by an outside heartbeat.
#
# The reason it is deliberately that small: the failure mode of every health
# system this replaces is that it becomes the thing that is down. A collector
# that hangs, a dashboard that needs a browser, a service that phones home on
# its own schedule — each is one more thing to be broken during the incident it
# was built to explain.
#
# ── Redaction is a property of this module, not of the script ───────────────
# The script emits booleans, counts, ages, sizes, unit names and file paths. It
# has no code path that prints a credential value: credential readiness comes
# from secret-env.sh, whose own JSON contains names and booleans only. The test
# suite plants a recognisable canary in every credential store on the fixture
# and asserts the canary appears nowhere in the output. See
# nixos/tests/agent-operations/health-redaction.sh.
#
# ── No inferred recipient, ever ──────────────────────────────────────────────
# The heartbeat URL is a credential the operator supplies. There is no default
# endpoint, no derived recipient, no "helpful" fallback to a paste site or a
# chat webhook, and no signup of any kind. With no URL configured the field
# reads "unconfigured", which is a true answer and not an error.
#
# ── No automatic reboot, ever ────────────────────────────────────────────────
# An ISP outage makes every network-dependent check fail simultaneously. The
# tempting response to "everything is down" is to reboot, and it is always
# wrong: it destroys the evidence, it cannot fix a link that is down, and it
# kills every running agent. There is no reboot path in the script, no
# ExecStop that touches power state, and no escalation from failure to power
# action anywhere in this module. ns-maint already owns rebooting, explicitly,
# with a confirmation window; this reports, ns-maint acts.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = config.agentOps.health;
  script = ./scripts/ns-agent-health.sh;
  # The backup script writes directly under AGENT_OPS_STATE_DIR, without
  # appending another /backup component.
  defaultBackupRecord = "${config.agentOps.backup.stateDir}/last-run.env";
  historyDir = "/var/lib/agent-ops/health/history";
  # One immutable, private file per run: <UTC timestamp>.<random>.json. There
  # is deliberately no append-only log; tmpfiles ages each file on its own
  # mtime, so the history is bounded by retentionHours without rotation.
  #
  # Exit contract (the unit's SuccessExitStatus is "0 1"):
  #   0/1  collector verdict (healthy / degraded-or-unhealthy), report kept
  #   >1   collector failure, propagated as-is (report kept if it is valid)
  #   65   collector exited 0/1 but its output was not ONE JSON object;
  #        nothing is written, and the unit fails visibly. The malformed output
  #        is never echoed, so it cannot leak into the journal.
  snapshotScript = name: arguments: pkgs.writeShellScript name ''
    set -euo pipefail
    umask 0077
    status=0
    snapshot="$(${lib.getExe tool} --json ${arguments})" || status=$?
    if ! printf '%s\n' "$snapshot" | ${pkgs.jq}/bin/jq -e -s \
      'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
      printf '%s: collector (exit %s) produced no single JSON object; nothing recorded\n' \
        ${lib.escapeShellArg name} "$status" >&2
      if [ "$status" -gt 1 ]; then exit "$status"; fi
      exit 65
    fi
    stamp="$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ)"
    # Write a hidden partial first and rename, so a reader (or the age
    # cleaner) never sees a truncated report under its final name.
    partial="$(${pkgs.coreutils}/bin/mktemp ${historyDir}/."$stamp".XXXXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f -- "$partial"' EXIT
    printf '%s\n' "$snapshot" >"$partial"
    final="${historyDir}/''${partial##*/.}.json"
    ${pkgs.coreutils}/bin/mv -n -T -- "$partial" "$final"
    [ ! -e "$partial" ] || { printf '%s: snapshot name collision\n' ${lib.escapeShellArg name} >&2; exit 73; }
    trap - EXIT
    exit "$status"
  '';
  ownerHome = config.users.users.${opts.username}.home;
  ownerServices = lib.attrByPath ["home-manager" "users" opts.username "systemd" "user" "services"] {} config;
  # Only enabled stateful agent services are required; desktop helpers and
  # oneshot validation units are not long-running health dependencies.
  requiredServices = lib.filter (name:
    let unit = ownerServices.${name} or {}; in
    (unit.Install.WantedBy or []) != [] && (unit.Service.Type or "simple") != "oneshot"
  ) ["herdr" "collie"];
  ownerEnvironment = {
    AGENT_OPS_HEALTH_USER = opts.username;
    AGENT_OPS_SECRET_ENV = toString (pkgs.writeShellScript "health-owner-readiness" ''
      export HOME=${lib.escapeShellArg ownerHome}
      export SECRET_ENV_MANIFEST=${lib.escapeShellArg "${ownerHome}/.config/agent-ops/secrets.manifest"}
      export XDG_STATE_HOME=${lib.escapeShellArg "${ownerHome}/.local/state"}
      export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u ${lib.escapeShellArg opts.username})"
      # Never execute a user-writable helper as the privileged collector.
      unset CREDENTIALS_DIRECTORY
      if [ "$(${pkgs.coreutils}/bin/id -u)" = 0 ]; then
        exec ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg opts.username} -- \
          ${pkgs.coreutils}/bin/env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" SECRET_ENV_MANIFEST="$SECRET_ENV_MANIFEST" \
          ${lib.escapeShellArg "${ownerHome}/.config/agent-ops/secret-env"} "$@"
      fi
      exec ${lib.escapeShellArg "${ownerHome}/.config/agent-ops/secret-env"} "$@"
    '');
    # The checker also invokes the owner's herdr client and user manager.
    # Run it as that owner, not as the root timer's HOME/session.
    AGENT_OPS_DAEMON_CHECK = if !(builtins.elem "herdr" requiredServices) then "" else toString (pkgs.writeShellScript "health-owner-daemon-check" ''
      export HOME=${lib.escapeShellArg ownerHome}
      export XDG_RUNTIME_DIR="/run/user/$(${pkgs.coreutils}/bin/id -u ${lib.escapeShellArg opts.username})"
      export HERDR_BIN=/etc/profiles/per-user/${opts.username}/bin/herdr
      unset CREDENTIALS_DIRECTORY
      if [ "$(${pkgs.coreutils}/bin/id -u)" = 0 ]; then
        exec ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg opts.username} -- \
          ${pkgs.coreutils}/bin/env HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HERDR_BIN="$HERDR_BIN" \
          ${lib.escapeShellArg "${ownerHome}/.config/agent-ops/herdr-daemon-check"} "$@"
      fi
      exec ${lib.escapeShellArg "${ownerHome}/.config/agent-ops/herdr-daemon-check"} "$@"
    '');
    AGENT_OPS_HEALTH_REQUIRED_SERVICES = lib.concatStringsSep " " (map (name: "${name}.service") requiredServices);
  };

  # sopsFileHasKey FILE KEY — does the sops YAML have a top-level KEY?
  #
  # A build-time existence check, not a decryption: the file is in the store and
  # readable. Used instead of `config.sops.secrets ? KEY`, which only ever asks
  # whether the OPTION was declared — and the module that wants the check declares
  # it itself, so that assertion compared the option to itself and could not
  # fail.
  #
  # 🔴 STRING OPERATIONS, NOT `builtins.match`. In nixpkgs' Nix (2.34) `match`
  # requires the regex to match the WHOLE string: `match "^OPEN" "OPENROUTER"`
  # returns null, so a `^KEY:` pattern silently found nothing and the assertion
  # failed for every key including the ones that exist. Comparing the text before
  # the first colon is exact, needs no escaping, and cannot depend on the
  # engine's anchoring rules.
  sopsFileHasKey =
    file: key:
    let
      lines = lib.splitString "\n" (builtins.readFile file);
      nameOf = line: lib.head (lib.splitString ":" line);
    in
    builtins.any (line: nameOf line == key) lines;
  tool = pkgs.writeShellApplication {
    name = "ns-agent-health";
    runtimeInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      # gawk, not awk: the NixOS minimal PATH has no /usr/bin/awk, and a
      # silently-missing awk leaves disk metrics empty and reports ZERO failed
      # units — which is the worst possible failure for a health check.
      pkgs.gawk
      pkgs.gnugrep
      pkgs.systemd
      pkgs.util-linux
      pkgs.curl
      pkgs.hostname
      # jq builds the JSON document. Hand-escaped JSON was wrong in every field
      # and nothing detected it, because the tests were substring matches.
      pkgs.jq
    ];
    text = builtins.readFile script;
  };

in {
  options.agentOps.health = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install the health collector, its timer and its CLI.";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "How often to collect and retain a health snapshot locally.";
    };

    retentionHours = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "How many hours of collected snapshots to keep on disk.";
    };

    heartbeat = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Contact an outside endpoint after each collection. Requires BOTH
          AGENT_OPS_HEARTBEAT_URL and AGENT_OPS_HEARTBEAT_TOKEN to exist in
          secrets.yaml. There is no default endpoint and nothing is signed up
          for anything: enabling this without adding the secrets fails the build.
        '';
      };

      urlSecretName = lib.mkOption {
        type = lib.types.str;
        default = "AGENT_OPS_HEARTBEAT_URL";
        description = "sops secret holding the https:// endpoint. Deliberately a URL, not a computed one.";
      };

      tokenSecretName = lib.mkOption {
        type = lib.types.str;
        default = "AGENT_OPS_HEARTBEAT_TOKEN";
        description = "sops secret holding the bearer token for that endpoint.";
      };

      maxAttempts = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          Bounded attempts with backoff. Bounded because the heartbeat runs
          exactly when things are broken, and an unbounded retry loop against a
          dead endpoint is a health check that causes the outage.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [tool];

      systemd.tmpfiles.rules = [
        "d /var/lib/agent-ops 0700 root root -"
        "d /var/lib/agent-ops/health 0700 root root -"
        # Immutable snapshots age independently; reading them or collecting a
        # new report must not refresh an older report's retention clock.
        "d ${historyDir} 0700 root root m:${toString cfg.retentionHours}h"
      ];

      environment.variables = ownerEnvironment // {
        AGENT_OPS_BACKUP_RECORD = defaultBackupRecord;
        AGENT_OPS_HEALTH_MAX_ATTEMPTS = toString cfg.heartbeat.maxAttempts;
      };

      # The secrets are declared only when the heartbeat is enabled, so a host
      # that does not use one is not asked for credentials it will never use —
      # and a host that enables it without adding them fails the build rather
      # than silently never sending.
      sops.secrets = lib.optionalAttrs cfg.heartbeat.enable {
        ${cfg.heartbeat.urlSecretName} = {};
        ${cfg.heartbeat.tokenSecretName} = {};
      };

      systemd.services.agent-ops-health = {
        description = "Collect one redacted health snapshot";
        after = ["local-fs.target"];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = snapshotScript "agent-ops-health-snapshot" "";
          MemoryMax = "128M";
          # Bounded on the unit as well as inside the script. A hung collector
          # must not be able to hold this open.
          TimeoutStartSec = "60";
          # Exit 1 means "degraded or unhealthy", which is DATA, not a failure of
          # the collector. Treating it as a failed unit would put a permanent red
          # entry in `systemctl list-units --state=failed` for a machine that is
          # merely unwell, and the failed-unit count is itself a health signal.
          SuccessExitStatus = "0 1";
          Restart = "no";
          # 🔴 No ExecStop touching power state, here or anywhere else.
          LoadCredential = lib.optionals cfg.heartbeat.enable [
            "AGENT_OPS_HEARTBEAT_URL:${config.sops.secrets.${cfg.heartbeat.urlSecretName}.path}"
            "AGENT_OPS_HEARTBEAT_TOKEN:${config.sops.secrets.${cfg.heartbeat.tokenSecretName}.path}"
          ];
        };
        environment = ownerEnvironment // {
          AGENT_OPS_BACKUP_RECORD = defaultBackupRecord;
          AGENT_OPS_HEARTBEAT_MAX_ATTEMPTS = toString cfg.heartbeat.maxAttempts;
        };
      };

      systemd.timers.agent-ops-health = {
        description = "Collect a health snapshot periodically";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.schedule;
          AccuracySec = "2min";
          Persistent = false;
          Unit = "agent-ops-health.service";
        };
      };

      # The snapshot is kept so "what did this look like at 3am" is answerable
      # from the box rather than from memory. Contains no values; see the
      # redaction note in the module header.
      systemd.services.agent-ops-health-record = {
        description = "Record one redacted boot health snapshot";
        environment = ownerEnvironment // {
          AGENT_OPS_BACKUP_RECORD = defaultBackupRecord;
        };
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          MemoryMax = "128M";
          User = "root";
          ExecStart = snapshotScript "agent-ops-health-record" "--no-heartbeat";
          SuccessExitStatus = "0 1";
          TimeoutStartSec = "60";
        };
      };
    })

    # ── Do the heartbeat secrets actually EXIST? ────────────────────────────
    #
    # 🔴 The previous check was `config.sops.secrets ? <name>` — and this very
    # module DECLARES those secrets two hundred lines up, so the assertion was
    # comparing the option to itself and could never fail. Enabling the heartbeat
    # without adding the keys to secrets.yaml therefore failed at ACTIVATION (or
    # at sops decryption), not at build time, which is the opposite of what the
    # option description promised.
    #
    # The real question is whether the key is present in the secrets FILE, so that
    # is what is read: the sops file is a YAML mapping and this is a build-time
    # existence check, not a decryption.
    (lib.mkIf (cfg.enable && cfg.heartbeat.enable) {
      assertions = [
        {
          assertion = sopsFileHasKey config.sops.defaultSopsFile cfg.heartbeat.urlSecretName;
          message = ''
            agentOps.health.heartbeat.enable requires the key
            ${cfg.heartbeat.urlSecretName} in ${config.sops.defaultSopsFile}.
            Add it with:  sops secrets set ${cfg.heartbeat.urlSecretName} --name ${config.sops.defaultSopsFile}
          '';
        }
        {
          assertion = sopsFileHasKey config.sops.defaultSopsFile cfg.heartbeat.tokenSecretName;
          message = ''
            agentOps.health.heartbeat.enable requires the key
            ${cfg.heartbeat.tokenSecretName} in ${config.sops.defaultSopsFile}.
            Add it with:  sops secrets set ${cfg.heartbeat.tokenSecretName} --name ${config.sops.defaultSopsFile}
          '';
        }
      ];
    })
  ];
}
