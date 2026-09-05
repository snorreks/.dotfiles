# nixos/hosts/gs65/default.nix
# Host module for the MSI GS65 Stealth.
{...}: {
  imports = [
    ./hardware.nix
    ./fan-control.nix
  ];

  # Disable Panel Self Refresh on the GS65's eDP panel to prevent the
  # panel from getting stuck showing a stale (black) frame after the
  # compositor stops sending updates — e.g., on a locked idle screen.
  # The GS65 has persistent i915 atomic update failures on pipe A during
  # normal desktop use (kernel: *ERROR* Atomic update failure on pipe A)
  # which suggest a buggy PSR implementation on this Coffee Lake panel.
  # PSR costs a little idle battery but prevents hard-lock scenarios.
  boot.kernelParams = ["i915.enable_psr=0"];
}
