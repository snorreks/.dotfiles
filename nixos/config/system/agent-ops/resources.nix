# nixos/config/system/agent-ops/resources.nix
#
# Keep builds, model inference, transcoding and downloads from starving the
# things this machine exists to do: answer a phone, run a herdr server, and
# keep an SSH session alive.
#
# ── What this protects, and why it is a cgroup and not a kill switch ────────
# The existing kill-switch scripts answer a different question: "the machine is
# misbehaving, take the load off". This one answers "the load is normal, keep it
# from taking everything". Those want opposite mechanisms — one kills, one
# bounds — and conflating them is how you end up with a box that kills the
# daemon that was going to tell you it was misbehaving.
#
# So: bounded, never killed.
#
# ── The limits below are DEFAULTS, NOT MEASUREMENTS ──────────────────────────
# They are deliberately conservative starting points chosen so that a mistake
# costs throughput rather than availability. They have NOT been calibrated
# against a load test on this hardware, and the numbers in `defaults` below say
# so. Anyone enabling this should run a measured calibration first — the
# procedure is in docs/agent-operations.md under "Calibrating the resource
# policy". Presenting a guessed limit as a measured one is how a machine ends
# up slower than before this module existed and nobody knows why.
#
# ── Why per-workload and not one global cap ──────────────────────────────────
# A single limit on every agent would cap the ONE build that is urgent at the
# same moment as the inference that is idle, and neither would get what it
# needed. Workload classes get their own weights instead:
#
#   agent        the thing you are talking to. Never starved.
#   build        nix builds. Spill to idle IO; they can wait.
#   inference    ollama. Bounded CPU share; a model that is too big for the box
#                should slow down, not take the root slice with it.
#   transcode    jpeg/vaapi work. Same class as inference: bounded, not excluded.
#   download     torrents and sync. Lowest priority of all, and the first thing
#                that gets throttled when the uplink matters.
#
# management      herdr, sshd, the agent that is driving, systemd itself.
#                 NOT limited, and NOT a kill target: see
#                 nixos/tests/kill-switch-targets.sh, which already asserts that
#                 management processes and their descendants are never swept.
#
# ── Why a focused module and not an edit to nixos/system.nix ────────────────
# nixos/system.nix and the host option composition are lane A's. This is a new
# capability with its own options, so it gets its own file and touches nothing
# of A's. Both are imported from config/system/default.nix, which is a shared
# import list — a four-line additive hunk, nothing more.
{
  config,
  lib,
  opts,
  pkgs,
  ...
}: let
  cfg = config.agentOps.resources;
  mkPolicyClass = defaults: lib.mkOption {
    default = {};
    type = lib.types.submodule {
      options = {
        cpuWeight = lib.mkOption {type = lib.types.ints.between 1 10000; default = defaults.cpuWeight;};
        ioWeight = lib.mkOption {type = lib.types.ints.between 1 10000; default = defaults.ioWeight;};
        ioLatencyTargetSec = lib.mkOption {type = lib.types.str; default = defaults.ioLatencyTargetSec;};
      };
    };
  };

  # ── The weight-class generators ────────────────────────────────────────────
  #
  # Generated from one table so the four classes cannot drift apart: a per-class
  # copy of these bodies is how `build` ends up idle-classed and `download`
  # best-effort.
  #
  # 🔴 THE WEIGHTS GO ON THE SLICE, NOT ON A PLACEHOLDER SERVICE.
  #
  # systemd applies a unit's resource settings to that unit's own cgroup. A
  # placeholder service that runs `true` and exits is weighted and then gone; a
  # real workload placed in `<parent>-build.slice` inherits the SLICE's settings
  # and nothing else. Weights on the service therefore bounded nothing while
  # looking as though they bounded something.
  mkClassSlice =
    name: description: policy: {
      systemd.user.slices.${name} = {
        inherit description;
        sliceConfig = {
          # Slice parentage comes from hyphenated names, not Slice= here.
          CPUWeight = policy.cpuWeight;
          IOWeight = policy.ioWeight;
          IOAccounting = true;
          TasksAccounting = true;
          MemoryAccounting = true;
        };
      };
    };

  mkClassSample =
    name: policy: {
      systemd.user.services.${name} = {
        description = "Sample unit proving ${name}.slice exists and is joinable";
        serviceConfig = {
          # `Slice=` is a [Service] directive for a SERVICE unit — unlike a slice
          # unit, whose hierarchy is encoded in its name. Putting it in either the top
          # level or a non-existent `sliceConfig` fails evaluation.
          Slice = "${name}.slice";
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
          # [Slice] has no IOSchedulingClass; that is a [Service] directive, so
          # it is applied by the class's sample unit rather than the slice.
          IOSchedulingClass = if policy.ioWeight <= 32 then "idle" else "best-effort";
        };
      };
    };
