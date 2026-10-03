# /config/system/kernel.nix
#
# The kernel, the modules that have to agree with it, and the per-host kernel
# command line.
{
  pkgs,
  config,
  opts,
  lib,
  ...
}: let
  acpi = opts.acpi;

  # Per-host kernel parameters, built from the per-host options rather than
  # declared as one list for both machines.
  #
  # `boot.kernelParams` is a `types.listOf types.str`: a parameter is either in
  # it for every host or for none. That is why "keep acpi_osi=Linux on the
  # server, drop it on the travel laptop" was not expressible before — the two
  # machines had to agree on the whole command line.
  #
  # ── i915.enable_guc, and why its value changed ────────────────────────────
  # The old comment here said:
  #
  #   "OPTIMIZATION: Enables GuC (Graphics uController) on the Intel iGPU.
  #    Offloads scheduling and low-level tasks from the CPU to the iGPU,
  #    improving performance and power efficiency. '2' enables GuC only."
  #
  # That description of GuC is from before GuC stopped being a scheduling
  # decision, and it no longer describes what the parameter does. What the
  # parameter does NOW, on the kernel this configuration actually boots, is
  # visible in its own boot log:
  #
  #   # journalctl -b | grep enable_guc
  #   kernel: Command line: ... i915.enable_guc=2 nvidia.NVreg_… acpi_osi=Linux …
  #   kernel: Setting dangerous option enable_guc - tainting kernel
  #
  # "Tainting kernel" is not a warning, it is the kernel marking itself as
  # having been started with options whose effects the developers cannot vouch
  # for — which then propagates into module signing, into supportability, and
  # into anything that checks whether the running kernel is stock. Meanwhile
  # /sys/module/i915/parameters/enable_guc is not even writable on this kernel:
  # the i915 driver no longer offers it as a runtime module parameter, so the
  # value on the command line is not reaching a knob. GuC and HuC firmware are
  # loaded by the driver itself now, unconditionally; the parameter is a
  # leftover from the era when loading GuC was optional.
  #
  # So the default here is to OMIT it. That is a change of value, and it is not
  # a blind one: it is made against the kernel log on the actual machine and
  # against the actual sysfs interface, both of which say the parameter is no
  # longer a knob. It stays available (opts.acpi.i915Guc) for anyone who is on a
  # kernel where it still is one, and the honest remaining question — "does the
  # iGPU still load its GuC/HuC firmware without it?" — is a hardware
  # observation, listed as pending in docs/headless-server.md rather than
  # claimed here.
  hostKernelParams =
    lib.optional (acpi.acpiOsi != null) "acpi_osi=${acpi.acpiOsi}"
    ++ lib.optional (acpi.i915Guc != null) "i915.enable_guc=${toString acpi.i915Guc}";
