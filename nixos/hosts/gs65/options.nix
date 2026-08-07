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

  # The GS65 travels standalone most of the time — default to laptop-only.
  # Flip to true (or override via local.nix) when it's docked to externals.
  enableExternalMonitors = false;
}
