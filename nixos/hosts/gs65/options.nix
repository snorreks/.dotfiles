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

  # Impermanence is OFF (base default). Flip to true to wipe the root
  # subvolume every boot — see docs/impermanence-migration.md.
  enablePersistence = false;

  # GS65 stealth is not powerful enough to run big models
  enableOllama = false;
}
