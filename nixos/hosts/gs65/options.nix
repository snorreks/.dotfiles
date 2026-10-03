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

  # Impermanence is OFF (base default). Flip to true to wipe the root
  # subvolume every boot — see docs/impermanence-migration.md.
  enablePersistence = false;

  # GS65 stealth is not powerful enough to run big models
  enableOllama = false;
}
