# nixos/hosts/gs65/options.nix
#
# Overrides merged on top of the base ../../options.nix when building the
# "gs65" flake output. Only put values here that differ from the Legion —
# everything else (username, theme, editors, etc.) is shared.
{
  hostname = "gs65";

  # TODO: run `lspci | grep -E "VGA|3D"` on the GS65 and fill these in —
  # they will NOT match the Legion's bus IDs.
  intelBusId = "0:2:0";
  nvidiaBusId = "1:0:0";

  # TODO: confirm the root disk name (`lsblk`) if you ever run disko.nix
  # against this machine.
  deviceName = "nvme0n1";

  # The GS65 travels standalone — laptop panel only. The rule is name+position
  # only (no forced width/height) so mango uses the panel's native mode.
  # Override via local.nix when docked to externals.
  monitorrule = [
    "name:^eDP-1$,x:0,y:0,rr:0,vrr:1"
  ];

  # ── Travel laptop ──────────────────────────────────────────────────────────
  # "desktop" is the role: this machine is carried, docked and unplugged, so it
  # suspends when the lid shuts, the lid and idle keys behave like a laptop, and
  # nothing suppresses that. That IS the travel policy — there is deliberately
  # no separate "travel" role, because a machine that is not a server already
  # behaves like a laptop and an enum value with no behaviour of its own is how
  # a policy stops being readable (see nixos/lib/host-policy.nix).
  #
  # Stated explicitly rather than left to the default so the role of both
  # machines is visible in one place when reading a diff.
  role = "desktop";

  # The travel half of the policy that is per-host rather than per-role. Nothing
  # here suppresses suspend, lid handling or the desktop.
  #
  # batteryChargeLimit is deliberately left at the base default (null) rather
  # than given a value here: a cap is worth having on a machine that lives in a
  # bag, but this host's writable threshold has not been confirmed, and
  # config/system/battery.nix only reports what it actually achieved. Set it
  # to 60 once that has been checked on the machine — see
  # docs/headless-server.md § "Charge limits are hardware claims".
  acpi.acpiCall = false;

  # ── Boot-noise workarounds for defects seen on THIS machine ─────────────────
  #
  # Everything below is here because it was observed in this host's own boot
  # log (`journalctl -k -b`) or module tree (`zcat /proc/config.gz`), not
  # because it was seen on the Legion. The Legion has different firmware and
  # different input hardware, so none of it is inherited there.
  #
  # Mechanism for both lists is config/system/kernel.nix + nixos/options.nix.

  hostKernelParams = [
    # silences: psmouse serio1: synaptics: Unable to query device: -71
    #           input: PS/2 Synaptics TouchPad as /devices/platform/i8042/serio1/...
    #           psmouse serio1: Failed to enable mouse on isa0060/serio1
    #
    # WHY IT IS HAPPENING: the touchpad controller exposes an I2C-HID channel
    # AND a legacy PS/2 AUX channel, and the firmware keeps the AUX side
    # powered and answering just enough for the i8042 AUX port to pass its
    # loopback/toggle test. psmouse then binds to serio1 and probes it with the
    # Synaptics protocol, which gets a 0xFC (PS2_RET_ERR) — hence -EPROTO,
    # the -71 — because nothing functional is behind that port. (-71 is EPROTO,
    # not EILSEQ.)
    #
    # WHY IT IS SAFE: the real, working touchpad is the I2C-HID one —
    #   CUST0001:00 06CB:CDAD Touchpad
    #     on /devices/pci0000:00/0000:00:15.2/i2c_designware.1/i2c-2
    # and it is registered and working (input16/mouse3). The PS/2 ghost is not
    # in /proc/bus/input/devices at all, because it fails to initialise.
    # Checked on this machine before adding the parameter:
    #   * no TrackPoint, no "TPPS/2", no "PS/2 Generic Mouse" in
    #     /proc/bus/input/devices — every pointing device is USB or the I2C
    #     touchpad, so nothing on the AUX port is actually in use;
    #   * the AT keyboard is on serio0, and i8042_setup_kbd() runs regardless
    #     of this parameter, so "AT Translated Set 2 keyboard" is unaffected;
    #   * on resume i8042_controller_resume() re-enables whichever ports exist
    #     and skips the NULL one, so suspend/resume is unaffected.
    #
    # REVERSELESS ALTERNATIVES, all rejected on purpose:
    #   i8042.nomux      — only stops serio2-5 from being created; serio1 (the
    #                     AUX port) is still created and still probed. No effect.
    #   psmouse.proto=bare — skips the Synaptics probe so the message stops, but
    #                     serio1 then binds as a generic PS/2 mouse and you get
    #                     a phantom cursor instead of a boot message. Worse.
    #
    # RISK: a PS/2 mouse or TrackPoint plugged into this machine would stop
    # working. Re-evaluate if one is ever used.
    "i8042.noaux"
  ];

  hostBlacklistedKernelModules = [
    # silences: ACPI BIOS Error (bug): AE_AML_BUFFER_LIMIT, Field [P2__] ...
    #           ACPI Error: Aborting method \_SB.AWAC._GRT due to previous error
    #           acpi-tad ACPI000E:00: hctosys: unable to read the hardware clock
    #
    # WHAT IS ACTUALLY BROKEN: this is an MSI AMI BIOS bug, not a kernel one.
    # \_SB.AWAC is the ACPI Time and Alarm Device (ACPI000E) and _GRT is its
    # "Get Real Time" method. The firmware allocates a 112-bit (14-byte)
    # buffer and then reads a Field at bit offset 104, length 24 — 104+24=128,
    # past the end of what it allocated. ACPICA correctly refuses. The kernel
    # side expects a 16-byte record, so that 14-byte return would have been
    # rejected regardless.
    #
    # NO KERNEL PARAMETER FIXES THIS. acpi_osi= (this host already runs
    # acpi_osi=Linux and still sees it) only services the _OSI method, and
    # acpi_tad calls _GRT unconditionally; acpi=noirq, pci=noacpi etc. are
    # unrelated. The AML is malformed; it cannot be talked out of it.
    #
    # WHY BLACKLISTING IS THE FIX AND NOT JUST NOISE-COSMETICS: since the
    # February 2026 "ACPI: TAD: Add RTC class device interface" series,
    # acpi_tad registers an RTC-class device and — because it probes first —
    # claims rtc0, ahead of rtc_cmos. This kernel gates hctosys on a fixed
    # device name:
    #     CONFIG_RTC_HCTOSYS=y
    #     CONFIG_RTC_HCTOSYS_DEVICE="rtc0"
    # and drivers/rtc/class.c compares dev_name() against exactly that string.
    # So the chain is: broken acpi-tad grabs rtc0 -> hctosys reads rtc0 ->
    # _GRT fails -> "unable to read the hardware clock". The working CMOS RTC
    # sits there as rtc1 and is never used. The same gate makes RTC
    # systohc and suspend/resume drift correction inert too.
    #
    # OBSERVED, not assumed: `hwclock --show` returned "Cannot access the
    # Hardware Clock via any known method" and `timedatectl` returned
    # "Failed to read RTC: Input/output error". Both were caused by /dev/rtc0
    # being the broken TAD.
    #
    # COST: the ACPI TAD wake timers (/sys/.../ACPI000E:00/{ac,dc}_alarm).
    # This host suspends with /sys/power/mem_sleep = "s2idle [deep]", which
    # does not cut power to devices, so TAD alarms are not in the resume path
    # and were doing nothing anyway. acpi_tad is a modular driver here
    # (CONFIG_ACPI_TAD=m) and is not in the initrd, so a plain blacklist in the
    # main system is enough. With it gone, rtc_cmos becomes rtc0 and hctosys
    # gets a real clock.
    #
    # NOT VERIFIED: the DSDT was not decompiled (it is root-only), so the exact
    # ASL statement is inferred from the 112/104/24 numbers rather than read.
    # And this has not been boot-tested here — the "rtc_cmos becomes rtc0"
    # step follows from drivers/rtc/class.c plus the observed registration
    # order, not from an observed boot. Confirm with `timedatectl` after the
    # next reboot.
    "acpi_tad"

    # silences: nvidia-gpu 0000:01:00.3: i2c timeout error e0000000
    #           ucsi_ccg 0-0008: i2c_transfer failed -110
    #           ucsi_ccg 0-0008: ucsi_ccg_init failed - -110
    #           ucsi_ccg 0-0008: probe with driver ucsi_ccg failed with error -110
    #
    # WHAT IS ACTUALLY HAPPENING: the RTX 2080 exposes an auxiliary PCI
    # function 0000:01:00.3 with class 0x0c80 — its I2C master. The in-tree
    # driver drivers/i2c/busses/i2c-nvidia-gpu.c matches on vendor + class
    # with PCI_ANY_ID for the device ID, registers "NVIDIA GPU I2C adapter",
    # and instantiates a UCSI client at address 0x08 through
    # i2c_new_ccgx_ucsi(). The generic ucsi_ccg driver matches on the type
    # string "ccgx-ucsi" with no DMI or PCI check, probes it, the controller
    # never completes a cycle, and -ETIMEDOUT (-110) propagates out. The
    # driver's own comment admits cards that should not bind will "timeout".
    #
    # This is NOT NVIDIA DDC-over-I2C / EDID — that is separate and is handled
    # by the proprietary driver and DRM aux. Nothing display-related is on this
    # path.
    #
    # WHY THE BUS DRIVER AND NOT ucsi_ccg: blacklisting ucsi_ccg alone stops
    # three of the four lines but leaves the first one, because the I2C
    # adapter is still registered and still instantiated; only ucsi_ccg would
    # stop being probed. Blocking i2c_nvidia_gpu removes the adapter, so there
    # is nothing left for ucsi_ccg to bind to and all four lines go. ucsi_ccg
    # stays enabled for a CCG device that is actually wired, unlike
    # ucsi_acpi which is a different transport entirely.
    #
    # COST: on THIS host there is none to speak of. ucsi_ccg's probe already
    # fails, so no Type-C connector is registered today — /sys/class/typec/port
    # does not exist, and nothing was working through this path to lose. The
    # real one also matters: a ucsi_ccg that DOES bind to a half-dead CCG can
    # add a multi-second-to-60-second suspend/resume hang (FS#65077), which
    # this removes.
    #
    # RISK: if this laptop's USB-C port turns out to be served by the dGPU's
    # CCG rather than the PCH, DP Alt-Mode from that port would stop working.
    # It is not working now, so this is not a regression — but it was not
    # verified which of the two owns the port either.
    "i2c_nvidia_gpu"
  ];

  # Impermanence is OFF (base default). Flip to true to wipe the root
  # subvolume every boot — see docs/impermanence-migration.md.
  enablePersistence = false;

  # GS65 stealth is not powerful enough to run big models
  enableOllama = false;

  # ── Travel ─────────────────────────────────────────────────────────────────
  #
  # The three things this machine needs in order to be useful away from a desk,
  # and nothing else. `role = "desktop"` above already means: suspends on lid
  # close, no lingering, no exit node, no server policy. None of it is
  # overridden here.
  travel.enable = true;

  # MagicDNS is intentionally not used by this configuration. Resolve the
  # Legion's current tailnet address through an explicit host entry instead.
  tailnetHosts = {
    "100.71.67.69" = ["legion"];
  };

  # Pin the Legion's OpenSSH host key. It was read directly from the Legion's
  # /etc/ssh/ssh_host_ed25519_key.pub; travel.nix uses it only for the ordinary
  # OpenSSH connection on port 2222.
  travel.serverHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ4mTQwCyuqFDzF69fuPiJjyG2S/4OUTMlgjlEIswUZD root@sonny-laptop";

  # ── Offload builds to the Legion ───────────────────────────────────────────
  #
  # `remoteBuilder.port = 2222` (the base default) is the load-bearing part.
  # Port 22 is Tailscale SSH: it authenticates with a Tailscale identity and
  # bypasses authorized_keys entirely, so a key-based Nix builder pointed at 22
  # fails in a way that reads as a Nix problem rather than a port problem. See
  # docs/media-travel.md § "The builder".
  #
  # The private half lives in ~/.ssh/nixbuilder on this client. Nix's daemon
  # runs as root and can read it; the public half is authorized only on Legion.
  remoteBuilder.sshKey = "/home/sonny/.ssh/nixbuilder";
  # The matching public half is set in hosts/legion/options.nix.
  remoteBuilder.enable = true;
  remoteBuilder.authorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBma7L7cRLEXSfdFHeCtwBEOg931x2uKYnkWM9Aa0vTh gs65-nixbuilder";

  # ── Private media: deliberately OFF ─────────────────────────────────────────
  #
  # 🔴 OFF rather than "configured and waiting". This lane's rule is that a
  # service stays disabled until it is configured, and none of the three can be
  # half-configured safely:
  #
  #   jellyfin   its first-run wizard CREATES the administrator account, and
  #              until one exists any tailnet device can reach the wizard and
  #              claim it. Enabling it from a repository is enabling an open
  #              admin UI, not configuring one.
  #   torrents   needs a WireGuard credential that cannot be generated here; a
  #              private key in a git repository is a credential in history.
  #   syncthing  propagates deletions, and must not be switched on before the
  #              folder list has been chosen deliberately.
  #
  # The modules, their options, their refusals and their tests are all present
  # and evaluated. What is missing is the operator's provisioning, which is a
  # deployment step rather than a reviewable change. docs/media-travel.md §
  # "Turning media on" is the checklist.
}
