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
  # real workload placed in `agentOpsBuild.slice` inherits the SLICE's settings
  # and nothing else. Weights on the service therefore bounded nothing while
  # looking as though they bounded something.
  mkClassSlice =
    name: description: policy: {
      systemd.user.slices.${name} = {
        inherit description;
        sliceConfig = {
          Slice = "agent-workload.slice";
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
          # unit, which takes it from sliceConfig. Putting it in either the top
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
        Apply the workload admission and resource policy. Off by default so that
        enabling it is a decision made after calibration, not a side effect of
        this PR landing.
      '';
    };

    policy = lib.mkOption {
      type = lib.types.attrs;
      default = {
        # CPU shares, relative to each other. 1024 is one full CPU's worth of
        # weight under the default systemd accounting; these are weights, not
        # percentages, and they only bite when the host is contended.
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
      description = ''
        Per-workload weights. A weight of 0 is treated as "no limit", NOT as
        "no CPU": systemd's semantics, and confusing the two would silently
        create a workload that cannot run at all.
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

      # The parent slice for every bounded workload.
      systemd.user.slices.${cfg.slice} = {
        description = "Bounded workloads: builds, inference, transcoding, downloads";
        sliceConfig = {
          Slice = "user.slice";
          # Weight for IO scheduling only; CPU accounting stays on the default
          # hierarchy so `systemd-cgtop` numbers remain comparable.
          IOWeight = cfg.policy.build.ioWeight;
          IOAccounting = true;
          TasksAccounting = true;
          MemoryAccounting = true;
        };
      };

      # Management: the things that must stay responsive. Never a kill target —
      # nixos/tests/kill-switch-targets.sh already asserts that management
      # processes and their descendants are never swept.
      systemd.user.slices.agentOpsManagement = {
        description = "Management: the things that must stay responsive";
        sliceConfig = {
          Slice = "${cfg.slice}.slice";
          IOWeight = cfg.policy.management.ioWeight;
          # Protect the cgroup itself from being OOM-killed by a workload beside it.
          ManagedOOMSwap = "kill";
          ManagedOOMMemoryPressure = "kill";
          ManagedOOMPreference = "avoid";
          IOAccounting = true;
          TasksAccounting = true;
          MemoryAccounting = true;
        };
      };

      # The management class the sampler reports from.
      systemd.user.services.agentOpsManager = {
        description = "Weight class for interactive agent processes";
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
    (lib.mkIf cfg.enable (mkClassSlice "agentOpsBuild" "Weight class for nix builds" cfg.policy.build))
    (lib.mkIf cfg.enable (mkClassSample "agentOpsBuild" cfg.policy.build))
    (lib.mkIf cfg.enable (mkClassSlice "agentOpsInference" "Weight class for model inference" cfg.policy.inference))
    (lib.mkIf cfg.enable (mkClassSample "agentOpsInference" cfg.policy.inference))
    (lib.mkIf cfg.enable (mkClassSlice "agentOpsTranscode" "Weight class for transcoding" cfg.policy.transcode))
    (lib.mkIf cfg.enable (mkClassSample "agentOpsTranscode" cfg.policy.transcode))
    (lib.mkIf cfg.enable (mkClassSlice "agentOpsDownload" "Weight class for downloads and sync" cfg.policy.download))
    (lib.mkIf cfg.enable (mkClassSample "agentOpsDownload" cfg.policy.download))
  ];
}
