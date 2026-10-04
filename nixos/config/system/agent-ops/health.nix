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
        # Retention on the snapshots themselves, so an hourly timer cannot
        # slowly fill the disk of the machine it is monitoring.
        #
        # ONE line for this path, not two: systemd-tmpfiles ignores a second
        # rule for the same path and logs a warning, so the retention age was
        # silently never applied.
        "d /var/lib/agent-ops/health 0700 root root ${toString cfg.retentionHours}h"
      ];

      environment.variables = {
        AGENT_OPS_BACKUP_RECORD = "/var/lib/agent-ops/backup/last-run.env";
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
          ExecStart = "${lib.getExe tool} --json";
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
        environment.AGENT_OPS_HEARTBEAT_MAX_ATTEMPTS = toString cfg.heartbeat.maxAttempts;
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
        description = "Append the latest health snapshot to the local history";
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "agent-ops-health-record" ''
            set -e
            printf '%s\n' "$(${lib.getExe tool} --json --no-heartbeat || true)" \
              >> /var/lib/agent-ops/health/history.jsonl
          '';
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