in {
  boot = {
    # ── Which kernel ─────────────────────────────────────────────────────────
    #
    # nixpkgs' newest kernel, from whatever revision flake.lock currently pins.
    #
    # This is deliberately NOT being changed here. The known hazard is real (see
    # README "NVIDIA driver/library version mismatch after a kernel bump") and
    # it is not the same as "our kernel is too new": the NVIDIA driver and
    # acpi_call are both taken from `config.boot.kernelPackages`, so a kernel
    # bump moves the driver WITH it and the mismatch only appears when the
    # running kernel is older than the modules the new activation installed —
    # which is a reboot-pending state, not a broken configuration.
    #
    # Choosing a different kernel FAMILY is a hardware decision, not an
    # evaluation one. Downgrading "to be safe" would trade a known, documented
    # property (latest stable, newest driver) for an unknown one, on a laptop
    # whose ACPI and fan control are already deep in vendor-firmware
    # territory. If a family change is ever needed it should be driven by a
    # specific failure, validated on this hardware with the out-of-tree modules
    # in play, and recorded here with the reason.
    kernelPackages = pkgs.linuxPackages_latest;

    # Kernel modules loaded at boot. Per host (opts.acpi.acpiCall) because the
    # only entry was one nothing in this configuration calls: acpi_call is a
    # userspace-callable ACPI method interface, needed by vendor tools that do
    # not exist here. Loading a module nothing uses is a small amount of attack
    # surface and a small amount of boot time, for no benefit.
    kernelModules = lib.optional acpi.acpiCall "acpi_call";

    # extraModulePackages is what makes an out-of-tree module follow the kernel
    # this host actually boots. acpi_call MUST come from config.boot.kernelPackages
    # and never from the top-level `pkgs`: a module built against a different
    # kernel refuses to load with an ENOEXEC vermagic error, and on a server
    # that error happens after the boot you needed the machine for.
    extraModulePackages =
      with config.boot.kernelPackages;
      lib.optional acpi.acpiCall acpi_call;

    # Prevent conflicting drivers from loading.
    blacklistedKernelModules = [
      "nouveau" # The open-source NVIDIA driver, which conflicts with the proprietary one.
    ];

    # Low-level kernel module configuration.
    extraModprobeConfig = ''
      # Ensure nouveau is fully disabled to prevent any conflicts with the NVIDIA driver.
      blacklist nouveau
      options nouveau modeset=0
    '';

    # ── Kernel boot parameters (systemd-boot) ────────────────────────────────
    kernelParams =
      [
        # Reduces boot message verbosity for a cleaner visual boot.
        "quiet"

        # STABILITY: recommended for laptops that suspend/sleep on Wayland.
        # Prevents the NVIDIA driver from discarding video memory on suspend,
        # which can lead to applications (or the entire session) crashing upon
        # resume. Kept on the travel laptop, which DOES suspend.
        #
        # On a server role it costs nothing to keep: the machine never suspends,
        # and the parameter is inert rather than wrong. Removing it would be a
        # change nobody can observe on this host, which is not a reason to make
        # it.
        "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
      ]
      ++ hostKernelParams;

    # --- Kernel System Controls (Sysctl) ---
    kernel.sysctl = {
      # Increases the maximum number of memory map areas a process can have.
      # Required by many modern games and applications running under Wine/Proton.
      "vm.max_map_count" = 262144;

      # Sets kernel tendency to swap. 10 is a good value for desktops/laptops
      # with ample RAM, telling it to avoid swapping unless necessary. Default is 60.
      "vm.swappiness" = 10;

      # Drastically increase inotify watcher limits.
      # Kitty's __watch_widget__ kitten recursively watches /etc/xdg for config
      # changes; on NixOS this tree is enormous (thousands of store symlinks),
      # easily consuming 500k+ watches. Modern tooling (TypeScript LSP, Biome,
      # Tailwind, Firebase emulators) also uses many watchers.
      # 2 million is the standard recommendation for NixOS dev environments.
      "fs.inotify.max_user_watches" = 2097152;
      # Raise max queued events to match the higher watch ceiling.
      "fs.inotify.max_queued_events" = 65536;
    };
  };

  # ── Service deadlines ──────────────────────────────────────────────────────
  #
  # REMOVED: systemd.settings.Manager.DefaultTimeoutStopSec = "10s" and
  # DefaultTimeoutStartSec = "30s".
  #
  # Those were global manager defaults, set to make shutdown snappy by not
  # waiting for a service that might be wedged. What they actually did was
  # bound EVERY service on the machine, including the ones whose work is
  # legitimately slow:
  #
  #   * nix-daemon writing a multi-gigabyte ollama-cuda closure into the store
  #     gets SIGKILLed at 30s, leaving a partial store path behind;
  #   * tailscaled or dnscrypt-proxy waiting for a link that has not come up is
  #     killed rather than being allowed to finish;
  #   * a service that is stopping and is mid-write is killed mid-write, which
  #     is how "shutdown was fast" turns into "a journal was truncated".
  #
  # systemd's own defaults (90s stop, 90s start) are not generous either, so the
  # replacements below are per-service, on the units that are actually known to
  # be slow here, each with a reason. Everything else keeps the systemd default,
  # which is the honest value for a unit nobody has measured.
  #
  # Net effect on shutdown: a genuinely wedged unit now takes the systemd
  # default (90s) to be killed rather than 10s. That is the correct direction —
  # the old value bought speed by destroying work, and bought it for everyone.
  systemd.services = {
    # The nix daemon's writes are long, large and interruptible; letting one
    # finish is worth more than a tidy shutdown log.
    nix-daemon.serviceConfig.TimeoutStopSec = "10min";

    # Both of these wait on a network link. They retry forever (see
    # networking.nix), so a stop deadline is the only thing that ends them, and
    # it should be long enough for a clean close of an established connection.
    tailscaled.serviceConfig.TimeoutStopSec = "1min";
    dnscrypt-proxy.serviceConfig.TimeoutStopSec = "1min";
  };

  # Disables a Systemd service that tries to manage the screen backlight via NVIDIA.
  # On most laptops, this is handled by other drivers, and this service just
  # produces harmless but annoying error messages in the journal.
  systemd.services."systemd-backlight@backlight:nvidia_0".enable = false;

  # --- Recommended User-space Tools ---
  # These are not kernel modules, but command-line tools that you were including.
  # This is the correct place to install them for system-wide availability.
  environment.systemPackages = [
    config.boot.kernelPackages.cpupower
  ];
}