in {
  options.agentOps.resources = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Apply workload weights and record admission targets. Off by default so that
        enabling it is a decision made after calibration, not a side effect of
        this PR landing.
      '';
    };

    policy = lib.mkOption {
      type = lib.types.submodule {
        options = lib.mapAttrs (_: defaults: mkPolicyClass defaults) {
        # Relative weights, not CPU counts or percentages. They only affect
        # sibling cgroups under contention; 1024 does not mean one full CPU.
        # Record-only: interactive agents inherit their shell/workspace cgroup;
        # no real agent workload is assigned these weights by this module.
        agent = {
          cpuWeight = 1024;
          ioWeight = 1024;
          ioLatencyTargetSec = "50ms";
        };
        build = {
          cpuWeight = 128;
          # idle IO class: a build writes a lot and blocks nothing if delayed.
          ioWeight = 32;
          ioLatencyTargetSec = "500ms";
        };
        inference = {
          cpuWeight = 256;
          ioWeight = 128;
          ioLatencyTargetSec = "100ms";
        };
        transcode = {
          cpuWeight = 256;
          ioWeight = 128;
          ioLatencyTargetSec = "100ms";
        };
        download = {
          cpuWeight = 64;
          ioWeight = 16;
          ioLatencyTargetSec = "2s";
        };
        management = {
          cpuWeight = 2048;
          ioWeight = 2048;
          ioLatencyTargetSec = "10ms";
        };
        };
      };
      default = {};
      description = ''
        Per-workload relative CPU/IO weights, from 1 through 10000. Zero is
        invalid, not unlimited. Latency targets are recorded for calibration,
        not enforced by this module.
      '';
    };

    admission = lib.mkOption {
      type = lib.types.attrs;
      default = {
        # How many heavy classes MAY run at once. See the description: this is
        # recorded, not enforced.
        maxConcurrentInference = 1;
        maxConcurrentTranscode = 1;
        maxConcurrentDownloads = 2;
      };
      description = ''
        How many members of each heavy class MAY be resident at once.

        🔴 CONFIGURED, NOT ENFORCED. This module creates `%t/agent-ops/slots/`
        so the numbers are visible and a future wrapper has somewhere to put a
        slot file, but nothing here acquires a slot or refuses a workload. A
        fourth concurrent inference will run.

        Enforcing it needs an interceptor in each workload's start path — a
        systemd wrapper, or an ExecStartPre that takes a slot before exec — and
        those units belong to the media/travel lane and to whatever runs the
        models. Claiming a limit that does not exist is worse than recording one
        that does, so it is recorded and labelled as not enforced.
      '';
    };

    slice = lib.mkOption {
      type = lib.types.str;
      default = "agent-workload";
      description = ''
        Name of the parent slice, WITHOUT the `.slice` suffix: NixOS appends it.
        NOT "system.slice" and NOT "init.scope" — management must not compete
        with the workloads it is measuring, and a dedicated slice is how that is
        expressed without touching nixos/system.nix.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # ── The slices ─────────────────────────────────────────────────────────
      #
      # 🔴 TWO NIXOS SHAPES IN ONE FILE, and getting them wrong is silent:
      #
      #   * `systemd.user.slices."<key>"` generates `<key>.slice`. The option
      #     APPENDS the suffix, so a key of "agent-workload.slice" produces
      #     `agent-workload.slice.slice` — a unit nothing references, from a
      #     configuration that reads correctly in review. Keys below carry no
      #     suffix.
      #
      #   * `systemd.user.services."<name>"` is a NixOS submodule with `after`,
      #     `wantedBy`, `serviceConfig` and `sliceConfig`. It has no `After`,
      #     `Install`, `Slice`, `CPUWeight` or `IOWeight` options — those are Home
      #     Manager spellings, and using them fails EVALUATION. This module is
      #     off by default, so nothing caught that until it was evaluated with
      #     `enable = true`; nixos/tests/agent-operations now does exactly that.
      #
      # `description` is the one directive that legitimately sits at the top
      # level; everything else goes in the section it belongs to.

      assertions = [{
        assertion = builtins.match "[A-Za-z0-9_]+(-[A-Za-z0-9_]+)*" cfg.slice != null
          && !(builtins.elem cfg.slice ["system" "user" "init" "agentOpsManagement"]);
        message = "agentOps.resources.slice must be a dedicated valid user slice name without .slice";
      } {
        assertion = lib.all (name: let policy = cfg.policy.${name} or {}; in
          lib.all (key: let weight = policy.${key} or 0; in
            builtins.isInt weight && weight >= 1 && weight <= 10000
          ) ["cpuWeight" "ioWeight"]
        ) ["agent" "build" "inference" "transcode" "download" "management"];
        message = "agentOps.resources requires CPU/IO weights between 1 and 10000 for every class";
      }];

      # User scopes must opt into these slices. System workload services below
      # receive real weights; these sample units are not workload admission.
      systemd.user.slices.${cfg.slice} = {
        description = "Bounded workloads: builds, inference, transcoding, downloads";
        sliceConfig = {
          # The hyphenated slice name determines its parent automatically.
          # Weight for IO scheduling only; CPU accounting stays on the default
          # hierarchy so `systemd-cgtop` numbers remain comparable.
          IOWeight = cfg.policy.build.ioWeight;
          IOAccounting = true;
          TasksAccounting = true;
          MemoryAccounting = true;
        };
      };

      # An empty calibration sample, NOT protection for real operator/agent
      # processes. Process-target safety in kill-switch-targets.sh is separate
      # from cgroup membership and cannot establish OOM protection here.
      systemd.user.slices.agentOpsManagement = {
        description = "Empty management calibration slice (no agent membership)";
        sliceConfig = {
          CPUWeight = cfg.policy.management.cpuWeight;
          IOWeight = cfg.policy.management.ioWeight;
          # Applies to this empty sample only, not to the operator's session.
          ManagedOOMSwap = "kill";
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMPreference = "avoid";
          IOAccounting = true;
          TasksAccounting = true;
          MemoryAccounting = true;
        };
      };

      # Explicit no-op sample; it does not admit, launch or classify agents.
      systemd.user.services.agentOpsManager = {
        description = "Unapplied interactive-agent calibration sample";
        serviceConfig = {
          Slice = "agentOpsManagement.slice";
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.coreutils}/bin/true";
        };
      };

      # ── Admission slots ────────────────────────────────────────────────────
      #
      # 🔴 NOT ENFORCED — see the `admission` option description.
      systemd.user.tmpfiles.rules = [
        "d %t/agent-ops/slots 0755 ${opts.username} ${opts.username} -"
      ];

      environment.etc."agent-ops/resources.conf".text = ''
        # Generated by nixos/config/system/agent-ops/resources.nix.
        #
        # 🔴 THESE ARE DEFAULTS, NOT MEASUREMENTS. They have not been calibrated
        # against a load test on this hardware. They are chosen so that a mistake
        # costs throughput rather than availability. See docs/agent-operations.md,
        # "Calibrating the resource policy", before raising or lowering any.
        slice=${cfg.slice}
        # 🔴 CONFIGURED, NOT ENFORCED. See the `admission` option description.
        admission.enforced=false
        policy.agent.applied=false
        management.sampleOnly=true
        maxConcurrentInference=${toString cfg.admission.maxConcurrentInference}
        maxConcurrentTranscode=${toString cfg.admission.maxConcurrentTranscode}
        maxConcurrentDownloads=${toString cfg.admission.maxConcurrentDownloads}
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            name: v: ''
              class.${name}.cpuWeight=${toString v.cpuWeight}
              class.${name}.ioWeight=${toString v.ioWeight}
              class.${name}.ioLatencyTargetSec=${v.ioLatencyTargetSec}
            ''
          )
          cfg.policy)}
      '';

      # ── The sampler ────────────────────────────────────────────────────────
      #
      # 🔴 A USER TIMER, because the service it starts is a USER service. A
      # `systemd.timers.*` unit cannot start a user service, so the system timer
      # fired hourly into nothing.
      systemd.user.timers.agentOpsResources = {
        description = "Sample the per-class resource accounting";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "1h";
          AccuracySec = "1min";
          Persistent = false;
          Unit = "agentOpsResources.service";
        };
      };

      systemd.user.services.agentOpsResources = {
        description = "Sample per-slice CPU/IO accounting for the resource policy";
        serviceConfig = {
          # `agentOpsManagement.slice` is a real slice: it is what
          # systemd.user.slices.agentOpsManagement generates.
          Slice = "agentOpsManagement.slice";
          Type = "oneshot";
          # ONE string. `"a" "b"` in Nix is function application, not two
          # arguments, and it fails evaluation rather than producing a bad unit.
          ExecStart = "${pkgs.systemd}/bin/systemd-cgtop --batch --iterations=1";
          TimeoutStartSec = 30;
        };
      };
    })

    # One merge element per class: these are function calls, which cannot be
    # statements inside an attribute set.
    (lib.mkIf cfg.enable (mkClassSlice "${cfg.slice}-build" "Weight class for nix builds" cfg.policy.build))
    (lib.mkIf cfg.enable (mkClassSample "${cfg.slice}-build" cfg.policy.build))
    (lib.mkIf cfg.enable (mkClassSlice "${cfg.slice}-inference" "Weight class for model inference" cfg.policy.inference))
    (lib.mkIf cfg.enable (mkClassSample "${cfg.slice}-inference" cfg.policy.inference))
    (lib.mkIf cfg.enable (mkClassSlice "${cfg.slice}-transcode" "Weight class for transcoding" cfg.policy.transcode))
    (lib.mkIf cfg.enable (mkClassSample "${cfg.slice}-transcode" cfg.policy.transcode))
    (lib.mkIf cfg.enable (mkClassSlice "${cfg.slice}-download" "Weight class for downloads and sync" cfg.policy.download))
    (lib.mkIf cfg.enable (mkClassSample "${cfg.slice}-download" cfg.policy.download))

    # Apply weights to real services, not only `true` sample units. Children
    # inherit these cgroups; no arbitrary PID moves or agent termination.
    (lib.mkIf cfg.enable {
      systemd.services.nix-daemon.serviceConfig = {
        CPUWeight = cfg.policy.build.cpuWeight;
        IOWeight = cfg.policy.build.ioWeight;
        IOSchedulingClass = "idle";
      };
    })
    (lib.mkIf (cfg.enable && config.services.openssh.enable) {
      systemd.services.sshd.serviceConfig = {CPUWeight = cfg.policy.management.cpuWeight; IOWeight = cfg.policy.management.ioWeight;};
    })
    (lib.mkIf (cfg.enable && config.services.tailscale.enable) {
      systemd.services.tailscaled.serviceConfig = {CPUWeight = cfg.policy.management.cpuWeight; IOWeight = cfg.policy.management.ioWeight;};
    })
    (lib.mkIf (cfg.enable && config.services.ollama.enable) {
      systemd.services.ollama.serviceConfig = {CPUWeight = cfg.policy.inference.cpuWeight; IOWeight = cfg.policy.inference.ioWeight;};
    })
    (lib.mkIf (cfg.enable && config.services.jellyfin.enable) {
      systemd.services.jellyfin.serviceConfig = {CPUWeight = cfg.policy.transcode.cpuWeight; IOWeight = cfg.policy.transcode.ioWeight;};
    })
    (lib.mkIf (cfg.enable && opts.media.torrents.enable) {
      systemd.services.qbittorrent.serviceConfig = {CPUWeight = cfg.policy.download.cpuWeight; IOWeight = cfg.policy.download.ioWeight;};
    })
    (lib.mkIf (cfg.enable && config.services.syncthing.enable) {
      systemd.services.syncthing.serviceConfig = {CPUWeight = cfg.policy.download.cpuWeight; IOWeight = cfg.policy.download.ioWeight;};
    })
  ];
}
